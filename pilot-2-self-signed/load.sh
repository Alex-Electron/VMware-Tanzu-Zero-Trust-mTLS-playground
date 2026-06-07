#!/bin/bash
# Control the pilot load across the three modes (sidecar/ambient/pure-k8s).
# Usage:
#   ./load.sh on              # turn on the in-cluster even background load
#   ./load.sh off             # turn it off
#   ./load.sh status          # show state
#   ./load.sh test [rps] [sec]# external open-loop measurement from your machine
#                             # (default 30 rps x 120s), prints p50/p90/p99
cd "$(dirname "$0")"
source ./env.sh >/dev/null 2>&1
kubectl config use-context "${TKC_NAME:-tkc-01-mtls}" >/dev/null 2>&1

case "$1" in
  on)
    kubectl -n loadgen scale deploy/loadgen --replicas=1 >/dev/null
    echo "✅ Background load ON (even across all 3 modes)." ;;
  off)
    kubectl -n loadgen scale deploy/loadgen --replicas=0 >/dev/null
    echo "⏹  Background load OFF." ;;
  status)
    kubectl -n loadgen get deploy loadgen -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas 2>/dev/null ;;
  test)
    ./loadtest.py --rps "${2:-30}" --duration "${3:-120}" ;;
  *)
    echo "Usage: $0 on|off|status|test [rps] [sec]" ;;
esac
