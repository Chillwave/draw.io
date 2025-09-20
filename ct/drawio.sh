#!/usr/bin/env bash
# Draw.io (diagrams.net) in an LXC using community framework for CT creation,
# but WITHOUT calling the upstream ${var_install}.sh app installer.
# Janky but it works, original script chokes up on line 1345 within the build func

# Keep -u off while sourcing; that repo references globals before we set them.
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

# --- Build a container WITHOUT running upstream app installer ---
build_container() {
  # Build options the community creator expects
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

  # Create the CT base OS only
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/create_lxc.sh)"

  msg_info "Starting CT ${CTID}"
  pct start "${CTID}"

  # Wait until CT is Running + systemd ready + has an IPv4 (best-effort)
  msg_info "Waiting for CT to boot and get network"
  for i in {1..40}; do
    if pct status "${CTID}" 2>/dev/null | grep -q 'status: running'; then
      if pct exec "${CTID}" -- bash -lc 'systemctl is-system-running --wait 2>/dev/null || true' >/dev/null 2>&1; then
        IP="$(pct exec "${CTID}" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)"
        [[ -n "${IP}" ]] && break
      fi
    fi
    sleep 2
  done
  [[ -z "${IP:-}" ]] && IP="$(pct exec "${CTID}" -- bash -lc "ip -4 -o a s scope global | awk '{print \$4}' | cut -d/ -f1 | head -n1" 2>/dev/null || true)"
  msg_ok "CT ${CTID} is running ${IP:+with IP ${IP}}"

  # Minimal packages inside CT
  case "${var_os}" in
    debian|ubuntu)
      pct exec "${CTID}" -- bash -lc "apt-get update >/dev/null && apt-get install -y ca-certificates curl gnupg jq >/dev/null"
      ;;
    *)
      msg_error "This script targets Debian/Ubuntu CTs. Set var_os=debian or var_os=ubuntu."
      exit 1
      ;;
  esac

  msg_ok "Customized LXC Container"
  install_ssh_keys_into_ct || true
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

# --- Framework flow (calculates defaults, shows summary, etc.) ---
start
build_container       # uses our override (no ${var_install}.sh)
description

# --- Install Docker Engine + compose plugin inside the CT ---
msg_info "Installing Docker Engine & compose plugin (inside CT ${CTID})"
pct exec "${CTID}" -- bash -lc 'set -euxo pipefail
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
pct exec "${CTID}" -- bash -lc 'set -e
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
