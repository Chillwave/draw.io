#!/usr/bin/env bash
# Draw.io (diagrams.net) inside a Debian LXC created via the community framework.
# Puts the URL in the LXC container's notes
# - No upstream ${var_install}.sh is invoked.
# - Notes field on the CT gets the access URL.

# Keep -u off while sourcing; community files reference globals early.
set -Eeo pipefail

# --- Load community framework (header/colors/helpers) ---
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# --- App / CT defaults (override via env before running) ---
APP="Draw.io"
var_tags="${var_tags:-diagramming}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-4}"
var_os="${var_os:-debian}"          # debian | ubuntu
var_version="${var_version:-12}"     # Debian 12 default
var_unprivileged="${var_unprivileged:-1}"  # 1=unprivileged, 0=privileged

# --- Override variables(): safe slug; required globals ---
variables() {
  NSAPP="${APP,,}"; NSAPP="${NSAPP//[^[:alnum:]-]/}"  # "Draw.io" -> "drawio"
  var_install="${NSAPP}-install"                       # not used, but some helpers expect it
  INTEGER='^[0-9]+([.][0-9]+)?$'
  PVEHOST_NAME="$(hostname)"
  DIAGNOSTICS="yes"
  METHOD="default"
  RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
}

# Now safe to use -u
set -u

header_info "$APP"
variables
color
catch_errors

# Helper: start CT and wait for system + IP
wait_for_ct() {
  local ct="$1"
  msg_info "Starting CT ${ct}"
  pct start "${ct}"

  msg_info "Waiting for CT to boot and get network"
  local ip=""
  for i in {1..50}; do
    if pct status "${ct}" 2>/dev/null | grep -q 'status: running'; then
      # Allow systemd to finish booting (best-effort, won't fail the loop)
      pct exec "${ct}" -- bash -lc 'systemctl is-system-running --wait || true' >/dev/null 2>&1 || true
      ip="$(pct exec "${ct}" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)"
      [[ -n "$ip" ]] && break
    fi
    sleep 2
  done
  if [[ -z "$ip" ]]; then
    ip="$(pct exec "${ct}" -- bash -lc "ip -4 -o a s scope global | awk '{print \$4}' | cut -d/ -f1 | head -n1" 2>/dev/null || true)"
  fi
  export IP="${ip:-}"
  msg_ok "CT ${ct} is running ${IP:+with IP ${IP}}"
}

# --- Build a container WITHOUT running upstream app installer ---
build_container() {
  local NET_STRING="-net0 name=eth0,bridge=${BRG:-vmbr0}${MAC:-},ip=${NET:-dhcp}${GATE:-}${VLAN:-}${MTU:-}"
  local FEATURES; [[ "${CT_TYPE}" == "1" ]] && FEATURES="keyctl=1,nesting=1" || FEATURES="nesting=1"

  export APPLICATION="$APP"
  export app="$NSAPP"
  export CTID="$CT_ID"
  export CTTYPE="$CT_TYPE"
  export PCT_OSTYPE="$var_os"
  export PCT_OSVERSION="${var_version%%.*}"
  export PCT_DISK_SIZE="$DISK_SIZE"
  export tz="${timezone:-Etc/UTC}"
  export VERBOSE="${VERBOSE:-no}"
  export PASSWORD="${PW:-}"
  export SSH_ROOT="${SSH:-no}"
  export SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"
  export PCT_OPTIONS=" -features ${FEATURES} -hostname ${HN} -tags ${TAGS} ${SD} ${NS} \
-net0 name=eth0,bridge=${BRG:-vmbr0}${MAC:-},ip=${NET:-dhcp}${GATE:-}${VLAN:-}${MTU:-} \
-onboot 1 -cores ${CORE_COUNT} -memory ${RAM_SIZE} -unprivileged ${CT_TYPE} ${PW} "

  # Create base OS CT (community script handles template + pct create)
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/create_lxc.sh)"

  # Ensure it's actually running before pct exec
  wait_for_ct "${CTID}"

  # ---- LOCALE FIX (quiet apt/perl warnings) ----
  case "${var_os}" in
    debian|ubuntu)
      # Use C locale for the very first apt ops, then install proper locales
      pct exec "${CTID}" -- bash -lc 'set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANGUAGE=C LANG=C
apt-get update
apt-get install -y locales
sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
printf "LANG=en_US.UTF-8\nLC_ALL=en_US.UTF-8\n" >/etc/environment
'
      ;;
    *)
      msg_error "This script targets Debian/Ubuntu CTs. Set var_os=debian or var_os=ubuntu."
      exit 1
      ;;
  esac

  # Minimal tools now that locale is fixed
  pct exec "${CTID}" -- bash -lc 'set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg jq
'

  msg_ok "Customized LXC Container"

  # Optional helper (only if the framework provided it)
  if declare -F install_ssh_keys_into_ct >/dev/null 2>&1; then
    install_ssh_keys_into_ct || true
  fi
}

# Optional updater: bash drawio.sh --update <CTID>
update_script() {
  local _ct="${1:-}"
  [[ -z "${_ct}" ]] && msg_error "Usage: $0 --update <CTID>" && exit 1
  header_info "$APP"
  msg_info "Updating Draw.io in CT ${_ct}"
  pct exec "${_ct}" -- bash -lc "cd /opt/drawio && docker compose pull && docker compose down && docker compose up -d"
  msg_ok "Updated Draw.io in CT ${_ct}"
  exit 0
}
if [[ "${1:-}" == "--update" ]]; then shift; update_script "$@"; fi

# --- Framework flow (calc defaults, summary, etc.) ---
start
build_container       # uses our override (no ${var_install}.sh)
description

# --- Install Docker Engine + compose plugin inside the CT ---
msg_info "Installing Docker Engine & compose plugin (inside CT ${CTID})"
pct exec "${CTID}" -- bash -lc 'set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
'
msg_ok "Docker & compose installed"

# --- Write compose file & launch Draw.io ---
msg_info "Setting up Draw.io container"
pct exec "${CTID}" -- bash -lc 'set -euxo pipefail
mkdir -p /opt/drawio
cat > /opt/drawio/docker-compose.yml <<'"'"'EOF'"'"'
version: "3.8"
services:
  drawio:
    image: jgraph/drawio:latest
    container_name: drawio
    restart: unless-stopped
    ports:
      - "8080:8080"
    # volumes:
    #   - ./data:/var/lib/drawio
EOF
cd /opt/drawio
docker compose up -d
'
msg_ok "Draw.io container is up"

# --- Proxmox Notes (Description) with access URL ---
if [[ -z "${IP:-}" ]]; then
  IP="$(pct exec "${CTID}" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)"
fi
if [[ -n "${IP:-}" ]]; then
  pct set "${CTID}" -description "$(printf 'Draw.io (diagrams.net)\n\nURL: http://%s:8080\nCreated: %s\n' "${IP}" "$(date -Is)")"
fi

# --- Final info ---
msg_ok "Completed Successfully!"
if [[ -n "${IP:-}" ]]; then
  echo -e "${INFO}${YW} Access it at:${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8080${CL}"
else
  echo -e "${INFO}${YW} Access it at:${CL}"
  echo -e "${TAB}${BGN}http://<CT_IP>:8080${CL}"
  echo -e "${TAB}Find the CT IP with: ${CL}pct exec ${CTID} -- ip -4 a"
fi
