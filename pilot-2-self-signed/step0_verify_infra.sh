#!/bin/bash

if [ ! -f ./env.sh ]; then
  echo "env.sh not found — run this from the pilot-2-self-signed directory."
  exit 1
fi
source ./env.sh

echo "=== Check 0: Required tooling ==="
miss=0
for c in kubectl helm istioctl dig python3; do
  if command -v "$c" >/dev/null 2>&1; then echo "✅ $c"; else echo "❌ $c not found in PATH"; miss=1; fi
done
# python 'requests' module (used by utils/check_ses.py and utils/check_vs.py) -- offer to install if missing
if python3 -c "import requests" >/dev/null 2>&1; then
  echo "✅ python module: requests"
else
  echo "⚠️  python module 'requests' is missing."
  read -r -p "   Install it now via pip? [Y/n] " ans
  if [ "$ans" != "n" ] && [ "$ans" != "N" ]; then
    python3 -m pip install requests 2>/dev/null \
      || python3 -m pip install --user requests 2>/dev/null \
      || python3 -m pip install --break-system-packages requests 2>/dev/null
  fi
  if python3 -c "import requests" >/dev/null 2>&1; then
    echo "✅ requests installed"
  else
    echo "❌ could not install 'requests' (try: pip3 install requests, or use a venv)"; miss=1
  fi
fi
if [ "$miss" -ne 0 ]; then echo "❌ Install the missing tools, then re-run."; exit 1; fi

echo -e "\n=== Check 1: Avi Service Engines ==="
python3 utils/check_ses.py

echo -e "\n=== Check 2: Avi DNS Service ==="
python3 utils/check_vs.py | grep "dns-vs-primary"

echo -e "\n=== Check 3: DNS resolution ==="
FQDN="$SUPERVISOR_IP"
# 3a. Is the record published in Avi DNS (authoritative)? Needs a route to the Avi DNS VIP.
if [ -n "$AVI_DNS" ]; then
  AVI_REC=$(dig @"$AVI_DNS" +short +time=2 +tries=1 "$FQDN" 2>/dev/null | grep -Eo '^[0-9]+(\.[0-9]+){3}$' | head -n1)
  if [ -n "$AVI_REC" ]; then
    echo "✅ Avi DNS ($AVI_DNS): $FQDN -> $AVI_REC"
  else
    echo "⚠️  Avi DNS ($AVI_DNS) not answering — record missing, or no route to the $AVI_DNS network"
  fi
fi
# 3b. Can THIS host resolve it -- the path kubectl/curl will actually use?
IP=$(python3 -c "import socket, sys; print(socket.gethostbyname(sys.argv[1]))" "$FQDN" 2>/dev/null)
if [ -n "$IP" ]; then
  echo "✅ OS resolver: $FQDN -> $IP"
else
  echo "❌ OS resolver cannot resolve $FQDN — the Supervisor is not reachable by name."
  echo "   Make sure the VPN routes the lab network and uses Avi DNS ($AVI_DNS) for this zone,"
  echo "   or add an /etc/hosts entry:  <supervisor-ip>  $FQDN"
  exit 1
fi

echo -e "\n=== Check 4: Cluster provisioning prerequisites (Supervisor) ==="
kubectl vsphere login --server="$SUPERVISOR_IP" --insecure-skip-tls-verify \
  -u administrator@vsphere.local >/dev/null 2>&1
kubectl config use-context "$SUPERVISOR_IP" >/dev/null 2>&1
echo "Target namespace (from env.sh): $VSPHERE_NAMESPACE"

MANIFEST="manifests/01-cluster.yaml"
KVER=$(grep -m1 -E '^[[:space:]]*version:[[:space:]]*v1\.' "$MANIFEST" | awk '{print $2}')
VMCLASSES=$(grep -E 'value:[[:space:]]*best-effort' "$MANIFEST" | awk '{print $2}' | sort -u)
SCLASS=$(awk '/name: storageClass/{getline; print $2; exit}' "$MANIFEST")

# Documented discovery -- "Workflow for Provisioning VKS Clusters Using kubectl"
echo "-- Discovery (what the namespace offers) --"
kubectl get kr 2>/dev/null | grep -q "$KVER" \
  && echo "✅ Kubernetes release $KVER offered" \
  || echo "⚠️  $KVER not seen in 'kubectl get kr' (check the content library)"
for vc in $VMCLASSES; do
  kubectl get virtualmachineclass "$vc" -n "$VSPHERE_NAMESPACE" >/dev/null 2>&1 \
    && echo "✅ VM class $vc bound to $VSPHERE_NAMESPACE" \
    || echo "⚠️  VM class $vc not bound to $VSPHERE_NAMESPACE"
done
kubectl get storageclass "$SCLASS" >/dev/null 2>&1 \
  && echo "✅ StorageClass $SCLASS available" \
  || echo "⚠️  StorageClass $SCLASS not found"

# Authoritative gate: server-side dry-run (resolves ClusterClass, VKr, VM classes,
# storage, variables, webhooks) with the cluster name from env.sh. Creates nothing.
echo "-- Validation (server-side dry-run, nothing is created) --"
if out=$(kubectl apply -f "$MANIFEST" -n "$VSPHERE_NAMESPACE" --dry-run=server 2>&1); then
  echo "✅ $out"
  echo -e "\n🎉 All prerequisites satisfied — ready to provision the cluster."
  echo "   Next: ./step1_provision.sh"
else
  echo "❌ Manifest failed server-side validation:"
  echo "$out"
  exit 1
fi
