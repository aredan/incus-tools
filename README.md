# Incus Tools

This repository contains utility scripts for managing Incus containers and templates. These scripts help automate the creation of container templates and deployment of containers with specific configurations that only applies to aaNetworks. If you find this repo and plan to use it, first look at the hardcoded values in the scripts and change them to match your environment.

## Prerequisites

- Incus (LXC) installed and configured
- Sudo/root access
- Internet access (for downloading packages during template creation)

## Scripts

### 1. build-template.sh

This script creates a custom Incus container template with pre-configured settings, packages, and user accounts.

#### Features

- Creates a Debian-based container with specified profiles
- Configures networking (DHCP by default)
- Sets up a non-root user with SSH access
- Installs common utilities (sudo, ifupdown, traceroute, etc.)
- Configures Docker inside the container
- Publishes the container as a reusable template

#### Usage

```bash
./build-template.sh
```

#### Configuration

Edit the following variables at the top of the script to customize the build:

```bash
CONTAINER_NAME="builder"          # Temporary container name during build
IMAGE="images:debian/13"          # Base image to use
PROFILES=(default vlan10)         # Incus profiles to apply
USERNAME="ariel"                  # Username to create in the container
DNS_SERVER="10.53.53.53"         # DNS server to use
DNS_DOMAIN="aanetworks.org"       # DNS domain
DEBCACHE_URL="http://debcache.aanetworks.org"  # APT cache server
TEMPLATE_NAME="template1"         # Name for the published template
STRICT_MODE="false"              # Toggle strict mode for container commands
```

### 2. deploy.sh

This script helps deploy containers from existing templates with custom network configurations.

#### Features

- Interactive template selection
- Customizable network settings (static IP, netmask, gateway, DNS)
- Automatic network configuration inside the container
- Support for multiple network profiles
- Automatic detection of networking service

#### Usage

```bash
./deploy.sh
```

The script will guide you through:
1. Selecting a template from available images
2. Naming your container
3. Configuring network settings (with defaults that can be overridden)

#### Default Network Settings

```bash
STORAGE_POOL="nvme1n1"
PROFILES=("default" "vlan10")
STATIC_IP="10.45.10.50"
NETMASK="255.255.255.0"
GATEWAY="10.45.10.1"
DNS="10.53.53.53 8.8.8.8"
INTERFACE="eth0"
```


