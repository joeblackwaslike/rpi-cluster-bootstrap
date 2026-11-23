# New Relic

Everything the cluster and its hosts send to New Relic, how it gets there, and where to look at it. The install, upgrade and key-rotation steps live in [operations.md](operations.md); this page is the overview.

Account `8755228`, US region, cluster name `cluster`. Sign in at [one.newrelic.com](https://one.newrelic.com).

## What sends data

| Source | Where it runs | What it sends |
|---|---|---|
| `nri-bundle` 8.0.40 | k3s `HelmChart` in `k8s/monitoring/newrelic.yaml`, namespace `newrelic` | Everything below except the PXE host |
| Kubernetes integration (`nrk8s-kubelet`, `nrk8s-controlplane`, `nrk8s-ksm`) | One pod per node, plus one for kube-state-metrics | Node, pod, container, volume, deployment and job state (`K8s*Sample` events) |
| `newrelic-logging` (fluent-bit) | DaemonSet, one per node | Pod logs, k3s journal, kernel messages (see Logs) |
| `nri-kube-events` | Deployment | Kubernetes events (`InfrastructureEvent`) |
| `newrelic-prometheus-agent` | StatefulSet | Prometheus metrics, including the extra `kube-etcd` scrape of `192.168.1.149:2381` (pi-1's etcd) |
| `k8s-agents-operator` + `nri-metadata-injection` | Deployments | APM auto-instrumentation (see APM) |
| `newrelic-infra` | systemd service on the PXE server (`pi-pxe`, 192.168.1.75) | Host metrics and logs, installed by `make newrelic-infra` |

Settings that shape the data: `global.lowDataMode: true` (drops low-value attributes and metrics), the eBPF agent is off for memory, and the license key never touches the repo (`.env` and the `newrelic-license` Secret).

The nodes are Pi 5s booting `kernel8.img` (4 KB pages); the fluent-bit image needs that. `lima-mac-1`, a fourth node, runs the same DaemonSets.

## Logs

fluent-bit sends three streams. All records carry `cluster_name` and `node_name`.

| Stream | Filter in New Relic | Notes |
|---|---|---|
| Pod logs | `namespace_name`, `pod_name`, `container_name` | Every namespace |
| k3s journal | `unit IN ('k3s.service', 'k3s-agent.service')` | apiserver, kubelet, scheduler, etcd and containerd all log inside these units |
| Kernel and warnings | `transport = 'kernel'`, or `PRIORITY` of 4 or lower | Kernel ring buffer plus warning-and-worse from any unit. `audit:` lines are dropped (up to about 9,000 a day on one node, from iptables and BPF program loads) |

The nodes keep journald in memory, so the journal sits in `/run/log/journal`, and the DaemonSet mounts that path. The PXE server sends its own logs: dnsmasq, tftpd-hpa, nfs-mountd, tailscaled, chrony and docker from journald, plus `/var/log/kern.log`.

Where to look:

1. The Logs UI. In the left nav, open Logs. Type a filter such as `node_name:pi-2` or `unit:k3s-agent.service`, or switch to the NRQL tab and paste a query from below.
2. A pod's own page. In the left nav, open Kubernetes, pick the cluster `cluster`, open a pod, then its Logs tab.
3. The query builder. In the left nav, open Query your data and paste NRQL. Use this for anything with `FACET`.

Queries to start from:

```sql
SELECT message FROM Log WHERE node_name = 'pi-2' SINCE 1 hour ago
SELECT message FROM Log WHERE unit IN ('k3s.service', 'k3s-agent.service') SINCE 1 hour ago
SELECT message FROM Log WHERE transport = 'kernel' FACET node_name SINCE 1 day ago
SELECT message FROM Log WHERE transport = 'kernel' AND PRIORITY <= 4 SINCE 7 days ago
SELECT message FROM Log WHERE hostname = 'pi-pxe' SINCE 1 hour ago
SELECT count(*) FROM Log FACET node_name SINCE 15 minutes ago
```

Kernel messages worth searching for: `Out of memory`, `Killed process`, `Undervoltage`, `nvme`, `I/O error`, `EXT4-fs error`.

## Metrics and events

| Question | Where | NRQL |
|---|---|---|
| Is a node healthy, how full is it | **Kubernetes** explorer, or Query builder | `SELECT latest(allocatableMemoryUtilization), latest(fsCapacityUtilization) FROM K8sNodeSample FACET nodeName` |
| Which pods restart or crash | Same | `SELECT latest(restartCount) FROM K8sContainerSample WHERE clusterName = 'cluster' FACET podName` |
| Volume usage | Same | `SELECT max(fsUsedPercent) FROM K8sVolumeSample WHERE pvcName IS NOT NULL FACET pvcName` |
| Cluster events | Query builder | `SELECT * FROM InfrastructureEvent WHERE clusterName = 'cluster' SINCE 1 hour ago` |
| etcd health | Query builder | `SELECT latest(etcd_server_has_leader), max(etcd_mvcc_db_total_size_in_bytes) FROM Metric WHERE job = 'kube-etcd'` |
| PXE host | **Infrastructure**, **Hosts**, `pi-pxe` | `SELECT latest(memoryUsedPercent), latest(diskUsedPercent) FROM SystemSample WHERE hostname = 'pi-pxe'` |

No custom dashboards exist in the account. The **Kubernetes** explorer and **Infrastructure** hosts view are New Relic's own; to pin a view, run any query above in Query builder and use **Add to dashboard**.

## APM

The operator injects the Node.js agent into pods labeled `instrument=true` (set on the pod template, not only the Deployment). The `Instrumentation` resource is `k8s/monitoring/newrelic-instrumentation.yaml`. A workload needs a glibc-based Node image; Bun and Alpine (musl) images can't use the agent. No production workload is instrumented yet. Once one is, find it under **APM & Services**. Setup steps are in [operations.md](operations.md#new-relic-apm-auto-instrumentation).

The operator's own logs appear under the mutated pod's name: `SELECT message FROM Log WHERE logger = 'mutation-webhook'`.

## Alerts

`make newrelic-alerts` builds everything below through the NerdGraph API and is safe to re-run. View incidents under **Alerts**, then **Issues & activity**.

| Policy | Notifies | Conditions (all 5 to 15 minutes of sustained breach) |
|---|---|---|
| Pi cluster critical (`8366486`) | PagerDuty and mobile push | Node not ready or silent, etcd has no leader or is silent |
| Pi cluster warning (`8366487`) | Mobile push | Node memory over 92%, node disk over 85%, volume over 85%, etcd over 70% of quota, pod crash looping, deployment missing replicas, job failed |

Because the node and etcd conditions fire when data stops, a node that dies completely still pages. Nothing yet alerts when the PXE server goes quiet.

## Known behavior

- The PXE server has 897 MB of RAM. On first install the agent's fluent-bit child read the whole journal and the kernel killed `newrelic-infra` once (2026-11-22 01:37, `kern.log`). dnsmasq, tftpd and NFS were not affected, and the agent has been stable since.
- Journal logs older than 48 hours are dropped by New Relic, so history uploaded on a fresh install is trimmed.
- avahi-daemon logs about 2,500 warnings a day on pi-1 and pi-3 and passes the warning filter.
- After deleting CRDs, restart k3s on pi-1 (`sudo systemctl restart k3s`). The controller manager keeps watching removed types and logs about 800 errors an hour until it restarts.
