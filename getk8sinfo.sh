#!/usr/bin/env bash
echo "=== cluster ==="
kubectl version || true
kubectl get nodes -o wide || true

echo "=== node runtime ==="
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.osImage}{"\t"}{.status.nodeInfo.kernelVersion}{"\t"}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}' || true

echo "=== kube-system pods (labels) ==="
kubectl -n kube-system get pods -o wide || true
kubectl -n kube-system get pods --show-labels || true

echo "=== tetragon pods ==="
kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon -o wide || true
kubectl -n kube-system get ds tetragon -o yaml || true

echo "=== tetragon recent logs (tail) ==="
kubectl -n kube-system logs ds/tetragon -c tetragon --tail=300 || true

echo "=== cilium pods (labels) ==="
kubectl -n kube-system get pods -l app.kubernetes.io/part-of=cilium -o wide || true
kubectl -n kube-system get pods -l app.kubernetes.io/part-of=cilium --show-labels || true

