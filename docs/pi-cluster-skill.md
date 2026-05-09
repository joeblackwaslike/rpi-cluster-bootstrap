# Pi Cluster — Operational Knowledge

## Topology

| Node | IP | Role | Serial |
|------|----|------|--------|
| pi-1 | 192.168.1.149 | k3s server (control-plane, etcd) | c5013a79 |
| pi-2 | 192.168.1.207 | k3s agent | fc1e11b7 |
| pi-3 | 192.168.1.29  | k3s agent | 6b91f29e |
| pxe  | 192.168.1.75  | PXE/NFS boot server (Pi 4) | — |

**SSH:** `ssh -i ~/.ssh/pi-cluster pi@<ip>`  
**kubectl:** `~/.kube/config` → `https://192.168.1.149:6443`  
**kube-vip VIP:** 192.168.1.10 (Traefik LB)

## NVMe Layout (all Pi 5 nodes)

```
nvme0n1p1  512M   /boot/firmware   (FAT32, PXE cmdline → root=nvme0n1p3)
nvme0n1p2   64G   /var/lib/rancher (k3s data: etcd, containerd, kubelet)
nvme0n1p3  ~400G  /               (OS root, rsync from NFS)
```

- p2 mounted via systemd **before** k3s/k3s-agent starts:
  - `/etc/systemd/system/var-lib-rancher.mount`
  - `/etc/systemd/system/k3s.service.d/wait-for-rancher-mount.conf` (pi-1)
  - `/etc/systemd/system/k3s-agent.service.d/wait-for-rancher-mount.conf` (pi-2, pi-3)

## k3s Config

**Server** (`/etc/rancher/k3s/config.yaml` on pi-1):
```yaml
cluster-init: true
tls-san: [192.168.1.149, pi-1]
token: 83458d7f7efa21579c5d97fe3c10079f55e6a16320a37042b740408f70c79e9d
disable: [servicelb, traefik]
data-dir: /var/lib/rancher/k3s
kubelet-arg:
- root-dir=/var/lib/rancher/k3s/kubelet
```

**Agent** (`/etc/rancher/k3s/config.yaml` on pi-2, pi-3):
```yaml
server: https://192.168.1.149:6443
token: 83458d7f7efa21579c5d97fe3c10079f55e6a16320a37042b740408f70c79e9d
data-dir: /var/lib/rancher/k3s
kubelet-arg:
- root-dir=/var/lib/rancher/k3s/kubelet
```

**Critical:** `kubelet-arg: root-dir=/var/lib/rancher/k3s/kubelet` makes the kubelet
use p2 for ALL kubelet data including pod volumes and CSI plugin sockets.

## Deployed Stack

| Component | Namespace | Chart | Notes |
|-----------|-----------|-------|-------|
| MetalLB | metallb-system | metallb/metallb | Pool 192.168.1.10-19 |
| Traefik | traefik | traefik/traefik | IP 192.168.1.10 |
| cert-manager | cert-manager | jetstack/cert-manager | v1.20.2 |
| External-DNS | external-dns | edns-porkbun/external-dns-porkbun-webhook | |
| Cloudflare Tunnel | cloudflared | raw manifests | 2024.8.3, HTTP2 protocol |
| Longhorn | longhorn-system | longhorn/longhorn | CSI kubeletRootDir patched |
| NFS Provisioner | nfs-provisioner | nfs-subdir | server=192.168.1.75, path=/mnt/k8s-storage |
| kube-prometheus-stack | monitoring | prometheus-community | Grafana, Prometheus, Alertmanager |
| Loki | monitoring | grafana/loki-stack | |
| Reloader | reloader | stakater/reloader | |
| Kured | kured | kubereboot/kured | reboots 02-05 ET, /sentinel path |
| Tailscale Operator | tailscale | tailscale/tailscale-operator | |
| oauth2-proxy | oauth2-proxy | oauth2-proxy/oauth2-proxy | GitHub OAuth |
| Kubernetes Dashboard | kubernetes-dashboard | k8s/dashboard | |

## TLS Certificates

**Wildcard cert:** `*.k8s.joeblack.nyc` via Let's Encrypt DNS01 + Porkbun API.

- Obtained by `lego` CronJob (`lego-cert-renewal` in cert-manager namespace)
- Stored as `wildcard-k8s-tls` Secret in: traefik, monitoring, oauth2-proxy, kubernetes-dashboard, longhorn-system
- Renewal: auto-runs 1st of each month; runs `lego renew --days 30` then falls back to `lego run`
- **LE rate limit:** 5 certs per 7 days for exact domain set. Don't spam re-issue.

HTTP01 challenge **does not work** — cfargotunnel.com CNAME only resolves to private IPv6.
Always use DNS01 with the lego CronJob.

## DNS (Porkbun — joeblack.nyc)

All `*.k8s` and explicit subdomains CNAME → `1ee1e71f-263e-4de6-a31b-7cb04cf79036.cfargotunnel.com.`

Explicit records: `oauth.k8s`, `grafana.k8s`, `prometheus.k8s`, `dashboard.k8s`, `longhorn.k8s`, `alertmanager.k8s`, `loki.k8s`

**Note:** `.nyc` TLD cannot use Cloudflare nameservers. Domain stays on Porkbun.

## Public URLs

| Service | URL |
|---------|-----|
| Grafana | https://grafana.k8s.joeblack.nyc |
| Prometheus | https://prometheus.k8s.joeblack.nyc |
| Alertmanager | https://alertmanager.k8s.joeblack.nyc |
| Longhorn UI | https://longhorn.k8s.joeblack.nyc |
| Dashboard | https://dashboard.k8s.joeblack.nyc |
| oauth2-proxy | https://oauth.k8s.joeblack.nyc |

All routes protected by GitHub OAuth (oauth2-proxy). Only `joeblackwaslike` allowed.

## Longhorn CSI — Critical Patches

After any `helm upgrade longhorn`, the DaemonSet `longhorn-csi-plugin` **must** have these patches applied:

```bash
# 1. Volume hostPaths → k3s kubelet path
kubectl patch daemonset longhorn-csi-plugin -n longhorn-system --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/volumes/0/hostPath/path","value":"/var/lib/rancher/k3s/kubelet/plugins/kubernetes.io/csi"},
  {"op":"replace","path":"/spec/template/spec/volumes/1/hostPath/path","value":"/var/lib/rancher/k3s/kubelet/plugins_registry"},
  {"op":"replace","path":"/spec/template/spec/volumes/2/hostPath/path","value":"/var/lib/rancher/k3s/kubelet/plugins/driver.longhorn.io"},
  {"op":"replace","path":"/spec/template/spec/volumes/3/hostPath/path","value":"/var/lib/rancher/k3s/kubelet/pods"}
]'

# 2. Container mountPaths (Bidirectional propagation must match hostPath)
kubectl patch daemonset longhorn-csi-plugin -n longhorn-system --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/2/volumeMounts/1/mountPath","value":"/var/lib/rancher/k3s/kubelet/plugins/kubernetes.io/csi"},
  {"op":"replace","path":"/spec/template/spec/containers/2/volumeMounts/2/mountPath","value":"/var/lib/rancher/k3s/kubelet/pods"}
]'

# 3. node-driver-registrar registration path
kubectl patch daemonset longhorn-csi-plugin -n longhorn-system --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/args/2","value":"--kubelet-registration-path=/var/lib/rancher/k3s/kubelet/plugins/driver.longhorn.io/csi.sock"}
]'
```

Also patch the CSI sidecar deployments (attacher, provisioner, resizer, snapshotter) socket-dir hostPath.

**Why:** k3s with `kubelet-arg: root-dir=/var/lib/rancher/k3s/kubelet` uses a non-default kubelet root.
Longhorn's Helm chart doesn't respect `csi.kubeletRootDir` fully — volume hostPaths AND container mountPaths must match.

## Cloudflare Tunnel

**Tunnel ID:** `1ee1e71f-263e-4de6-a31b-7cb04cf79036`  
**Credentials:** 1Password → "Cloudflare Tunnel - joeblack-homelab"  
**Protocol:** HTTP2 (QUIC drops connections causing pod exits)  
**Note:** cloudflared exits when all connections fail. k8s restarts it. With 2 replicas, one is usually up.

## Credentials (all in 1Password — Personal vault)

| Item | Notes |
|------|-------|
| Cloudflare API | Tunnel management |
| Porkbun API | DNS records + cert DNS01 challenges |
| Cloudflare Tunnel - joeblack-homelab | tunnel_id, token, account_id |
| oauth2-proxy - joeblack-homelab | cookie_secret, github_client_id/secret |
| Tailscale trust oauth creds | k8s operator client id/secret |

## MCP Servers (Claude Code `~/.claude/settings.json`)

- `kubernetes` — mcp-server-kubernetes, KUBECONFIG=/Users/joe/.kube/config  
- `cloudflare` — @cloudflare/mcp-server-cloudflare via op run  
- `porkbun` — mcp-server-porkbun via op run

## Common Operations

**Refresh kubeconfig** (after k3s cert regeneration):
```bash
ssh -i ~/.ssh/pi-cluster pi@192.168.1.149 "sudo cat /etc/rancher/k3s/k3s.yaml" > /tmp/k3s.yaml
sed -i '' 's|https://127.0.0.1:6443|https://192.168.1.149:6443|g' /tmp/k3s.yaml
cp /tmp/k3s.yaml ~/.kube/config
```

**Restart agent after cert issues:**
```bash
for ip in 192.168.1.207 192.168.1.29; do
  ssh -i ~/.ssh/pi-cluster pi@$ip "sudo rm -f /var/lib/rancher/k3s/agent/client-*.{crt,key} /var/lib/rancher/k3s/agent/server-ca.crt && sudo systemctl restart k3s-agent"
done
```

**Force lego cert renewal now:**
```bash
kubectl create job --from=cronjob/lego-cert-renewal lego-manual-$(date +%s) -n cert-manager
```

**Longhorn CSI stuck (volume attached but not mounting):**
Check that `pods-mount-dir` container mountPath is `/var/lib/rancher/k3s/kubelet/pods` (not `/var/lib/kubelet/pods`).
The `Bidirectional` propagation must write mounts to the path the kubelet actually watches.

## Ubiquiti Switch

**API:** `https://192.168.1.1/proxy/network/api/s/default/`  
**Key:** `gWeU8v5paf__9M8qwnO7L3RCdtzXlUE3`  
**Switch MAC:** `24:5a:4c:92:09:be`  
Port assignments: pi-1=port1, pi-2=port2, pi-3=port3
