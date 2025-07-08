#!/usr/bin/env bash

# Exit on error, undefined variable, and pipe failure
set -euo pipefail

# Error handling function
error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check command status and exit on failure
check_status() {
    local exit_code=$?
    local cmd=$1
    local msg=${2:-}
    
    if [ $exit_code -ne 0 ]; then
        error_exit "Command failed with exit code $exit_code: $cmd\n$msg"
    fi
}

# Parameters
CONTAINER_NAME="builder"
IMAGE="images:debian/13"
PROFILES=(default vlan10)
USERNAME="ariel"
DNS_SERVER="10.53.53.53"
DNS_DOMAIN="aanetworks.org"
DEBCACHE_URL="http://debcache.aanetworks.org"
TEMPLATE_NAME="template1"  # name for the published template
# Toggle strict mode for commands inside container ("true" to include set -euo pipefail)
STRICT_MODE="false"

# 0. Prompt and remove existing container if present
if incus info "${CONTAINER_NAME}" &>/dev/null; then
  read -r -p "Container '${CONTAINER_NAME}' already exists. Delete and recreate? (y/N): " choice
  case "$choice" in
    [Yy]*)
      echo "Deleting existing container '${CONTAINER_NAME}'..."
      incus delete "${CONTAINER_NAME}" --force
      echo "Deleted '${CONTAINER_NAME}'.";;
    *)
      echo "Aborting."; exit 1;;
  esac
fi

# 1. Launch container
echo "Launching ${CONTAINER_NAME} from ${IMAGE} with profiles ${PROFILES[*]}..."
if ! command_exists incus; then
    error_exit "Incus is not installed. Please install Incus before running this script."
fi

incus launch "${IMAGE}" "${CONTAINER_NAME}" -p "${PROFILES[0]}" -p "${PROFILES[1]}" > /dev/null
check_status "incus launch \"${IMAGE}\" \"${CONTAINER_NAME}\" -p \"${PROFILES[0]}\" -p \"${PROFILES[1]}\"" "Failed to launch container"

# 2. Wait until RUNNING
echo "Waiting for ${CONTAINER_NAME} to reach RUNNING state..."
local max_attempts=30
local attempt=0

while [ $attempt -lt $max_attempts ]; do
    if incus info "${CONTAINER_NAME}" 2>/dev/null | grep -q '^Status: RUNNING$'; then
        break
    fi
    printf '.'
    sleep 2
    attempt=$((attempt + 1))
done

if [ $attempt -eq $max_attempts ]; then
    error_exit "Timed out waiting for container ${CONTAINER_NAME} to reach RUNNING state"
fi

echo -e "\n${CONTAINER_NAME} is RUNNING."

# Helper to run and validate inside container
run_exec() {
    local cmd="$1"
    # Build shell options
    if [ "${STRICT_MODE}" = "true" ]; then
        shell_opts="set -euo pipefail;"
    else
        shell_opts="set -e;"
    fi
    
    echo "-> Executing inside container: $cmd"
    if ! incus exec "${CONTAINER_NAME}" -- bash -c "$shell_opts $cmd"; then
        error_exit "Failed to execute command in container: $cmd"
    fi
    echo "   [OK]"
}

disable_unit() {
  local unit="$1"
  run_exec "systemctl disable ${unit} --now || true"
}

# 3a. Ensure curl is available for APT rewrite
run_exec 'DEBIAN_FRONTEND=noninteractive apt-get update -qq'
run_exec 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl'

# 3b. Point APT to internal cache via external rewrite script
run_exec "curl -fsSL ${DEBCACHE_URL}/rewrite.sh | bash"

# 3c. Disable systemd-networkd and systemd-resolved, and remove network configs
disable_unit systemd-networkd
disable_unit systemd-resolved
# Remove any lingering systemd-networkd config for eth0
run_exec 'rm -f /etc/systemd/network/eth0.network || true'

# 3d. Configure DNS (parametrizable). Configure DNS (parametrizable)
run_exec "rm -f /etc/resolv.conf && printf '%s\n' 'nameserver ${DNS_SERVER}' 'search ${DNS_DOMAIN}' 'domain ${DNS_DOMAIN}' > /etc/resolv.conf && chmod 644 /etc/resolv.conf"

# 3e. Validate APT cache
run_exec 'DEBIAN_FRONTEND=noninteractive apt-get update -qq'

# 4. Install base packages non-interactively (sudo, ifupdown, traceroute, nslookup)
run_exec 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo ifupdown traceroute dnsutils apt-utils openssh-server'

# 5. Create user ${USERNAME}
run_exec "id ${USERNAME} || useradd -m -s /bin/bash ${USERNAME}"
run_exec "passwd -d ${USERNAME}"

# 6. Install SSH keys for ${USERNAME}
run_exec "mkdir -p /home/${USERNAME}/.ssh"
run_exec "curl -sfL https://github.com/aredan.keys -o /home/${USERNAME}/.ssh/authorized_keys"
run_exec "chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh && chmod 700 /home/${USERNAME}/.ssh && chmod 600 /home/${USERNAME}/.ssh/authorized_keys"

# 7. Grant sudo
echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" | run_exec "tee /etc/sudoers.d/${USERNAME}"
run_exec "chmod 440 /etc/sudoers.d/${USERNAME}"

# 8. Configure ifupdown networking
echo "Configuring ifupdown network inside container..."
run_exec 'cat > /etc/network/interfaces <<EOL
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOL'

# 9. Flush any existing IP addresses on eth0 to avoid duplicates
run_exec 'ip addr flush dev eth0 || true'

# 10. Bring up interface
run_exec 'ifdown eth0 || true && ifup eth0'

# 11. Install Docker via official script
run_exec 'curl -fsSL https://get.docker.com | sh'

# 12. Add ${USERNAME} to Docker group
run_exec "usermod -aG docker ${USERNAME}"

# Final status
echo "Setup complete: ${CONTAINER_NAME} configured for user ${USERNAME} with Docker."

# 13. Convert container to template and clean up
# 13a. Check if alias already exists via alias list
if ! incus image alias list 2>/dev/null | awk '{print $2}' | grep -qx "${TEMPLATE_NAME}"; then
    echo "Template alias '${TEMPLATE_NAME}' does not exist. Proceeding with template creation..."
else
  read -r -p "Template alias '${TEMPLATE_NAME}' already exists. Delete and recreate? (y/N): " alias_choice
  case "${alias_choice}" in
    [Yy]*)
      echo "Deleting existing alias '${TEMPLATE_NAME}'..."
      incus image alias delete "${TEMPLATE_NAME}"
      echo "Deleted alias '${TEMPLATE_NAME}'.";;
    *)
      echo "Aborting template publish.";
      exit 1;;
  esac
fi

echo "Stopping ${CONTAINER_NAME}..."
if ! incus stop "${CONTAINER_NAME}" >/dev/null; then
    error_exit "Failed to stop container ${CONTAINER_NAME}"
fi

echo "Publishing ${CONTAINER_NAME} as template '${TEMPLATE_NAME}'..."
if ! incus publish "${CONTAINER_NAME}" --alias "${TEMPLATE_NAME}" >/dev/null; then
    error_exit "Failed to publish container as template ${TEMPLATE_NAME}"
fi

echo "Deleting original container '${CONTAINER_NAME}'..."
if ! incus delete "${CONTAINER_NAME}" --force >/dev/null; then
    echo "Warning: Failed to delete container ${CONTAINER_NAME}" >&2
else
    echo "Container '${CONTAINER_NAME}' successfully deleted."
fi

echo "Template '${TEMPLATE_NAME}' successfully created."
