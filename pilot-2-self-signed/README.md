# Pilot guide — Istio mTLS + Avi AKO on VKS

A full, step-by-step walkthrough of the pilot: what to run, in what order, what each step should produce, and why.

## What this pilot proves

The same Bookinfo app is deployed **three ways in one VKS cluster** — plain Kubernetes, mTLS via the Istio sidecar, and mTLS via Istio ambient — and every one of them is published through **NSX ALB (Avi)** using the **Gateway API + AKO**, with mesh-wide `STRICT` mTLS. Then an even load runs against all three so you can compare latency and resource cost.

The point: a Zero-Trust, mTLS-everywhere service mesh inside VMware **vSphere Kubernetes Service (VKS, formerly vSphere with Tanzu)** is achievable today, and it integrates natively with the platform's own load balancer through the Gateway API. The article that frames all of this is in the [repository root README](../README.md).

## Tested versions

| Component | Version |
|---|---|
| VMware vSphere (vCenter) | 8.0 U3 (8.0.3, build 25197330) |
| VKS (vSphere Kubernetes Service) | 3.6.2 |
| Kubernetes release (VKr) | `v1.34.2---vmware.2-vkr.2` |
| NSX ALB (Avi) Controller | 31.2.2 |
| Avi Kubernetes Operator (AKO) | 2.1.4 |
| Istio (ambient profile) | 1.30.0 |
| Gateway API (standard channel) | v1.3.0 |
| cert-manager (lab HTTPS CA only) | v1.14.5 |

All versions are pinned in `env.sh` (`ISTIO_VERSION`, `AKO_VERSION`, `CM_VERSION`, `GATEWAY_API_VERSION`) and the cluster manifest. References: [AKO 2.1.4 release notes](https://techdocs.broadcom.com/us/en/vmware-security-load-balancing/avi-load-balancer/avi-kubernetes-operator/2-1/ako-release-notes/release-notes-for-ako-version-2-1-2.html) · [AKO compatibility matrix](https://techdocs.broadcom.com/us/en/vmware-security-load-balancing/avi-load-balancer/avi-kubernetes-operator/2-1/ako-release-notes/compatibility-guide-for-ako.html) (Avi Controller ≥ 30.1.1) · [AKO Gateway API + Istio mTLS](https://techdocs.broadcom.com/us/en/vmware-security-load-balancing/avi-load-balancer/avi-kubernetes-operator/2-1/avi-kubernetes-operator-guide-2-1/avi-kubernetes-operator-deployment-guide/service-mesh/ako-gateway-api-with-istio-mtls-support.html).

## Environment requirements (must exist before you start)

The pilot provisions a cluster and the mesh; it does **not** build the platform underneath. All of the following has to be in place first.

### 1. vSphere + VKS
- vSphere with the **Supervisor enabled** and VKS 3.6.x.
- A **vSphere namespace** you can deploy into, with `administrator@vsphere.local` access. Inside it:
  - a **Kubernetes release (VKr)** in the content library — `kubectl get kr` (the pilot uses `v1.34.2`);
  - **VM classes** bound to the namespace — `kubectl get virtualmachineclass -n <ns>` (`best-effort-small`, `best-effort-medium`);
  - a **storage class/policy** — `kubectl get storageclass` (`k8s-policy`).
- The `builtin-generic-v3.6.0` **ClusterClass**, served from `vmware-system-vks-public` (ships with VKS 3.6).

### 2. NSX ALB (Avi) — and the Supervisor must run on the Avi load balancer
- **Avi Controller** (31.2.x) reachable from your workstation.
- The **Supervisor is configured with NSX ALB (Avi) as its load balancer** — the Supervisor API and every `Service` of type `LoadBalancer` are fronted by Avi. (This is what makes AKO + Gateway API the native ingress path.)
- An Avi **Service Engine Group**, a **VIP network** and a **node network**, and the Avi **cloud** — all referenced in `env.sh`.

### 3. DNS services for the Gateway API
Every Gateway API hostname is published as an Avi VIP and must resolve. You need an **Avi DNS service** (a DNS Virtual Service) that is authoritative for your zone and answers for:
- the **Supervisor FQDN** (so `kubectl vsphere login` works by name);
- `bookinfo-sidecar.<domain>`, `bookinfo-ambient.<domain>`, `bookinfo-pure-k8s.<domain>`;
- `kiali.<domain>`, `grafana.<domain>`.

Your workstation must use that DNS for the zone (over the VPN/resolver), or add the names to `/etc/hosts`. `step0` checks this and tells you exactly what is missing.

### 4. Workstation tools
`kubectl` + the vSphere plugin (`kubectl-vsphere`), `helm`, `istioctl` **1.30.0**, `dig`, and `python3` with the `requests` module. `step0` verifies all of them (and offers to `pip install requests`); `step2` downloads the Helm charts and, if needed, `istioctl 1.30.0` automatically.

### 5. Configuration
Edit **`env.sh`** with your values: Supervisor FQDN, Avi controller/DNS, cluster name, namespace, networks, cloud, SE group, `BASE_DOMAIN`, pinned versions, and credentials. The install-specific AKO settings are rendered from `env.sh` into `manifests/03-ako-values.yaml` at deploy time, so nothing environment-specific is hard-coded in the manifests.

## The steps (order · what it does · expected result · why)

Run them in order from the `pilot-2-self-signed/` directory. All manifests live in `manifests/`, numbered by the order the pilot applies them (`01-cluster` … `12-comparison-dashboard`).

### `./step0_verify_infra.sh` — pre-flight
- **Does:** checks the workstation tools; verifies the Avi Service Engines and DNS VS are up; resolves the Supervisor FQDN (Avi DNS + OS resolver); and **server-side dry-runs `manifests/01-cluster.yaml`** so the ClusterClass, Kubernetes release, VM classes and storage are confirmed available in your namespace.
- **Result:** every check is ✅ and it prints *"All prerequisites satisfied — ready to provision."*
- **Why:** catch a missing prerequisite in seconds, instead of after a 20-minute provisioning attempt fails.

### `./step1_provision.sh` — provision the cluster
- **Does:** applies `manifests/01-cluster.yaml`, then watches the cluster, printing live progress (phase, `Available`, and `nodes Running X/Y`).
- **Result:** it stops on its own with *"Cluster is provisioned and available — N/N nodes Running"* (1 control-plane + 3 workers).
- **Why:** this is the workload cluster the mesh runs in.

### `./step2_setup_mesh.sh` — install the mesh and AKO
- **Does:** installs **Istio 1.30.0 (ambient profile)**, **cert-manager** with a self-signed lab CA, and **AKO 2.1.4 in Istio mode**. Versions and charts are pinned; AKO's `avi-system` namespace is kept on the **classic sidecar** (see the nuance below).
- **Result:** `istiod`, `istio-cni`, `ztunnel`, `cert-manager` and `ako` are Running; the lab root CA is written to `$CERT_FILE`. It waits for AKO and prints ✅ when ready.
- **Why:** the Zero-Trust data plane, plus the AKO integration that lets Avi speak mTLS into the mesh.

### `./step3_scenarios.sh` — deploy the three scenarios + monitoring
- **Does:** installs Kiali, Prometheus and Grafana over HTTPS **first** (so you can watch each mode appear), then deploys Bookinfo three times — `bookinfo-pure-k8s` (no Istio), then `bookinfo-istio-sidecar` and `bookinfo-istio-ambient` (both with `PeerAuthentication STRICT`) — each behind its own Avi VIP via the Gateway API; finally it starts the even load generator. It waits until each gateway actually answers over HTTPS, **prints the open URL as it deploys each mode**, and pauses between modes so you can watch them appear.
- **First — import the CA:** add the lab root CA (`pilot-2-root.crt`, written by step 2) to your browser as trusted, or every HTTPS page warns. The script prints the exact file path and reminds you before the first pause.
- **What to open and where to look:**
  - **Apps** (each link is printed right after that mode deploys):
    - `https://bookinfo-pure-k8s.<domain>/productpage` — no Istio, plaintext, no lock
    - `https://bookinfo-sidecar.<domain>/productpage` — mTLS via the sidecar
    - `https://bookinfo-ambient.<domain>/productpage` — mTLS via ztunnel
  - **Kiali** — `https://kiali.<domain>/kiali` → **Graph**, select the three `bookinfo-*` namespaces, then Display → enable **Security** to see the mTLS lock badges on the edges. Click a pod: sidecar shows **2/2** (app + `istio-proxy`), ambient and pure-k8s show **1/1**.
  - **Grafana** — `https://grafana.<domain>/` → the **Mesh Comparison** dashboard (auto-provisioned) → latency p50/p90/p99 and per-container CPU/memory (`istio-proxy` vs `ztunnel` vs `waypoint`).
- **Result:** all three Bookinfo URLs answer over HTTPS, Kiali and Grafana are reachable, load is flowing. The script ends with a consolidated list of every access link.
- **Why:** the three comparison subjects, plus the observability to see mTLS and measure the cost.

### `./step4_verify_mtls.sh` — prove STRICT mTLS
- **Does:** from a pod that is **not** in the mesh, calls each mode's **internal** `productpage` service (`productpage.<ns>:9080`) directly in plaintext — east-west, bypassing the Avi gateway (the "attacker already has a foothold in the cluster" case) — then repeats the call from inside the mesh as a positive control.
- **What to look for in the output:**
  - sidecar / ambient → `Connection reset by peer`, `http_code=000` = **REJECTED** by mTLS
  - pure-k8s → `http_code=200` = plaintext reachable (no mesh)
  - in-mesh client → `http_code=200` = a valid mesh identity is accepted
  - the `reached=<ClusterIP>:9080` field proves the TCP actually reached the service before the reset — it is the mesh dropping plaintext, not a routing miss
- **Result:** plaintext from outside the mesh is dropped for the two meshed modes and allowed for pure-k8s — Zero-Trust is actually enforced.
- **Why:** "STRICT" only matters if you show non-mesh traffic is really dropped.

### Load and numbers
- **`./loadtest.py`** sends an identical RPS to all three modes and prints `p50/p90/p99` (or use `./load.sh on` for the in-cluster generator that fills Kiali/Grafana). the `mesh-compare` Grafana dashboard (`manifests/12-comparison-dashboard.json`) is provisioned into Grafana automatically by step 3 (via its dashboards ConfigMap, so it survives restarts).
- **Why:** the latency and resource comparison between plain, sidecar and ambient.

### Access
Import the lab root CA (`$CERT_FILE`) into your browser, then:
- `https://bookinfo-{sidecar,ambient,pure-k8s}.<domain>/productpage`
- `https://kiali.<domain>/kiali` · `https://grafana.<domain>/`

### Teardown and rollback
- **`./rollback.sh`** — the single teardown tool: an interactive menu (driven by env.sh, no arguments). It shows the cluster/namespace and asks **what** to remove; each destructive choice confirms first:

  | Menu option | Removes | Keeps |
  |---|---|---|
  | Step 4 | the mTLS test pod | everything else |
  | Step 3 | Bookinfo ×3 + `loadgen` + monitoring (Kiali / Prometheus / Grafana) | the cluster + mesh |
  | Step 2 | AKO + cert-manager + Istio (and their namespaces) | the cluster |
  | Step 1 | the whole cluster (also wipes steps 2–4) | — |

  Each step undoes exactly what that step created (for step 3 the monitoring manifests are deleted the same way they were applied, rendered with `BASE_DOMAIN`). After a step rollback you can re-run just that step. Step 1 is a **hard** delete: AKO is torn down with the cluster and may leave orphaned Avi objects (VS/pools/VIPs), so for a clean Avi state roll back steps 3 and 2 first. The vSphere namespace is never deleted — its owner created it.

## The nuance that makes it work

With mesh-wide `STRICT` mTLS the external load balancer still has to reach the pods. AKO can speak mTLS into the mesh (`AKOSettings.istioEnabled: true`), but it reads its workload certificate from `/etc/istio-output-certs`, and **only the classic Istio sidecar writes that directory** — ambient's ztunnel does not. So the pilot runs a hybrid: business apps on **ambient**, and the `avi-system` namespace (where AKO lives) on the **sidecar**. They coexist in the same cluster. The article walks the packet path end to end.
