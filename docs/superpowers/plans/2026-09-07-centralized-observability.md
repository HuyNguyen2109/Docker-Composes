# Centralized Observability Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a centralized Loki + Prometheus + Grafana (+ Alloy agents on every host) stack on talos-cloud-01 per `docs/superpowers/specs/2026-09-07-centralized-observability-design.md`, and consolidate the existing k8s and swarm monitoring onto it.

**Architecture:** talos-cloud-01 runs a Docker Compose stack `observability` (Loki 3.6.7, Prometheus v3.11.2, Grafana 11.x, Alloy v1.16.1, node-exporter v1.12.1), reachable only over the NetBird overlay at static IP `100.88.153.244`. Logs and metrics from all hosts flow in through Grafana Alloy agents (k8s DaemonSet with `hostNetwork: true`; standalone containers on tower.local, proxmox-00, talos-cloud-00, talos-cloud-01). Loki persists to self-hosted MinIO (`s3.mcb-homelab.com`, bucket `loki`, Vault credentials).

**Tech Stack:** Docker Compose, Grafana Alloy (River config), Loki, Prometheus, Grafana, MinIO (S3), Vault, NetBird, Arcane (dashboard.mcb-homelab.com), ArgoCD, rsyslog/journald, shell.

## Global Constraints

- Cluster-bound commits land on branch `develop` (ArgoCD apps target `develop`).
- Central endpoints (use verbatim everywhere): Loki push `http://100.88.153.244:3100/loki/api/v1/push`; Prometheus remote-write `http://100.88.153.244:9090/api/v1/write`; NetBird IP `100.88.153.244`.
- Versions pinned (verified 2026-09-07): `grafana/loki:3.6.7`, `prom/prometheus:v3.11.2`, `grafana/grafana:11.5.2`, `grafana/alloy:v1.16.1`, `prom/node-exporter:v1.12.1`.
- S3: endpoint/creds from Vault `kubernetes/docker-secrets` properties `common-s3-endpoint`, `loki-s3-access-key`, `loki-s3-secret-key`; bucket `loki`; `region: auto`; `s3forcepathstyle: true`. Never commit secrets or the `.env` file.
- Retention: Loki 30d (`limits_config.retention_period`), Prometheus 90d (`--storage.tsdb.retention.time=90d`).
- Exposure: bind all published ports to `100.88.153.244` only. No public exposure of Loki/Prometheus.
- Time-gap feasibility already verified (≈8 ms max clock spread) — no ingest-safety action needed beyond `reject_old_samples_max_age: 168h`.

---

### Task 1: Prerequisites & Arcane API discovery

**Files:** none (read-only verification)

**Interfaces:**
- Consumes: SSH keys `/root/ssh-keys/homelab-linux` and `/root/ssh-keys/oracle`; Vault env (`VAULT_ADDR`, `vault` CLI v2.1.0 on controller); NetBird IP `100.88.153.244`; Arcane API token (user-provided `arc_…`, to be stored in Vault in Task 10).
- Produces: a decision — Arcane API works (use it for stack/agent creation) or fall back to the SSH+docker-compose deploy scripts written in Tasks 2/6.

- [ ] **Step 1: Verify S3/Vault prerequisites**

Run (on controller):
```bash
vault kv get -field=common-s3-endpoint kubernetes/docker-secrets
vault kv get -field=loki-s3-access-key kubernetes/docker-secrets
```
Expected: `https://s3.mcb-homelab.com` printed for the first command; a non-empty key for the second. (Do not print the secret value beyond confirming it is non-empty.)

- [ ] **Step 2: Verify MinIO reachability from talos-cloud-01**

Run:
```bash
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 "curl -skI --connect-timeout 5 https://s3.mcb-homelab.com | head -3; echo rc=$?"
```
Expected: an HTTP reply line (`HTTP/2 403` is fine — TLS+reachability is what matters), `rc=0`. If unreachable, stop and report — the S3 backend must be reachable from the cloud host before Loki can start.

- [ ] **Step 3: Verify NetBird connectivity to the target**

Run (from controller):
```bash
ssh -i /root/ssh-keys/homelab-linux ubuntu@192.168.1.11 "ping -c 2 -W 2 100.88.153.244 | tail -2"
```
Expected: `0% packet loss`. (Host-level path, already verified once; re-check before rollout.)

- [ ] **Step 4: Discover the Arcane API surface**

```bash
for base in /openapi.json /swagger.json /api/openapi.json /api/docs /api; do
  echo "== $base =="
  curl -sk -o /dev/null -w "%{http_code}\n" --connect-timeout 5 "https://dashboard.mcb-homelab.com$base"
done
curl -sk --connect-timeout 5 "https://dashboard.mcb-homelab.com/openapi.json" | head -c 400
```
Expected: at least one `200`; the OpenAPI JSON (if present) names the stacks endpoint (e.g. `POST /api/v1/stacks`) and its request schema (compose content + environment variables + target host selector).

- [ ] **Step 5: Record the decision**

If Step 4 found a working create-stack endpoint and the token authenticates (`curl -sk -H "Authorization: Bearer $TOKEN" https://dashboard.mcb-homelab.com<stacks-endpoint> | head`), note in the plan/commit message that Arcane will be used for stack creation. Otherwise switch every "deploy via Arcane" step to the provided SSH fallback script (`deploy_observability.sh` / `deploy_agent.sh`). No commit (nothing changed).

---

### Task 2: Central stack files in repo

**Files:**
- Create: `docker/talos-cloud-01/observability/compose.yaml`
- Create: `docker/talos-cloud-01/observability/config/loki-config.yml`
- Create: `docker/talos-cloud-01/observability/config/prometheus.yml`
- Create: `docker/talos-cloud-01/observability/config/alloy-local.alloy`
- Create: `docker/talos-cloud-01/observability/config/grafana/provisioning/datasources/datasources.yaml`
- Create: `docker/talos-cloud-01/observability/config/grafana/provisioning/dashboards/dashboards.yaml`
- Create: `docker/talos-cloud-01/observability/config/grafana/dashboards/node-overview.json`
- Create: `docker/talos-cloud-01/observability/config/grafana/dashboards/logs.json`
- Create: `docker/talos-cloud-01/observability/.env.example`
- Create: `docker/talos-cloud-01/observability/deploy_observability.sh`

**Interfaces:**
- Consumes: Task 1 decision (Arcane vs script).
- Produces: the deployable stack bundle; `deploy_observability.sh` is the canonical (fallback) deployer; compose service names `loki`, `prometheus`, `grafana`, `alloy`, `node-exporter` on network `obs-net`.

- [ ] **Step 1: Create `compose.yaml`**

```yaml
name: observability

services:
  loki:
    image: grafana/loki:3.6.7
    container_name: obs-loki
    restart: unless-stopped
    command:
      - -config.file=/etc/loki/loki-config.yml
      - -config.expand-env=true
    env_file: .env
    ports:
      - "100.88.153.244:3100:3100"
    volumes:
      - ./config/loki-config.yml:/etc/loki/loki-config.yml:ro
      - /docker-volume/observability/loki:/loki
    networks: [obs-net]

  prometheus:
    image: prom/prometheus:v3.11.2
    container_name: obs-prometheus
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=90d
    ports:
      - "100.88.153.244:9090:9090"
    volumes:
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - /docker-volume/observability/prometheus:/prometheus
    networks: [obs-net]

  grafana:
    image: grafana/grafana:11.5.2
    container_name: obs-grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "false"
    ports:
      - "100.88.153.244:3000:3000"
    volumes:
      - ./config/grafana/provisioning:/etc/grafana/provisioning:ro
      - ./config/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - /docker-volume/observability/grafana:/var/lib/grafana
    networks: [obs-net]

  alloy:
    image: grafana/alloy:v1.16.1
    container_name: obs-alloy
    restart: unless-stopped
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - /etc/alloy/config.alloy
    ports:
      - "100.88.153.244:12345:12345"
    volumes:
      - ./config/alloy-local.alloy:/etc/alloy/config.alloy:ro
      - /var/log:/var/log:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock
    networks: [obs-net]

  node-exporter:
    image: prom/node-exporter:v1.12.1
    container_name: obs-node-exporter
    restart: unless-stopped
    pid: host
    network_mode: host
    volumes:
      - /:/rootfs:ro,rslave
    command:
      - --path.rootfs=/rootfs

networks:
  obs-net:
    driver: bridge
```

- [ ] **Step 2: Create `config/loki-config.yml`**

```yaml
auth_enabled: false
server:
  http_listen_port: 3100
common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2025-01-01
      store: tsdb
      object_store: aws
      schema: v13
      index:
        prefix: index_
        period: 24h
storage_config:
  aws:
    s3: s3://${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}@${AWS_ENDPOINTS}/loki
    endpoint: https://s3.mcb-homelab.com
    region: auto
    s3forcepathstyle: true
compactor:
  working_directory: /loki/compactor
  compactor_ring:
    kvstore:
      store: inmemory
limits_config:
  retention_period: 30d
  reject_old_samples: true
  reject_old_samples_max_age: 168h
```

- [ ] **Step 3: Create `config/prometheus.yml`**

```yaml
global:
  scrape_interval: 30s
  evaluation_interval: 30s
scrape_configs: []
```

- [ ] **Step 4: Create `config/alloy-local.alloy`**

```alloy
logging {
  level = "info"
}

discovery.docker "self" {
  host = "unix:///var/run/docker.sock"
}

loki.source.docker "self" {
  host     = "unix:///var/run/docker.sock"
  targets  = discovery.docker.self.targets
  forward_to = [loki.relabel.host.receiver]
}

loki.source.file "syslog" {
  targets = [{
    __path__ = "/var/log/syslog",
  }]
  forward_to = [loki.relabel.host.receiver]
}

loki.relabel "host" {
  forward_to = [loki.write.central.receiver]

  rule {
    target_label = "host"
    replacement   = "talos-cloud-01"
  }
}

loki.write "central" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}

prometheus.scrape "node" {
  targets = [{
    __address__ = "127.0.0.1:9100",
  }]
  forward_to = [prometheus.relabel.host_metrics.receiver]
}

prometheus.relabel "host_metrics" {
  forward_to = [prometheus.remote_write.central.receiver]

  rule {
    target_label = "host"
    replacement   = "talos-cloud-01"
  }
}

prometheus.remote_write "central" {
  endpoint {
    url = "http://prometheus:9090/api/v1/write"
  }
}
```

- [ ] **Step 5: Create Grafana provisioning files and dashboards**

`config/grafana/provisioning/datasources/datasources.yaml`:
```yaml
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    uid: loki
    url: http://loki:3100
    access: proxy
  - name: Prometheus
    type: prometheus
    uid: prometheus
    url: http://prometheus:9090
    access: proxy
    isDefault: true
```

`config/grafana/provisioning/dashboards/dashboards.yaml`:
```yaml
apiVersion: 1
providers:
  - name: default
    folder: Homelab
    type: file
    disableDeletion: false
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
```

`config/grafana/dashboards/node-overview.json`:
```json
{
  "annotations": {"list": []},
  "editable": true,
  "graphTooltip": 1,
  "panels": [
    {
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "fieldConfig": {"defaults": {"unit": "short"}},
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
      "id": 1,
      "targets": [{"expr": "rate(node_cpu_seconds_total{mode=\"idle\"}[5m])", "refId": "A"}],
      "title": "CPU idle rate",
      "type": "timeseries"
    },
    {
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "fieldConfig": {"defaults": {"unit": "bytes"}},
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
      "id": 2,
      "targets": [{"expr": "node_memory_MemAvailable_bytes", "refId": "A"}],
      "title": "Memory available",
      "type": "timeseries"
    }
  ],
  "schemaVersion": 39,
  "title": "Node Overview",
  "uid": "homelab-node",
  "version": 1
}
```

`config/grafana/dashboards/logs.json`:
```json
{
  "annotations": {"list": []},
  "editable": true,
  "graphTooltip": 1,
  "panels": [
    {
      "datasource": {"type": "loki", "uid": "loki"},
      "gridPos": {"h": 12, "w": 24, "x": 0, "y": 0},
      "id": 1,
      "options": {"showTime": true, "showLabels": false},
      "targets": [{"expr": "{host=~\".+\"}", "refId": "A"}],
      "title": "All Logs",
      "type": "logs"
    }
  ],
  "schemaVersion": 39,
  "title": "Homelab Logs",
  "uid": "homelab-logs",
  "version": 1
}
```

- [ ] **Step 6: Create `.env.example` and `deploy_observability.sh`**

`.env.example`:
```
# Populated at deploy time from Vault (kubernetes/docker-secrets) — never commit .env
AWS_ENDPOINTS=https://s3.mcb-homelab.com
AWS_ACCESS_KEY_ID=changeme
AWS_SECRET_ACCESS_KEY=changeme
GRAFANA_ADMIN_PASSWORD=changeme
```

`deploy_observability.sh`:
```bash
#!/usr/bin/env bash
# Deploys the central observability stack to talos-cloud-01.
# Fallback path if Arcane API is unavailable (see Task 1 decision).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="opc@140.245.100.82"
SSH_KEY="/root/ssh-keys/oracle"
REMOTE_DIR="/docker-volume/observability"

[ -x "$(command -v vault)" ] || { echo "vault CLI required" >&2; exit 1; }

echo "== fetching S3 credentials from Vault =="
S3_ENDPOINT="$(vault kv get -field=common-s3-endpoint kubernetes/docker-secrets)"
S3_ACCESS="$(vault kv get -field=loki-s3-access-key kubernetes/docker-secrets)"
S3_SECRET="$(vault kv get -field=loki-s3-secret-key kubernetes/docker-secrets)"
GF_PASS="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -hex 16)}"
echo "Grafana admin password: ${GF_PASS}  (set GRAFANA_ADMIN_PASSWORD to override)"

echo "== building .env =="
printf 'AWS_ENDPOINTS=%s\nAWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nGRAFANA_ADMIN_PASSWORD=%s\n' \
  "$S3_ENDPOINT" "$S3_ACCESS" "$S3_SECRET" "$GF_PASS" > "${DIR}/.env"
chmod 600 "${DIR}/.env"

echo "== preparing remote dirs =="
ssh -i "$SSH_KEY" "$TARGET" "sudo mkdir -p ${REMOTE_DIR}/{loki,prometheus,grafana} && sudo chown -R \$(id -u):\$(id -g) ${REMOTE_DIR}"

echo "== uploading stack =="
scp -i "$SSH_KEY" -r "${DIR}/compose.yaml" "${DIR}/config" "${DIR}/.env" "$TARGET":/tmp/obs/
ssh -i "$SSH_KEY" "$TARGET" "sudo cp -r /tmp/obs/* ${REMOTE_DIR}/"

echo "== starting stack =="
ssh -i "$SSH_KEY" "$TARGET" "cd ${REMOTE_DIR} && sudo docker compose up -d"

echo "== health check =="
ssh -i "$SSH_KEY" "$TARGET" "cd ${REMOTE_DIR} && sudo docker compose ps"
```

Make it executable, then validate YAML syntax:
```bash
chmod +x docker/talos-cloud-01/observability/deploy_observability.sh
python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in ['docker/talos-cloud-01/observability/compose.yaml','docker/talos-cloud-01/observability/config/loki-config.yml','docker/talos-cloud-01/observability/config/prometheus.yml']]; print('YAML OK')"
```
Expected: `YAML OK`.

- [ ] **Step 7: Commit**

```bash
git add docker/talos-cloud-01/observability
git commit -m "feat(observability): central stack files for talos-cloud-01 (loki+prometheus+grafana+alloy)"
```

---

### Task 3: Deploy the central stack on talos-cloud-01

**Files:** none (remote action)

**Interfaces:**
- Consumes: Task 2 bundle; Task 1 decision.
- Produces: running stack on talos-cloud-01; verified bindings on `100.88.153.244` only.

- [ ] **Step 1: Deploy (Arcane path — if Task 1 found the API)**

Using the discovered endpoint, create the stack on host talos-cloud-01 with:
- compose content = Task 2 `compose.yaml`
- env = the three S3 vars + a generated `GRAFANA_ADMIN_PASSWORD`

Example (adapt path/schema to what Task 1 discovered):
```bash
curl -sk -X POST "https://dashboard.mcb-homelab.com/api/v1/stacks" \
  -H "Authorization: Bearer ${ARCANE_TOKEN}" -H "Content-Type: application/json" \
  -d '{"name":"observability","host":"talos-cloud-01","compose":"<compose.yaml content>","environment":{"AWS_ENDPOINTS":"...","AWS_ACCESS_KEY_ID":"...","AWS_SECRET_ACCESS_KEY":"...","GRAFANA_ADMIN_PASSWORD":"..."}}'
```
Expected: `200` with a stack/host id.

**Step 1-alt: Deploy (SSH fallback — default)**

```bash
./docker/talos-cloud-01/observability/deploy_observability.sh
```
Expected: compose reports `Started`/`Running` for `obs-loki`, `obs-prometheus`, `obs-grafana`, `obs-alloy`, `obs-node-exporter`. Note the printed Grafana admin password.

- [ ] **Step 2: Verify containers & port bindings**

```bash
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 "sudo docker compose -f /docker-volume/observability/compose.yaml ps --format '{{.Name}} {{.Status}}'"
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 "sudo ss -tlnp | grep -E ':3100|:9090|:3000|:12345'"
```
Expected: 5 containers with `Up`/`healthy`; **all** listeners bound to `100.88.153.244` (nothing on `0.0.0.0` or `10.0.0.79`).

- [ ] **Step 3: Verify Loki readiness over NetBird (from controller)**

```bash
curl -sk --connect-timeout 5 http://100.88.153.244:3100/ready
curl -sk --connect-timeout 5 http://100.88.153.244:9090/-/ready
```
Expected: Loki replies `ready`; Prometheus replies `Prometheus Server is Ready.`

- [ ] **Step 4: Commit any fix-ups**

If Step 1 required file changes (e.g. env syntax), commit:
```bash
git add docker/talos-cloud-01/observability
git commit -m "fix(observability): deploy adjustments for central stack"
```

---

### Task 4: End-to-end ingest verification from talos-cloud-01

**Files:** none

**Interfaces:**
- Consumes: Task 3 running stack.
- Produces: proof that logs and metrics flow into central Loki/Prometheus.

- [ ] **Step 1: Verify self-host Alloy ships logs to Loki**

```bash
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 "sudo docker logs --tail 20 obs-alloy 2>&1 | grep -iE 'error|failed' || echo NO-ERRORS"
curl -sk --get --data-urlencode 'query={host="talos-cloud-01"}' \
  --data-urlencode 'limit=3' "http://100.88.153.244:3100/loki/api/v1/query_range" | head -c 600
```
Expected: no Alloy errors; Loki returns at least one stream entry with label `host="talos-cloud-01"` (Docker container logs).

- [ ] **Step 2: Verify node metrics arrive in Prometheus**

```bash
curl -sk http://100.88.153.244:9090/api/v1/targets | python3 -c "import json,sys; d=json.load(sys.stdin); [print(t['labels'].get('job'), t['health']) for t in d['data']['activeTargets']]"
curl -sk --get --data-urlencode 'query=count(node_memory_MemAvailable_bytes)' http://100.88.153.244:9090/api/v1/query | head -c 300
```
Expected: at least one target (`node` job) with `up`; metric query returns a value (count ≥ 1).

- [ ] **Step 3: Verify Grafana serves and sees datasources**

```bash
curl -sk http://100.88.153.244:3000/api/health
```
Expected: `{"database":"ok","version":"11...",...}`. (No password needed for health; do not log in yet.)

---

### Task 5: Repoint the k8s Alloy DaemonSet to the central stack

**Files:**
- Modify: `k8s/kube-prometheus-stack/values/alloy.yaml` (config block and `hostNetwork`)

**Interfaces:**
- Consumes: `kube-prometheus-stack` ArgoCD app (chart 87.16.1, values from repo, auto-sync on `develop`); ServiceMonitor CRDs + RBAC already in place (verified).
- Produces: DaemonSet Alloy reaching the central stack from all three k8s nodes; node metrics + ServiceMonitor metrics flowing to central Prometheus.

- [ ] **Step 1: Edit the Alloy config block**

In `k8s/kube-prometheus-stack/values/alloy.yaml`, replace the `loki.write "loki"` block:
```alloy
      loki.write "loki" {
        endpoint {
          url = "http://loki-gateway/loki/api/v1/push"
          tenant_id = "1"
        }
      }
```
with a central target plus host labelling and metrics pipelines:
```alloy
      loki.write "loki" {
        endpoint {
          url = "http://100.88.153.244:3100/loki/api/v1/push"
        }
      }
      loki.relabel "host" {
        forward_to = [loki.write.loki.receiver]

        rule {
          source_labels = ["__meta_kubernetes_pod_node_name"]
          target_label  = "host"
          action        = "replace"
        }
      }
      discovery.kubernetes "nodes" {
        role = "node"
      }
      prometheus.scrape "nodes" {
        targets    = discovery.kubernetes.nodes.targets
        forward_to = [prometheus.relabel.node_host.receiver]
      }
      prometheus.relabel "node_host" {
        forward_to = [prometheus.remote_write.central.receiver]

        rule {
          source_labels = ["__meta_kubernetes_node_name"]
          target_label  = "host"
          action        = "replace"
        }
      }
      prometheus.operator.servicemonitors "default" {
        forward_to = [prometheus.remote_write.central.receiver]
      }
      prometheus.remote_write "central" {
        endpoint {
          url = "http://100.88.153.244:9090/api/v1/write"
        }
      }
```
Then in the **same** file, wire the log sources through the new relabel into the existing pipeline: change `loki.source.kubernetes "pods"`'s `forward_to` from `[loki.process.process.receiver]` to `[loki.relabel.host.receiver]`, and set the new `loki.relabel "host"` block's `forward_to` to `[loki.process.process.receiver]`. `loki.process "process"` keeps its existing `forward_to = [loki.write.loki.receiver]`. Final chain: `loki.source.kubernetes.pods → loki.relabel.host → loki.process.process → loki.write.loki`.

- [ ] **Step 2: Enable host networking**

In `k8s/kube-prometheus-stack/values/alloy.yaml` change:
```yaml
  hostNetwork: false
```
to:
```yaml
  hostNetwork: true
```

- [ ] **Step 3: Validate the config**

```bash
grep -n "100.88.153.244" k8s/kube-prometheus-stack/values/alloy.yaml | wc -l
grep -n "hostNetwork: true" k8s/kube-prometheus-stack/values/alloy.yaml
```
Expected: first command prints `4` (loki write URL, remote-write URL); second prints a line `…hostNetwork: true`.

- [ ] **Step 4: Push to develop and wait for ArgoCD sync**

```bash
git add k8s/kube-prometheus-stack/values/alloy.yaml
git commit -m "feat(observability): point k8s alloy daemonset at central stack (hostNetwork, remote-write)"
git push origin develop
```
Then poll the application:
```bash
curl -sk -H "Authorization: Bearer $ARGOCD_TOKEN" \
  "https://argocd.ingress.internal/api/v1/applications/kube-prometheus-stack" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['status']['sync']['status'], d['status']['health']['status'])"
```
Expected: `Synced Healthy` (allow a few minutes for auto-sync + rollout).

- [ ] **Step 5: Verify DaemonSet pods use host networking**

```bash
ssh -i /root/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy -o wide"
```
Expected: three Alloy pods, one per node, with `hostIP` equal to their own node IPs (192.168.1.11/12/13).

- [ ] **Step 6: Verify end-to-end from the cluster**

```bash
curl -sk --get --data-urlencode 'query={host=~"talos-00|talos-01|talos-02"}' \
  --data-urlencode 'limit=3' "http://100.88.153.244:3100/loki/api/v1/query_range" | head -c 600
curl -sk http://100.88.153.244:9090/api/v1/targets | python3 -c "import json,sys; d=json.load(sys.stdin); [print(t['labels'].get('job'), t['labels'].get('instance'), t['health']) for t in d['data']['activeTargets']]"
curl -sk --get --data-urlencode 'query=count(node_memory_MemAvailable_bytes{job=\"nodes\"})' http://100.88.153.244:9090/api/v1/query | head -c 300
```
Expected: pod log lines on all three `host=` labels; `nodes` and `prometheus`-operator targets `up`; node metric count == number of k8s nodes (or more, after Tasks 6-8).

---

### Task 6: Alloy agent on tower.local (unRAID)

**Files:**
- Create: `docker/tower.local/alloy/compose.yaml`
- Create: `docker/tower.local/alloy/config.alloy`
- Create: `docker/tower.local/alloy/deploy_agent.sh`
- Create: `scripts/agent-deploy.md` (usage note)

**Interfaces:**
- Consumes: `deploy_agent.sh` shared helper (defined here, used by Tasks 7-8).
- Produces: tower.local logs (unRAID syslog via `loki.source.file` — journald does not exist on unRAID) + Docker container logs + node metrics in the central stack, labelled `host="tower"`.

- [ ] **Step 1: Create `compose.yaml`** (agents only ever initiate outbound connections to the central stack — no published ports)

```yaml
name: alloy-tower

services:
  alloy:
    image: grafana/alloy:v1.16.1
    container_name: tower-alloy
    restart: unless-stopped
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - /etc/alloy/config.alloy
    volumes:
      - ./config.alloy:/etc/alloy/config.alloy:ro
      - /var/log:/var/log:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock
    networks: [obs-net]

  node-exporter:
    image: prom/node-exporter:v1.12.1
    container_name: tower-node-exporter
    restart: unless-stopped
    pid: host
    network_mode: host
    volumes:
      - /:/rootfs:ro,rslave
    command:
      - --path.rootfs=/rootfs

networks:
  obs-net:
    external: true
```

- [ ] **Step 2: Create `config.alloy`**

```alloy
logging {
  level = "info"
}

discovery.docker "self" {
  host = "unix:///var/run/docker.sock"
}

loki.source.docker "self" {
  host     = "unix:///var/run/docker.sock"
  targets  = discovery.docker.self.targets
  forward_to = [loki.relabel.host.receiver]
}

loki.source.file "syslog" {
  targets = [{
    __path__ = "/var/log/syslog",
  }]
  forward_to = [loki.relabel.host.receiver]
}

loki.relabel "host" {
  forward_to = [loki.write.central.receiver]

  rule {
    target_label = "host"
    replacement   = "tower"
  }
}

loki.write "central" {
  endpoint {
    url = "http://100.88.153.244:3100/loki/api/v1/push"
  }
}

prometheus.scrape "node" {
  targets = [{
    __address__ = "127.0.0.1:9100",
  }]
  forward_to = [prometheus.relabel.host_metrics.receiver]
}

prometheus.relabel "host_metrics" {
  forward_to = [prometheus.remote_write.central.receiver]

  rule {
    target_label = "host"
    replacement   = "tower"
  }
}

prometheus.remote_write "central" {
  endpoint {
    url = "http://100.88.153.244:9090/api/v1/write"
  }
}
```

- [ ] **Step 3: Create `deploy_agent.sh`** (shared by Tasks 6-8)

```bash
#!/usr/bin/env bash
# Deploys an Alloy agent stack to a Docker host via SSH (fallback path —
# use Arcane API if available per Task 1). Usage: deploy_agent.sh <host> <user> <ssh_key> <local_dir> <remote_dir>
set -euo pipefail
HOST="$1"; USER="$2"; KEY="$3"; LOCAL_DIR="$4"; REMOTE_DIR="$5"
ssh -i "$KEY" "$USER@$HOST" "sudo mkdir -p $REMOTE_DIR"
scp -i "$KEY" -r "$LOCAL_DIR"/compose.yaml "$LOCAL_DIR"/config.alloy "$USER@$HOST":/tmp/alloy/
ssh -i "$KEY" "$USER@$HOST" "sudo cp -r /tmp/alloy/* $REMOTE_DIR/ && cd $REMOTE_DIR && sudo docker compose up -d && sudo docker compose ps --format '{{.Name}} {{.Status}}'"
```
Make executable. Usage note `scripts/agent-deploy.md` documents the four positional args (one line per host).

- [ ] **Step 4: Deploy to tower.local**

On unRAID, Docker Compose (v2) is available; the agent needs the `monitoring-internetwork`… in this design the agent uses a self-created external network. Create it first:
```bash
ssh -i /root/ssh-keys/homelab-linux root@192.168.1.40 "docker network create obs-net 2>/dev/null || true"
./docker/tower.local/alloy/deploy_agent.sh 192.168.1.40 root /root/ssh-keys/homelab-linux \
  "$(pwd)/docker/tower.local/alloy" /docker-volume/alloy
```
Expected: `tower-alloy` and `tower-node-exporter` `Up`.

- [ ] **Step 5: Verify**

```bash
curl -sk --get --data-urlencode 'query={host="tower"}' \
  --data-urlencode 'limit=3' "http://100.88.153.244:3100/loki/api/v1/query_range" | head -c 600
curl -sk --get --data-urlencode 'query=node_memory_MemAvailable_bytes{host="tower"}' \
  http://100.88.153.244:9090/api/v1/query | python3 -c "import json,sys; d=json.load(sys.stdin); print('tower node_exporter series:', len(d['data']['result']))"
```
Expected: stream entries with `host="tower"`; at least one node-exporter series with `host="tower"` (metrics carry the label thanks to `prometheus.relabel.host_metrics`).

- [ ] **Step 6: Commit**

```bash
git add docker/tower.local/alloy scripts/agent-deploy.md
git commit -m "feat(observability): alloy agent for tower.local (+ shared agent deploy helper)"
```

---

### Task 7: Alloy agent on proxmox-00

**Files:**
- Create: `docker/proxmox-00/alloy/compose.yaml`
- Create: `docker/proxmox-00/alloy/config.alloy`

**Interfaces:**
- Consumes: `deploy_agent.sh` from Task 6.
- Produces: proxmox-00 journald + syslog + node metrics in central stack, labelled `host="proxmox-00"`.

- [ ] **Step 1: Create `compose.yaml`**

```yaml
name: alloy-proxmox

services:
  alloy:
    image: grafana/alloy:v1.16.1
    container_name: proxmox-alloy
    restart: unless-stopped
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - /etc/alloy/config.alloy
    volumes:
      - ./config.alloy:/etc/alloy/config.alloy:ro
      - /var/log:/var/log:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [obs-net]

  node-exporter:
    image: prom/node-exporter:v1.12.1
    container_name: proxmox-node-exporter
    restart: unless-stopped
    pid: host
    network_mode: host
    volumes:
      - /:/rootfs:ro,rslave
    command:
      - --path.rootfs=/rootfs

networks:
  obs-net:
    external: true
```

- [ ] **Step 2: Create `config.alloy`** (journald + syslog; no docker logs — Proxmox host has no Docker)

```alloy
logging {
  level = "info"
}

loki.source.journal "system" {
  forward_to = [loki.relabel.host.receiver]
}

loki.source.file "syslog" {
  targets = [{
    __path__ = "/var/log/syslog",
  }]
  forward_to = [loki.relabel.host.receiver]
}

loki.relabel "host" {
  forward_to = [loki.write.central.receiver]

  rule {
    target_label = "host"
    replacement   = "proxmox-00"
  }
}

loki.write "central" {
  endpoint {
    url = "http://100.88.153.244:3100/loki/api/v1/push"
  }
}

prometheus.scrape "node" {
  targets = [{
    __address__ = "127.0.0.1:9100",
  }]
  forward_to = [prometheus.relabel.host_metrics.receiver]
}

prometheus.relabel "host_metrics" {
  forward_to = [prometheus.remote_write.central.receiver]

  rule {
    target_label = "host"
    replacement   = "proxmox-00"
  }
}

prometheus.remote_write "central" {
  endpoint {
    url = "http://100.88.153.244:9090/api/v1/write"
  }
}
```

- [ ] **Step 3: Prepare the external network on proxmox-00 and deploy**

```bash
ssh -i /root/ssh-keys/homelab-linux root@192.168.1.9 "docker network create obs-net 2>/dev/null || true"
./docker/tower.local/alloy/deploy_agent.sh 192.168.1.9 root /root/ssh-keys/homelab-linux \
  "$(pwd)/docker/proxmox-00/alloy" /docker-volume/alloy
```
Expected: `proxmox-alloy` and `proxmox-node-exporter` `Up`.

- [ ] **Step 4: Verify + commit**

```bash
curl -sk --get --data-urlencode 'query={host="proxmox-00"}' \
  --data-urlencode 'limit=3' "http://100.88.153.244:3100/loki/api/v1/query_range" | head -c 400
git add docker/proxmox-00/alloy
git commit -m "feat(observability): alloy agent for proxmox-00"
```
Expected: stream entries with `host="proxmox-00"` (journald lines appear within ~30s).

---

### Task 8: Alloy agent on talos-cloud-00

**Files:**
- Create: `docker/talos-cloud-00/alloy/compose.yaml`
- Create: `docker/talos-cloud-00/alloy/config.alloy`

**Interfaces:**
- Consumes: `deploy_agent.sh` from Task 6.
- Produces: talos-cloud-00 journald + syslog + Docker logs + node metrics in central stack, labelled `host="talos-cloud-00"`.

- [ ] **Step 1: Create `compose.yaml`**

```yaml
name: alloy-talosc00

services:
  alloy:
    image: grafana/alloy:v1.16.1
    container_name: talos-cloud-00-alloy
    restart: unless-stopped
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - /etc/alloy/config.alloy
    volumes:
      - ./config.alloy:/etc/alloy/config.alloy:ro
      - /var/log:/var/log:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock
    networks: [obs-net]

  node-exporter:
    image: prom/node-exporter:v1.12.1
    container_name: talos-cloud-00-node-exporter
    restart: unless-stopped
    pid: host
    network_mode: host
    volumes:
      - /:/rootfs:ro,rslave
    command:
      - --path.rootfs=/rootfs

networks:
  obs-net:
    external: true
```

- [ ] **Step 2: Create `config.alloy`** (journald + syslog + docker logs + node scrape)

```alloy
logging {
  level = "info"
}

loki.source.journal "system" {
  forward_to = [loki.relabel.host.receiver]
}

loki.source.file "syslog" {
  targets = [{
    __path__ = "/var/log/syslog",
  }]
  forward_to = [loki.relabel.host.receiver]
}

discovery.docker "self" {
  host = "unix:///var/run/docker.sock"
}

loki.source.docker "self" {
  host     = "unix:///var/run/docker.sock"
  targets  = discovery.docker.self.targets
  forward_to = [loki.relabel.host.receiver]
}

loki.relabel "host" {
  forward_to = [loki.write.central.receiver]

  rule {
    target_label = "host"
    replacement   = "talos-cloud-00"
  }
}

loki.write "central" {
  endpoint {
    url = "http://100.88.153.244:3100/loki/api/v1/push"
  }
}

prometheus.scrape "node" {
  targets = [{
    __address__ = "127.0.0.1:9100",
  }]
  forward_to = [prometheus.relabel.host_metrics.receiver]
}

prometheus.relabel "host_metrics" {
  forward_to = [prometheus.remote_write.central.receiver]

  rule {
    target_label = "host"
    replacement   = "talos-cloud-00"
  }
}

prometheus.remote_write "central" {
  endpoint {
    url = "http://100.88.153.244:9090/api/v1/write"
  }
}
```

- [ ] **Step 3: Deploy**

```bash
ssh -i /root/ssh-keys/oracle root@14.225.220.145 "docker network create obs-net 2>/dev/null || true"
./docker/tower.local/alloy/deploy_agent.sh 14.225.220.145 root /root/ssh-keys/oracle \
  "$(pwd)/docker/talos-cloud-00/alloy" /docker-volume/alloy
```
Expected: `talos-cloud-00-alloy` and `talos-cloud-00-node-exporter` `Up`.

- [ ] **Step 4: Verify + commit**

```bash
curl -sk --get --data-urlencode 'query={host="talos-cloud-00"}' \
  --data-urlencode 'limit=3' "http://100.88.153.244:3100/loki/api/v1/query_range" | head -c 400
git add docker/talos-cloud-00/alloy
git commit -m "feat(observability): alloy agent for talos-cloud-00"
```
Expected: stream entries with `host="talos-cloud-00"`.

---

### Task 9: Consolidation — decommission old stacks & dashboards

**Files:**
- Modify: `k8s/kube-prometheus-stack/values/values.yaml`
- Modify: `scripts/agent-deploy.md` (final host table)

**Interfaces:**
- Consumes: Task 5 (k8s Alloy already central); Task 6 (tower already replaced swarm).
- Produces: single central stack; k8s in-cluster Prometheus/Grafana and swarm Loki/Promtail retired.

- [ ] **Step 1: Disable in-cluster Prometheus and Grafana**

In `k8s/kube-prometheus-stack/values/values.yaml`, set:
```yaml
prometheus:
  enabled: false
```
and:
```yaml
grafana:
  enabled: false
```
Keep everything else (CRDs, operator, alertmanager, serviceMonitors, alloy) untouched.

- [ ] **Step 2: Validate + push**

```bash
python3 -c "import yaml; d=yaml.safe_load(open('k8s/kube-prometheus-stack/values/values.yaml')); assert d['prometheus']['enabled'] is False and d['grafana']['enabled'] is False; print('OK')"
git add k8s/kube-prometheus-stack/values/values.yaml
git commit -m "chore(observability): disable in-cluster prometheus and grafana (centralized)"
git push origin develop
```
Wait for ArgoCD sync (poll as in Task 5 Step 4), then confirm removal:
```bash
ssh -i /root/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get sts,deploy -n monitoring | grep -iE 'prometheus|grafana' || echo 'PROM-GRAFANA-REMOVED'"
```
Expected: `PROM-GRAFANA-REMOVED` (alertmanager, alloy, kube-state-metrics, operator remain).

- [ ] **Step 3: Remove the swarm logging-agents stack on tower**

```bash
ssh -i /root/ssh-keys/homelab-linux root@192.168.1.40 "docker stack rm logging-agents"
ssh -i /root/ssh-keys/homelab-linux root@192.168.1.40 "docker service ls | grep -i logging || echo 'SWARM-AGENTS-REMOVED'"
```
Expected: services removed (node `None` after `General` removal); second command prints `SWARM-AGENTS-REMOVED`.

- [ ] **Step 4: Final end-to-end verification**

```bash
for q in '{host="tower"}' '{host="proxmox-00"}' '{host="talos-cloud-00"}' '{host="talos-cloud-01"}' '{host=~"talos-0[0-2]"}'; do
  curl -sk --get --data-urlencode "query=$q" --data-urlencode 'limit=1' \
    "http://100.88.153.244:3100/loki/api/v1/query_range" | python3 -c "import json,sys; d=json.load(sys.stdin); print('$q ->', len(d['data']['result']), 'streams')"
done
curl -sk http://100.88.153.244:9090/api/v1/query?query=count_up%28node_memory_MemAvailable_bytes%29 -s | head -c 300
```
Expected: ≥1 stream per host query; node metric count ≥ 6 (all hosts).

- [ ] **Step 5: Update `scripts/agent-deploy.md`** with the final host table (hosts, users, keys, remote dirs, stack names) and commit:

```bash
git add scripts/agent-deploy.md
git commit -m "docs(observability): final alloy agent host table"
```

---

### Task 10: Hardening — exposure check & Arcane token rotation

**Files:** none (ops tasks)

**Interfaces:**
- Consumes: running stack.
- Produces: confirmed no public exposure; rotated Arcane token stored in Vault.

- [ ] **Step 1: Confirm no public binding**

```bash
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 "sudo ss -tlnp | grep -E ':3100|:9090|:3000|:12345'"
```
Expected: every listener bound to `100.88.153.244` only. Also scan the public IP from outside the overlay (e.g. from the controller, which is on the LAN, not the OCI VCN — a timeout/refused on `10.0.0.79` from within talos-cloud-01's own VCN subnet peer is expected; primary assertion is the `ss` binding check + absent `0.0.0.0`):

```bash
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 "curl -sk --connect-timeout 3 http://10.0.0.79:3100/ready || echo PUBLIC-LOKI-BLOCKED"
```
Expected: `PUBLIC-LOKI-BLOCKED` (connection refused/timeout).

- [ ] **Step 2: Store the Arcane token in Vault and rotate**

```bash
vault kv patch kubernetes/docker-secrets arcane-api-token="<new token from Arcane dashboard>"
```
Verify:
```bash
vault kv get -field=arcane-api-token kubernetes/docker-secrets | wc -c
```
Expected: non-zero length. Update `deploy_observability.sh`/`deploy_agent.sh` to read it if/when they are adapted to Arcane (per Task 1 outcome).

- [ ] **Step 3: Grafana smoke test**

```bash
ssh -i /root/ssh-keys/oracle opc@140.245.100.82 "sudo cat /docker-volume/observability/.env | grep GRAFANA_ADMIN_PASSWORD | cut -d= -f2"
```
Then open `http://100.88.153.244:3000` over NetBird, log in with `admin` + that password, and confirm both datasources show "healthy" and the two provisioned dashboards are present. (Manual UI check — perform as the last step.)

- [ ] **Step 4: Final commit (if any tweaks)**

```bash
git add -A docker/ scripts/
git commit -m "chore(observability): final hardening tweaks" || echo "no changes"
```

---

## Post-Plan Notes

- The Arcane API is the preferred deploy channel (Task 1); every SSH-based deploy in Tasks 3/6-8 has an equivalent Arcane action if the API turned out to work in Task 1 — apply the same files/env through the dashboard/API instead, keeping the SSH scripts as the canonical fallback and documentation.
- The old swarm `logging-agents` R2 credentials stay in Vault but become unused after Task 9; removal is optional.
- All commits are on `develop`; ArgoCD self-heals the k8s side from that branch.
- **Spec deviation (documented):** spec §8 proposed rsyslog forwarding into an Alloy `:1514` syslog listener. The plan instead uses `loki.source.journal` (systemd hosts) + `loki.source.file` on `/var/log/syslog` (unRAID hosts). Rationale: journald already captures all systemd logs (no duplication), and unRAID's `/etc/rsyslog.conf` is ephemeral on its tmpfs — a file source is persistent without extra config. Same outcome (syslog coverage), fewer moving parts.