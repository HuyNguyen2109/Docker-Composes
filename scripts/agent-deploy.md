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

| Host | User | Key | Local dir | Remote dir | Stack name |
|---|---|---|---|---|---|
| tower.local (192.168.1.40) | root | `/root/ssh-keys/homelab-linux` | `docker/tower.local/alloy` | `/docker-volume/alloy` | `alloy-tower` |
| proxmox-00 (192.168.1.9) | root | `/root/ssh-keys/homelab-linux` | `docker/proxmox-00/alloy` | `/docker-volume/alloy` | `alloy-proxmox` |
| talos-cloud-00 (14.225.220.145) | root | `/root/ssh-keys/oracle` | `docker/talos-cloud-00/alloy` | `/docker-volume/alloy` | `alloy-talosc00` |

> Note: talos-cloud-00 is managed via the Arcane API (its SSH is not reachable
> from the homelab controller; the SSH fallback is listed for documentation).
> On talos-cloud-00 the host runs UFW with a default DROP INPUT policy: allow
> the obs-net bridge subnet to reach node-exporter once:
> `ufw allow from 172.22.0.0/16 to any port 9100 proto tcp`.
> Node metrics scrape target: `100.88.0.70:9100` (NetBird IP of the host).

All agents push logs to central Loki (`http://100.88.153.244:3100`) and
metrics to central Prometheus (`http://100.88.153.244:9090`) over the NetBird
overlay; no inbound ports are published.