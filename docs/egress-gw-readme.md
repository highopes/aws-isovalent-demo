# Egress Gateway HA

本文记录本项目中 Isovalent Cilium Enterprise Egress Gateway HA 的自动化部署、检查、修改、故障测试与拆除方式。

## 当前目标

- 集群：`k8s-demo-0`，context `k8s-demo-0-0`
- 目标服务：同 VPC 的 `test-server-01`
- Echo Server 私网地址：`172.31.38.183`
- Egress Gateway policy 模板：`egress-gw-policy-ha.yaml`
- 实际部署文件：`egress-gw-policy-ha-0.yaml`
- 业务 Namespace：`starwar`
- 流量来源：`xwing`，标签 `org=alliance`
- 对照 Pod：`tiefighter`，标签 `org=empire`

## 当前部署结果

本次部署选择的两个 gateway 节点：

- `ip-172-31-38-41.ap-southeast-1.compute.internal`，AZ `ap-southeast-1a`，gateway IP `172.31.38.41`
- `ip-172-31-26-129.ap-southeast-1.compute.internal`，AZ `ap-southeast-1b`，gateway IP `172.31.26.129`

剩余业务节点：

- `ip-172-31-10-62.ap-southeast-1.compute.internal`，AZ `ap-southeast-1c`

当前 demo Pod：

- `xwing`：`172.31.4.48`
- `tiefighter`：`172.31.7.3`

当前 Echo Server 返回说明：

- `xwing` 连续访问时，Echo Server 看到的源 IP 在 `172.31.26.129` 与 `172.31.38.41` 之间切换，并返回 `Access granted`，说明 Egress Gateway HA 与 Remote Outpost allowlist 都已生效。
- `tiefighter` 访问时，Echo Server 看到的源 IP 是 `172.31.7.3`，说明未匹配 policy 的 Pod 保持普通路径。
- `tiefighter` 会返回 `Access denied`，因为 Remote Outpost 的 `ALLOWED_IP` 只包含 `172.31.26.129,172.31.38.41`。

## 配置项

`kup.conf` 中默认启用 Egress Gateway HA：

```bash
EGRESS_GW_ENABLE="true"
EGRESS_GW_HA_ENABLE="true"
EGRESS_GW_NAMESPACE="starwar"
EGRESS_GW_POLICY_NAME="outpost-ha"
EGRESS_GW_DESTINATION_CIDRS="172.31.38.183/32"
EGRESS_GW_EGRESS_CIDRS=""
EGRESS_GW_AZ_AFFINITY="localOnlyFirst"
EGRESS_GW_NODE_LABEL_KEY="egress-gw"
EGRESS_GW_NODE_LABEL_VALUE="true"
EGRESS_GW_NODE_NAMES=""
EGRESS_GW_ECHO_SERVER_PORT="18080"
EGRESS_GW_REMOTE_OUTPOST_AUTOCONFIG="true"
EGRESS_GW_REMOTE_OUTPOST_INSTANCE_NAME="test-server-01"
EGRESS_GW_REMOTE_OUTPOST_CONTAINER_NAME="remote-outpost"
EGRESS_GW_REMOTE_OUTPOST_IMAGE="quay.io/isovalent-dev/egressgw-whatismyip:latest"
EGRESS_GW_REMOTE_OUTPOST_HOST_PORT="18080"
EGRESS_GW_REMOTE_OUTPOST_CONTAINER_PORT="8000"
```

说明：

- `EGRESS_GW_ENABLE=false` 会关闭并清理本 demo 的 Egress Gateway policy、`starwar` namespace 和 gateway 标签。
- `EGRESS_GW_HA_ENABLE=false` 会保留普通 Cilium Egress Gateway，但只选择 1 个 gateway 节点。
- `EGRESS_GW_EGRESS_CIDRS` 留空时，Cilium 使用 gateway 节点默认路由接口地址作为出口源 IP。
- 如果要演示 Isovalent Egress Gateway IPAM，可把 `EGRESS_GW_EGRESS_CIDRS` 设置为可路由且已正确规划的 CIDR，例如 `"172.31.x.y/31"`。在 AWS 上不要随便填未分配给 ENI 或不可路由的地址。
- `EGRESS_GW_REMOTE_OUTPOST_AUTOCONFIG=true` 时，脚本会通过 SSM 重启 `test-server-01` 上的 `remote-outpost` 容器，把所选 gateway node IP 写入 `ALLOWED_IP`。如果设置了 `EGRESS_GW_EGRESS_CIDRS`，脚本会跳过该自动配置，避免把 node IP 误写为 allowlist。

## 部署

一键部署或重放：

```bash
./kup
```

脚本会完成：

1. 渲染 Cilium values，启用 `egressGateway.enabled=true`。
2. 启用 `enterprise.egressGatewayHA.enabled=true`。
3. 在 feature gate 中批准 `EgressGatewayIPv4` 和 `EgressGatewayHA`。
4. 自动选择两个不同 AZ 的 Ready 节点作为 gateway。
5. 给 gateway 节点打标签：

```bash
egress-gw=true
io.cilium/egress-gateway=true
```

6. 渲染并应用 `egress-gw-policy-ha-0.yaml`。
7. 在 `starwar` namespace 部署 `xwing` 与 `tiefighter` netperf Pod。
8. Cilium Helm upgrade 后，脚本会滚动重启 Cilium agent，确保 feature gate 和 datapath 配置生效。
9. 通过 SSM 更新 `test-server-01` 上的 Remote Outpost allowlist：

```bash
docker stop remote-outpost
docker rm remote-outpost
docker run -d \
  --name remote-outpost \
  --restart unless-stopped \
  -p 18080:8000 \
  -e ALLOWED_IP=<gateway-node-ip-1>,<gateway-node-ip-2> \
  quay.io/isovalent-dev/egressgw-whatismyip:latest
```

## 检查

查看 Cilium 功能是否启用：

```bash
kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'enable-egress-gateway|enable-ipv4-egress-gateway-ha|feature-gates-approved'
```

查看 gateway 节点与 zone：

```bash
kubectl get nodes -L egress-gw,io.cilium/egress-gateway,topology.kubernetes.io/zone
```

查看 demo Pod 调度位置：

```bash
kubectl -n starwar get pod -owide
```

查看 policy：

```bash
kubectl get isovalentegressgatewaypolicy outpost-ha -o yaml
```

可选：查看 Cilium egress BPF 表：

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf egress list
```

在当前 Isovalent Cilium Enterprise 1.18.7 HA 模式下，该命令可能返回 `No entries found`，即使 Egress Gateway 已经工作。以 `IsovalentEgressGatewayPolicy.status` 中的 `activeGatewayIPs` / `healthyGatewayIPs` 和 Echo Server 看到的源 IP 作为主要判断依据。

## 演示访问

先查看两个 Pod 的 IP：

```bash
kubectl -n starwar get pod xwing tiefighter -owide
```

从 `xwing` 访问 Echo Server：

```bash
kubectl -n starwar exec xwing -- curl --max-time 2 http://172.31.38.183:18080
```

循环观察：

```bash
for i in $(seq 1 10); do
  kubectl -n starwar exec xwing -- curl --max-time 2 http://172.31.38.183:18080
done
```

对照访问：

```bash
kubectl -n starwar exec tiefighter -- curl --max-time 2 http://172.31.38.183:18080
```

预期：

- `xwing` 会匹配 `org=alliance`，流量经 Egress Gateway。
- `tiefighter` 不匹配策略，应保持普通路径。
- Echo Server 的 `allowed_ip` 应允许 Egress Gateway 出口源 IP，而不是直接允许 `xwing` Pod IP。留空 `EGRESS_GW_EGRESS_CIDRS` 时，这通常是 gateway 节点默认路由接口 IP；设置 `EGRESS_GW_EGRESS_CIDRS` 后，则应允许该 CIDR 中被分配的 egress IP。
- 当前 Echo Server 监听端口是 `18080`。

## 修改

修改目标服务器 CIDR：

```bash
EGRESS_GW_DESTINATION_CIDRS="172.31.38.183/32"
```

固定 gateway 节点：

```bash
EGRESS_GW_NODE_NAMES="node-a,node-b"
```

只启用普通 Egress Gateway，不启用 HA：

```bash
EGRESS_GW_ENABLE="true"
EGRESS_GW_HA_ENABLE="false"
```

完全关闭并清理 demo：

```bash
EGRESS_GW_ENABLE="false"
```

改完后执行：

```bash
./kup
```

## 手工拆除

只拆 Egress Gateway demo，不动其他演示组件：

```bash
kubectl delete isovalentegressgatewaypolicy outpost-ha --ignore-not-found
kubectl delete ciliumegressgatewaypolicy outpost-ha --ignore-not-found
kubectl delete namespace starwar --ignore-not-found
kubectl label nodes --all egress-gw- io.cilium/egress-gateway- --overwrite
```

如果还要关闭 Cilium 的 Egress Gateway 功能，把 `kup.conf` 改为：

```bash
EGRESS_GW_ENABLE="false"
```

然后执行：

```bash
./kup
```

## 故障测试

查看当前 gateway：

```bash
kubectl get nodes -l egress-gw=true -owide
```

在 AWS EKS 中不建议直接暂停或关停节点来做演示，除非确认不会影响其他功能。更温和的方式是临时移除某个 gateway 节点标签：

```bash
kubectl label node <gateway-node-name> egress-gw- io.cilium/egress-gateway-
```

然后观察：

```bash
for i in $(seq 1 10); do
  kubectl -n starwar exec xwing -- curl --max-time 2 http://172.31.38.183:18080
done
```

恢复标签：

```bash
kubectl label node <gateway-node-name> egress-gw=true io.cilium/egress-gateway=true --overwrite
```

## 参考点

- Cilium Egress Gateway 需要 `kubeProxyReplacement=true` 与 `bpf.masquerade=true`。
- Isovalent Egress Gateway HA 使用 `IsovalentEgressGatewayPolicy` 与 `egressGroups`。
- `azAffinity=localOnlyFirst` 会优先选择与源 Pod 同 AZ 的 gateway；如果该 AZ 没有可用 gateway，会回退到其他 AZ。
