# shellcheck shell=bash
# T-104 NVIDIA GPU Operator: default stack on the host driver; a CUDA pod and DCGM metrics prove it.

GPU_NS=gpu-operator

register_stage gpu-operator GPU_OPERATOR_VERSION   # a new version in versions.env upgrades it
register_teardown gpu-operator
stage_gpu_operator() {
  [ "$(gpu_count nvidia)" -gt 0 ] || { warn "no NVIDIA GPU on any node: GPU Operator skipped"; return 0; }
  mkdir -p "$STATE/charts"; local chart=$STATE/charts/gpu-operator-$GPU_OPERATOR_VERSION.tgz
  [ -s "$chart" ] || fetch_pinned "https://helm.ngc.nvidia.com/nvidia/charts/gpu-operator-$GPU_OPERATOR_VERSION.tgz" "$GPU_OPERATOR_SHA256" "$chart"
  rec "TEARDOWN gpu-operator"
  log "GPU Operator $GPU_OPERATOR_VERSION (pulls the operator images, 3-8 min)"
  hl upgrade --install gpu-operator "$chart" -n "$GPU_NS" --create-namespace \
    -f "$OIF_HOME/platform/gpu-nvidia/values.yaml" --wait --timeout 10m >> "$LOG" 2>&1 \
    || die "GPU Operator chart failed (kubectl -n $GPU_NS get pods; helm -n $GPU_NS status gpu-operator)"
  wait_for "GPU Operator ready (ClusterPolicy)" 1200 15 bash -c \
    "kubectl --kubeconfig $KCFG get clusterpolicy cluster-policy -o jsonpath='{.status.state}' | grep -qx ready" \
    || { kc -n "$GPU_NS" get pods | grep -vE 'Running|Completed' | tee -a "$TLOG"; die "GPU Operator not ready (kubectl -n $GPU_NS get pods)"; }
}

teardown_gpu_operator() {   # chart first so the toolkit undoes its containerd and CDI changes
  if kc get --raw /readyz >/dev/null 2>&1; then
    hl uninstall gpu-operator -n "$GPU_NS" --wait --timeout 5m >> "$LOG" 2>&1 || warn "helm uninstall gpu-operator did not finish"
  fi
  ok "GPU Operator removed"   # its runtime files go in nvidia_runtime_leftovers, after Kubernetes has stopped every container
}

nvidia_runtime_leftovers() {   # called by teardown_containerd: GPU pods need nvidia-container-runtime until they are stopped
  # seen on the reference host: conf.d/99-nvidia.toml, /var/run/cdi/{k8s.device-plugin,management}.nvidia.com-gpu.*
  rm -rf /etc/containerd/conf.d/99-nvidia.toml /usr/local/nvidia /etc/cdi/*nvidia* /var/run/cdi/*nvidia* 2>/dev/null || true
  rmdir /etc/containerd/conf.d /etc/cdi /var/run/cdi 2>/dev/null || true
}

# T-143: a node can lose its NVIDIA driver after the install (a kernel update without NVIDIA modules, then a reboot).
# Before the stages of a re-run the first node checks every node with an NVIDIA GPU (NV_CHECK, 30-gpu-host.sh). A node
# with a problem gets its node stages again, where nvidia-driver repairs it; where the driver was gone, the GPU
# Operator's toolkit decided at boot that no driver is installed on the host and waits for a driver container forever,
# so gpu-verify restarts it there and checks the GPUs again.
NV_REPAIR_FILE=nvidia-repair   # under $STATE: the addresses of nodes whose driver was gone
nv_nodes_check() {   # "label address check" per node with an NVIDIA GPU; check is an NV_CHECK line, or "unreachable"
  local inv name addr kind _r out seen=" "
  inv=$( (gpu_inventory) 2>/dev/null ) || return 1
  while read -r name addr kind _r; do
    [ "$kind" = nvidia ] || continue; [[ $seen == *" $addr "* ]] && continue; seen+="$addr "
    out=$(on_gpu_node "$addr" "$NV_CHECK" 2>/dev/null) || out=unreachable
    echo "$name $addr ${out:-unreachable}"
  done <<< "$inv"; }
nv_drift() {   # install_run, before the stages
  [ -f "$DONE/gpu-verify" ] || return 0   # not installed yet: the stages install the driver anyway
  local out name addr chk
  out=$(nv_nodes_check) || { warn "NVIDIA driver check skipped: cannot list the GPUs of every node"; return 0; }
  while read -r name addr chk; do
    [[ $chk == "none "* ]] || continue   # unreachable nodes are left to the nodes stage
    warn "$name: NVIDIA driver not loaded (a kernel update without NVIDIA modules?): its driver stage runs again"
    [ -n "$(host_prefix "$addr")" ] || rm -f "$DONE/nodes"   # this host: the driver stage's pin (nv_driver_rev) sees it
    echo "$addr" >> "$STATE/$NV_REPAIR_FILE"; rm -f "$DONE/gpu-verify"
  done <<< "$out"; }
nv_operator_restart() {   # the toolkit on each repaired node; its daemonset starts a new one, which finds the host driver
  local a n
  for a in $(sort -u "$STATE/$NV_REPAIR_FILE"); do
    n=$(node_name_of "$a"); [ -n "$n" ] || continue
    kc -n "$GPU_NS" delete pod -l app=nvidia-container-toolkit-daemonset --field-selector "spec.nodeName=$n" --wait=false >> "$LOG" 2>&1 || true
    ok "$n: GPU Operator toolkit restarted (it gave up on the host driver while it was missing)"
  done; }

register_stage gpu-verify GPU_OPERATOR_VERSION
stage_gpu_verify() {
  local want n node; want=$(gpu_count nvidia); [ "$want" -gt 0 ] || return 0
  if [ -s "$STATE/$NV_REPAIR_FILE" ]; then nv_operator_restart; fi   # T-143
  wait_for "nvidia.com/gpu advertised ($want in the cluster)" 300 10 gpu_resource_is nvidia.com/gpu "$want" \
    || die "the cluster does not advertise $want nvidia.com/gpu (kubectl describe nodes | grep -A6 Allocatable; kubectl -n $GPU_NS get pods -o wide)"
  rm -f "$STATE/$NV_REPAIR_FILE"
  node=$(node_with nvidia.com/gpu)
  n=$(kc get node "$node" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.product}')
  [ -n "$n" ] || die "GPU feature discovery labels missing (kubectl get node $node --show-labels)"
  ok "node advertises nvidia.com/gpu: $want ($n)"
  export CUDA_SAMPLE_IMAGE
  kc delete namespace oif-gpu-test --ignore-not-found --wait=true >/dev/null 2>&1
  render "$OIF_HOME/platform/gpu-nvidia/gpu-test.yaml" | kc apply -f - >> "$LOG" || die "GPU test pod could not be created"
  wait_for "CUDA test pod finished" 600 5 bash -c \
    "kubectl --kubeconfig $KCFG -n oif-gpu-test get pod cuda -o jsonpath='{.status.phase}' | grep -qE 'Succeeded|Failed'" || true
  local smi va; smi=$(kc -n oif-gpu-test logs cuda -c nvidia-smi 2>&1 | head -3); va=$(kc -n oif-gpu-test logs cuda -c vectoradd 2>&1 | tail -3)
  printf '%s\n%s\n' "$smi" "$va" | sed 's/^/    /' | tee -a "$TLOG"
  grep -q '^GPU 0:' <<< "$smi" || die "nvidia-smi did not see a GPU inside the pod (kubectl -n oif-gpu-test describe pod cuda)"
  grep -q 'Test PASSED' <<< "$va" || die "CUDA vectorAdd did not pass (kubectl -n oif-gpu-test logs cuda -c vectoradd)"
  kc delete namespace oif-gpu-test --wait=true >> "$LOG" 2>&1 || warn "test namespace oif-gpu-test not deleted"
  local ip m; ip=$(kc -n "$GPU_NS" get svc nvidia-dcgm-exporter -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  [ -n "$ip" ] || die "DCGM exporter service missing"
  wait_for "DCGM metrics" 180 10 bash -c "curl -fsS -m 10 http://$ip:9400/metrics | grep -q '^DCGM_FI_DEV_GPU_TEMP'" || die "no DCGM metrics at $ip:9400"
  # labels hold spaces (modelName="NVIDIA RTX A6000"): drop them before splitting
  m=$(curl -fsS -m 10 "http://$ip:9400/metrics" | grep -E '^DCGM_FI_DEV_(GPU_TEMP|POWER_USAGE|FB_USED)\{' | sed -E 's/\{[^}]*\}//' \
    | awk '{n=$1; sub(/^DCGM_FI_DEV_/,"",n); printf "%s=%s ", tolower(n), $2}')
  ok "pod saw the GPU, CUDA test passed; DCGM: $m"
}
