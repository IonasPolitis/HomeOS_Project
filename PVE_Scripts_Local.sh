#!/bin/bash

##PVE Community Scripts Diagnostics Check
mkdir -p /usr/local/community-scripts/
cat << EOF > /usr/local/community-scripts/diagnostics
DIAGNOSTICS=yes

# Community-Scripts Telemetry Configuration
# https://telemetry.community-scripts.org
#
# This file stores your telemetry preference.
# Set DIAGNOSTICS=yes to share anonymous installation data.
# Set DIAGNOSTICS=no to disable telemetry.
#
# You can also change this via the Settings menu during installation.
#
# Data collected (when enabled):
#   disk_size, core_count, ram_size, os_type, os_version,
#   nsapp, method, pve_version, status, exit_code
#
# No personal data (IPs, hostnames, passwords) is ever collected.
# Privacy: https://github.com/community-scripts/telemetry-service/blob/main/docs/PRIVACY.md
EOF

## Instal PVEScriptsLocal
mode=generated var_ctid="100" var_ssh="yes" var_container_storage="local-lvm" var_template_storage="local" bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/pve-scripts-local.sh)"
wget -q -O /tmp/pve-scripts-local.sh https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/pve-scripts-local.sh
HOST_IP=$(hostname -I | awk '{print $1}')
LXC_IP=$(pct exec 100 -- ip a | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1)
LXC_PORT=$(tail -n 1 /tmp/pve-scripts-local.sh | sed 's/.*:\([0-9]*\)\${CL}.*/\1/')
iptables -t nat -A PREROUTING -p tcp -d "$HOST_IP" --dport "$LXC_PORT" -j DNAT --to-destination "$LXC_IP":"$LXC_PORT"