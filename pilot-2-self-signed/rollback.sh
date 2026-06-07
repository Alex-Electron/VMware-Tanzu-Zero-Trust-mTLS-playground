#!/bin/bash
# Single interactive teardown tool for the pilot.
# Driven by env.sh (cluster + namespace) - it only asks WHAT to remove, never which cluster.
# Each step undoes exactly what that step created; lower steps stay. Destructive actions confirm.
source ./env.sh

confirm() { read -r -p "$1 [y/N] " a; [ "$a" = "y" ] || [ "$a" = "Y" ]; }
hr()  { echo "── $1 ──────────────────────────────────────────" ; }
step(){ echo "  → $1" ; }

login_tkc() {
  step "Logging in to cluster '$TKC_NAME'..."
  kubectl vsphere login --server="$SUPERVISOR_IP" \
    --tanzu-kubernetes-cluster-namespace "$VSPHERE_NAMESPACE" \
    --tanzu-kubernetes-cluster-name "$TKC_NAME" \
    --insecure-skip-tls-verify -u administrator@vsphere.local >/dev/null 2>&1
  kubectl config use-context "$TKC_NAME" >/dev/null 2>&1
}
login_supervisor() {
  step "Logging in to the Supervisor..."
  kubectl vsphere login --server="$SUPERVISOR_IP" --insecure-skip-tls-verify -u administrator@vsphere.local >/dev/null 2>&1
  kubectl config use-context "$SUPERVISOR_IP" >/dev/null 2>&1
}

# delete a manifest, substituting the lab domain (the same rendering step3 used)
del() { sed "s/n2\.nested\.sclabs\.cloud/${BASE_DOMAIN}/g" "$1" | kubectl delete -f - --ignore-not-found; }

do_step4() {
  echo ""; hr "Rolling back STEP 4 (mTLS test pod)"
  login_tkc
  step "Deleting pod curl-test in the default namespace..."
  kubectl delete pod curl-test -n default --ignore-not-found
  echo "✅ Step 4 rolled back (test pod removed)."
}

do_step3() {
  confirm "Roll back STEP 3: delete Bookinfo (sidecar/ambient/pure-k8s), loadgen and the monitoring stack. Cluster + mesh stay." || { echo "Skipped."; return; }
  echo ""; hr "Rolling back STEP 3 (apps + loadgen + monitoring)"
  login_tkc
  echo "  Present now:"
  kubectl get ns bookinfo-istio-sidecar bookinfo-istio-ambient bookinfo-pure-k8s loadgen --no-headers 2>/dev/null | sed 's/^/     /' || true
  step "Deleting Bookinfo + loadgen namespaces (removes their gateways, certs, PeerAuthentication)..."
  step "  (namespaces take ~30-60s to terminate while pods drain)"
  kubectl delete ns bookinfo-istio-sidecar bookinfo-istio-ambient bookinfo-pure-k8s loadgen --ignore-not-found
  step "Removing monitoring HTTPS gateways and TLS certs from istio-system..."
  del manifests/09-grafana-gateway.yaml
  del manifests/08-monitoring-gateway.yaml
  del manifests/07-monitoring-https.yaml
  step "Removing Kiali / Prometheus / Grafana..."
  kubectl delete -f manifests/06-grafana.yaml -f manifests/05-kiali.yaml -f manifests/04-prometheus.yaml --ignore-not-found
  echo "  Still in the cluster (mesh + AKO stay):"
  kubectl get ns --no-headers 2>/dev/null | awk '{print $1}' | grep -E '^(istio-system|avi-system|cert-manager)$' | sed 's/^/     ns: /'
  echo "✅ Step 3 rolled back. Re-run ./step3_scenarios.sh to redeploy."
}

do_step2() {
  confirm "Roll back STEP 2: uninstall AKO, cert-manager and Istio; delete avi-system/cert-manager/istio-system. The cluster stays." || { echo "Skipped."; return; }
  echo ""; hr "Rolling back STEP 2 (AKO + cert-manager + Istio)"
  login_tkc
  step "Uninstalling AKO (Helm release in avi-system)..."
  helm uninstall ako -n avi-system 2>/dev/null || echo "     (AKO release not found)"
  step "Removing the lab CA issuer..."
  kubectl delete -f manifests/02-selfsigned-issuer.yaml --ignore-not-found
  step "Uninstalling cert-manager..."
  helm uninstall cert-manager -n cert-manager 2>/dev/null || echo "     (cert-manager release not found)"
  step "Uninstalling Istio (istioctl uninstall --purge)..."
  local ISTIOCTL=istioctl
  [ "$(istioctl version --remote=false 2>/dev/null | awk '/client version:/{print $NF}')" = "$ISTIO_VERSION" ] || ISTIOCTL="$(pwd)/istio-${ISTIO_VERSION}/bin/istioctl"
  "$ISTIOCTL" uninstall --purge -y 2>/dev/null
  step "Deleting namespaces avi-system / cert-manager / istio-system..."
  kubectl delete ns avi-system cert-manager istio-system --ignore-not-found
  echo "  Istio control-plane pods left (should be empty):"
  kubectl get pods -n istio-system --no-headers 2>/dev/null | sed 's/^/     /' || echo "     (istio-system is gone)"
  echo "✅ Step 2 rolled back. Re-run ./step2_setup_mesh.sh. (Gateway API CRDs are left in place.)"
}

do_step1() {
  echo "⚠️  This is a HARD delete of the whole cluster. AKO goes down with it and may NOT get to"
  echo "    deregister its Avi objects, so VS/pools/VIPs can be left ORPHANED in the Avi Controller."
  echo "    For a clean Avi state, roll back step 3 and step 2 first (that lets AKO release them), then this."
  echo "    The vSphere namespace '$VSPHERE_NAMESPACE' is kept - its owner created it, not this pilot."
  confirm "DESTROY the cluster '$TKC_NAME' in '$VSPHERE_NAMESPACE' (also wipes steps 2-4)?" || { echo "Skipped."; return; }
  echo ""; hr "Rolling back STEP 1 (destroy the cluster)"
  login_supervisor
  step "Requesting deletion of cluster '$TKC_NAME'..."
  kubectl delete cluster "$TKC_NAME" -n "$VSPHERE_NAMESPACE" --wait=false
  step "Current cluster status:"
  kubectl get cluster "$TKC_NAME" -n "$VSPHERE_NAMESPACE" 2>/dev/null | sed 's/^/     /' || echo "     (already gone)"
  echo "✅ Cluster deletion requested (VM removal + Avi cleanup take a few minutes)."
  echo "   Watch: kubectl get cluster $TKC_NAME -n $VSPHERE_NAMESPACE"
}

while true; do
  echo ""
  echo "================================================="
  echo "  Pilot teardown / rollback"
  echo "  Cluster: $TKC_NAME   Namespace: $VSPHERE_NAMESPACE"
  echo "================================================="
  echo "  What do you want to remove?"
  echo "   [4] Step 4 — remove the mTLS test pod"
  echo "   [3] Step 3 — Bookinfo apps + loadgen + monitoring   (keep cluster + mesh)"
  echo "   [2] Step 2 — AKO + cert-manager + Istio             (keep cluster)"
  echo "   [1] Step 1 — destroy the cluster                    (also wipes steps 2-4; see the Avi note)"
  echo "   [q] Quit"
  read -r -p "> " choice
  case "$choice" in
    4) do_step4 ;;
    3) do_step3 ;;
    2) do_step2 ;;
    1) do_step1 ;;
    q|Q|"") echo "Bye."; break ;;
    *) echo "Unknown option: '$choice'" ;;
  esac
done
