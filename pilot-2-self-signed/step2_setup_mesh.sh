#!/bin/bash
source ./env.sh

pause() {
  echo -e "\n⏸  Press [Enter] to continue or [Ctrl+C] to abort..."
  read -r
}

echo "--- 1. Log in to cluster '$TKC_NAME' (namespace '$VSPHERE_NAMESPACE') ---"
kubectl vsphere login --server="$SUPERVISOR_IP" \
  --tanzu-kubernetes-cluster-namespace "$VSPHERE_NAMESPACE" \
  --tanzu-kubernetes-cluster-name "$TKC_NAME" \
  --insecure-skip-tls-verify -u administrator@vsphere.local
kubectl config use-context "$TKC_NAME"
pause

echo -e "\n--- 2. Dependencies (pinned versions; charts ship in ./helm-charts, downloaded only if missing) ---"
mkdir -p helm-charts
if [ ! -f "helm-charts/ako-${AKO_VERSION}.tgz" ]; then
  echo "  pulling AKO ${AKO_VERSION} ..."
  helm pull oci://projects.registry.vmware.com/ako/helm-charts/ako --version "$AKO_VERSION" -d helm-charts/
fi
if [ ! -f "helm-charts/cert-manager-v${CM_VERSION}.tgz" ]; then
  echo "  pulling cert-manager v${CM_VERSION} ..."
  helm pull cert-manager --repo https://charts.jetstack.io --version "v${CM_VERSION}" -d helm-charts/
fi
# istioctl pinned to $ISTIO_VERSION: use the one in PATH if it matches, otherwise download exactly that version
ISTIOCTL=istioctl
if [ "$(istioctl version --remote=false 2>/dev/null | awk '/client version:/{print $NF}')" != "$ISTIO_VERSION" ]; then
  echo "  downloading istioctl ${ISTIO_VERSION} ..."
  [ -x "istio-${ISTIO_VERSION}/bin/istioctl" ] || curl -sL https://istio.io/downloadIstio | ISTIO_VERSION="$ISTIO_VERSION" sh -
  ISTIOCTL="$(pwd)/istio-${ISTIO_VERSION}/bin/istioctl"
fi
echo "  istioctl $("$ISTIOCTL" version --remote=false 2>/dev/null | awk '/client version:/{print $NF}') | AKO ${AKO_VERSION} | cert-manager v${CM_VERSION} | Gateway API ${GATEWAY_API_VERSION}"
pause

echo -e "\n--- 3. Gateway API CRDs (standard channel, ${GATEWAY_API_VERSION}) ---"
if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  echo "  already present: $(kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')"
else
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
fi

echo -e "\n--- 4. Install Istio ${ISTIO_VERSION} (ambient profile) ---"
kubectl create ns istio-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label ns istio-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite
"$ISTIOCTL" install --set profile=ambient -y

echo -e "\n--- 5. Install cert-manager v${CM_VERSION} ---"
helm upgrade --install cert-manager "helm-charts/cert-manager-v${CM_VERSION}.tgz" \
  --namespace cert-manager --create-namespace --set installCRDs=true

echo -e "\n--- 6. Set up the internal (lab) CA ---"
kubectl apply -f manifests/02-selfsigned-issuer.yaml
echo "⏳ Waiting for the root certificate to be generated..."
sleep 10
kubectl get secret lab-root-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 --decode > "$CERT_FILE"
echo "🔐 Root certificate written to $(pwd)/$CERT_FILE"
echo "   Import it into your browser and trust it for websites (Firefox: Settings ->"
echo "   Privacy & Security -> Certificates -> View Certificates -> Authorities -> Import)."

echo -e "\n--- 7. Install AKO ${AKO_VERSION} (Istio mode) ---"
# Render the AKO values from env.sh. The committed manifests/03-ako-values.yaml is a template;
# no install-specific values are stored in it.
python3 -c "import os, string, sys; sys.stdout.write(string.Template(open('manifests/03-ako-values.yaml').read()).safe_substitute(os.environ))" > /tmp/ako-values.rendered.yaml
# avi-system stays on the classic sidecar: AKO reads its workload cert from
# /etc/istio-output-certs, which only the sidecar writes (ambient/ztunnel does not).
kubectl create ns avi-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label ns avi-system istio-injection=enabled pod-security.kubernetes.io/enforce=privileged --overwrite
helm upgrade --install ako "helm-charts/ako-${AKO_VERSION}.tgz" -n avi-system -f /tmp/ako-values.rendered.yaml

echo -e "\n⏳ Waiting for AKO to be ready..."
if kubectl -n avi-system rollout status statefulset/ako --timeout=300s; then
  echo -e "\n✅ Mesh + AKO installed (Istio ${ISTIO_VERSION}, AKO ${AKO_VERSION}, cert-manager v${CM_VERSION})."
  echo "   Next: ./step3_scenarios.sh"
else
  echo -e "\n⚠️  AKO is not ready yet — check: kubectl -n avi-system get pods"
fi
