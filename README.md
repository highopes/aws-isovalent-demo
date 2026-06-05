# ISOVALENT Enterprise Platform 演示环境一键部署（AWS EKS）

本项目用于在 **AWS EKS（ap-southeast-1 等区域）** 快速拉起一套可演示的 Isovalent Enterprise Platform 环境：  
- EKS 集群（Control Plane + Managed Node Group）
- Cilium Enterprise（含 Hubble / Timescape 集成）
- Cilium Enterprise Egress Gateway HA（默认启用，支持 zone-aware 出口选择）
- kube-prometheus-stack（用于采集与可视化）
- OpenTelemetry Demo（用于演示应用与可观测性）
- Tetragon Enterprise + Tetragon Policy Ruleset（TPR）并对噪声进行优化
- 定制化AlertRule示例以及演示攻击的靶机应用
- 在每个 EKS 节点自动安装 Splunk Universal Forwarder（UF），把 Tetragon 日志/告警转发到 Splunk Enterprise
- 本项目不包含Splunk Enterprise和非Kubernetes的单机的安装，这部分请另行参考安装文档

> 目标：**不演示时关机/停用资源**，演示时快速恢复；并将所有 YAML 以“本地模板 + 变量渲染”的方式管理，方便构建多个集群时复用。

---

## 原理概览

### 1) 模板化渲染
- 所有 Kubernetes / Helm values / eksctl 配置均以 **模板文件**保存在 `~/aws/` 下。
- `kup` 执行时读取 `kup.conf`，把模板中的 `${VAR}` 变量替换为实际值，生成一份“已渲染”的部署文件：
  - 输出文件名格式：`<模板名>-<cluster-id>.yaml`  
  - 同时在终端打印渲染后的内容，方便审计与回溯。

### 2) 保持 EKS 创建逻辑稳定
- `kup` 的 EKS 创建与 NodeGroup 创建过程保持简洁：  
  - `eksctl create cluster -f cluster-<id>.yaml`  
  - `eksctl create nodegroup -f nodegroup-<id>.yaml`
- 避免在 NodeGroup 创建阶段引入不必要的 IAM / LaunchTemplate / UserData 改动，从而降低 “Instances failed to join the kubernetes cluster” 风险。

### 3) Splunk 联通与节点时区通过 AWS API 自动化（可选）
- **Security Group**：可自动把 Splunk EC2 的 SG 入站规则打开（TCP/9997 或你指定端口），来源为 EKS Cluster Security Group。
- **节点时区**：使用 AWS SSM 在所有节点上执行 `timedatectl set-timezone Asia/Singapore`。
- **UF 安装**：使用 AWS SSM 执行脚本，在每个节点上安装并配置 UF（自动识别 `x86_64` / `aarch64`），并监控 Tetragon 日志路径。

---

## 项目结构与文件说明

请自行定义项目的所有文件所在的本地工作目录。

- `kup`  
  主脚本：一键创建 EKS 并完成组件安装（Prometheus、Cilium、Otel Demo、Tetragon、TPR、可选 UF）。

- `kup.conf`  
  配置文件：集中管理变量（集群名、id、节点规格、Splunk 地址、版本号等）。  
  `kup` **不接收命令行参数**，只读该配置文件。

- 模板文件（必须）
  - `cluster.yaml`：eksctl ClusterConfig 模板
  - `nodegroup.yaml`：eksctl NodeGroup 模板
  - `cilium-enterprise-values.yaml`：Cilium Enterprise Helm values 模板
  - `egress-gw-policy-ha.yaml`：Egress Gateway HA 演示资源与策略模板
  - `netcheck.yaml`：连通性验证 DaemonSet 模板
  - `otel-demo-allow-all.yaml`：Otel demo 基础放行策略模板
  - `otel-demo-l7-visibility.yaml`：Otel demo L7 可视化策略模板
  - `tetragon.yaml`：Tetragon Enterprise Helm values 模板
  - `tpr-values.yaml`：TPR Helm values 模板

- 运行时生成文件（自动产生，无需手工编辑）
  - `cluster-<id>.yaml`, `nodegroup-<id>.yaml`, `cilium-enterprise-values-<id>.yaml`, ...  
  这些是模板渲染后的“最终部署文件”，脚本会打印并用于实际安装。
  - `egress-gw-policy-ha-<id>.yaml`：Egress Gateway HA 渲染后的实际部署文件。

- 自行定义的各类策略文件
  - 'custom-....yaml'等，作为示例提供了一个AlertRule自定义规则策略

---

## 前置条件

### 账号与网络
- AWS 账号已配置好权限（可创建 EKS、EC2、CloudFormation、IAM、SSM、EC2 Security Group 等）并已经完成命令行登录aws login。
- Splunk Enterprise EC2 与 EKS 在**同账号同 Region**，并且在同一个 VPC（脚本会校验 VPC 一致性）。

### 本地工具
在执行 `kup` 的机器上需要安装并配置：
- `aws` CLI（已 `aws configure` 或使用环境变量/角色）
- `eksctl`
- `kubectl`
- `helm`
- `python3`

### Helm 仓库可访问
- `https://helm.isovalent.com`
- `https://prometheus-community.github.io/helm-charts`
- `https://open-telemetry.github.io/opentelemetry-helm-charts`

---

## 安装方法

### 1) 准备目录
比如工作目录定义为~/aws
```bash
mkdir -p ~/aws
cd ~/aws
```

### 2) 放置模板与配置文件
将以下文件放入 `~/aws/`：
- `kup`
- `kup.conf.example`
- `cluster.yaml`
- `nodegroup.yaml`
- `cilium-enterprise-values.yaml`
- `netcheck.yaml`
- `otel-demo-allow-all.yaml`
- `otel-demo-l7-visibility.yaml`
- `tetragon.yaml`
- `tpr-values.yaml`
- ...

确保脚本可执行：
```bash
chmod +x ~/aws/kup
```

### 3) 配置 `kup.conf`
基于`kup.conf.example`按你的环境修改关键项形成kup.conf，比如：
- `CLUSTER_NAME`, `CLUSTER_ID`, `REGION`, `K8S_VERSION`
- `NG_INSTANCE_TYPE`, `NG_DESIRED_CAPACITY`
- `CILIUM_CHART_VER`, `TETRAGON_CHART_VER`, `TPR_CHART_VER`
- `EGRESS_GW_ENABLE=true/false`, `EGRESS_GW_HA_ENABLE=true/false`（默认自动启用 Egress Gateway HA）
- `EGRESS_GW_DESTINATION_CIDRS`（默认指向同 VPC 内 `test-server-01` 的 Echo Server）
- `EGRESS_GW_ECHO_SERVER_PORT`（默认 `18080`，用于部署完成后显示的演示命令）
- `EGRESS_GW_EGRESS_CIDRS`（可选；留空时使用 gateway 节点默认路由接口 IP，填 CIDR 时用于 Isovalent Egress Gateway IPAM）
- `EGRESS_GW_REMOTE_OUTPOST_AUTOCONFIG=true/false`（默认通过 SSM 重启 `test-server-01` 上的 `remote-outpost` 容器，并把 gateway node IP 写入 `ALLOWED_IP`）
- `SPLUNK_INDEXER_HOST`, `SPLUNK_INDEXER_PORT`
- `SPLUNK_EC2_SG_ID`（用于自动开通入站端口）
- `UF_ENABLE=true/false`（是否启用 UF 自动安装）
- `NODE_TIMEZONE=Asia/Singapore`

### 4) 执行安装
```bash
~/aws/kup
```

### 5) 安装后常用命令
```bash
# Check Cilium Tetragon FSO Monitor pods
kubectl -n kube-system get pod -owide
kubectl -n fsomonitor get pod -owide 

# Connectivity
netcheck 1 ping -c 5 <other node's POD IP@>
netcheck_all sh -c  "curl -I https://www.cisco.com"

# Tetragon policies
kubectl get alertrules
kubectl get tracingpolicies

# show tetragon regular events log
for n in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do p=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$n -o jsonpath='{.items[0].metadata.name}'); echo "=== node=$n pod=$p ==="; kubectl -n kube-system exec $p -c cilium-agent -- ls -al /var/run/cilium/hubble || true; done

# show tetragon alerts log
for n in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do p=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$n -o jsonpath='{.items[0].metadata.name}'); echo "=== node=$n pod=$p ==="; kubectl -n kube-system exec $p -c cilium-agent -- ls -al /var/run/cilium/hubble/alert 2>/dev/null || echo "no /var/run/cilium/hubble/alert on $n"; done

# Expose the victim app. Use with caution. Please roll back after use
./shiro124

# Check Tetragon Events BPF missed events
echo "---"; kubectl -n kube-system get pod -l app.kubernetes.io/component=agent,app.kubernetes.io/name=tetragon -o jsonpath='{range .items[*]}{.spec.nodeName}{"\t"}{.metadata.name}{"\n"}{end}' | while read -r node pod; do echo "${node}  ${pod}"; kubectl -n kube-system exec "$pod" -c tetragon -- sh -c "wget -qO- localhost:2112/metrics | awk '/^tetragon_bpf_missed_events_total(\\{.*\\})?[[:space:]]/{print}'"; echo "---"; done

# Check Tetragon Events RingBuf lost events
echo "---"; kubectl -n kube-system get pod -l app.kubernetes.io/component=agent,app.kubernetes.io/name=tetragon -o jsonpath='{range .items[*]}{.spec.nodeName}{"\t"}{.metadata.name}{"\n"}{end}' | while read -r node pod; do echo "${node}  ${pod}"; kubectl -n kube-system exec "$pod" -c tetragon -- sh -c "wget -qO- localhost:2112/metrics | awk '/^tetragon_observer_ringbuf_queue_events_(lost|received)_total[[:space:]]/{print}'"; echo "---"; done

# Hubble UI Enterprise with Timescape
kubectl -n kube-system port-forward svc/hubble-ui 18080:80

# Grafana UI
kubectl -n fsomonitor port-forward svc/fsomonitor-grafana 3000:80

# OTel demo app
kubectl --namespace otel-demo port-forward svc/frontend-proxy 28080:8080

# Egress Gateway HA
kubectl get nodes -L egress-gw,io.cilium/egress-gateway,topology.kubernetes.io/zone
kubectl -n starwar get pod -owide
kubectl get isovalentegressgatewaypolicy outpost-ha -o yaml
kubectl -n starwar exec xwing -- curl --max-time 2 http://172.31.38.183:18080
for i in $(seq 1 10); do kubectl -n starwar exec xwing -- curl --max-time 2 http://172.31.38.183:18080; done
kubectl -n starwar exec tiefighter -- curl --max-time 2 http://172.31.38.183:18080

```

---

## Splunk 对接说明（重要）

若开启 UF（`UF_ENABLE=true`），请确保 Splunk Enterprise 已完成：
1. 开启接收端口（默认 `9997`）。
2. 创建索引（例如 `index=alert`）。
3. 创建/克隆 sourcetype（例如 `alert_json` 从 `_json` clone），并确保解析策略符合预期。

UF 默认监控（可在 `kup.conf` 调整）：
- 普通日志：`${UF_TETRAGON_LOG}`（sourcetype `_json`，默认 index）
- 告警日志：`${UF_ALERT_GLOB}`（sourcetype `alert_json`，index `alert`）

---

## 注意事项

- **模板变量**：模板文件中的 `${VAR}` 由 `kup.conf` 提供。建议只改 `kup.conf`，不要直接改渲染后的 `*-<id>.yaml`。
- **Egress Gateway HA**：默认启用 `egressGateway.enabled` 与 `enterprise.egressGatewayHA.enabled`，并自动选择两个不同 AZ 的 Ready 节点打 `egress-gw=true` / `io.cilium/egress-gateway=true` 标签；`starwar` namespace 中的 `xwing` 与 `tiefighter` Pod 会避开 gateway 节点部署。策略默认只匹配 `starwar` namespace 中 `org=alliance` 的 Pod，并只覆盖 `EGRESS_GW_DESTINATION_CIDRS` 指定的目标 CIDR。脚本会在 Cilium Helm upgrade 后滚动重启 Cilium agent，让需要进程启动时加载的 datapath 配置生效；如果 `EGRESS_GW_REMOTE_OUTPOST_AUTOCONFIG=true`，还会通过 SSM 找到同 VPC 中名为 `test-server-01` 的 EC2，重启 `remote-outpost` 容器并把所选 gateway node IP 自动写入 `ALLOWED_IP`。
- **VPC 一致性**：脚本自动配置 Splunk SG 入站时，会校验 Splunk SG 与 EKS VPC 一致；否则会报错并停止（避免误开放端口）。
- **SSM 与权限**：节点时区设置 / UF 安装依赖 SSM。若节点未注册到 SSM，脚本会尝试给 NodeRole 附加 `AmazonSSMManagedInstanceCore`（在节点 Ready 之后进行）。
- **成本控制**：
  - 不演示时建议停用/缩容 NodeGroup 或关闭 Splunk EC2（保留 EBS）。kiall可以实现完全卸载已安装的所有资源。注意kiall并不读取kup.conf文件，必须带参数执行以避免在多集群时误删集群，执行格式为：
```bash
./kiall <集群名称> <集群id> [Region]
```
  - 注意清理 CloudFormation / EKS / LoadBalancer 等资源，避免长期计费。
- **安全**：
  - 部署后应自行优化安全组，开放应尽量最小化，已定义仅允许 EKS Cluster SG 访问 Splunk 的接收端口。
  - UF 的管理员密码在 `kup.conf` 中以明文出现，仅用于演示，生产中使用其他密码。
- **性能**
  - 本演示默认采用低规格的虚机实例t3a.large，2 vCPU 8 Mem，属于 burstable 实例，每 vCPU baseline 30%（2 vCPU 合计也只相当于“长期 0.6 vCPU @100%”的量级）——持续高 CPU 场景会非常吃力，因而只用于演示，otel-demo示例应用也将压力生成调小，所以当需要演示资源敏感类业务时应适当升级规格
  - 安装Tetragon Policy Ruleset（TPR）时需要针对环境做降噪处理，本环境已按当前应用做了降噪，此过程可以持续迭代，根据新应用持续优化，TPR values是幂等部署的，非常方便。优化的目标是原始事件量不会造成大量RingBuf Queue排队，Splunk看板上不会有大量干扰信息（正常基线下一般可以把15分钟滚动的告警量压缩为几条甚至零且没有CRITICAL）。查看RingBuf在10秒间隔的动态变化的命令
```bash
# TPOD=tetragon-xxxx 为你关注的节点的Tetragon DaemonSet POD
kubectl -n kube-system exec -it "$TPOD" -c tetragon -- sh -c 'm(){ wget -qO- localhost:2112/metrics | awk "/tetragon_observer_ringbuf_queue_events_(lost|received)_total/{print \$1\" \"\$2}"; }; m; sleep 10; echo "---"; m'
```

---

## Egress Gateway HA

Egress Gateway HA 的部署、修改、检查、故障测试与拆除步骤参见：[docs/egress-gw-readme.md](docs/egress-gw-readme.md)。

---

## 后续使用指南

请参见：https://share.evernote.com/note/6b6d1702-e895-084d-a32b-ba2154bfba3f

---

## 许可与声明

本项目用于内部演示与自动化实验环境搭建。  
涉及商业软件与订阅（Isovalent Enterprise、Splunk Enterprise 等）时，请遵循你的许可协议与公司合规要求。
