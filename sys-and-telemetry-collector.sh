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