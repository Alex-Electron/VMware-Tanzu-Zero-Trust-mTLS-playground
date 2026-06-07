#!/bin/bash
source ./env.sh
kubectl config use-context "$TKC_NAME" > /dev/null 2>&1

line() { printf '   %s\n' "----------------------------------------------------------"; }

echo "================================================="
echo "  🔒 mTLS verification (Istio PeerAuthentication)"
echo "================================================="

echo -e "\n0️⃣  Mesh enforcement state — what we are testing against"
line
echo "   PeerAuthentication (mTLS mode per namespace):"
kubectl get peerauthentication -A 2>/dev/null | sed 's/^/     /' || echo "     (none)"
echo "   Bookinfo namespaces and their dataplane mode:"
kubectl get ns bookinfo-istio-sidecar bookinfo-istio-ambient bookinfo-pure-k8s \
  -L istio-injection -L istio.io/dataplane-mode 2>/dev/null | sed 's/^/     /'
echo "   productpage pods per mode (sidecar = 2/2: app + istio-proxy):"
for ns in bookinfo-istio-sidecar bookinfo-istio-ambient bookinfo-pure-k8s; do
  kubectl get pods -n "$ns" -l app=productpage --no-headers -o wide 2>/dev/null | sed "s/^/     [$ns] /"
done

echo -e "\n1️⃣  Start a NON-MESH client pod in the default namespace"
line
# default enforces the 'restricted' Pod Security Standard, so the pod needs a compliant
# securityContext. curlimages/curl runs as non-root uid 100.
kubectl delete pod curl-test -n default --ignore-not-found >/dev/null 2>&1
cat <<'POD' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: curl-test, namespace: default }
spec:
  restartPolicy: Never
  containers:
  - name: curl-test
    image: curlimages/curl
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 100
      capabilities: { drop: ["ALL"] }
      seccompProfile: { type: RuntimeDefault }
POD
if ! kubectl wait --for=condition=Ready pod/curl-test -n default --timeout=60s; then
  echo "❌ The test pod did not become ready; cannot run the mTLS check."
  kubectl describe pod curl-test -n default 2>/dev/null | tail -n 15
  exit 1
fi
echo "   This pod is NOT in the mesh. It targets the INTERNAL ClusterIP services"
echo "   (productpage.<ns>:9080, in-cluster only — NOT the published Avi gateway) in plaintext."
echo "   This is the east-west \"compromised workload\" test: can a non-mesh pod reach a meshed"
echo "   service directly? With STRICT mTLS it must be refused; pure-k8s (no mesh) will answer."

# Verbose probe from the non-mesh pod: prints curl's error + http_code + timing + the pod IP
# it actually reached (proving the TCP connection was made, then reset). Echoes the code.
probe() {
  local host="$1" out
  out=$(kubectl exec curl-test -n default -- sh -c \
    "curl -sS -o /dev/null --max-time 5 -w 'http_code=%{http_code} time=%{time_total}s reached=%{remote_ip}:%{remote_port}' http://$host:9080/productpage" 2>&1)
  printf '%s\n' "$out" | sed 's/^/        /' >&2
  printf '%s' "$out" | sed -n 's/.*http_code=\([0-9][0-9]*\).*/\1/p'
}

echo -e "\n2️⃣  Sidecar mode — STRICT mTLS (expect the plaintext connection to be reset)"
echo "      curl http://productpage.bookinfo-istio-sidecar:9080/productpage"
code=$(probe productpage.bookinfo-istio-sidecar)
[ "$code" = "200" ] && echo "      ❌ NOT blocked — got HTTP 200 (is mTLS really STRICT?)" \
                     || echo "      ✅ REJECTED (http_code=${code:-000}; the Envoy sidecar requires mTLS)"

echo -e "\n3️⃣  Ambient mode — ztunnel + STRICT (expect the connection to be reset)"
echo "      curl http://productpage.bookinfo-istio-ambient:9080/productpage"
code=$(probe productpage.bookinfo-istio-ambient)
[ "$code" = "200" ] && echo "      ❌ NOT blocked — got HTTP 200 (is ztunnel enforcing?)" \
                     || echo "      ✅ REJECTED (http_code=${code:-000}; ztunnel enforces HBONE/mTLS)"

echo -e "\n4️⃣  Pure K8s mode — no mesh (expect HTTP 200 in plaintext)"
echo "      curl http://productpage.bookinfo-pure-k8s:9080/productpage"
code=$(probe productpage.bookinfo-pure-k8s)
[ "$code" = "200" ] && echo "      ✅ HTTP 200 (plaintext reachable, no mesh)" \
                    || echo "      ⚠️  Unexpected http_code=${code:-000} (is bookinfo-pure-k8s deployed?)"

echo -e "\n5️⃣  Positive control — the SAME call from INSIDE the mesh (expect HTTP 200)"
echo "      proves the app is healthy and STRICT mTLS allows in-mesh callers; only the non-mesh client is blocked."
line
if kubectl get ns bookinfo-istio-sidecar >/dev/null 2>&1; then
  kubectl delete pod curl-mesh -n bookinfo-istio-sidecar --ignore-not-found >/dev/null 2>&1
  cat <<'POD' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: curl-mesh, namespace: bookinfo-istio-sidecar }
spec:
  restartPolicy: Never
  containers:
  - name: curl
    image: curlimages/curl
    command: ["sleep", "300"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 100
      capabilities: { drop: ["ALL"] }
      seccompProfile: { type: RuntimeDefault }
POD
  echo "      (waiting for the in-mesh pod to get its sidecar...)"
  if kubectl wait --for=condition=Ready pod/curl-mesh -n bookinfo-istio-sidecar --timeout=90s >/dev/null 2>&1; then
    mout=$(kubectl exec curl-mesh -n bookinfo-istio-sidecar -- sh -c \
      "curl -sS -o /dev/null --max-time 5 -w 'http_code=%{http_code} time=%{time_total}s reached=%{remote_ip}:%{remote_port}' http://productpage:9080/productpage" 2>&1)
    printf '%s\n' "$mout" | sed 's/^/        /'
    mcode=$(printf '%s' "$mout" | sed -n 's/.*http_code=\([0-9][0-9]*\).*/\1/p')
    [ "$mcode" = "200" ] && echo "      ✅ HTTP 200 from an in-mesh client — mTLS permits it (the sidecar provides the client cert)." \
                          || echo "      ⚠️  in-mesh call returned ${mcode:-000} (sidecar may still be warming up; retry)."
  else
    echo "      (skipped: the in-mesh probe pod did not become ready in time)"
  fi
  kubectl delete pod curl-mesh -n bookinfo-istio-sidecar --ignore-not-found >/dev/null 2>&1
else
  echo "      (skipped: bookinfo-istio-sidecar is not deployed — run ./step3_scenarios.sh first)"
fi

echo -e "\n🧹 Deleting the test pod..."
kubectl delete pod curl-test -n default --ignore-not-found

echo -e "\n================================================="
echo "  Interpretation"
echo "================================================="
echo "  • Non-mesh client -> sidecar/ambient: connection RESET (http_code 000) = STRICT mTLS dropped the plaintext."
echo "  • Non-mesh client -> pure-k8s:        HTTP 200 = no encryption, anyone on the network can read it."
echo "  • In-mesh client  -> sidecar:         HTTP 200 = the mesh issues a workload cert, so mutual TLS succeeds."
echo "  The difference is the CLIENT's mesh membership, not the app — that is what mTLS buys you."
echo "  Next: ./loadtest.py  (latency/throughput comparison)"
