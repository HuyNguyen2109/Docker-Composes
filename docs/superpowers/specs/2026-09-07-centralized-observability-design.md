# Centralized Observability Stack — Loki + Prometheus + Grafana + Alloy

**Date:** 2026-09-07
**Status:** Approved design (pending implementation plan)
**Branch:** develop

---

## 1. Overview & Goals

Centralize all logging and metrics from the homelab into a single observability
stack hosted on **talos-cloud-01**, replacing the current split across:

- the k8s `kube-prometheus-stack` (Prometheus + Grafana + Loki in-cluster), and
- the Docker Swarm `logging-agents` stack on tower.local (Loki + Promtail).

Goals:

1. One **Loki** (logs) + one **Prometheus** (metrics) + one **Grafana** (UI) on
   talos-cloud-01, run as a Docker Compose stack managed via **Arcane**.
2. **Grafana Alloy** on every host: k8s DaemonSet (talos-00/01/02) + standalone
   containers (tower.local, proxmox-00, talos-cloud-00, talos-cloud-01).
   Logs → Loki; metrics → Prometheus.
3. Loki long-term storage on the existing **self-hosted MinIO**
   (`s3.mcb-homelab.com`, bucket `loki`), credentials from Vault.
4. Access exclusively via the **NetBird overlay** (no public exposure of
   Loki/Prometheus push endpoints).
5. Retention: logs 30 days (Loki/MinIO), metrics 90 days (Prometheus local disk).

Non-goals: centralized alerting (Alertmanager stays in k8s for now), vault-agent
(LXC) coverage.

---

## 2. Context & Prerequisites (verified 2026-09-07)

### NTP / time-gap feasibility (why this is safe)

All six hosts were standardized on `0-3.asia.pool.ntp.org` (2026-09-07). The
daemon-reported clock offsets relative to the shared pool:

| Node | Daemon | Offset vs pool (ms) |
|---|---|---|
| talos-00 | ntpsec | −2.5 |
| talos-01 | ntpsec | +3.4 |
| talos-02 | ntpsec | −4.2 |
| proxmox-00 | chrony | +0.9 |
| talos-cloud-00 | timesyncd | −4.9 |
| talos-cloud-01 | chrony | +0.8 |

Max gap ≈ **8 ms** — far below any Loki/Alloy rejection threshold. Loki will
still get a generous `reject_old_samples_max_age` as defense in depth.

### NetBird topology (the critical finding)

- All hosts run the NetBird agent (`wt0`, `100.88.0.0/16`, DNS domain
  `netbird.selfhosted`, self-hosted management on talos-cloud-00).
- talos-cloud-01 NetBird IP: **`100.88.153.244`** (static), FQDN
  `talos-cloud-01.netbird.selfhosted`.
- **K8s pods CANNOT reach the NetBird mesh** (verified with a test pod, 100% loss):
  - pods are SNAT'd by Calico to the node's LAN IP (`192.168.1.x`) without
    NetBird's fwmark-MASQUERADE → asymmetric return path → blackhole;
  - CoreDNS forwards everything to Pi-hole, so `netbird.selfhosted` names do
    not resolve inside the cluster either.
- **`hostNetwork: true` pods CAN reach the mesh** (verified, 0% loss, ~60 ms).

**Decision:** the k8s Alloy DaemonSet runs with `hostNetwork: true` and addresses
the central stack by the static NetBird IP `100.88.153.244` (no dependency on
cluster DNS).

### Current monitoring state

- In-cluster stack is partially broken already: the kube-prometheus-stack Grafana
  deployment is in `CrashLoopBackOff` (observed 2026-09-07) — another argument
  for consolidating onto the central stack.
- Deployed versions (verified 2026-09-07, used for pinning in §4): Loki 3.6.7,
  Prometheus v3.11.2, Alloy v1.16.1, node-exporter v1.12.1.

### Current S3 backend

- **MinIO** in k8s (`k8s/homelab-external-apps/minio.yaml`, namespace
  `production-external-apps`) backed by host `192.168.1.250` (ports 9768/9769),
  exposed as `https://s3.mcb-homelab.com`.
- Current kube-prometheus-stack Loki uses Vault `kubernetes/docker-secrets`
  properties: `common-s3-endpoint`, `loki-s3-access-key`, `loki-s3-secret-key`;
  bucket `loki`, `region: auto`, `s3forcepathstyle: true`.
- Cloudflare R2 (old swarm stack) is **obsolete** — not used.

---

## 3. Target Architecture

```
                    ┌────────────────────────────────────────────────┐
                    │  talos-cloud-01  (central observability)       │
                    │  Docker compose "observability" (via Arcane)   │
                    │   ┌─────────┐   ┌────────────┐   ┌─────────┐   │
                    │   │  Loki   │   │ Prometheus │   │ Grafana │   │
                    │   └────┬────┘   └─────┬──────┘   └────┬────┘   │
                    │        │ MinIO        │ local disk     │        │
                    │        ▼              │                ▼        │
                    │   s3.mcb-homelab.com  │   Alloy (self-host)     │
                    │   bucket "loki"       │   node_exporter          │
                    └────────────────────────────────────────────────┘
          logs+metrics ↑ (NetBird overlay, static IP 100.88.153.244)
    ┌──────────────┐  ┌───────────────┐  ┌────────────────┐  ┌──────────────┐
    │ k8s DaemonSet│  │ tower.local   │  │ proxmox-00     │  │ talos-cloud-00│
    │ Alloy        │  │ Alloy + nxp   │  │ Alloy + nxp    │  │ Alloy + nxp   │
    │ hostNetwork  │  │ (unRAID)      │  │ (chrony host)  │  │               │
    └──────────────┘  └───────────────┘  └────────────────┘  └──────────────┘
```

Everything is reached over NetBird (`100.88.153.244`); the OCI public interface
(`enp0s6`, `10.0.0.79`) is firewalled off from these ports (see §6).

---

## 4. Central Stack (talos-cloud-01, Docker Compose via Arcane)

Stack name: **`observability`**, created through the Arcane API
(`https://dashboard.mcb-homelab.com`, API token from Vault — see §7).

| Service | Image | Config |
|---|---|---|
| `loki` | `grafana/loki:3.6.7` | single binary; TSDB schema v13; MinIO object store; retention 30d; see §5. Version matches the in-cluster Loki (verified) |
| `prometheus` | `prom/prometheus:v3.11.2` | `--storage.tsdb.retention.time=90d`; receives remote-writes; local disk (`/docker-volume/observability/prometheus`). Version matches in-cluster Prometheus (verified) |
| `grafana` | `grafana/grafana:11.x` | Loki + Prometheus datasources provisioned; dashboards provisioned from git JSON. Exact tag pinned at implementation time from the kube-prometheus-stack grafana subchart |
| `alloy` | `grafana/alloy:v1.16.1` | ships talos-cloud-01's own Docker logs + node metrics. Version matches the in-cluster Alloy DaemonSet (verified) |
| `node-exporter` | `prom/node-exporter:v1.12.1` | host metrics for talos-cloud-01 |

- Internal Docker network `obs-net`; **no published ports** on the public
  interface (see §6 binding).
- Compose file, Loki/Prometheus/Grafana configs, and dashboards are git-tracked
  under `docker/talos-cloud-01/observability/`.

## 5. Loki Storage (MinIO)

```
storage_config:
  aws:
    s3: s3://${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}@${AWS_ENDPOINTS}/loki
    endpoint: https://s3.mcb-homelab.com
    region: auto
    s3forcepathstyle: true
schema_config:
  configs:
    - from: 2025-01-01
      store: tsdb
      object_store: aws
      schema: v13
limits_config:
  retention_period: 30d
  reject_old_samples: true
  reject_old_samples_max_age: 168h   # tolerates node clock skew
```

- Env vars `AWS_ENDPOINTS` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` come
  from Vault `kubernetes/docker-secrets` (`common-s3-endpoint`,
  `loki-s3-access-key`, `loki-s3-secret-key`), injected as Arcane stack env —
  never in git.
- Prereq to verify during implementation: talos-cloud-01 can reach
  `https://s3.mcb-homelab.com` (path-style) from the cloud.

## 6. Exposure & Firewall

- All services listen on the **NetBird interface IP `100.88.153.244`** only
  (Docker `ports: 100.88.153.244:3100:3100` etc.), so OCI's `10.0.0.79` never
  serves them.
- Grafana, Loki, Prometheus are reachable via NetBird DNS
  (`talos-cloud-01.netbird.selfhosted`) or the static NetBird IP. No public
  auth proxy is required or planned; a future Grafana SSO (Authentik) is
  explicitly out of scope.
- Host iptables/OCI security list optionally restrict 3100/9090/3000 to
  `100.88.0.0/16` as defense in depth.

## 7. Secrets

| Secret | Source | Used by |
|---|---|---|
| `common-s3-endpoint`, `loki-s3-access-key`, `loki-s3-secret-key` | Vault `kubernetes/docker-secrets` | central Loki env |
| Arcane API token (`arc_…`) | Stored in Vault (`kubernetes/docker-secrets` → `arcane-api-token`), NOT in git | Arcane stack creation + agent deploys |

The token shared during design (`arc_88aae…e2`) is used for the rollout and
should be rotated afterwards.

## 8. Agent Layer

### k8s DaemonSet (talos-00/01/02) — ArgoCD-managed

- `hostNetwork: true` (verified working; see §2).
- Default `namespace`: `monitoring` (existing Alloy location).
- Sources:
  - `loki.source.kubernetes` (pod logs) + `loki.source.journal` (systemd) →
    `loki.write` → `http://100.88.153.244:3100/loki/api/v1/push`
  - `discovery.kubernetes` (pods/services/nodes) +
    `prometheus.operator.servicemonitors` (existing ServiceMonitor CRDs) →
    `prometheus.remote_write` → `http://100.88.153.244:9090/api/v1/write`
- Replaces `kube-prometheus-stack/values/alloy.yaml` remote endpoints
  (in-cluster Loki → central).

### Standalone Alloys (tower.local, proxmox-00, talos-cloud-00, talos-cloud-01)

- Alloy + `node-exporter` containers deployed via **Arcane** (compose files
  git-tracked under `docker/<host>/alloy/`).
- Sources per host:
  - `loki.source.syslog` on `:1514`, fed by host `rsyslog` forwarding
    `*.* @@127.0.0.1:1514` (all hosts; journald not used on unRAID);
  - `loki.source.journal` (proxmox-00, talos-cloud-00/01);
  - `loki.source.docker` (container logs on tower + cloud hosts);
  - `prometheus.scrape` of `node-exporter:9100`.
- Targets: same central endpoints via NetBird.

## 9. Decommission & Consolidation

1. **kube-prometheus-stack**: disable `prometheus` and `grafana` in values
   (`prometheus.enabled: false`, `grafana.enabled: false`); keep the chart for
   ServiceMonitor CRDs + Alloy. Alertmanager stays in k8s (out of scope).
2. **Swarm `logging-agents`** on tower.local: `docker stack rm logging-agents`
   — retire the old Loki + Promtail (R2 creds obsolete).
3. Old Grafana dashboards migrate to the central Grafana (provisioned JSON).

## 10. Verification Plan

1. Time-gap sanity (already done): offsets ≤ ~8 ms — ingest-safe.
2. Per-host agent rollout: Alloy shows UP targets in central Prometheus
   (`/api/v1/targets`) and log lines appear in Loki
   (`query_range` round-trip per host label).
3. MinIO bucket `loki` grows; `loki_ingester_chunks_flushed_total` increases.
4. Dashboards populate: syslog, Docker, node, k8s views.
5. Retention honored: `retention_period: 30d` / `tsdb.retention 90d`.

## 11. Rollout Order

1. Central stack on talos-cloud-01 (Arcane) + firewall/binding checks.
2. Repoint k8s Alloy (hostNetwork + central endpoints) via ArgoCD → verify pod
   reachability (already proven) + ingestion.
3. Standalone Alloys: tower.local, proxmox-00, talos-cloud-00, talos-cloud-01
   (Arcane) + rsyslog forwarding.
4. Consolidate: disable k8s Prometheus/Grafana; remove swarm logging-agents;
   migrate dashboards.
5. Rotate Arcane API token.

## 12. Risks & Fallbacks

| Risk | Mitigation |
|---|---|
| MinIO unreachable from cloud host | Pre-verify from talos-cloud-01; fall back to NetBird-routed endpoint if the public ingress is unavailable |
| NetBird IP drift (new peer / rebuild) | IPs are static per peer; central IP recorded in repo; agents use FQDN where cluster DNS allows, else IP |
| hostNetwork port collisions (e.g. :1514) | Alloy listen ports configurable; verify before rollout |
| Loki 3.5.1 single-binary capacity | Homelab scale; monitor `loki` resource usage; upgrade path to SimpleScalable noted |
| Arcane API schema unknown | Confirm exact create-stack endpoint during implementation; fallback: `docker compose up -d` via SSH |

## 13. Out of Scope

- Centralized Alertmanager/alerting.
- vault-agent (LXC) observability.
- Public exposure with auth (decided against).
- Grafana SSO (Authentik) — future.
- Long-term metrics storage beyond Prometheus local disk.