# proxmox-alloy-loki

Ship **Proxmox VE** logs to **Grafana Loki** with one script, split into **host** logs and **per-guest (VM / LXC)** logs as seen from the hypervisor.

- One self-contained `install.sh`: installs [Grafana Alloy](https://grafana.com/docs/alloy/), writes its config, sets permissions, and starts it.
- **No guest IDs in the config.** A small timer reads the cluster's guest list from `pvesh` every 2 minutes. New, renamed and removed VMs and containers are picked up automatically, and Alloy reloads the list without a restart.
- Same script, same config on every node. Each node labels its logs with its own hostname.
- Works on regular Proxmox VE (x86) and on Proxmox on Raspberry Pi (Pimox / PXVirt, arm64).
- Includes an importable Grafana dashboard.

---

## What you get in Loki

Every line gets these labels:

| Label | Values | Meaning |
|---|---|---|
| `job` | `proxmox` | Always set, so all nodes are `{job="proxmox"}` |
| `host` | node hostname | e.g. `pve-router` |
| `scope` | `host` / `guest` | `guest` when the line is about a VM or container |
| `guest_id` | `100`, `101`, … | VMID / CTID (guest lines only) |
| `guest_type` | `qemu` / `lxc` / `unknown` | from the cluster's guest list |
| `guest_name` | `pihole`, `HAOS`, … | from the cluster's guest list (`guest-<id>` if unknown) |
| `service_name` | `pvedaemon`, `kernel`, `pve-task`, … | systemd identifier, `kernel`, or `pve-task` for task logs |

The severity (`critical`, `error`, `warn`, `info`, `debug`) is stored as `level` in Loki's [structured metadata](https://grafana.com/docs/loki/latest/get-started/labels/structured-metadata/), along with `unit` (systemd unit) and `task` (Proxmox task type). Use them as filters, for example `| level="error"`.

### Sources

| Source | Examples | Labelled as guest when… |
|---|---|---|
| systemd journal | pvedaemon, pveproxy, pve-cluster, pve-ha-*, kernel, smartd | the line names a guest (`VM 100`, `CT 101`, a task UPID, `tap100i0`, `veth101i0`, a guest cgroup) |
| VM process scopes | `100.scope` (the VM's `kvm` process) | always |
| Container services | `pve-container@101.service` | always |
| **Task logs** `/var/log/pve/tasks` | start, stop, backup (vzdump), snapshot, migrate | the task targets a guest. `TASK ERROR` is an error, `TASK WARNINGS` a warning |
| Serial console *(optional)* | VM kernel messages, panics | always (`--console-vms`) |

## Requirements

- A Proxmox VE 8/9 node (Debian bookworm/trixie), with root access.
- A Loki server reachable from the node over HTTP(S), for example `http://192.168.1.10:3100`.
- Internet access from the node, for `apt.grafana.com`.

## Limitations

The installer targets a plain Loki endpoint. It does **not** currently support:

| Not supported | Affects | Workaround for now |
|---|---|---|
| **Authentication** (basic auth, bearer token) | Grafana Cloud, Loki behind an authenticating reverse proxy | Add a `basic_auth { … }` or `bearer_token` block to `loki.write` in `/etc/alloy/config.alloy` by hand |
| **Multi-tenant Loki** (`auth_enabled: true`, `X-Scope-OrgID`) | Loki with tenants enabled; pushes are rejected without a tenant | Add `tenant_id = "…"` to the `endpoint` block in `loki.write` by hand |
| **Custom or self-signed TLS certificates** | `https://` Loki whose certificate the node doesn't trust | Install the CA in the node's trust store (`/usr/local/share/ca-certificates/` then `update-ca-certificates`) |
| **Extra static labels** (e.g. `cluster`, `site`) | Several Proxmox clusters sharing one Loki | Tell them apart by `host`, or add labels to the `labels` block of `loki.source.journal` and a `rule` in `discovery.relabel "pve_tasks"` by hand |

Manual edits to `/etc/alloy/config.alloy` are **overwritten** when you re-run `install.sh`. Keep a copy and re-apply them after updating.

Some things are fixed on purpose:
- `job="proxmox"`, because the dashboard relies on it.
- A 12-hour journal catch-up when Alloy starts.
- Task logs older than 1 hour are skipped on first start.

## Install

On each Proxmox node, as root:

```bash
curl -fsSLO https://raw.githubusercontent.com/bennydiamond/proxmox-alloy-loki/main/install.sh
chmod +x install.sh
./install.sh --loki-url http://LOKI_HOST:3100
```

or from a clone:

```bash
git clone https://github.com/bennydiamond/proxmox-alloy-loki.git
cd proxmox-alloy-loki
./install.sh --loki-url http://LOKI_HOST:3100
```

The script:

1. Checks that Loki answers at `<url>/ready`, and stops if it doesn't (`--skip-check` overrides this).
2. Installs `alloy` from Grafana's apt repository, plus `acl` and `python3`.
3. Lets the `alloy` user read the journal and the task logs, and caps its memory (200 MB by default).
4. Installs `/usr/local/bin/pve-guest-map` and `pve-guest-map.timer`, and generates the guest list.
5. Writes `/etc/alloy/config.alloy` (backing up any existing config) and validates it.
6. Starts Alloy and reports any errors.

It sets `NEEDRESTART_SUSPEND=1`, so installing packages does **not** restart Proxmox services such as `pve-cluster`.

### Options

| Option | Default | Description |
|---|---|---|
| `--loki-url URL` | *(required)* | Loki base URL. `/loki/api/v1/push` is added for you. Also accepted as the `LOKI_URL` environment variable. |
| `--memory-max SIZE` | `200M` | systemd `MemoryMax` for Alloy |
| `--console-vms "IDS"` | none | Capture the serial console of these VMs (e.g. `"100 200"`) so a guest kernel panic is recorded. While active, the web UI's serial console is unavailable for those VMs; the VNC console still works. |
| `--skip-check` | off | Install even if Loki is unreachable right now |
| `--uninstall` | | Remove everything this script installed |
| `--purge-alloy` | | With `--uninstall`: also remove the `alloy` package and the Grafana apt repository |

### Update

Re-run the same command. The script is idempotent and overwrites its own files.

### Uninstall

```bash
./install.sh --uninstall            # keep the alloy package
./install.sh --uninstall --purge-alloy
```

## Verify

On the node:

```bash
systemctl status alloy pve-guest-map.timer
cat /var/lib/alloy/pve-guest-names.txt          # "101" "pihole" "200" "vm-opnsense"
logger -t pve-test "VM 101 guest-map check"     # use one of your guest IDs
```

In Grafana Explore, the test line should arrive with `scope="guest"`, `guest_id="101"`, `guest_name="pihole"`:

```logql
{job="proxmox"} |= "guest-map check"
```

## Grafana dashboard

Import [`dashboards/proxmox-logs.json`](dashboards/proxmox-logs.json) through **Dashboards → New → Import**, and pick your Loki data source.

- **Filters:** Node, Scope (host/guest), Guest, Service, Severity, text search. Each dropdown only offers what matches the ones before it.
- **Counts:** log lines, errors, **failed tasks**, **out-of-memory kills / kernel panics**.
- **Tables:** log volume by severity, services, **task results** per guest (e.g. `HAOS · qmstart · TASK OK`), guests (click to filter), recurring errors and warnings.
- **Logs:** a guest event log and the full log.

## Handy LogQL

```logql
# everything about one guest, from the hypervisor's point of view
{job="proxmox", guest_name="vm-opnsense"}

# failed Proxmox tasks (backups, starts, migrations ...) on all nodes
{job="proxmox", service_name="pve-task"} |= "TASK ERROR"

# OOM kills / kernel panics on nodes or in VM consoles
{job="proxmox"} |~ "(?i)oom-kill|killed process|out of memory|kernel panic"

# error rate per node
sum by (host) (count_over_time({job="proxmox"} | level=~"critical|error" [5m]))

# host-level logs only
{job="proxmox", scope="host"}
```

## How it works

```
 Proxmox node
 ├─ systemd journal ─────────────┐
 ├─ /var/log/pve/tasks/*/UPID:* ─┤        ┌───────────────────────────────┐
 │                               ├──────▶ │ Alloy (loki.process)          │ ──▶ Loki
 └─ pve-guest-map.timer          │        │  find guest id in each line   │
      pvesh get /cluster/resources        │  look up name/type in the map │
      └▶ /var/lib/alloy/pve-guest-*.txt ─▶│  set scope / guest_* labels   │
                                          │  normalise level              │
                                          └───────────────────────────────┘
```

The guest ID comes from, in order of reliability:
1. the systemd unit (`100.scope`, `pve-container@101.service`, `vm-console@100.service`)
2. the task file name (`UPID:<node>:…:<type>:<id>:<user>:`)
3. the message text: task UPIDs, `VM 100`, `CT 101`, `tap100i0`, `veth101i0`, `fwbr100i0`, `qemu.slice/100.scope`, `lxc/101`

`guest_name` and `guest_type` then come from the generated map. The helper writes those files only when the guest list changes, and Alloy's `local.file` component reloads them automatically.

On a cluster, `pvesh get /cluster/resources` lists the guests of **every** node, so a line about a guest that migrated in is still named correctly.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Loki not reachable … HTTP 000` | Wrong URL or blocked network: test `curl http://LOKI_HOST:3100/ready` from the node |
| `Loki not reachable … HTTP 503` is reported as reachable | Normal: Loki answers 503 while a component warms up, and accepts logs anyway |
| Alloy log: `permission denied` on `/var/log/pve/tasks/...` | Re-run the script, which re-applies the ACL. Task files are `www-data:root 0640`, so group membership alone isn't enough. |
| Guests show as `guest-<id>` | The guest isn't in `pvesh get /cluster/resources` yet; it's fixed on the next timer run (≤ 2 min) |
| Nothing from a VM's serial console | The guest OS must write its console to the serial port (e.g. `console=ttyS0` / `ttyAMA0`) |
| Lots of Pimox `Use of uninitialized value…` noise | Already dropped by the config |

Useful commands on the node:

```bash
journalctl -u alloy -n 50 --no-pager          # Alloy's own log
systemctl list-timers pve-guest-map.timer     # guest map schedule
/usr/local/bin/pve-guest-map                  # regenerate the map now
alloy fmt /etc/alloy/config.alloy             # validate the config
```

Alloy's web UI, which shows the pipeline and each component's health, listens on `127.0.0.1:12345` on the node. Reach it over SSH: `ssh -L 12345:127.0.0.1:12345 root@node`.

## Security notes

- Alloy runs as the unprivileged `alloy` user, with read-only access to the journal (`systemd-journal`, `adm` groups) and to the task logs (an ACL on `/var/log/pve/tasks`).
- Only outbound traffic goes from the node to Loki. Nothing listens on the network.
- The guest-map helper runs as root (it needs `pvesh`) and only writes two text files under `/var/lib/alloy`.
- Logs may contain hostnames, IPs and usernames. Secure your Loki endpoint accordingly; HTTPS and auth can be added in `loki.write` (see the [Alloy docs](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.write/)).

## License

[MIT](LICENSE)
