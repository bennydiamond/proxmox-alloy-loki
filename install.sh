#!/usr/bin/env bash
# =============================================================================
# proxmox-alloy-loki — ship Proxmox VE host + per-guest (VM / LXC) logs to Loki
#
# Installs Grafana Alloy on this Proxmox node and configures it to send:
#   * the systemd journal (Proxmox daemons, kernel, VM/CT units)
#   * Proxmox task logs (start/stop/backup/migrate ...)
# labelled scope=host|guest, guest_id, guest_type (qemu|lxc), guest_name.
# The guest id->name/type map is generated from `pvesh` every 2 minutes,
# so no guest IDs are ever written into the Alloy config.
#
# Usage:  ./install.sh --loki-url http://LOKI_HOST:3100 [options]
#         ./install.sh --uninstall
# Re-running the script updates everything in place.
# =============================================================================
set -euo pipefail

VERSION="1.0.0"

LOKI_URL="${LOKI_URL:-}"
MEMORY_MAX="${MEMORY_MAX:-200M}"
CONSOLE_VMS="${CONSOLE_VMS:-}"
UNINSTALL=0
PURGE_ALLOY=0
SKIP_CHECK=0

ALLOY_CONFIG=/etc/alloy/config.alloy
ALLOY_DATA=/var/lib/alloy
GUEST_MAP_BIN=/usr/local/bin/pve-guest-map
UNIT_DIR=/etc/systemd/system
DROPIN_DIR=$UNIT_DIR/alloy.service.d
TASK_DIR=/var/log/pve/tasks
GRAFANA_KEY=/etc/apt/keyrings/grafana.gpg
GRAFANA_LIST=/etc/apt/sources.list.d/grafana.list

# ----------------------------------------------------------------------------- helpers
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_dim=$'\e[2m'; c_off=$'\e[0m'
[[ -t 1 ]] || { c_ok=""; c_warn=""; c_err=""; c_dim=""; c_off=""; }
step() { printf '\n%s==>%s %s\n' "$c_ok" "$c_off" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
proxmox-alloy-loki $VERSION

Install:    $0 --loki-url http://LOKI_HOST:3100 [options]
Uninstall:  $0 --uninstall [--purge-alloy]

Options:
  --loki-url URL        Loki base URL (the script adds /loki/api/v1/push). Also: LOKI_URL env.
  --memory-max SIZE     systemd MemoryMax for Alloy (default: $MEMORY_MAX).
  --console-vms "IDS"   Also capture the serial console of these VM IDs (e.g. "100 200"),
                        so a guest kernel panic is recorded. Disables the web UI serial
                        console for those VMs while active (VNC console unaffected).
  --skip-check          Do not abort if Loki is unreachable right now.
  --uninstall           Remove the config, helper, timer and units installed by this script.
  --purge-alloy         With --uninstall: also remove the alloy package and Grafana apt repo.
  -h, --help            Show this help.
EOF
}

# ----------------------------------------------------------------------------- args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --loki-url)     LOKI_URL="${2:?--loki-url needs a value}"; shift 2 ;;
    --memory-max)   MEMORY_MAX="${2:?--memory-max needs a value}"; shift 2 ;;
    --console-vms)  CONSOLE_VMS="${2:?--console-vms needs a value}"; shift 2 ;;
    --skip-check)   SKIP_CHECK=1; shift ;;
    --uninstall)    UNINSTALL=1; shift ;;
    --purge-alloy)  PURGE_ALLOY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage; die "unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root"
command -v systemctl >/dev/null || die "systemd is required"

# Keep apt from restarting Proxmox services (needrestart would restart pve-cluster etc.)
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1

# ----------------------------------------------------------------------------- uninstall
if [[ $UNINSTALL -eq 1 ]]; then
  step "Uninstalling proxmox-alloy-loki"
  systemctl disable --now pve-guest-map.timer 2>/dev/null || true
  for u in $(systemctl list-units --all --plain --no-legend 'vm-console@*' | awk '{print $1}'); do
    systemctl disable --now "$u" 2>/dev/null || true
  done
  systemctl disable --now alloy 2>/dev/null || true
  rm -f "$UNIT_DIR/pve-guest-map.service" "$UNIT_DIR/pve-guest-map.timer" "$UNIT_DIR/vm-console@.service" \
        "$GUEST_MAP_BIN" "$DROPIN_DIR/proxmox-alloy-loki.conf" \
        "$ALLOY_DATA/pve-guest-names.txt" "$ALLOY_DATA/pve-guest-types.txt"
  if command -v setfacl >/dev/null && [[ -d $TASK_DIR ]] && id alloy >/dev/null 2>&1; then
    setfacl -R -x u:alloy "$TASK_DIR" 2>/dev/null || true
    setfacl -R -d -x u:alloy "$TASK_DIR" 2>/dev/null || true
  fi
  if [[ -f $ALLOY_CONFIG ]] && grep -q 'proxmox-alloy-loki' "$ALLOY_CONFIG"; then
    mv "$ALLOY_CONFIG" "$ALLOY_CONFIG.removed-$(date +%Y%m%d-%H%M%S)"
    info "config moved aside: $ALLOY_CONFIG.removed-*"
  fi
  if [[ $PURGE_ALLOY -eq 1 ]]; then
    apt-get purge -y alloy || true
    rm -f "$GRAFANA_LIST" "$GRAFANA_KEY"
    info "alloy package and Grafana apt repo removed"
  fi
  systemctl daemon-reload
  step "Done"
  exit 0
fi

# ----------------------------------------------------------------------------- preflight
command -v pvesh >/dev/null || die "pvesh not found — this does not look like a Proxmox VE node"
[[ -d $TASK_DIR ]] || die "$TASK_DIR not found — this does not look like a Proxmox VE node"

if [[ -z $LOKI_URL ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Loki base URL (e.g. http://192.168.1.10:3100): " LOKI_URL
  fi
  [[ -n $LOKI_URL ]] || die "--loki-url is required"
fi
LOKI_URL="${LOKI_URL%/}"
LOKI_URL="${LOKI_URL%/loki/api/v1/push}"
[[ $LOKI_URL =~ ^https?:// ]] || die "--loki-url must start with http:// or https://"
PUSH_URL="$LOKI_URL/loki/api/v1/push"

for id in $CONSOLE_VMS; do
  [[ $id =~ ^[0-9]+$ ]] || die "--console-vms: '$id' is not a VM ID"
done

step "Checking Loki at $LOKI_URL"
# 200 = ready, 503 = reachable but (briefly) not ready, anything else = unreachable/wrong URL
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$LOKI_URL/ready" 2>/dev/null || true)
case "$code" in
  200) info "reachable, ready" ;;
  503) info "reachable (Loki reports a component still warming up — it accepts logs anyway)" ;;
  *)
    if [[ $SKIP_CHECK -eq 1 ]]; then
      warn "Loki not reachable right now (HTTP ${code:-none}); continuing because of --skip-check"
    else
      die "Loki not reachable at $LOKI_URL/ready (HTTP ${code:-none}). Fix network/URL or use --skip-check."
    fi ;;
esac

# ----------------------------------------------------------------------------- packages
step "Installing packages"
apt-get install -y -qq gpg acl python3 wget curl ca-certificates >/dev/null
if [[ ! -f $GRAFANA_LIST ]]; then
  mkdir -p "$(dirname "$GRAFANA_KEY")"
  wget -qO- https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o "$GRAFANA_KEY"
  echo "deb [signed-by=$GRAFANA_KEY] https://apt.grafana.com stable main" > "$GRAFANA_LIST"
  info "Grafana apt repository added"
fi
apt-get update -qq
apt-get install -y -qq alloy >/dev/null
info "$(alloy --version 2>/dev/null | head -1)"
[[ -n $CONSOLE_VMS ]] && apt-get install -y -qq socat >/dev/null

# ----------------------------------------------------------------------------- permissions
step "Granting Alloy read access (journal + task logs) and capping memory at $MEMORY_MAX"
usermod -aG systemd-journal,adm,www-data alloy
# task files are www-data:root 0640 -> group membership is not enough; ACL for current + future files
setfacl -R -m u:alloy:rX "$TASK_DIR"
setfacl -R -d -m u:alloy:rX "$TASK_DIR"
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_DIR/proxmox-alloy-loki.conf" <<EOF
# Managed by proxmox-alloy-loki install.sh
[Service]
MemoryMax=$MEMORY_MAX
EOF

# ----------------------------------------------------------------------------- guest map helper
step "Installing guest map helper + timer"
mkdir -p "$ALLOY_DATA"
cat > "$GUEST_MAP_BIN" <<'PYEOF'
#!/usr/bin/env python3
"""proxmox-alloy-loki: write the Proxmox guest list (whole cluster) as Go-template
dict arguments for Alloy. Files are only rewritten when the guest list changes.
  /var/lib/alloy/pve-guest-names.txt   "100" "HAOS" "101" "pihole"
  /var/lib/alloy/pve-guest-types.txt   "100" "qemu" "101" "lxc"
"""
import json, os, subprocess

OUT = "/var/lib/alloy"

def write_if_changed(path, content):
    try:
        with open(path) as f:
            if f.read() == content:
                return False
    except FileNotFoundError:
        pass
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    return True

raw = subprocess.run(["pvesh", "get", "/cluster/resources", "--type", "vm", "--output-format", "json"],
                     check=True, capture_output=True, text=True).stdout
rows = sorted(json.loads(raw), key=lambda g: int(g["vmid"]))
q = json.dumps  # Go template string literals accept JSON-style quoting
names = " ".join(f'{q(str(g["vmid"]))} {q(g.get("name") or "guest-%s" % g["vmid"])}' for g in rows)
types = " ".join(f'{q(str(g["vmid"]))} {q(g.get("type", "unknown"))}' for g in rows)
os.makedirs(OUT, exist_ok=True)
changed = write_if_changed(f"{OUT}/pve-guest-names.txt", names + "\n")
changed |= write_if_changed(f"{OUT}/pve-guest-types.txt", types + "\n")
print(f"{len(rows)} guests, {'updated' if changed else 'unchanged'}")
PYEOF
chmod 755 "$GUEST_MAP_BIN"

cat > "$UNIT_DIR/pve-guest-map.service" <<EOF
# Managed by proxmox-alloy-loki install.sh
[Unit]
Description=Write Proxmox guest id/name/type map for Alloy
After=pve-cluster.service
Before=alloy.service

[Service]
Type=oneshot
ExecStart=$GUEST_MAP_BIN
EOF

cat > "$UNIT_DIR/pve-guest-map.timer" <<'EOF'
# Managed by proxmox-alloy-loki install.sh
[Unit]
Description=Refresh Proxmox guest map for Alloy every 2 minutes

[Timer]
OnBootSec=20s
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
info "$("$GUEST_MAP_BIN")"
info "guests: $(cat "$ALLOY_DATA/pve-guest-names.txt")"
systemctl enable --now pve-guest-map.timer >/dev/null 2>&1

# ----------------------------------------------------------------------------- alloy config
step "Writing $ALLOY_CONFIG (push to $PUSH_URL)"
if [[ -f $ALLOY_CONFIG ]] && ! grep -q 'proxmox-alloy-loki' "$ALLOY_CONFIG"; then
  cp "$ALLOY_CONFIG" "$ALLOY_CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
  info "existing config backed up to $ALLOY_CONFIG.bak-*"
fi
tmpcfg=$(mktemp)
cat > "$tmpcfg" <<'ALLOYEOF'
// =============================================================================
// Managed by proxmox-alloy-loki install.sh — re-run the script instead of editing.
// Proxmox VE node -> Loki. Labels: job="proxmox", host, scope=host|guest,
// guest_id, guest_type (qemu|lxc), guest_name. Level in structured metadata.
// =============================================================================

// ---------- 1. systemd journal: Proxmox daemons, kernel, VM scopes, CT services ----------
loki.relabel "journal" {
  forward_to = []

  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal_syslog_identifier"]
    target_label  = "service_name"
  }
  rule {
    source_labels = ["__journal__transport"]
    regex         = "kernel"
    target_label  = "service_name"
    replacement   = "kernel"
  }
  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "journal_priority"
  }
}

loki.source.journal "host" {
  forward_to    = [loki.process.proxmox.receiver]
  relabel_rules = loki.relabel.journal.rules
  max_age       = "12h"
  labels        = {
    job  = "proxmox",
    host = constants.hostname,
  }
}

// ---------- 2. Proxmox task logs: one file per task, the UPID names the guest ----------
local.file_match "pve_tasks" {
  path_targets      = [{ __path__ = "/var/log/pve/tasks/*/UPID:*" }]
  ignore_older_than = "1h"
}

discovery.relabel "pve_tasks" {
  targets = local.file_match.pve_tasks.targets

  rule {
    target_label = "job"
    replacement  = "proxmox"
  }
  rule {
    target_label = "host"
    replacement  = constants.hostname
  }
  rule {
    target_label = "service_name"
    replacement  = "pve-task"
  }
  rule {
    source_labels = ["__path__"]
    regex         = `.*/UPID:[^:]*:[0-9A-Fa-f]+:[0-9A-Fa-f]+:[0-9A-Fa-f]+:([^:]*):([^:]*):.*`
    target_label  = "task"
    replacement   = "$1"
  }
  rule {
    source_labels = ["__path__"]
    regex         = `.*/UPID:[^:]*:[0-9A-Fa-f]+:[0-9A-Fa-f]+:[0-9A-Fa-f]+:[^:]*:([0-9]+):.*`
    target_label  = "task_guest"
    replacement   = "$1"
  }
}

loki.source.file "pve_tasks" {
  targets    = discovery.relabel.pve_tasks.output
  forward_to = [loki.process.proxmox.receiver]
}

// ---------- 3. Guest maps, generated by pve-guest-map.timer (reloaded on change) ----------
local.file "guest_names" {
  filename = "/var/lib/alloy/pve-guest-names.txt"
}

local.file "guest_types" {
  filename = "/var/lib/alloy/pve-guest-types.txt"
}

// ---------- 4. host vs guest, guest identity, severity ----------
loki.process "proxmox" {
  forward_to = [loki.write.loki.receiver]

  // Pimox (Proxmox on Raspberry Pi) noise, repeats every 10 s. Never matches on x86.
  stage.drop {
    expression = `Use of uninitialized value in multiplication|Module ip_tables not found|iptables-restore|unable to initialize table 'filter'|Error occurred at line: 1|iptables_restore_cmdlist`
  }

  // guest id: unit names first, then task UPIDs, "VM 100"/"CT 101", tap/veth ifaces, cgroups
  stage.regex {
    source     = "unit"
    expression = `^(?P<gid_vm>[0-9]+)\.scope$`
  }
  stage.regex {
    source     = "unit"
    expression = `^pve-container@(?P<gid_ct>[0-9]+)\.service$`
  }
  stage.regex {
    source     = "unit"
    expression = `^vm-console@(?P<gid_vm_console>[0-9]+)\.service$`
  }
  stage.regex {
    expression = `UPID:[^:]+:[0-9A-Fa-f]+:[0-9A-Fa-f]+:[0-9A-Fa-f]+:(?P<msg_task>[a-z]+):(?P<gid_upid>[0-9]+):`
  }
  stage.regex {
    expression = `\b(?P<msg_kind>VM|CT) (?P<gid_word>[0-9]{3,})\b`
  }
  stage.regex {
    expression = `\b(?P<ifkind>tap|veth|fwbr|fwpr|fwln)(?P<gid_if>[0-9]{3,})(?:i|p)[0-9]+`
  }
  stage.regex {
    expression = `(?P<slice>qemu|lxc)(?:\.slice)?/(?P<gid_cg>[0-9]{3,})(?:\.scope)?\b`
  }

  // Alloy's own lines mention task file names: never treat them as guest lines
  stage.template {
    source   = "guest_id"
    template = `{{ if hasPrefix "alloy" (or .service_name "") }}{{ else }}{{ or .gid_vm .gid_ct .gid_vm_console .task_guest .gid_upid .gid_word .gid_if .gid_cg "" }}{{ end }}`
  }

  // type: generated map first, then evidence (vzdump backs up both kinds: not a hint)
  stage.template {
    source   = "guest_type"
    template = string.format(`{{- if .guest_id -}}
{{- $known := dict %s -}}
{{- $t := or .task .msg_task "" -}}
{{- if get $known .guest_id -}}{{ get $known .guest_id }}
{{- else if or .gid_vm .gid_vm_console (hasPrefix "qm" $t) (eq (or .msg_kind "") "VM") (eq (or .ifkind "") "tap") (eq (or .slice "") "qemu") -}}qemu
{{- else if or .gid_ct (and (hasPrefix "vz" $t) (ne $t "vzdump")) (eq (or .msg_kind "") "CT") (eq (or .ifkind "") "veth") (eq (or .slice "") "lxc") -}}lxc
{{- else -}}unknown{{- end -}}
{{- end -}}`, string.trim_space(local.file.guest_types.content))
  }

  stage.template {
    source   = "scope"
    template = `{{ if .guest_id }}guest{{ else }}host{{ end }}`
  }

  // name: generated map; unknown ids show as guest-<id>
  stage.template {
    source   = "guest_name"
    template = string.format(`{{ $n := dict %s }}{{ if .guest_id }}{{ get $n .guest_id | default (printf "guest-%%s" .guest_id) }}{{ end }}`, string.trim_space(local.file.guest_names.content))
  }

  stage.labels {
    values = {
      scope      = "",
      guest_id   = "",
      guest_type = "",
      guest_name = "",
    }
  }

  // severity: journal priority, then task result, then keywords
  stage.regex {
    expression = `(?P<task_result>TASK (?:OK|ERROR|WARNINGS))`
  }
  stage.regex {
    expression = `(?:^|[^A-Za-z])(?P<lvl_kw>CRITICAL|FATAL|ERROR|WARNING|WARN|INFO|DEBUG)(?:[^A-Za-z]|$)`
  }
  stage.regex {
    expression = `(?i)\b(?P<lvl_word>panic|oom-kill|out of memory|killed process|error|failed|failure|warning)\b`
  }

  stage.template {
    source   = "level"
    template = `{{- $p := or .journal_priority "" -}}
{{- $r := or .task_result "" -}}
{{- $w := lower (or .lvl_kw .lvl_word "") -}}
{{- if or (eq $p "emerg") (eq $p "alert") (eq $p "crit") (eq $w "panic") (eq $w "oom-kill") (eq $w "out of memory") (eq $w "killed process") -}}critical
{{- else if or (eq $p "err") (eq $r "TASK ERROR") (hasPrefix "er" $w) (hasPrefix "fail" $w) -}}error
{{- else if or (eq $p "warning") (eq $r "TASK WARNINGS") (hasPrefix "warn" $w) -}}warn
{{- else if eq $p "debug" -}}debug
{{- else -}}info{{- end -}}`
  }

  stage.structured_metadata {
    values = {
      level = "",
      unit  = "",
      task  = "",
    }
  }

  stage.label_drop {
    values = ["unit", "task", "task_guest", "journal_priority"]
  }
}

// ---------- 5. push ----------
loki.write "loki" {
  endpoint {
    url = "__PUSH_URL__"
  }
}
ALLOYEOF
sed -i "s#__PUSH_URL__#${PUSH_URL//&/\\&}#" "$tmpcfg"
alloy fmt "$tmpcfg" >/dev/null || { rm -f "$tmpcfg"; die "generated config failed 'alloy fmt' — please report a bug"; }
install -m 0644 "$tmpcfg" "$ALLOY_CONFIG"
rm -f "$tmpcfg"
info "config valid"

# ----------------------------------------------------------------------------- serial consoles (optional)
if [[ -n $CONSOLE_VMS ]]; then
  step "Capturing serial console of VM(s): $CONSOLE_VMS"
  cat > "$UNIT_DIR/vm-console@.service" <<'EOF'
# Managed by proxmox-alloy-loki install.sh
[Unit]
Description=Serial console of VM %i to the journal
After=pve-guests.service

[Service]
ExecStart=/bin/sh -c "exec socat -u UNIX-CONNECT:/var/run/qemu-server/%i.serial0 STDOUT"
StandardOutput=journal
SyslogIdentifier=vm-console
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  for id in $CONSOLE_VMS; do
    systemctl enable --now "vm-console@$id" >/dev/null 2>&1 && info "vm-console@$id enabled"
  done
fi

# ----------------------------------------------------------------------------- start + verify
step "Starting Alloy"
systemctl daemon-reload
systemctl enable alloy >/dev/null 2>&1
since=$(date '+%Y-%m-%d %H:%M:%S')
systemctl restart alloy
sleep 15
systemctl is-active --quiet alloy || die "alloy is not running — see: journalctl -u alloy -n 50"
errors=$(journalctl -u alloy --since "$since" --no-pager | grep -E 'level=(error|warn)' || true)
if [[ -n $errors ]]; then
  warn "Alloy logged warnings/errors since start:"
  printf '%s\n' "$errors" | tail -5 >&2
else
  info "alloy active, no errors"
fi

logger -t proxmox-alloy-loki "installed v$VERSION, shipping to $PUSH_URL"

step "Done"
cat <<EOF
    Node:   $(hostname)
    Loki:   $PUSH_URL
    Query:  {job="proxmox", host="$(hostname)"}
            {job="proxmox", host="$(hostname)", scope="guest"}
    Test:   logger -t pve-test "VM <ID> guest-map check"   ${c_dim}# should arrive with scope=guest + guest_name${c_off}
EOF
