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
node-taint:
- node-role.kubernetes.io/control-plane=:PreferNoSchedule
kubelet-arg:
- root-dir=/var/lib/rancher/k3s/kubelet
etcd-arg:
- auto-compaction-mode=periodic
- auto-compaction-retention=1h
- quota-backend-bytes=4294967296
etcd-expose-metrics: true
kube-apiserver-arg:
- event-ttl=1h
```

k3s applies `node-taint` only when the node first registers. On a running pi-1, editing the config doesn't add the taint, so set it directly:

```bash
kubectl taint node pi-1 node-role.kubernetes.io/control-plane=:PreferNoSchedule --overwrite
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
| kube-prometheus-stack | monitoring | prometheus-community | Grafana, Prometheus, Alertmanager |
| Reloader | reloader | stakater/reloader | |
| New Relic | newrelic | newrelic/nri-bundle | k3s HelmChart CR, eBPF agent off |
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

Explicit records: `oauth.k8s`, `grafana.k8s`, `prometheus.k8s`, `dashboard.k8s`, `longhorn.k8s`, `alertmanager.k8s`

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

## Longhorn Replica Count

Volumes use 2 replicas, set by `defaultSettings.defaultReplicaCount` and `persistence.defaultClassReplicaCount` in `helm/longhorn-values.yaml`. Longhorn ignores `defaultSettings.replicaCount` because it isn't a chart key, which is why the cluster ran 3 replicas until 2026-11-19.

Lowering `numberOfReplicas` on an existing volume leaves the extra replica in place unless `replica-auto-balance` is on (`cleanupAutoBalancedReplicas` in longhorn-manager v1.11.2 `controller/volume_controller.go` returns early when it is disabled). We use `best-effort`. With `least-effort`, the cleanup on 2026-11-19 removed every replica from pi-2 and left pi-1 and pi-3 with 22 replicas each.

Each replica and engine runs as a process in its node's `instance-manager` pod. On 2026-11-19 that measured about 25 MiB per process, so replica count drives most of Longhorn's memory use.

pi-1 holds no replicas. Its Longhorn node has `allowScheduling: false`, which is runtime state, not a Helm value, so set it again after a rebuild:

```bash
kubectl -n longhorn-system patch nodes.longhorn.io pi-1 --type merge \
  -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
```

This keeps replica memory off the control-plane node. A pi-2 or pi-3 reboot leaves every volume on one replica until it comes back and rebuilds.

## Prometheus Memory

`helm/kube-prometheus-stack-values.yaml` drops the apiserver request/response histograms (about 100k of 211k series on 2026-11-19) and disables the `kubeApiserverAvailability`, `kubeApiserverBurnrate`, `kubeApiserverHistogram` and `kubeApiserverSlos` rule groups that read them. As a result, the "Kubernetes / API server" Grafana dashboard shows empty latency, availability and error-budget panels and the `KubeAPIErrorBudgetBurn` alert no longer exists. `KubeAPIDown` and `KubeClientCertificateExpiration` still fire.

Prometheus has a 768Mi request and a 1536Mi limit. It used 1146 MiB before the drop and 827 MiB right after the restart with 7d retention. If it gets OOMKilled, raise the limit or shorten retention before re-adding the histograms.

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

## etcd Capacity

When the embedded etcd database reaches its quota, k3s on pi-1 shuts down with
`etcdserver: mvcc: database space exceeded` and systemd restarts it forever, so the API is down.
It happened on 2026-09-29 (38k events, 1.6 GB) and was found again on 2026-11-17 (2.16 GB, 4,240 restarts).
Compaction frees pages inside the file but never shrinks it, so a weekly defrag is what keeps it small.

**Prevention** (all on pi-1, installed by cloud-init):
- `quota-backend-bytes=4294967296` raises the quota from the 2 GiB default.
- `etcd-defrag.timer` runs `/usr/local/bin/etcd-defrag` Sundays at 04:00. It needs `/usr/local/bin/etcdctl`, which cloud-init installs pinned and checksummed.
- `EtcdDbNearQuota` (over 70% of quota) and `EtcdUnstable` (etcd unreachable over 20% of 15 minutes) in `k8s/monitoring/etcd-rules.yaml`.
- Alertmanager sends `warning` and `critical` alerts to ntfy.sh. Set `NTFY_TOPIC` in `.env` (`openssl rand -hex 8`), run `make ntfy-secret`, and subscribe to that topic in the ntfy app. Alert labels and text go to a public service, so keep secrets out of annotations.
- `etcd-expose-metrics: true` serves unauthenticated HTTP metrics on pi-1 port 2381, reachable from the LAN. They hold no secret values. Restricting the port to the Pis and the pod CIDR is an open follow-up.

**Apply to a running pi-1** (cloud-init only runs on first boot):
1. Merge the new keys into `/etc/rancher/k3s/config.yaml`, then `sudo systemctl restart k3s`. The API is down for 2-3 minutes; pods keep running.
2. Copy `/usr/local/bin/etcd-defrag` and the two `etcd-defrag.*` units from `cloud-init/nodes/pi-1/user-data`, install `etcdctl` the same way, `sudo systemctl daemon-reload`, `sudo systemctl enable --now etcd-defrag.timer`.
3. `make ntfy-secret`, then `tail -n +2 helm/kube-prometheus-stack-values.yaml | helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --version 84.5.0 --reuse-values -f -`, then `kubectl apply -f k8s/monitoring/etcd-rules.yaml`.
4. If the upgrade fails on `Endpoints "kube-prometheus-stack-kube-etcd"`, delete that Service and Endpoints in `kube-system` and rerun it. Helm recreates them selector-less.

**Recover from "database space exceeded"** (`journalctl -u k3s | grep 'space exceeded'` on pi-1):
1. `sudo systemctl stop k3s`, then `sudo cp -a /var/lib/rancher/k3s/server/db/etcd/member/snap/db /var/lib/rancher/etcd-backup.db` (needs the disk space).
2. Add `quota-backend-bytes=4294967296` to `etcd-arg` in the k3s config if it isn't there, then `sudo systemctl start k3s` (it takes up to 3 minutes).
3. With the etcd client flags from `/usr/local/bin/etcd-defrag` (the quota raise in step 2 keeps k3s up while you do this): get the revision from `etcdctl endpoint status -w fields | awk -F': ' '/"Revision"/{print $2}'`, run `etcdctl compact <revision>`, `etcdctl defrag` (use `--command-timeout=600s`, the default 5 s fails and k3s restarts), then `etcdctl alarm disarm`.
4. Confirm `etcdctl endpoint status -w table` shows a small DB size, take a snapshot with `sudo k3s etcd-snapshot save`, and delete the backup copy.

## Paging for severe alerts (PagerDuty)

`critical` alerts go to PagerDuty as well as ntfy. PagerDuty turns each one into an incident with a link back to Alertmanager and Prometheus, and your own notification rules there decide the channel and timing (for example push at once, a phone call after 1 minute, an SMS after 3). The free plan allows 5 users and 100 SMS or phone notifications a month, so only `critical` is routed.

1. In PagerDuty, create a service named `pi-cluster` with an **Events API v2** integration and copy its 32 character integration key.
2. In the PagerDuty app, set your notification rules for high-urgency incidents (My Profile, Notification Rules).
3. Put the key in `.env` as `PAGERDUTY_ROUTING_KEY` and run `make pagerduty-secret`. Do this before the helm upgrade: Alertmanager mounts the Secret, and without it the pod stays in ContainerCreating and no alert goes anywhere. Confirm it exists with `kubectl -n monitoring get secret pagerduty-routing-key -o name`.
4. Apply: `tail -n +2 helm/kube-prometheus-stack-values.yaml | helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --version 84.5.0 --reuse-values -f -`, then wait for it with `kubectl -n monitoring rollout status statefulset/alertmanager-kube-prometheus-stack-alertmanager`.
5. Test: `kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- amtool alert add PagerTest severity=critical namespace=monitoring --annotation=summary="paging test" --alertmanager.url=http://localhost:9093`. Expect the page after about 30 seconds (Alertmanager's group wait), then resolve the incident in PagerDuty.

Alertmanager's `externalUrl` and Prometheus's `externalUrl` are set to the live `*.joeblack.nyc` hostnames so the links in a page open from a phone. They differ from the `*.k8s` hosts in the Public URLs table; update both when issue #5 is reconciled. Labels and annotations are sent to PagerDuty too, so keep secrets out of them. PagerDuty only hears about problems Alertmanager can see: if the whole cluster is down, nothing pages.

## New Relic

New Relic runs from a `HelmChart` resource that k3s's built-in helm-controller reconciles, so there is no `helm` command to run. The chart and its values live in `k8s/monitoring/newrelic.yaml`. The license key stays out of the repo: it sits in `.env` as `NEW_RELIC_LICENSE_KEY` and in the `newrelic-license` Secret.

1. Put the key in `.env`, then run `make newrelic-secret`. It also creates the `newrelic` namespace if it's missing.
2. Apply: `kubectl apply -f k8s/monitoring/newrelic.yaml`.
3. Wait for the install job: `kubectl -n kube-system get job helm-install-newrelic-bundle`, then `kubectl -n newrelic get pods`.
4. Check memory with `kubectl top nodes`. The nodes were at 69 to 84% before this install.

To upgrade, change `version` or the values in the manifest and re-apply; the controller runs `helm upgrade`. To remove it, `kubectl delete -f k8s/monitoring/newrelic.yaml`. That leaves the `newrelic` namespace and the `newrelic-license` Secret in place; delete the namespace too if you want them gone (then re-run `make newrelic-secret` before a reinstall). Helm leaves any CRDs the chart installed behind.

To rotate the license key, update `.env`, run `make newrelic-secret`, then `kubectl -n newrelic rollout restart deployment,daemonset,statefulset`. Running pods keep the old key until they restart.

`kube-state-metrics.image.tag` is pinned to `v2.13.0`, the tag New Relic's install command specifies; the chart's own default is newer. `global.region` is `US` because the chart can't infer a region from a key kept in a Secret. The eBPF agent is off for memory reasons; set `nr-ebpf-agent.enabled: true` to turn it on.

Log forwarding is on (`logging.enabled`, fluent-bit as a DaemonSet). It needs two things the nodes now provide: 4 KB kernel pages (the image fails on the Pi 5 default of 16 KB; see Kernel page size) and `fs.inotify.max_user_instances = 512` (with `fs.inotify.max_user_watches = 524288`), because the default of 128 makes fluent-bit exit with `Too many open files` on a busy node. cloud-init sets both in `/etc/sysctl.d/99-k3s.conf` on new nodes. The three running nodes were patched by hand in `/etc/sysctl.d/99-inotify.conf`; use the same file on any other running node. fluent-bit's own counters (`/api/v1/metrics` on port 2020) show records processed and any output errors or retries.

## New Relic APM auto-instrumentation

The k8s-agents-operator injects the New Relic agent into pods that opt in. `k8s/monitoring/newrelic-instrumentation.yaml` is the `Instrumentation` resource: apply it with `kubectl apply -f`. It targets pods labeled `instrument=true`, in any namespace, and injects the Node.js agent (`newrelic/newrelic-node-init`). The selector uses `operator: In` with a list of values; the operator does not accept `Eq`.

To instrument a workload, add `instrument: "true"` to its **pod template** labels (not just the Deployment's) and let it roll. Set `NEW_RELIC_APP_NAME` on the container to name the app in New Relic. The operator copies the license key from the `newrelic-key-secret` Secret (field `new_relic_license_key`, in the `newrelic` namespace) into each instrumented pod's namespace. `make newrelic-secret` creates it next to `newrelic-license`. A rotated key does not reach the copies already made; delete them and restart the pods.

Limits: the Node.js init image supports glibc Linux on amd64, arm and arm64, not Alpine (musl), and the agent runs on Node, not Bun. A Node 22 glibc pod labeled this way reported transactions to New Relic within about a minute. A workload on an Alpine or Bun image, such as ai-listings, needs a glibc Node runtime first.

## New Relic alerts

`make newrelic-alerts` creates the alert policies, conditions, notification destinations and workflows in the New Relic account through its NerdGraph API. It's safe to re-run: anything that already exists, matched by name, is skipped. It does not update a condition that already exists, so to change a threshold, edit it in New Relic or delete the condition and re-run.

It needs `NEW_RELIC_API_KEY` (a User key, starts `NRAK-`) and `NEW_RELIC_ACCOUNT_ID` in `.env`. The PagerDuty key is only needed the first time, when the PagerDuty destination gets created. The script takes it from `PAGERDUTY_ROUTING_KEY` in the environment, or else reads the `pagerduty-routing-key` Secret in the cluster. To rotate that key, delete the "PagerDuty" destination in New Relic (its channel too) and re-run.

Two policies, each with its own workflow:

- **Pi cluster critical** pages through PagerDuty and also sends a push to the New Relic mobile app. It fires when a node is not Ready or stops reporting for 5 minutes, or when etcd has no leader or stops reporting.
- **Pi cluster warning** sends a push only. It covers etcd over 70% of quota, node memory over 92%, node disk over 85%, a volume over 85% full, a crash-looping pod, a deployment missing replicas, and a failed job.

A New Relic notification channel can belong to only one workflow, which is why the push destination has two channels. The crash-looping-pod and failed-job conditions close their incident 5 minutes after their data disappears, because a filtered query has no rows once the problem clears.

etcd metrics reach New Relic through an extra scrape job (`kube-etcd`, `192.168.1.149:2381`, pi-1's etcd metrics port) in the Prometheus agent's config in `k8s/monitoring/newrelic.yaml`. If pi-1's address changes, update the target there. The mobile push destination belongs to one user and needs that person logged in to the New Relic app.

## Kernel page size (4 KB)

The nodes boot `kernel8.img`, the common 64-bit kernel with 4 KB pages. A Pi 5's firmware loads `kernel_2712.img` by default, which uses 16 KB pages, and some arm64 images don't run on those: `newrelic-fluentbit-output` stops at start with `jemalloc: Unsupported system page size`.

The switch is one line, `kernel=kernel8.img`, at the end of each node's `/tftpboot/<serial>/config.txt` on the PXE server. `setup-nfs-roots.sh` in `cloud-init/pxe-server/user-data` appends it when it builds a node's TFTP directory, so a new cluster gets it automatically. Check a node with `getconf PAGESIZE`; it prints `4096`.

To change an existing node, edit its `config.txt` and reboot it; re-running `setup-nfs-roots.sh` regenerates every `config.txt`, so a lasting change belongs in the script. Do one node at a time and take the workers first, because pi-1 is the only control-plane node and the API is unavailable for about 3 minutes while it reboots. Use `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --pod-selector='longhorn.io/component!=instance-manager'`: Longhorn's PodDisruptionBudget on `instance-manager` blocks a plain drain. After each reboot, uncordon the node and wait until every Longhorn volume reports `healthy` before touching the next one.

On the live PXE server the previous `config.txt` files were saved by hand as `config.txt.16k-backup` in each serial directory; a new cluster has no such backups. Restoring one and rebooting returns that node to 16 KB pages.

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
