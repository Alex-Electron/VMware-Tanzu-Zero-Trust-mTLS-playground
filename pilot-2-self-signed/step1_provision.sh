#!/bin/bash
source ./env.sh

pause() {
  echo -e "\n⏸  Press [Enter] to continue or [Ctrl+C] to abort..."
  read -r
}

echo "--- 1. Log in to the Supervisor ---"
kubectl vsphere login --server="$SUPERVISOR_IP" --insecure-skip-tls-verify -u administrator@vsphere.local

echo -e "\n--- 2. Create cluster '$TKC_NAME' in namespace '$VSPHERE_NAMESPACE' ---"
kubectl config use-context "$VSPHERE_NAMESPACE"
kubectl apply -f manifests/01-cluster.yaml -n "$VSPHERE_NAMESPACE"
echo "🚀 Manifest applied to namespace $VSPHERE_NAMESPACE."
pause

echo -e "\n--- 3. Waiting for the cluster to be provisioned and ready ---"
echo "    (VKS Cluster has no single 'Ready' condition; the readiness signal is Available=True)"
deadline=$(( $(date +%s) + 1800 ))   # give up after 30 minutes
while true; do
  phase=$(kubectl get cluster "$TKC_NAME" -n "$VSPHERE_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
  conds=$(kubectl get cluster "$TKC_NAME" -n "$VSPHERE_NAMESPACE" -o jsonpath='{range .status.conditions[*]}{.type}={.status};{end}' 2>/dev/null)
  avail=$(printf '%s' "$conds" | tr ';' '\n' | awk -F= '$1=="Available"{print $2}')
  pending=$(printf '%s' "$conds" | tr ';' '\n' | awk -F= '$1 ~ /^(InfrastructureReady|ControlPlaneMachinesReady|WorkerMachinesReady|SystemChecksSucceeded|AddonsReconciled)$/ && $2!="True"{printf "%s ",$1}')
  cp_want=$(kubectl get cluster "$TKC_NAME" -n "$VSPHERE_NAMESPACE" -o jsonpath='{.spec.topology.controlPlane.replicas}' 2>/dev/null)
  wk_want=0
  for r in $(kubectl get cluster "$TKC_NAME" -n "$VSPHERE_NAMESPACE" -o jsonpath='{.spec.topology.workers.machineDeployments[*].replicas}' 2>/dev/null); do wk_want=$((wk_want + r)); done
  want=$(( ${cp_want:-0} + wk_want ))
  running=$(kubectl get machines -n "$VSPHERE_NAMESPACE" -l cluster.x-k8s.io/cluster-name="$TKC_NAME" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -cw Running)
  echo "  $(date +%H:%M:%S)  phase=${phase:-?}  available=${avail:-?}  nodes Running ${running:-0}/${want:-?} (CP ${cp_want:-?} + workers ${wk_want})${pending:+  pending: $pending}"
  if [ "$phase" = "Provisioned" ] && [ "$avail" = "True" ]; then
    echo -e "\n✅ Cluster '$TKC_NAME' is provisioned and available — $running/$want nodes Running."
    kubectl get machines -n "$VSPHERE_NAMESPACE" -l cluster.x-k8s.io/cluster-name="$TKC_NAME"
    echo "   Next: ./step2_setup_mesh.sh"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo -e "\n❌ Timed out after 30 min (phase=${phase:-?} available=${avail:-?} ${running:-0}/${want:-?} nodes Running)."
    kubectl get machines -n "$VSPHERE_NAMESPACE" -l cluster.x-k8s.io/cluster-name="$TKC_NAME" 2>/dev/null
    echo "   Inspect: kubectl get cluster,machines -n $VSPHERE_NAMESPACE"
    exit 1
  fi
  sleep 15
done
