#!/usr/bin/env bash
#set -euo pipefail

# Interactive menu to select image template and VM name
# Load available templates (image aliases)
echo "Fetching available templates..."
mapfile -t TEMPLATES < <(incus image list --format csv | tail -n +1 | cut -d',' -f1 | sort -u)
if [ ${#TEMPLATES[@]} -eq 0 ]; then
  echo "No templates found. Exiting."
  exit 1
fi

echo "Available templates:"
for i in "${!TEMPLATES[@]}"; do
  printf "%3d) %s\n" "$((i+1))" "${TEMPLATES[i]}"
done

# Prompt for template selection
while true; do
  read -rp "Select a template by number: " sel
  if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#TEMPLATES[@]} )); then
    TEMPLATE="${TEMPLATES[sel-1]}"
    break
  else
    echo "Invalid selection. Choose a number between 1 and ${#TEMPLATES[@]}."
  fi
done

echo "Selected template: $TEMPLATE"

# Prompt for VM/container name
read -rp "Enter desired container name: " NAME

# User-configurable static-network defaults (can override below)
STORAGE_POOL="nvme1n1"
PROFILES=("default" "vlan10")
STATIC_IP="10.45.10.50"
NETMASK="255.255.255.0"
GATEWAY="10.45.10.1"
DNS="10.53.53.53 8.8.8.8"
INTERFACE="eth0"

# Confirm or override network settings
read -rp "Use default static IP settings? [Y/n] " yn
if [[ "$yn" =~ ^[Nn] ]]; then
  read -rp "IP address (e.g. 10.45.10.50): " STATIC_IP
  read -rp "Netmask (e.g. 255.255.255.0): " NETMASK
  read -rp "Gateway (e.g. 10.45.10.1): " GATEWAY
  read -rp "DNS (space-separated): " DNS
fi

# 1) Initialize container
echo "Initializing container '$NAME' from template '$TEMPLATE'..."
incus init "$TEMPLATE" "$NAME" \
  --storage "$STORAGE_POOL" \
  $(printf -- "--profile %s " "${PROFILES[@]}")

# 2) Start container and wait for RUNNING status
echo "Starting container..."
incus start "$NAME"
echo -n "Waiting for container to enter RUNNING state"
until incus info "$NAME" | grep -q "Status: RUNNING"; do
  echo -n "."
  sleep 1
done
echo " OK"

# 3) Configure /etc/network/interfaces inside container
echo "Configuring static network in /etc/network/interfaces..."
incus exec "$NAME" -- bash -c "cat > /etc/network/interfaces <<EOF
# This file is managed by script
auto lo
iface lo inet loopback

auto $INTERFACE
iface $INTERFACE inet static
    address $STATIC_IP
    netmask $NETMASK
    gateway $GATEWAY
    dns-nameservers $DNS
EOF"

# 4) Restart networking service inside container
# Prefer init.d, then service, then ifdown/ifup
echo "Restarting networking service inside container..."
incus exec "$NAME" -- bash -c "
if [ -x /etc/init.d/networking ]; then
  /etc/init.d/networking restart
elif command -v service &>/dev/null; then
  service networking restart
elif command -v ifdown &>/dev/null && command -v ifup &>/dev/null; then
  ifdown $INTERFACE && ifup $INTERFACE
else
  echo 'Warning: cannot restart networking automatically; please restart it manually inside the container'
fi
"

# 5) Verify network
echo "Waiting for network to apply..."
incus exec "$NAME" -- bash -c "until ip addr show $INTERFACE | grep -q $STATIC_IP; do sleep 1; done"

echo "🎉 Container '$NAME' is up with static IP $STATIC_IP on $INTERFACE"
