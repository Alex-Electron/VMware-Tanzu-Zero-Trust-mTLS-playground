#!/bin/bash
# In-cluster sequential benchmark — isolates the mesh "tax" per mode.
# A fortio pod is deployed INTO each mode's namespace (so it inherits the mode:
# sidecar=injected, ambient=ztunnel-captured, pure=plain) and loads the LOCAL
# productpage:9080 directly (no gateway, no tunnel). Modes are run one at a time,
# interleaved over ROUNDS, so they never contend for the client/node/SE at once.
#
# Params (env): QPS=50 DUR=120s CONN=16 WARM=20s ROUNDS=3 OUT=/tmp/bench
set -u
cd "$(dirname "$0")/.."
source ./env.sh
CTX="$TKC_NAME"
kc() { kubectl --context "$CTX" "$@"; }

QPS=${QPS:-50}; DUR=${DUR:-120s}; CONN=${CONN:-16}; WARM=${WARM:-20s}; ROUNDS=${ROUNDS:-3}
OUT=${OUT:-/tmp/bench}; mkdir -p "$OUT"
: > "$OUT/resources.txt"

declare -A NS=( [pure]=bookinfo-pure-k8s [sidecar]=bookinfo-istio-sidecar [ambient]=bookinfo-istio-ambient )
ORDER=(pure sidecar ambient)

echo "[$(date +%H:%M:%S)] loadgen OFF (isolate the bench)"
kc -n loadgen scale deploy/loadgen --replicas=0 >/dev/null 2>&1

echo "[$(date +%H:%M:%S)] deploying fortio into each namespace..."
for m in "${ORDER[@]}"; do
  ns=${NS[$m]}
  cat <<YAML | kc apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: { name: fortio, namespace: $ns }
spec:
  replicas: 1
  selector: { matchLabels: { app: fortio } }
  template:
    metadata: { labels: { app: fortio } }
    spec:
      containers:
      - name: fortio
        image: fortio/fortio
        args: ["server"]
YAML
done
for m in "${ORDER[@]}"; do kc -n "${NS[$m]}" rollout status deploy/fortio --timeout=180s; done

run_one() {  # $1 mode  $2 round
  local m=$1 r=$2 ns=${NS[$m]}
  echo "[$(date +%H:%M:%S)] round $r  mode $m  ($ns)"
  # warm-up (discarded)
  kc -n "$ns" exec deploy/fortio -- fortio load -qps "$QPS" -c "$CONN" -t "$WARM" -quiet "http://${TARGET:-productpage}:9080${TPATH:-/productpage}" >/dev/null 2>&1
  # sample per-container resources during the measured run (this ns + ztunnel + waypoint)
  ( for i in 1 2 3 4 5; do
      ts=$(date +%H:%M:%S)
      kc top pod -n "$ns" --containers --no-headers 2>/dev/null | awk -v p="$m r$r $ts" '{print p, $0}'
      kc top pod -n istio-system --containers --no-headers 2>/dev/null | grep ztunnel | awk -v p="$m r$r $ts ZTUN" '{print p, $0}'
      sleep 20
    done >> "$OUT/resources.txt" ) &
  local respid=$!
  # measured run -> fortio JSON
  kc -n "$ns" exec deploy/fortio -- fortio load -qps "$QPS" -c "$CONN" -t "$DUR" -json - "http://${TARGET:-productpage}:9080${TPATH:-/productpage}" > "$OUT/${m}_r${r}.json" 2>/dev/null
  wait $respid 2>/dev/null
}

for r in $(seq 1 "$ROUNDS"); do
  for m in "${ORDER[@]}"; do run_one "$m" "$r"; done
done

echo "[$(date +%H:%M:%S)] cleanup fortio + restore loadgen"
for m in "${ORDER[@]}"; do kc -n "${NS[$m]}" delete deploy/fortio --ignore-not-found >/dev/null 2>&1; done
kc -n loadgen scale deploy/loadgen --replicas=1 >/dev/null 2>&1
echo "[$(date +%H:%M:%S)] DONE. fortio JSON in $OUT/*.json , resources in $OUT/resources.txt"
