#!/bin/bash
# Pilot environment configuration — edit these values for your environment.

# --- Supervisor / infrastructure ---
export SUPERVISOR_IP="supervisor.n2.nested.sclabs.cloud"   # vSphere Supervisor FQDN (or IP)
export AVI_CONTROLLER="10.0.20.80"                          # NSX ALB (Avi) Controller
export AVI_DNS="10.144.7.101"                               # Avi DNS service VIP (authoritative for the lab zone)
export BASE_DOMAIN="n2.nested.sclabs.cloud"             # DNS zone for the Gateway API hostnames (bookinfo/kiali/grafana)

# --- Target cluster ---
export VSPHERE_NAMESPACE="dz-istio"
export TKC_NAME="tkc-01-mtls"                               # VKS (TKG) cluster name
export CERT_FILE="pilot-2-root.crt"                       # exported lab root CA filename (import into your browser)

# --- Avi / AKO installation (rendered into manifests/03-ako-values.yaml) ---
export AVI_CLOUD_NAME="n2-vc"                               # Avi cloud name
export AVI_SE_GROUP="ako-se-group"                          # Avi Service Engine Group for this cluster
export AVI_CONTROLLER_VERSION="31.2.2"                      # Avi Controller version
export AVI_TENANT="admin"                                   # Avi tenant
export AVI_VIP_NETWORK="net-10.144.6"                       # Avi network that carries the VIPs
export AVI_VIP_CIDR="10.144.6.0/24"                         # VIP network CIDR
export AVI_NODE_NETWORK="net-10.144.7"                      # Avi network for cluster nodes
export AVI_NODE_CIDR="10.144.7.0/24"                        # node network CIDR

# --- Pinned component versions (the pilot is tested on exactly these) ---
export ISTIO_VERSION="1.30.0"                              # Istio (ambient) - must match your istioctl
export AKO_VERSION="2.1.4"                                 # AKO chart -> helm-charts/ako-2.1.4.tgz
export CM_VERSION="1.14.5"                                 # cert-manager chart -> helm-charts/cert-manager-v1.14.5.tgz
export GATEWAY_API_VERSION="v1.3.0"                       # Gateway API CRDs (standard channel)

# --- Credentials ---
export KUBECTL_VSPHERE_PASSWORD='VMware1!'                  # vSphere SSO (administrator@vsphere.local)
export AVI_USERNAME="admin"                                 # Avi Controller user
export AVI_PASSWORD="VMware1!"                              # Avi Controller password

echo "✅ Environment variables loaded"
