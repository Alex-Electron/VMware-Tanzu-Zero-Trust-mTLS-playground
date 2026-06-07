#!/usr/bin/env python3
"""
External even-load generator for the three Bookinfo modes (sidecar / ambient / pure-k8s)
and a fair latency comparison under identical load.

- Open-loop: every mode gets the SAME RPS (load is independent of response time),
  so the comparison is fair.
- DNS-aware: connects to the VIP with a Host header; the name is resolved via the Avi
  DNS VS first, then via the OS resolver. Config (BASE_DOMAIN, AVI_DNS) comes from env.sh.
- Prints a table at the end: count / ok% / rps / p50 / p90 / p99 / avg / max per mode.

Examples:
  ./loadtest.py                      # 20 rps each, 60s
  ./loadtest.py --rps 50 --duration 120
  ./loadtest.py --rps 30 --duration 300 --path /productpage
"""
import argparse, threading, time, http.client, subprocess, sys, os, socket
import concurrent.futures

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

def env(var, default=None):
    """Read a variable from the environment, falling back to sourcing env.sh."""
    v = os.environ.get(var)
    if v:
        return v
    try:
        out = subprocess.run(
            ["bash", "-c", f'source "{SCRIPT_DIR}/env.sh" >/dev/null 2>&1 && printf "%s" "${{{var}}}"'],
            capture_output=True, text=True, timeout=5).stdout.strip()
        return out or default
    except Exception:
        return default

AVI_DNS = env("AVI_DNS", "10.144.7.101")
BASE_DOMAIN = env("BASE_DOMAIN", "n2.nested.sclabs.cloud")
PATH_DEFAULT = "/productpage"
TARGETS = [
    ("sidecar",  f"bookinfo-sidecar.{BASE_DOMAIN}"),
    ("ambient",  f"bookinfo-ambient.{BASE_DOMAIN}"),
    ("pure-k8s", f"bookinfo-pure-k8s.{BASE_DOMAIN}"),
]

def resolve(host):
    # Try the Avi DNS VS directly, then fall back to the OS resolver.
    try:
        out = subprocess.run(["dig", f"@{AVI_DNS}", "+short", "+time=2", "+tries=1", host],
                             capture_output=True, text=True, timeout=5).stdout
        for line in out.splitlines():
            line = line.strip()
            if line and line[0].isdigit():
                return line
    except Exception:
        pass
    try:
        return socket.gethostbyname(host)
    except Exception:
        return None

def pct(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    k = (len(sorted_vals) - 1) * (p / 100.0)
    f = int(k)
    return sorted_vals[f] if f + 1 >= len(sorted_vals) else sorted_vals[f] + (sorted_vals[f+1]-sorted_vals[f])*(k-f)

def run_target(name, host, vip, path, rps, duration, results):
    interval = 1.0 / rps
    deadline = time.perf_counter() + duration
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=max(8, int(rps * 3)))
    lat, codes = results[name]["lat"], results[name]["codes"]
    def one():
        t0 = time.perf_counter()
        code = 0
        try:
            c = http.client.HTTPConnection(vip, 80, timeout=10)
            c.request("GET", path, headers={"Host": host})
            r = c.getresponse(); r.read(); code = r.status; c.close()
        except Exception:
            code = 0
        lat.append((time.perf_counter() - t0) * 1000.0)
        codes.append(code)
    next_t = time.perf_counter()
    while time.perf_counter() < deadline:
        pool.submit(one)
        next_t += interval
        s = next_t - time.perf_counter()
        if s > 0:
            time.sleep(s)
    pool.shutdown(wait=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rps", type=int, default=20, help="RPS per mode (identical for all)")
    ap.add_argument("--duration", type=int, default=60, help="seconds")
    ap.add_argument("--path", default=PATH_DEFAULT)
    a = ap.parse_args()

    targets = []
    for (n, h) in TARGETS:
        ip = resolve(h)
        if ip:
            targets.append((n, h, ip))
        else:
            print(f"   ! {n:9s} -> {h} did not resolve (Avi DNS {AVI_DNS} / OS resolver); skipping")
    if not targets:
        print("No targets resolved. Make sure the apps are deployed and the names resolve.")
        sys.exit(1)

    print(f"== Load: {a.rps} rps x {a.duration}s per mode (identical), path={a.path} ==")
    for n, h, ip in targets:
        print(f"   {n:9s} -> {ip}  (Host: {h})")
    print("   ... running ...")

    results = {n: {"lat": [], "codes": []} for n, _, _ in targets}
    threads = [threading.Thread(target=run_target, args=(n, h, ip, a.path, a.rps, a.duration, results))
               for (n, h, ip) in targets]
    t0 = time.perf_counter()
    for t in threads: t.start()
    for t in threads: t.join()
    elapsed = time.perf_counter() - t0

    print(f"\n{'approach':10s} {'count':>6s} {'ok%':>5s} {'rps':>6s} {'p50':>7s} {'p90':>7s} {'p99':>7s} {'avg':>7s} {'max':>8s}  (ms)")
    print("-" * 78)
    for n, _, _ in targets:
        lat = sorted(results[n]["lat"]); codes = results[n]["codes"]
        cnt = len(codes); ok = sum(1 for c in codes if c == 200)
        okp = (ok / cnt * 100) if cnt else 0
        rps = cnt / elapsed if elapsed else 0
        print(f"{n:10s} {cnt:6d} {okp:5.0f} {rps:6.1f} {pct(lat,50):7.1f} {pct(lat,90):7.1f} "
              f"{pct(lat,99):7.1f} {(sum(lat)/len(lat) if lat else 0):7.1f} {(lat[-1] if lat else 0):8.1f}")
    print("\nCompare the rows: ambient/sidecar overhead vs the pure-k8s baseline.")

if __name__ == "__main__":
    main()
