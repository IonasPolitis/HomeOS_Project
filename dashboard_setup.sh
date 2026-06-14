#!/bin/bash
# ==============================================================================
# Proxmox OS Dashboard - Ultimate Master Setup Script (Monolithic Framework)
# Run this on your Proxmox Host as root.
# ==============================================================================

# --- Environment Variable Pre-Checks ---
if [ -z "$OS_NAME" ]; then echo "Error: OS_NAME is not set."; exit 1; fi
if [ -z "$OS_DIR" ]; then echo "Error: OS_DIR is not set."; exit 1; fi
if [ -z "$OS_BIN_DIR" ]; then echo "Error: OS_BIN_DIR is not set."; exit 1; fi
if [ -z "$OS_TMP_DIR" ]; then echo "Error: OS_TMP_DIR is not set."; exit 1; fi
if [ -z "$OS_TMP_RAM" ]; then echo "Error: OS_TMP_RAM is not set."; exit 1; fi

# --- Setup Variables ---
LXC_ID=100
LXC_HOSTNAME="os-dashboard"
LXC_PASSWORD="xxxxx"      
LXC_CORES=1
LXC_RAM=512
LXC_STORAGE="local-lvm"         
NETWORK_BRIDGE="vmbr0"
NETWORK_IP="dhcp"

# --- Directory Structures (Inside LXC) ---
LXC_APP_DIR="/opt/dashboard"
LXC_BIN_DIR="$LXC_APP_DIR/bin"
LXC_WEB_DIR="$LXC_APP_DIR/web"

# --- Dynamic Host Variables ---
PVE_NODE=$(hostname)
PVE_HOST_IP=$(ip -4 addr show $NETWORK_BRIDGE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

echo "=============================================================================="
echo " Starting $OS_NAME Dashboard Monolithic Deployment..."
echo " Host: $PVE_NODE ($PVE_HOST_IP)"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 0. AUTOMATIC API TOKEN GENERATION
# ------------------------------------------------------------------------------
echo "[0/5] Generating Proxmox API Token dynamically..."
pveum user token delete root@pam dashboard &>/dev/null
TOKEN_SECRET=$(pveum user token add root@pam dashboard --privsep=0 --output-format json | python3 -c "import sys, json; print(json.load(sys.stdin)['value'])")
API_TOKEN="PVEAPIToken=root@pam"'!'"dashboard=$TOKEN_SECRET"

# ------------------------------------------------------------------------------
# 1. SETUP HOST GPU DAEMON & PRE-SEED UNATTENDED COMMUNITY PREFERENCES
# ------------------------------------------------------------------------------
echo "[1/5] Pre-seeding community script choices and initializing hardware metrics..."

mkdir -p /etc/apcluster /usr/local/community-scripts/ /etc/community-scripts
echo "false" > /etc/apcluster/telemetry.txt 2>/dev/null
echo "disable" > /etc/community-scripts/telemetry 2>/dev/null
echo "false" > /etc/community-scripts/analytics 2>/dev/null

cat << 'EOF' > /usr/local/community-scripts/diagnostics
DIAGNOSTICS=no
# Community-Scripts Telemetry Configuration
# Privacy: https://github.com/community-scripts/telemetry-service/blob/main/docs/PRIVACY.md
EOF


# ==============================================================================
# 🔴 DROP ZONE 1: PASTE YOUR ENTIRE host-gpu-daemon.sh CODE HERE
# ==============================================================================
cat << 'EOF' > /tmp/host-gpu-daemon.sh
#!/bin/bash
PORT=9090
RAM_DISK_FILE="__OS_TMP_RAM__/gpu_telemetry.json"

# Initialize with empty data safely
echo "{}" > "$RAM_DISK_FILE"

cd "__OS_TMP_RAM__" || exit
# Start the lightweight Python web server in the background
python3 -m http.server $PORT &
SERVER_PID=$!
trap "kill $SERVER_PID; exit" INT TERM EXIT

# HARDWARE CHECK: Look for NVIDIA drivers ONCE at boot.
if ! command -v nvidia-smi &> /dev/null; then
    echo "No NVIDIA GPU detected. Serving empty telemetry and suspending loop to save CPU."
    # Suspends the script indefinitely (0% CPU usage) while keeping the Python server alive!
    sleep infinity 
    exit 0
fi

# If a GPU IS detected, proceed with the active 5-second polling loop
while true; do
    NVIDIA_LOAD=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | awk '{print $1}')
    NVIDIA_MEM=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits | awk -F', ' '{printf "%.1f / %.1f GB", $1/1024, $2/1024}')
    NVIDIA_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader)
    GPU_JSON=$(jq -n --arg type "dGPU" --arg name "$NVIDIA_NAME" --arg load "$NVIDIA_LOAD" --arg vram "$NVIDIA_MEM" '{type: $type, name: $name, load: $load, vram: $vram}')
    
    echo "$GPU_JSON" > "$RAM_DISK_FILE"
    sleep 5
done
EOF

sed -i "s|__OS_TMP_RAM__|$OS_TMP_RAM|g" /tmp/host-gpu-daemon.sh
mv /tmp/host-gpu-daemon.sh "$OS_BIN_DIR/host-gpu-daemon.sh"
chmod +x "$OS_BIN_DIR/host-gpu-daemon.sh"

cat << EOF > /etc/systemd/system/gpu-daemon-$OS_NAME.service
[Unit]
Description=$OS_NAME GPU Telemetry Daemon
After=network.target
[Service]
ExecStart=$OS_BIN_DIR/host-gpu-daemon.sh
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "gpu-daemon-$OS_NAME.service"
systemctl restart "gpu-daemon-$OS_NAME.service"

# ------------------------------------------------------------------------------
# 2. DOWNLOAD LXC TEMPLATE
# ------------------------------------------------------------------------------
echo "[2/5] Fetching Debian Template..."
pveam update > /dev/null
DEBIAN_TEMPLATE=$(pveam available | grep system | grep debian-13 | awk '{print $2}' | head -n 1)
if [ -z "$DEBIAN_TEMPLATE" ]; then
    DEBIAN_TEMPLATE=$(pveam available | grep system | grep debian-12 | awk '{print $2}' | head -n 1)
fi
pveam download local $DEBIAN_TEMPLATE > /dev/null
TEMPLATE_PATH="local:vztmpl/${DEBIAN_TEMPLATE##*/}"

# ------------------------------------------------------------------------------
# 3. CREATE & START LXC & ESTABLISH TRUST TUNNEL
# ------------------------------------------------------------------------------
echo "[3/5] Creating LXC Container $LXC_ID ($LXC_HOSTNAME)..."
if pct status $LXC_ID &> /dev/null; then pct stop $LXC_ID && pct destroy $LXC_ID; fi

pct create $LXC_ID $TEMPLATE_PATH \
    --hostname $LXC_HOSTNAME --password $LXC_PASSWORD --cores $LXC_CORES \
    --memory $LXC_RAM --rootfs $LXC_STORAGE:8 --net0 name=eth0,bridge=$NETWORK_BRIDGE,ip=$NETWORK_IP \
    --unprivileged 1 --features nesting=1 \
    --onboot 1 --startup order=0

pct start $LXC_ID
sleep 15

echo "Configuring secure roots SSH authorization channels loop..."
pct exec $LXC_ID -- mkdir -p /root/.ssh
pct exec $LXC_ID -- ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa -q

LXC_PUB_KEY=$(pct exec $LXC_ID -- cat /root/.ssh/id_rsa.pub)
echo "$LXC_PUB_KEY" >> /root/.ssh/authorized_keys

ssh-keyscan -H $PVE_HOST_IP 2>/dev/null > /tmp/host_vif
pct push $LXC_ID /tmp/host_vif /root/.ssh/known_hosts
rm -f /tmp/host_vif

# ------------------------------------------------------------------------------
# 4. PROVISION LXC DIRECTORIES, ASSETS & DATA ENGINE
# ------------------------------------------------------------------------------
echo "[4/5] Installing dependencies and building data engine..."
pct exec $LXC_ID -- bash -c "apt-get update > /dev/null && apt-get install -y jq curl python3 python3-websockets > /dev/null"
# FIXED: Create the strict apps/icons directory instead of the redundant web/icons one
pct exec $LXC_ID -- mkdir -p "$LXC_BIN_DIR" "/opt/dashboard/apps/icons" "$LXC_WEB_DIR/api" "$LXC_WEB_DIR/fonts"

# FIXED: Route the default fallback image directly into the strict backend folder
pct exec $LXC_ID -- curl -sL -o /opt/dashboard/apps/icons/default.png "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/proxmox.png"
pct exec $LXC_ID -- curl -s -o "$LXC_WEB_DIR/fonts/inter-400.woff2" "https://cdn.jsdelivr.net/fontsource/fonts/inter@latest/latin-400-normal.woff2"
pct exec $LXC_ID -- curl -s -o "$LXC_WEB_DIR/fonts/inter-500.woff2" "https://cdn.jsdelivr.net/fontsource/fonts/inter@latest/latin-500-normal.woff2"
pct exec $LXC_ID -- curl -s -o "$LXC_WEB_DIR/fonts/inter-600.woff2" "https://cdn.jsdelivr.net/fontsource/fonts/inter@latest/latin-600-normal.woff2"
pct exec $LXC_ID -- curl -s -o "$LXC_WEB_DIR/fonts/jetbrains-mono-400.woff2" "https://cdn.jsdelivr.net/fontsource/fonts/jetbrains-mono@latest/latin-400-normal.woff2"
pct exec $LXC_ID -- curl -s -o "$LXC_WEB_DIR/fonts/jetbrains-mono-500.woff2" "https://cdn.jsdelivr.net/fontsource/fonts/jetbrains-mono@latest/latin-500-normal.woff2"
pct exec $LXC_ID -- curl -s -o "$LXC_WEB_DIR/fonts/jetbrains-mono-600.woff2" "https://cdn.jsdelivr.net/fontsource/fonts/jetbrains-mono@latest/latin-600-normal.woff2"

# ==============================================================================
# 🔴 DROP ZONE 2: PASTE YOUR ENTIRE sys-and-telemetry-collector.sh CODE HERE
# ==============================================================================
cat << 'EOF' > /tmp/sys-and-telemetry-collector.sh
#!/bin/bash
PVE_HOST="__PVE_HOST__"
PVE_NODE="__PVE_NODE__"
API_TOKEN="__API_TOKEN__"

HOST_DAEMON_URL="http://$PVE_HOST:9090/gpu_telemetry.json"

# --- NEW DIRECTORY ARCHITECTURE ---
# Writing strictly to /run/ (which is automatically a tmpfs RAM disk in Debian LXCs)
OUTPUT_FILE="/run/dashboard_pulse.json"

while true; do
    # 1. Hardware Metrics
    GPU_DATA=$(curl -s --max-time 2 "$HOST_DAEMON_URL" || echo "{}")
    [ -z "$GPU_DATA" ] && GPU_DATA="{}"
    
    NODE_STATUS=$(curl -s -k --max-time 5 -H "Authorization: $API_TOKEN" "https://$PVE_HOST:8006/api2/json/nodes/$PVE_NODE/status" || echo "{}")
    CPU_USAGE=$(echo "$NODE_STATUS" | jq -r '.data.cpu // 0' 2>/dev/null || echo "0")
    CPU_PCT=$(awk -v cpu="$CPU_USAGE" 'BEGIN { printf "%.1f", cpu * 100 }')
    
    MEM_USED=$(echo "$NODE_STATUS" | jq -r '.data.memory.used // 0' 2>/dev/null || echo "0")
    MEM_TOTAL=$(echo "$NODE_STATUS" | jq -r '.data.memory.total // 1' 2>/dev/null || echo "1")
    MEM_USED_GB=$(awk -v mem="$MEM_USED" 'BEGIN { printf "%.1f", mem / 1073741824 }')
    MEM_TOTAL_GB=$(awk -v mem="$MEM_TOTAL" 'BEGIN { printf "%.1f", mem / 1073741824 }')
    
    # 2. Storage Metrics
    STORAGE_JSON_RAW=$(curl -s -k --max-time 5 -H "Authorization: $API_TOKEN" "https://$PVE_HOST:8006/api2/json/nodes/$PVE_NODE/storage" || echo "{}")
    STORAGE_ARRAY=$(echo "$STORAGE_JSON_RAW" | jq -c '[.data[]? | select(.total > 0) | {
        name: .storage, 
        pct: ((.used / .total) * 100 | round),
        total: (
            if .total < 1099511627776 then 
                ( (.total / 1073741824 | round | tostring) + "G" )
            else 
                ( ((.total / 1099511627776) * 10 | round / 10 | tostring) + "T" )
            end
        )
    }] | sort_by(.name)' 2>/dev/null || echo "[]")
    [ -z "$STORAGE_ARRAY" ] && STORAGE_ARRAY="[]"
    
    # 3. Container Parsing (UPGRADED WITH CONFIG FETCHING)
    NODES_JSON=$(curl -s -k --max-time 5 -H "Authorization: $API_TOKEN" "https://$PVE_HOST:8006/api2/json/nodes/$PVE_NODE/lxc" || echo "{}")
    
    APPS_TMP=$(mktemp)
    STOPPED_TMP=$(mktemp)

    ROWS=$(echo "$NODES_JSON" | jq -r '.data[]? | @base64' 2>/dev/null)
    
    for row in $ROWS; do
        [ -z "$row" ] && continue
        
        _jq() { echo "$row" | base64 --decode | jq -r "$1" 2>/dev/null || echo "Unknown"; }
        
        RAW_NAME=$(_jq '.name')
        STATUS=$(_jq '.status')
        VMID=$(_jq '.vmid')
        
        HUMAN_NAME=$(echo "$RAW_NAME" | sed 's/[-_]/ /g' | awk '{for(i=1;i<=NF;i++)sub(/./,toupper(substr($i,1,1)),$i)}1')
        SAFE_NAME=$(echo "$RAW_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')
        ICON_PATH="icons/${SAFE_NAME}.png"

        # --- PHASE 1 UPGRADE: Fetch Advanced Proxmox Configuration (5s Timeout) ---
        CONFIG_JSON=$(curl -s -k --max-time 5 -H "Authorization: $API_TOKEN" "https://$PVE_HOST:8006/api2/json/nodes/$PVE_NODE/lxc/$VMID/config" || echo "{}")
        
        CORES=$(echo "$CONFIG_JSON" | jq -r '.data.cores // 1')
        MEMORY=$(echo "$CONFIG_JSON" | jq -r '.data.memory // 512')
        SWAP=$(echo "$CONFIG_JSON" | jq -r '.data.swap // 0')
        ONBOOT=$(echo "$CONFIG_JSON" | jq -r '.data.onboot // 0')
        PROTECTION=$(echo "$CONFIG_JSON" | jq -r '.data.protection // 0')
        TAGS=$(echo "$CONFIG_JSON" | jq -r '.data.tags // ""')
        NET0=$(echo "$CONFIG_JSON" | jq -r '.data.net0 // ""')
        ROOTFS=$(echo "$CONFIG_JSON" | jq -r '.data.rootfs // ""')

        if [ "$STATUS" == "running" ]; then
            jq -n --arg id "$VMID" --arg name "$HUMAN_NAME" --arg raw "$RAW_NAME" --arg icon "$ICON_PATH" --arg status "$STATUS" --arg cores "$CORES" --arg memory "$MEMORY" --arg swap "$SWAP" --arg onboot "$ONBOOT" --arg protection "$PROTECTION" --arg tags "$TAGS" --arg net0 "$NET0" --arg rootfs "$ROOTFS" '{id: $id, name: $name, raw_name: $raw, icon: $icon, status: $status, config: {cores: $cores, memory: $memory, swap: $swap, onboot: $onboot, protection: $protection, tags: $tags, net0: $net0, rootfs: $rootfs}}' >> "$APPS_TMP"
        else
            jq -n --arg id "$VMID" --arg name "$HUMAN_NAME" --arg raw "$RAW_NAME" --arg icon "$ICON_PATH" --arg status "$STATUS" --arg cores "$CORES" --arg memory "$MEMORY" --arg swap "$SWAP" --arg onboot "$ONBOOT" --arg protection "$PROTECTION" --arg tags "$TAGS" --arg net0 "$NET0" --arg rootfs "$ROOTFS" '{id: $id, name: $name, raw_name: $raw, icon: $icon, status: $status, config: {cores: $cores, memory: $memory, swap: $swap, onboot: $onboot, protection: $protection, tags: $tags, net0: $net0, rootfs: $rootfs}}' >> "$STOPPED_TMP"
        fi
    done

    # Slurp the temporary files into pure, valid JSON arrays
    APPS_JSON=$(jq -s '.' "$APPS_TMP" 2>/dev/null || echo "[]")
    STOPPED_JSON=$(jq -s '.' "$STOPPED_TMP" 2>/dev/null || echo "[]")
    rm -f "$APPS_TMP" "$STOPPED_TMP"

    # 4. Master Assembly (RAM Write)
    MASTER_JSON=$(jq -n \
        --argjson gpu "$GPU_DATA" \
        --arg cpu "$CPU_PCT" \
        --arg memUsed "$MEM_USED_GB" \
        --arg memTotal "$MEM_TOTAL_GB" \
        --argjson storage "$STORAGE_ARRAY" \
        --argjson apps "$APPS_JSON" \
        --argjson stopped "$STOPPED_JSON" \
        '{ system: { cpu: $cpu, mem_used: $memUsed, mem_total: $memTotal, gpu: $gpu, storage: $storage }, applications: $apps, stopped_apps: $stopped }')
        
    echo "$MASTER_JSON" > "${OUTPUT_FILE}.tmp"
    mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
    sleep 5
done
EOF

sed -i "s|__PVE_HOST__|$PVE_HOST_IP|g" /tmp/sys-and-telemetry-collector.sh
sed -i "s|__PVE_NODE__|$PVE_NODE|g" /tmp/sys-and-telemetry-collector.sh
sed -i "s|__API_TOKEN__|$API_TOKEN|g" /tmp/sys-and-telemetry-collector.sh
sed -i "s|__LXC_WEB_DIR__|$LXC_WEB_DIR|g" /tmp/sys-and-telemetry-collector.sh
pct push $LXC_ID /tmp/sys-and-telemetry-collector.sh "$LXC_BIN_DIR/sys-and-telemetry-collector.sh"
rm -f /tmp/sys-and-telemetry-collector.sh
pct exec $LXC_ID -- chmod +x "$LXC_BIN_DIR/sys-and-telemetry-collector.sh"


cat << 'EOF' > /tmp/web-server.py
# ==============================================================================
# 🔴 DROP ZONE 3: PASTE YOUR ENTIRE web-server.py CODE HERE
#    (Overwrite these brackets entirely)
# ==============================================================================
EOF

sed -i "s|__PVE_HOST__|$PVE_HOST_IP|g" /tmp/web-server.py
sed -i "s|__PVE_NODE__|$PVE_NODE|g" /tmp/web-server.py
sed -i "s|__API_TOKEN__|$API_TOKEN|g" /tmp/web-server.py
pct push $LXC_ID /tmp/web-server.py "$LXC_WEB_DIR/web-server.py"
rm -f /tmp/web-server.py


# --- Dashboard HTML Generation ---
cat << 'EOF' > /tmp/index.html
# ==============================================================================
# 🔴 DROP ZONE 5: PASTE YOUR ENTIRE dashboard.html CODE HERE 
#    (Overwrite these brackets entirely)
# ==============================================================================
EOF

sed -i "s|__PVE_HOST__|$PVE_HOST_IP|g" /tmp/index.html
pct push $LXC_ID /tmp/index.html "$LXC_WEB_DIR/index.html"
rm -f /tmp/index.html


# --- Installation Terminal Daemon ---
cat << 'EOF' > /tmp/terminal-daemon.py
# ==============================================================================
# 🔴 DROP ZONE 6: PASTE YOUR ENTIRE terminal-daemon.py CODE HERE 
#    (Overwrite these brackets entirely)
# ==============================================================================
EOF

sed -i "s|__PVE_HOST__|$PVE_HOST_IP|g" /tmp/terminal-daemon.py
pct push $LXC_ID /tmp/terminal-daemon.py "$LXC_WEB_DIR/terminal-daemon.py"
rm -f /tmp/terminal-daemon.py


# --- Blueprints Schema Generation ---
# ==============================================================================
# 🔴 DROP ZONE 7: PASTE YOUR ENTIRE flags_blueprint.json CODE HERE 
# ==============================================================================
cat << 'EOF' > /tmp/flags_blueprint.json
{
  "system_defaults": {
    "mode": { "type": "hidden", "default": "generated" },
    "var_ctid": { "type": "number", "label": "Container ID (Leave blank for auto)", "default": "" }
  },
  "basic_settings": {
    "var_hostname": { "type": "text", "label": "Container Hostname", "default": "" },
    "var_pw": { "type": "password", "label": "Root Password (Optional)", "default": "" },
    "var_cores": { "type": "number", "label": "CPU Cores", "default": 1, "min": 1, "max": 16 },
    "var_ram": { "type": "number", "label": "RAM Allocation (MB)", "default": 512, "min": 256, "max": 8192 }
  },
  "network_routing": {
    "var_net": { "type": "select", "label": "IP Assignment Type", "options": ["dhcp", "static"], "default": "dhcp" },
    "var_net_ip": { "type": "text", "label": "Static IP/CIDR (e.g., 10.0.5.50/24)", "default": "", "depends_on": "var_net=static" },
    "var_gateway": { "type": "text", "label": "Gateway IP Address", "default": "", "depends_on": "var_net=static" },
    "var_vlan": { "type": "text", "label": "VLAN Tag", "default": "" },
    "var_mtu": { "type": "number", "label": "MTU Size Override", "default": "" },
    "var_ns": { "type": "text", "label": "Custom DNS Server", "default": "" },
    "var_searchdomain": { "type": "text", "label": "DNS Search Domain", "default": "" },
    "var_mac": { "type": "text", "label": "Custom MAC Address", "default": "" }
  },
  "advanced_privileges": {
    "var_unprivileged": { "type": "toggle", "label": "Unprivileged Container", "default": true, "invert_value": "0" },
    "var_nesting": { "type": "toggle", "label": "Enable Nesting Features", "default": true },
    "var_fuse": { "type": "toggle", "label": "Mount FUSE Storage Engines", "default": false },
    "var_tun": { "type": "toggle", "label": "Expose TUN/TAP Network Drivers", "default": false },
    "var_keyctl": { "type": "toggle", "label": "Enable Keyctl System Calls", "default": false },
    "var_mknod": { "type": "toggle", "label": "Allow Mknod Block Operations", "default": false },
    "var_protection": { "type": "toggle", "label": "Enable Deletion Protection", "default": false }
  },
  "hardware_passthrough": {
    "var_gpu": { "type": "toggle", "label": "Passthrough Host GPU Compute Resources", "default": false }
  },
  "provisioning_tweaks": {
    "var_ssh": { "type": "toggle", "label": "Pre-configure OpenSSH Server", "default": true, "string_output": true },
    "var_ssh_authorized_key": { "type": "textarea", "label": "Authorized Public SSH Keys", "default": "", "depends_on": "var_ssh=true" },
    "var_timezone": { "type": "text", "label": "System Timezone Override", "default": "" },
    "var_apt_cacher": { "type": "toggle", "label": "Connect via APT Cacher Proxy", "default": false, "string_output": true },
    "var_apt_cacher_ip": { "type": "text", "label": "APT Cacher Proxy IP", "default": "", "depends_on": "var_apt_cacher=true" },
    "var_container_storage": { "type": "text", "label": "Target Container Storage Volume", "default": "" },
    "var_template_storage": { "type": "text", "label": "Target Template Storage Volume", "default": "" },
    "var_tags": { "type": "text", "label": "LXC Inventory Tags (comma separated)", "default": "" },
    "var_mount_fs": { "type": "text", "label": "Custom Shared Filesystem Mounts", "default": "" },
    "var_verbose": { "type": "toggle", "label": "Enable Verbose Installer Logs", "default": true, "string_output": true }
  }
}
EOF

pct push $LXC_ID /tmp/flags_blueprint.json "$LXC_WEB_DIR/flags_blueprint.json"
rm -f /tmp/flags_blueprint.json

# ------------------------------------------------------------------------------
# 5. CREATE SYSTEMD SERVICES INSIDE LXC
# ------------------------------------------------------------------------------
echo "[5/5] Configuring LXC Systemd Services..."
cat << EOF > /tmp/sys-and-telemetry-collector.service
[Unit]
Description=$OS_NAME Dashboard Sync Engine
After=network.target
[Service]
ExecStart=$LXC_BIN_DIR/sys-and-telemetry-collector.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOF
pct push $LXC_ID /tmp/sys-and-telemetry-collector.service /etc/systemd/system/sys-and-telemetry-collector.service
rm -f /tmp/sys-and-telemetry-collector.service

cat << EOF > /tmp/web-server.service
[Unit]
Description=$OS_NAME Dashboard Web Server
After=network.target
[Service]
ExecStart=/usr/bin/python3 $LXC_WEB_DIR/web-server.py
WorkingDirectory=$LXC_WEB_DIR
Restart=always
[Install]
WantedBy=multi-user.target
EOF
pct push $LXC_ID /tmp/web-server.service /etc/systemd/system/web-server.service
rm -f /tmp/web-server.service

cat << 'EOF' > /tmp/terminal-daemon.service
[Unit]
Description=HomeOS Terminal WebSocket Daemon
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/dashboard/web/terminal-daemon.py
WorkingDirectory=/opt/dashboard/web
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Push to the LXC and clean up
pct push $LXC_ID /tmp/terminal-daemon.service /etc/systemd/system/terminal-daemon.service
rm -f /tmp/terminal-daemon.service


pct exec $LXC_ID -- systemctl daemon-reload
pct exec $LXC_ID -- systemctl enable --now sys-and-telemetry-collector.service
pct exec $LXC_ID -- systemctl enable --now web-server.service
pct exec $LXC_ID -- systemctl enable --now terminal-daemon.service

sleep 2
LXC_IP=$(pct exec $LXC_ID -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

echo "=============================================================================="
echo " Monolithic Template Compiled & Executed Successfully! "
echo " Internal LXC Directory: $LXC_APP_DIR"
echo ""
echo " 🌐 Your Live Dashboard: http://$LXC_IP"
echo "=============================================================================="