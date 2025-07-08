#!/usr/bin/env bash

# Exit on error, undefined variable, and pipe failure
set -euo pipefail

# Version
VERSION="1.0.0"

# Default parameters
CONTAINER_NAME="builder"
IMAGE="images:debian/13"
PROFILES="default,vlan10"
USERNAME="ariel"
DNS_SERVER="10.53.53.53"
DNS_DOMAIN="aanetworks.org"
DEBCACHE_URL="http://debcache.aanetworks.org"
TEMPLATE_NAME="template1"
STRICT_MODE="false"
SHOW_HELP=false

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

# Display help
show_help() {
    cat << EOF
Build Template Script v${VERSION}

Usage: $0 [OPTIONS]

Options:
  -n, --name NAME        Container name (default: ${CONTAINER_NAME})
  -i, --image IMAGE      Base image (default: ${IMAGE})
  -p, --profiles LIST    Comma-separated list of profiles (default: ${PROFILES})
  -u, --user USER        Username to create (default: ${USERNAME})
  -d, --dns IP           DNS server (default: ${DNS_SERVER})
  -D, --domain DOMAIN    DNS domain (default: ${DNS_DOMAIN})
  -c, --cache URL        Deb cache URL (default: ${DEBCACHE_URL})
  -t, --template NAME    Template name (default: ${TEMPLATE_NAME})
  -s, --strict           Enable strict mode in container
  -h, --help             Show this help message
  -v, --version          Show version

Examples:
  $0 -n mybuilder -i images:debian/12 -p default,vlan20 -u admin
  $0 --dns 8.8.8.8 --domain example.com --strict

Note: This script requires root privileges and Incus to be installed.
EOF
    exit 0
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name)
                CONTAINER_NAME="$2"
                shift 2
                ;;
            -i|--image)
                IMAGE="$2"
                shift 2
                ;;
            -p|--profiles)
                PROFILES="$2"
                shift 2
                ;;
            -u|--user)
                USERNAME="$2"
                shift 2
                ;;
            -d|--dns)
                DNS_SERVER="$2"
                shift 2
                ;;
            -D|--domain)
                DNS_DOMAIN="$2"
                shift 2
                ;;
            -c|--cache)
                DEBCACHE_URL="$2"
                shift 2
                ;;
            -t|--template)
                TEMPLATE_NAME="$2"
                shift 2
                ;;
            -s|--strict)
                STRICT_MODE="true"
                shift
                ;;
            -h|--help)
                show_help
                ;;
            -v|--version)
                echo "build-template.sh v${VERSION}"
                exit 0
                ;;
            *)
                error_exit "Unknown option: $1"
                ;;
        esac
    done
}

# Validate parameters
validate_parameters() {
    # Check if required commands exist
    command_exists incus || error_exit "Incus is not installed. Please install Incus before running this script."
    
    # Validate username (alphanumeric and underscores only)
    if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
        error_exit "Invalid username. Must be lowercase alphanumeric with underscores."
    fi
    
    # Validate DNS server format
    if ! [[ "$DNS_SERVER" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        error_exit "Invalid DNS server IP address format: $DNS_SERVER"
    fi
    
    # Validate DEBCACHE_URL
    if ! [[ "$DEBCACHE_URL" =~ ^https?:// ]]; then
        error_exit "Debcache URL must start with http:// or https://"
    fi
    
    # Convert comma-separated profiles to array
    IFS=',' read -ra PROFILES_ARR <<< "$PROFILES"
    if [ ${#PROFILES_ARR[@]} -eq 0 ]; then
        error_exit "At least one profile must be specified"
    fi
}

# Main function
main() {
    parse_arguments "$@"
    validate_parameters
    
    echo "=== Build Template Configuration ==="
    echo "Container Name: $CONTAINER_NAME"
    echo "Base Image: $IMAGE"
    echo "Profiles: $PROFILES"
    echo "Username: $USERNAME"
    echo "DNS Server: $DNS_SERVER"
    echo "DNS Domain: $DNS_DOMAIN"
    echo "Debcache URL: $DEBCACHE_URL"
    echo "Template Name: $TEMPLATE_NAME"
    echo "Strict Mode: $STRICT_MODE"
    echo "==================================="
    
    # Rest of the script will use these parameters
    # ...
}

# Start the main function
main "$@"

# 0. Prompt and remove existing container if present
if incus info "${CONTAINER_NAME}" &>/dev/null; then
    read -r -p "Container '${CONTAINER_NAME}' already exists. Delete and recreate? (y/N): " choice
    case "$choice" in
        [Yy]*)
            echo "Deleting existing container '${CONTAINER_NAME}'..."
            if ! incus delete "${CONTAINER_NAME}" --force >/dev/null; then
                error_exit "Failed to delete existing container ${CONTAINER_NAME}"
            fi
            echo "Deleted '${CONTAINER_NAME}'."
            ;;
        *)
            echo "Aborting."
            exit 1
            ;;
    esac
fi

# 1. Launch container
echo "Launching ${CONTAINER_NAME} from ${IMAGE} with profiles ${PROFILES}..."

# Build the incus launch command with all profiles
launch_cmd="incus launch \"${IMAGE}\" \"${CONTAINER_NAME}\"
for profile in "${PROFILES_ARR[@]}"; do
    launch_cmd+=" -p \"$profile\""
done

if ! eval "$launch_cmd" > /dev/null; then
    error_exit "Failed to launch container with command: $launch_cmd"
fi

# 2. Wait until RUNNING
echo -n "Waiting for ${CONTAINER_NAME} to reach RUNNING state..."
local max_attempts=30
local attempt=0

while [ $attempt -lt $max_attempts ]; do
    if incus info "${CONTAINER_NAME}" 2>/dev/null | grep -q '^Status: RUNNING$'; then
        echo " RUNNING"
        break
    fi
    printf '.'
    sleep 2
    attempt=$((attempt + 1))
done

if [ $attempt -eq $max_attempts ]; then
    echo " FAILED"
    error_exit "Timed out waiting for container ${CONTAINER_NAME} to reach RUNNING state"
fi

# Helper to run and validate inside container
run_exec() {
    local cmd="$1"
    # Build shell options
    if [ "${STRICT_MODE}" = "true" ]; then
        shell_opts="set -euo pipefail;"
    else
        shell_opts="set -e;"
    fi
    
    # Print the command being executed (truncate if too long)
    local display_cmd="$cmd"
    if [ ${#display_cmd} -gt 60 ]; then
        display_cmd="${display_cmd:0:60}..."
    fi
    echo -n "-> Executing: ${display_cmd} "
    
    # Execute the command
    if ! incus exec "${CONTAINER_NAME}" -- bash -c "$shell_opts $cmd" >/dev/null 2>&1; then
        echo "[FAILED]"
        error_exit "Command failed in container: $cmd"
    fi
    echo "[OK]"
}

disable_unit() {
    local unit="$1"
    run_exec "systemctl disable ${unit} --now || true"
}

echo "=== Configuring Container ==="

# 3a. Ensure curl is available for APT rewrite
run_exec 'DEBIAN_FRONTEND=noninteractive apt-get update -qq'
run_exec 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl'

# 3b. Point APT to internal cache via external rewrite script
if [ -n "${DEBCACHE_URL}" ]; then
    echo "Configuring APT to use cache at ${DEBCACHE_URL}..."
    run_exec "curl -fsSL ${DEBCACHE_URL}/rewrite.sh | bash"
else
    echo "Skipping APT cache configuration (no DEBCACHE_URL provided)"
fi

# 3c. Disable systemd-networkd and systemd-resolved, and remove network configs
disable_unit systemd-networkd
disable_unit systemd-resolved
# Remove any lingering systemd-networkd config for eth0
run_exec 'rm -f /etc/systemd/network/eth0.network || true'

# 3d. Configure DNS
echo "Configuring DNS: server=${DNS_SERVER}, domain=${DNS_DOMAIN}"
run_exec "rm -f /etc/resolv.conf && printf '%s\\n' 'nameserver ${DNS_SERVER}' 'search ${DNS_DOMAIN}' 'domain ${DNS_DOMAIN}' > /etc/resolv.conf && chmod 644 /etc/resolv.conf"

# 3e. Validate APT cache
run_exec 'DEBIAN_FRONTEND=noninteractive apt-get update -qq'

# 4. Install base packages non-interactively
echo "=== Installing Base Packages ==="
run_exec 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo ifupdown traceroute dnsutils apt-utils openssh-server'

# 5. Create user
echo "=== Configuring User: ${USERNAME} ==="
run_exec "id ${USERNAME} || useradd -m -s /bin/bash ${USERNAME}"
run_exec "passwd -d ${USERNAME}"

# 6. Install SSH keys for the user
echo "=== Configuring SSH Access ==="
run_exec "mkdir -p /home/${USERNAME}/.ssh"
run_exec "curl -sfL https://github.com/aredan.keys -o /home/${USERNAME}/.ssh/authorized_keys"
run_exec "chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh && chmod 700 /home/${USERNAME}/.ssh && chmod 600 /home/${USERNAME}/.ssh/authorized_keys"

# 7. Grant sudo
echo "=== Configuring Sudo Access ==="
echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" | run_exec "tee /etc/sudoers.d/${USERNAME}"
run_exec "chmod 440 /etc/sudoers.d/${USERNAME}"

# 8. Configure ifupdown networking
echo "=== Configuring Network ==="
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
echo "=== Installing Docker ==="
run_exec 'curl -fsSL https://get.docker.com | sh'

# 12. Add user to Docker group
run_exec "usermod -aG docker ${USERNAME}"

echo "=== Container Setup Complete ==="
echo "Successfully configured container '${CONTAINER_NAME}' with the following settings:"
echo "- Base Image: ${IMAGE}"
echo "- User: ${USERNAME} (with sudo and Docker access)"
echo "- DNS: ${DNS_SERVER} (${DNS_DOMAIN})"
echo "- Profiles: ${PROFILES}"
echo "- Template Name: ${TEMPLATE_NAME}"

# 13. Convert container to template and clean up
echo "=== Creating Template ==="

# 13a. Check if alias already exists via alias list
if ! incus image alias list 2>/dev/null | awk '{print $2}' | grep -qx "${TEMPLATE_NAME}"; then
    echo "Template alias '${TEMPLATE_NAME}' does not exist. Proceeding with template creation..."
else
    read -r -p "Template alias '${TEMPLATE_NAME}' already exists. Delete and recreate? (y/N): " alias_choice
    case "${alias_choice}" in
        [Yy]*)
            echo "Deleting existing alias '${TEMPLATE_NAME}'..."
            if ! incus image alias delete "${TEMPLATE_NAME}"; then
                error_exit "Failed to delete existing template alias '${TEMPLATE_NAME}'"
            fi
            echo "Deleted alias '${TEMPLATE_NAME}'."
            ;;
        *)
            echo "Aborting template publish."
            exit 1
            ;;
    esac
fi

echo "Stopping ${CONTAINER_NAME}..."
if ! incus stop "${CONTAINER_NAME}" >/dev/null; then
    error_exit "Failed to stop container ${CONTAINER_NAME}"
fi

echo "Publishing ${CONTAINER_NAME} as template '${TEMPLATE_NAME}'..."
if ! incus publish "${CONTAINER_NAME}" --alias "${TEMPLATE_NAME}" >/dev/null; then
    error_exit "Failed to publish container as template '${TEMPLATE_NAME}'"
fi

echo "Cleaning up..."
if ! incus delete "${CONTAINER_NAME}" --force >/dev/null; then
    echo "Warning: Failed to delete container '${CONTAINER_NAME}'" >&2
else
    echo "Container '${CONTAINER_NAME}' successfully deleted."
fi

echo -e "\n=== Template Creation Complete ==="
echo "Successfully created template '${TEMPLATE_NAME}' from container '${CONTAINER_NAME}'"
echo "You can now create new containers using this template with:"
echo "  incus launch ${TEMPLATE_NAME} <container-name>"

# List the created template
echo -e "\nAvailable templates:"
incus image list | grep -i "${TEMPLATE_NAME}"
