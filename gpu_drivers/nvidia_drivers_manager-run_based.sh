#!/bin/bash
set -e

# ==============================================================================
# Universal Proxmox & LXC NVIDIA Manager (v10.1)
# Methodology: Environment Detection, Version Parity, & Interactive Deployment
# Features: Dynamic CUDA/cuDNN, Host UVM Auto-Fix, & True Verbose Tracing
# ==============================================================================
export DEBIAN_FRONTEND=noninteractive 

# --- Immediate Root Check ---
if [ "$EUID" -ne 0 ]; then 
    echo "❌ CRITICAL: Please run this script as root (e.g., using sudo)."
    exit 1
fi

# ==============================================================================
# 1. GLOBAL VARIABLES, VERBOSITY & ENVIRONMENT DETECTION
# ==============================================================================
CURRENT_KERNEL=$(uname -r)
NVIDIA_BASE_URL="https://download.nvidia.com/XFree86/Linux-x86_64"

LOG_FILE="/var/log/nvidia_manager.log"
if [ -f "$LOG_FILE" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
fi
echo "=== NVIDIA Manager Deployment Started at $(date) ===" > "$LOG_FILE"

# --- Dynamic Verbosity Flags ---
read -p "Run in Verbose mode? [y/N]: " PROMPT_VERBOSE
if [[ "$PROMPT_VERBOSE" =~ ^[Yy]$ ]]; then
    VERBOSE=1
    APT_FLAGS="-y"
    WGET_FLAGS="--progress=dot:giga"
    NV_INSTALL_FLAGS="--accept-license --ui=none"
    NV_UNINST_FLAGS="--ui=none --no-questions"
else
    VERBOSE=0
    APT_FLAGS="-yq"
    WGET_FLAGS="-q"
    NV_INSTALL_FLAGS="--silent"
    NV_UNINST_FLAGS="--silent"
fi

# --- Detect Environment (Host vs LXC) ---
if grep -qa 'container=lxc' /proc/1/environ 2>/dev/null || [ "$(systemd-detect-virt 2>/dev/null)" == "lxc" ]; then
    IS_LXC=1
    echo "🖥️  ENVIRONMENT DETECTED: LXC Container (User-Space Only Mode)" | tee -a "$LOG_FILE"
else
    IS_LXC=0
    echo "🖥️  ENVIRONMENT DETECTED: Bare-Metal Host (Full Kernel Mode)" | tee -a "$LOG_FILE"
fi

# ==============================================================================
# 2. HARDWARE DISCOVERY & VERSION RESOLUTION
# ==============================================================================

if [ "$IS_LXC" -eq 1 ]; then
    if [ ! -f "/proc/driver/nvidia/version" ]; then
        echo "❌ CRITICAL: Host NVIDIA driver not found. Ensure GPU is passed through to LXC." | tee -a "$LOG_FILE"
        exit 1
    fi
    TARGET_VER=$(grep -oP 'Module  \K[0-9.]+' /proc/driver/nvidia/version)
    DEVICE_PCI_ID="Passed-through from Host"
else
    DEVICE_PCI_ID=$(lspci -nn | grep -i "10de" | grep -oP '10de:\K[0-9a-fA-F]{4}' | head -n 1 | tr '[:upper:]' '[:lower:]' || echo "")

    if [ -z "$DEVICE_PCI_ID" ]; then
        echo "❌ No NVIDIA GPU detected. Exiting..." | tee -a "$LOG_FILE"
        exit 1
    fi

    case "$DEVICE_PCI_ID" in
        "1180"|"1184"|"11c0"|"0f"*) TARGET_BRANCH="47[0-9]" ;; 
        "0dc0"|"0de0"|"0de1")       TARGET_BRANCH="39[0-9]" ;; 
        "1b"*|"1c"*)                TARGET_BRANCH="58[0-9]" ;; 
        *)                          TARGET_BRANCH="latest"  ;; 
    esac
fi

# ==============================================================================
# 3. CORE FUNCTIONS
# ==============================================================================

msg() { 
    local TIMESTAMP
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TIMESTAMP] $2" >> "$LOG_FILE"
    if [ "$VERBOSE" -eq 1 ]; then echo "$2"; else echo "$1 $2"; fi 
}

rollback() {
    msg "⏪" "CRITICAL FAILURE DETECTED. Initiating system rollback..."
    rm -f /tmp/NVIDIA-Linux-*.run
    if [ -x "$(command -v nvidia-uninstall)" ]; then
        msg "🗑️" "Rollback: Attempting to remove corrupted driver fragments..."
        nvidia-uninstall --silent >> "$LOG_FILE" 2>&1 || true
    fi
    msg "❌" "Rollback complete. The system has been restored to a safe state."
    echo "🚨 ERROR DETAILS (Last 15 lines):"
    tail -n 15 "$LOG_FILE"
    exit 1
}

execute() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] EXECUTING: $*" >> "$LOG_FILE"
    if [ "$VERBOSE" -eq 1 ]; then 
        if ! "$@" 2>&1 | tee -a "$LOG_FILE"; then rollback; fi
    else
        if ! "$@" >> "$LOG_FILE" 2>&1; then rollback; fi
    fi
}

find_best_version_host() {
    msg "🌐" "Resolving highest available driver for the $TARGET_BRANCH branch..."
    if [ "$TARGET_BRANCH" == "latest" ]; then
        TARGET_VER=$(curl -s "${NVIDIA_BASE_URL}/latest.txt" | awk '{print $1}')
    else
        TARGET_VER=$(curl -s "${NVIDIA_BASE_URL}/" | grep -oP "${TARGET_BRANCH}\.\d+(\.\d+)?" | sort -rV | head -n 1)
    fi
    [ -z "$TARGET_VER" ] && { msg "❌" "Failed to resolve version."; exit 1; }
}

clean_apt_conflicts() {
    msg "🧹" "Purging APT-based NVIDIA packages to prevent binary collisions..."
    execute apt-get purge $APT_FLAGS '*nvidia*'
    execute apt-get autoremove $APT_FLAGS
}

uninstall_nvidia_stack() {
    msg "🗑️" "Initiating complete uninstallation..."
    
    if [ -x "$(command -v nvidia-uninstall)" ]; then
        execute nvidia-uninstall $NV_UNINST_FLAGS
    fi
    
    clean_apt_conflicts
    
    if [ "$IS_LXC" -eq 1 ]; then
        msg "🧹" "Deep cleaning LXC: Removing CUDA toolkits and cuDNN..."
        execute apt-get purge $APT_FLAGS '*cuda*' '*cublas*' '*cudnn*'
        execute rm -f /etc/apt/sources.list.d/cuda*.list
        execute apt-get autoremove $APT_FLAGS
    fi
    
    msg "✅" "SUCCESS: NVIDIA and CUDA stacks completely removed."
    rm -f /tmp/NVIDIA-Linux-*.run
}

apply_configurations() {
    if [ "$IS_LXC" -eq 1 ]; then
        msg "⚙️" "LXC Environment: Skipping kernel module & initramfs configurations."
        return 0
    fi

    msg "⚙️" "Configuring modules and LXC rules on Host..."
    echo -e "blacklist nouveau\noptions nouveau modeset=0" > /etc/modprobe.d/blacklist-nouveau.conf
    
    echo "nvidia" > /etc/modules-load.d/nvidia.conf
    echo "nvidia-uvm" >> /etc/modules-load.d/nvidia.conf
    if ! grep -q "nvidia-uvm" /etc/modules; then echo "nvidia-uvm" >> /etc/modules; fi

    execute modprobe nvidia
    execute modprobe nvidia-uvm
    if [ -x "$(command -v nvidia-modprobe)" ]; then
        execute nvidia-modprobe -u -c=0
    fi

    execute update-initramfs -u -k all
    
    if [ -x "$(command -v nvidia-persistenced)" ]; then
        if [ "$VERBOSE" -eq 1 ]; then
            nvidia-persistenced --user root || true
        else
            nvidia-persistenced --user root > /dev/null 2>&1 || true
        fi
    fi

    cat <<EOF > /etc/udev/rules.d/70-nvidia-lxc.rules
KERNEL=="nvidia", MODE="0666"
KERNEL=="nvidia_uvm", MODE="0666"
KERNEL=="nvidia_uvm_tools", MODE="0666"
KERNEL=="nvidiactl", MODE="0666"
EOF
    udevadm control --reload-rules && udevadm trigger
}

install_lxc_cuda_stack() {
    if [ "$IS_LXC" -eq 0 ]; then return 0; fi

    msg "🧠" "LXC Environment: Initializing dynamic CUDA Toolkit & cuDNN deployment..."
    source /etc/os-release
    
    local REPO_OS
    local REPO_URL_PART
    if [[ "$ID" == "ubuntu" ]]; then
        REPO_OS="ubuntu"; REPO_URL_PART=$(echo "$VERSION_ID" | tr -d '.')
    elif [[ "$ID" == "debian" ]]; then
        REPO_OS="debian"; REPO_URL_PART=$(echo "$VERSION_ID" | cut -d. -f1)
    else
        msg "⚠️" "CUDA auto-install only supports Ubuntu/Debian LXCs. Skipping..."
        return 0
    fi

    msg "📥" "Adding official NVIDIA CUDA repository for $ID $VERSION_ID..."
    local KEYRING_URL
    KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/${REPO_OS}${REPO_URL_PART}/x86_64/cuda-keyring_1.1-1_all.deb"
    
    execute wget $WGET_FLAGS "$KEYRING_URL" -O /tmp/cuda-keyring.deb
    execute dpkg -i /tmp/cuda-keyring.deb
    execute apt-get update $APT_FLAGS

    local MAX_CUDA
    local CUDA_PKG
    local CUDNN_PKG
    local CUDA_MAJOR

    MAX_CUDA=""
    CUDA_PKG="cuda-toolkit"
    CUDNN_PKG="cudnn9-cuda-12"

    if [ -x "$(command -v nvidia-smi)" ]; then
        MAX_CUDA=$(nvidia-smi | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' | head -n 1)
    fi

    if [ -n "$MAX_CUDA" ]; then
        msg "🔍" "Hardware reports Max Supported CUDA Version: $MAX_CUDA"
        local FORMATTED_VER
        FORMATTED_VER="${MAX_CUDA//./-}"
        CUDA_PKG="cuda-toolkit-${FORMATTED_VER}"
        
        CUDA_MAJOR=$(echo "$MAX_CUDA" | cut -d. -f1)
        if apt-cache show "cudnn9-cuda-${CUDA_MAJOR}" > /dev/null 2>&1; then
            CUDNN_PKG="cudnn9-cuda-${CUDA_MAJOR}"
        else
            msg "⚠️" "cudnn9-cuda-${CUDA_MAJOR} not found. Falling back to cudnn9-cuda-12."
            CUDNN_PKG="cudnn9-cuda-12"
        fi
    fi

    # --- NEW: Staged Installation to manage Peak Disk Space ---
    msg "🛠️" "Step 1/2: Installing $CUDA_PKG (this may take several minutes)..."
    execute apt-get install $APT_FLAGS "$CUDA_PKG"
    
    msg "🧹" "Clearing APT cache to free up temporary disk space..."
    execute apt-get clean
    
    msg "🛠️" "Step 2/2: Installing $CUDNN_PKG (this may take several minutes)..."
    execute apt-get install $APT_FLAGS "$CUDNN_PKG"
    
    msg "🧹" "Performing final cleanup..."
    execute apt-get clean

    # --- Path Configuration ---
    echo 'export PATH=/usr/local/cuda/bin:$PATH' > /etc/profile.d/cuda.sh
    echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> /etc/profile.d/cuda.sh
    msg "🎉" "SUCCESS: CUDA stack deployed."
    rm -f /tmp/cuda-keyring.deb
}

# ==============================================================================
# 4. START OF THE PIPELINE
# ==============================================================================

msg "🔍" "Analyzing environment..."
if [ "$VERBOSE" -eq 1 ]; then
    dpkg --configure -a 2>&1 | tee -a "$LOG_FILE" || true
else
    dpkg --configure -a >> "$LOG_FILE" 2>&1 || true
fi

if [ "$IS_LXC" -eq 0 ]; then 
    find_best_version_host
else 
    msg "✅" "LXC Parity Lock: Inheriting Version $TARGET_VER from Host."
fi

INSTALLED_VER="none"
if [ -x "$(command -v nvidia-uninstall)" ]; then
    INSTALLED_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 || echo "none")
fi

# ==============================================================================
# 5. INTERACTIVE PROMPT & EXECUTION
# ==============================================================================

if [ "$INSTALLED_VER" != "none" ]; then
    echo "----------------------------------------------------------------------"
    msg "ℹ️" "Existing Driver: $INSTALLED_VER | Target: $TARGET_VER"
    echo "----------------------------------------------------------------------"
    if [ "$TARGET_VER" == "$INSTALLED_VER" ]; then
        msg "✅" "System up to date."
        read -p "Action: [F]orce Reinstall, [R]emove, [C]ancel: " PROMPT_ACTION
    else
        msg "🚀" "Update recommended."
        read -p "Action: [U]pdate, [R]emove, [C]ancel: " PROMPT_ACTION
    fi
    
    case "$PROMPT_ACTION" in
        [Uu]*|[Ff]* ) msg "🔄" "Proceeding..." ;;
        [Rr]* )
            uninstall_nvidia_stack
            if [ "$IS_LXC" -eq 0 ]; then
                read -p "Reboot required. Reboot now? [y/N]: " REBOOT_NOW
                [[ "$REBOOT_NOW" =~ ^[Yy]$ ]] && reboot
            fi
            exit 0 
            ;;
        * ) msg "🛑" "Cancelled."; exit 0 ;;
    esac
fi

msg "🏗️" "Deploying NVIDIA $TARGET_VER..."
execute apt-get update $APT_FLAGS
if [ "$IS_LXC" -eq 1 ]; then
    execute apt-get install $APT_FLAGS build-essential pkg-config libglvnd-dev
    INSTALL_FLAGS="$NV_INSTALL_FLAGS --no-kernel-module --no-questions --no-cc-version-check"
else
    execute apt-get install $APT_FLAGS build-essential dkms pkg-config libglvnd-dev "proxmox-headers-$CURRENT_KERNEL"
    INSTALL_FLAGS="$NV_INSTALL_FLAGS --dkms --no-questions --no-cc-version-check"
fi

clean_apt_conflicts
INSTALLER="NVIDIA-Linux-x86_64-${TARGET_VER}.run"
msg "📥" "Downloading $INSTALLER..."
execute wget $WGET_FLAGS "${NVIDIA_BASE_URL}/${TARGET_VER}/${INSTALLER}" -O "/tmp/$INSTALLER"
chmod +x "/tmp/$INSTALLER"

if [ "$INSTALLED_VER" != "none" ]; then execute nvidia-uninstall $NV_UNINST_FLAGS; fi
msg "🛠️" "Installing binary..."
execute /tmp/"$INSTALLER" $INSTALL_FLAGS

apply_configurations
install_lxc_cuda_stack

msg "🎉" "SUCCESS: NVIDIA $TARGET_VER deployed."
rm -f "/tmp/$INSTALLER"

if [ "$IS_LXC" -eq 0 ]; then
    read -p "Reboot now? [y/N]: " REBOOT_NOW
    [[ "$REBOOT_NOW" =~ ^[Yy]$ ]] && reboot
else
    msg "💡" "LXC ready. Restart GPU-dependent services."
fi