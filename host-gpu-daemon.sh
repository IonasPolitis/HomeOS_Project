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