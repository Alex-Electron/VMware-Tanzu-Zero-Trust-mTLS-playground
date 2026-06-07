#!/bin/bash
source ./env.sh

pause() {
  echo -e "\n⏸  Press [Enter] to continue or [Ctrl+C] to abort..."
  read -r
}

# Apply a manifest, substituting the lab domain with BASE_DOMAIN from env.sh
render() { sed "s/n2\.nested\.sclabs\.cloud/${BASE_DOMAIN}/g" "$1" | kubectl apply -f - ; }

# Wait until a Gateway LoadBalancer actually serves over HTTPS, then print the openable URL.
# Probes the Avi VIP using the hostname for SNI+Host (Istio's HTTPS listener is SNI-based);
# -k skips the self-signed lab cert. A bare -H Host would omit SNI and get a TLS reset (000).
# Args: <namespace> <svc> <host> <path>
wait_serving() {
  local ns="$1" svc="$2" host="$3" path="$4" vip code
  for i in $(seq 1 36); do
    vip=$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ -n "$vip" ]; then
      code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 4 --resolve "$host:443:$vip" "https://$host$path" 2>/dev/null)
      case "$code" in
        200|301|302|303|307|308) printf "\r   READY → https://%s%s   (VIP %s, HTTP %s)%-8s\n" "$host" "$path" "$vip" "$code" ""; return 0;;
      esac
      printf "\r   %-34s waiting: VIP %s, HTTP %s (try %s/36)   " "$host" "$vip" "${code:-000}" "$i"
    else
      printf "\r   %-34s waiting for Avi VIP... (try %s/36)        " "$host" "$i"
    fi
    sleep 3
  done
  printf "\r   %-34s NOT READY (VIP %s, last HTTP %s)\n" "$host" "${vip:-pending}" "${code:-000}"
  echo "      diagnose: kubectl get svc $svc -n $ns ; kubectl get gateway -n $ns"
  return 1
}

# Deploy Bookinfo into a namespace over HTTPS (cert from the self-signed lab CA),
# with a specific host (no wildcard) and STRICT mTLS for the istio modes.
# Args: <namespace> <hostname> <mesh: sidecar|ambient|none>
deploy_bookinfo() {
  local ns="$1" host="$2" mesh="$3"
  kubectl create ns "$ns" --dry-run=client -o yaml | kubectl apply -f -
  case "$mesh" in
    sidecar) kubectl label ns "$ns" istio-injection=enabled pod-security.kubernetes.io/enforce=privileged --overwrite ;;
    ambient) kubectl label ns "$ns" istio.io/dataplane-mode=ambient pod-security.kubernetes.io/enforce=privileged --overwrite ;;
    none)    kubectl label ns "$ns" pod-security.kubernetes.io/enforce=privileged --overwrite ;;
  esac
  kubectl apply -f manifests/11-bookinfo.yaml -n "$ns"

  # TLS cert for the gateway HTTPS listener (signed by the self-signed lab CA)
  cat <<CRT | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: bookinfo-tls, namespace: $ns }
spec:
  secretName: bookinfo-tls
  commonName: $host
  dnsNames: ["$host"]
  issuerRef: { name: lab-ca-issuer, kind: ClusterIssuer }
CRT

  # Pin the specific host (no wildcard) on the HTTPRoute and both gateway listeners (http+https)
  kubectl patch httproute bookinfo -n "$ns" --type=merge -p "{\"spec\":{\"hostnames\":[\"$host\"]}}"
  kubectl patch gateway bookinfo-gateway -n "$ns" --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/listeners/0/hostname\",\"value\":\"$host\"},{\"op\":\"add\",\"path\":\"/spec/listeners/1/hostname\",\"value\":\"$host\"}]"

  # STRICT mTLS enforcement for the istio namespaces
  if [ "$mesh" = "sidecar" ] || [ "$mesh" = "ambient" ]; then
    cat <<PA | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: { name: default, namespace: $ns }
spec: { mtls: { mode: STRICT } }
PA
  fi

  echo "⏳ Waiting for the LoadBalancer service for $ns ..."
  while ! kubectl get svc bookinfo-gateway-istio -n "$ns" >/dev/null 2>&1; do sleep 2; done
  kubectl annotate svc bookinfo-gateway-istio -n "$ns" external-dns.alpha.kubernetes.io/hostname="$host" --overwrite
  echo "   Verifying it answers over HTTPS (open this in your browser):"
  wait_serving "$ns" bookinfo-gateway-istio "$host" "/productpage"
}

echo "--- 0. Log in to cluster '$TKC_NAME' ---"
kubectl vsphere login --server="$SUPERVISOR_IP" \
  --tanzu-kubernetes-cluster-namespace "$VSPHERE_NAMESPACE" \
  --tanzu-kubernetes-cluster-name "$TKC_NAME" \
  --insecure-skip-tls-verify -u administrator@vsphere.local > /dev/null 2>&1
kubectl config use-context "$TKC_NAME"

echo "--- 1. Install monitoring FIRST (Kiali, Prometheus, Grafana + HTTPS) ---"
echo "    so you can watch each app mode appear as it is deployed."
kubectl apply -f manifests/04-prometheus.yaml
kubectl apply -f manifests/05-kiali.yaml
kubectl apply -f manifests/06-grafana.yaml
# Provision the mesh-compare dashboard into Grafana via its dashboards ConfigMap
# (Grafana's file provider loads it; survives pod restarts, no port-forward needed).
python3 -c "import json; d=json.load(open('manifests/12-comparison-dashboard.json'))['dashboard']; print(json.dumps({'data':{'mesh-compare-dashboard.json': json.dumps(d)}}))" > /tmp/grafana-dash-patch.json
kubectl patch configmap istio-grafana-dashboards -n istio-system --type merge --patch-file /tmp/grafana-dash-patch.json >/dev/null 2>&1 \
  && echo "   provisioned the mesh-compare dashboard into Grafana" \
  || echo "   warning: could not patch ConfigMap istio-grafana-dashboards"
# kiali-tls/grafana-tls certs BEFORE the gateways (otherwise the HTTPS listeners won't program)
render manifests/07-monitoring-https.yaml
render manifests/08-monitoring-gateway.yaml
render manifests/09-grafana-gateway.yaml
echo "⏳ Waiting for the monitoring LoadBalancer services ..."
while ! kubectl get svc monitoring-gateway-istio -n istio-system >/dev/null 2>&1; do sleep 2; done
while ! kubectl get svc grafana-gateway-istio -n istio-system >/dev/null 2>&1; do sleep 2; done
kubectl annotate svc monitoring-gateway-istio -n istio-system external-dns.alpha.kubernetes.io/hostname="kiali.${BASE_DOMAIN}" --overwrite
kubectl annotate svc grafana-gateway-istio -n istio-system external-dns.alpha.kubernetes.io/hostname="grafana.${BASE_DOMAIN}" --overwrite

echo -e "\n--- 2. Start the load generator EARLY ---"
echo "    It hits all three Bookinfo modes in a loop. While a mode isn't deployed yet its"
echo "    requests just fail fast; the moment you deploy it, traffic flows and Kiali draws the graph."
render manifests/10-loadgen.yaml
echo "   Control the load:  ./load.sh on | off | status | test [rps] [sec]"

echo ""
echo "⏳ Verifying monitoring is actually reachable (pods Ready + Avi VIP + HTTPS through the gateway)..."
for d in prometheus kiali grafana; do
  kubectl -n istio-system rollout status deploy/$d --timeout=180s
done
wait_serving istio-system monitoring-gateway-istio "kiali.${BASE_DOMAIN}"   "/kiali"
wait_serving istio-system grafana-gateway-istio    "grafana.${BASE_DOMAIN}" "/"

echo -e "\n▶ Monitoring is up and load is running."
echo "   ⚠️  First import the lab root CA into your browser as TRUSTED, or HTTPS will warn:"
echo "       $(pwd)/$CERT_FILE   (generated by step2)"
echo "   Then open these and watch each Bookinfo mode light up as you deploy it below:"
echo "   Kiali:   https://kiali.${BASE_DOMAIN}/kiali"
echo "   Grafana: https://grafana.${BASE_DOMAIN}/"
pause

echo "--- 3. Deploy Pure K8s mode (no Istio) ---"
deploy_bookinfo bookinfo-pure-k8s "bookinfo-pure-k8s.${BASE_DOMAIN}" none
echo "   → in Kiali: bookinfo-pure-k8s lights up with traffic, no sidecars and no mTLS lock."
pause

echo "--- 4. Deploy Sidecar mode (mTLS STRICT) ---"
deploy_bookinfo bookinfo-istio-sidecar "bookinfo-sidecar.${BASE_DOMAIN}" sidecar
echo "   → in Kiali: bookinfo-istio-sidecar shows sidecars (2/2 pods) and the mTLS lock badge."
pause

echo "--- 5. Deploy Ambient mode (mTLS via ztunnel + STRICT) ---"
deploy_bookinfo bookinfo-istio-ambient "bookinfo-ambient.${BASE_DOMAIN}" ambient
echo "🏗 Installing the Waypoint proxy for Ambient (L7)..."
istioctl waypoint apply --namespace bookinfo-istio-ambient --wait
echo "   → in Kiali: bookinfo-istio-ambient runs with no sidecars; mTLS is carried by ztunnel."
pause

echo -e "\n✅ Demo environment ready. Compare the three namespaces in Kiali."
echo "   Grafana mesh-compare dashboard was provisioned in step 1 (no manual import needed)."
echo -e "\n========================================================"
echo -e "🔗 ACCESS LINKS (HTTPS; import the root CA '$CERT_FILE' into your browser):"
echo -e "========================================================"
echo -e "1. Bookinfo (pure K8s, no Istio):        https://bookinfo-pure-k8s.${BASE_DOMAIN}/productpage"
echo -e "2. Bookinfo (sidecar, mTLS STRICT):      https://bookinfo-sidecar.${BASE_DOMAIN}/productpage"
echo -e "3. Bookinfo (ambient, ztunnel + STRICT): https://bookinfo-ambient.${BASE_DOMAIN}/productpage"
echo -e "4. Kiali:                                https://kiali.${BASE_DOMAIN}/kiali"
echo -e "5. Grafana (mesh-compare dashboard):     https://grafana.${BASE_DOMAIN}/"
echo -e "========================================================"
echo -e "Note: the gateway serves the app at /productpage over both HTTP and HTTPS."
echo -e "Make sure these names resolve to the cluster VIPs in your DNS (Avi DNS)."
echo -e "\nNext: ./step4_verify_mtls.sh  — prove STRICT mTLS drops non-mesh (plaintext) east-west traffic."
pause
