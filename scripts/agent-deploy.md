# Alloy Agent Deployment Helper

`docker/tower.local/alloy/deploy_agent.sh` deploys a standalone Grafana Alloy
agent stack (Alloy + node-exporter) to a Docker host over SSH. It is the
**fallback** deploy path when the Arcane API is unavailable for a host.

## Usage

```bash
./docker/tower.local/alloy/deploy_agent.sh <host> <user> <ssh_key> <local_dir> <remote_dir>
```

| Position | Meaning |
|---|---|
| `host` | IP or hostname of the target |
| `user` | SSH login user |
| `ssh_key` | Path to the SSH private key |
| `local_dir` | Directory with `compose.yaml` + `config.alloy` (e.g. `docker/<host>/alloy`) |
| `remote_dir` | Remote directory the stack is copied to (e.g. `/docker-volume/alloy`) |

The stack requires an external Docker network named `obs-net` to exist on the
target first (created once per host):

```bash
ssh -i <key> <user>@<host> "docker network create obs-net 2>/dev/null || true"
```

## Hosts

| Host | Deploy channel | User | Key | Local dir | Stack / project | Status |
|---|---|---|---|---|---|---|
| tower.local (192.168.1.40) | Arcane project (env `unRAID`) | root | `/root/ssh-keys/homelab-linux` | `docker/tower.local/alloy` | project `alloy-tower` | ✅ logs + metrics flowing |
| proxmox-00 (192.168.1.9) | SSH/native systemd (no docker) | root | `/root/ssh-keys/homelab-linux` | `docker/proxmox-00/alloy` | `alloy-proxmox` (install_agent.sh) | ⛔ BLOCKED: no NetBird service, no docker, no Arcane env |
| talos-cloud-00 (14.225.220.145) | Arcane project | root | `/root/ssh-keys/oracle` | `docker/talos-cloud-00/alloy` | project `alloy-talosc00` | ✅ logs + metrics flowing |
| talos-cloud-01 (140.245.100.82) | Arcane project | opc | `/root/ssh-keys/oracle` | `docker/talos-cloud-01/observability` | project `observability` | ✅ central stack |
| talos-00/01/02 | k8s DaemonSet (ArgoCD `alloy` app) | ubuntu | `/root/ssh-keys/homelab-linux` | `k8s/kube-prometheus-stack/values/alloy.yaml` | DS `alloy` in `monitoring` | ✅ hostNetwork pods, logs + kubelet metrics flowing |

All agents push logs to central Loki (`http://100.88.153.244:3100`) and
metrics to central Prometheus (`http://100.88.153.244:9090`) over the NetBird
overlay; no inbound ports are published.

## Operational notes

- talos-cloud-00 is managed via the Arcane API (its SSH is not reachable from
  the homelab controller). The host runs UFW with a default DROP INPUT policy;
  the obs-net bridge subnet must be allowed to reach node-exporter once:
  `ufw allow from 172.22.0.0/16 to any port 9100 proto tcp`.
  Node metrics scrape target: `100.88.0.70:9100` (NetBird IP of the host).
- proxmox-00 has no Docker and no NetBird service: deploy natively via
  `docker/proxmox-00/alloy/install_agent.sh` after NetBird registration
  (setup key from the management console on talos-cloud-00) — required before
  it can reach the central stack (`100.88.153.244` is NetBird-only).
- The k8s Alloy DaemonSet is managed by the `alloy` ArgoCD app from
  `k8s/kube-prometheus-stack/values/alloy.yaml` (chart `grafana/alloy` 1.8.1);
  it runs with `hostNetwork: true`, tolerates the control-plane taint, and
  requires kubelet scraping with the service-account token + `https` scheme.