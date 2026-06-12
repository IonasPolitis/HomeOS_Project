#!/bin/bash
set -e

# ==============================================================================
# Definitive Proxmox NVIDIA Manager (v14)
# Features: Dynamic Package Purging, Auto-Repair, Safe Execution Wrapper
# ==============================================================================

export DEBIAN_FRONTEND=noninteractive 

# ==============================================================================
# 1. GLOBAL VARIABLES & CONFIGURATION
# ==============================================================================
STABLE_KERNEL="6.14" # The known-safe baseline for fresh installations
CURRENT_KERNEL=$(uname -r)

# ==============================================================================
# 2. CORE FUNCTIONS
# ==============================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo "❌ Please run as root."
        exit 1
    fi
}

msg() {
    local emoji="$1"
    local text="$2"
    if [ "$VERBOSE" -eq 1 ]; then 
        echo "$text"
    else 
        echo "$emoji $text"
    fi
}

execute() {
    if [ "$VERBOSE" -eq 1 ]; then
        "$@"
    else
        if ! "$@" > /tmp/nvidia_manager_error.log 2>&1; then
            echo ""
            echo "❌ CRITICAL ERROR: The following command failed:"
            echo "   Command: $*"
            echo "--- Error Details ---"
            cat /tmp/nvidia_manager_error.log
            echo "---------------------"
            exit 1
        fi
    fi
}

# --- Universal Reboot Handler ---
reboot_handler() {
    local REASON="$1"
    echo "================================================================================"
    if [ "$REASON" == "ALIGNMENT" ]; then
        msg "🚨" "BASELINE ALIGNMENT COMPLETE: REBOOT REQUIRED."
        msg "ℹ️" "System must boot into Kernel $STABLE_KERNEL before installing drivers."
    elif [ "$REASON" == "NEW_KERNEL" ]; then
        msg "🎉" "EXTRA NOTICE: A new stable Proxmox kernel was found and successfully installed!"
        msg "⚠️" "ACTION REQUIRED: Please reboot your system to apply the new kernel,"
        msg "ℹ️" "and then re-run this script to ensure the NVIDIA drivers are properly compiled."
    elif [ "$REASON" == "UNINSTALL" ]; then
        msg "✅" "NVIDIA ECOSYSTEM COMPLETELY UNINSTALLED."
        msg "🔄" "REBOOT REQUIRED: Please reboot to restore the open-source Nouveau drivers."
    else
        msg "🔄" "SYSTEM MODIFIED: REBOOT REQUIRED."
    fi
    echo "================================================================================"
    
    # Interactive Reboot Prompt
    read -p "Would you like to reboot the system now? [y/N]: " PROMPT_REBOOT
    if [[ "$PROMPT_REBOOT" =~ ^[Yy]$ ]]; then
        msg "🔄" "Rebooting system now..."
        reboot
    else
        msg "ℹ️" "Reboot cancelled. Please remember to reboot manually later to apply changes."
        exit 0
    fi
}

exit_handler() {
    local REASON="$1"
    echo "================================================================================"
    if [ "$REASON" == "NO_UPDATES" ]; then
        msg "✅" "SYSTEM OPTIMIZED: No new drivers or compatible kernels found."
        msg "ℹ️" "Current Kernel: $CURRENT_KERNEL"
    elif [ "$REASON" == "SUCCESS_INSTALL" ]; then
        msg "🎉" "NVIDIA ECOSYSTEM SUCCESSFULLY DEPLOYED."
        msg "ℹ️" "System is optimized on Kernel $CURRENT_KERNEL. Verify with 'nvidia-smi'."
    fi
    echo "================================================================================"
    exit 0
}

uninstall_ecosystem() {
    msg "🗑️" "Initiating complete removal of the NVIDIA ecosystem..."

    msg "🛡️" "Stopping and disabling NVIDIA persistence services..."
    systemctl stop nvidia-persistenced > /dev/null 2>&1 || true
    systemctl disable nvidia-persistenced > /dev/null 2>&1 || true

    msg "📦" "Purging all NVIDIA packages and cleaning unused dependencies..."
    execute apt-get purge -yq '*nvidia*'
    execute apt-get autoremove -yq

    msg "⚙️" "Reverting LXC passthrough rules and module configurations..."
    rm -f /etc/udev/rules.d/70-nvidia-lxc.rules
    rm -f /etc/modules-load.d/nvidia-uvm.conf
    udevadm control --reload-rules > /dev/null 2>&1 || true
    udevadm trigger > /dev/null 2>&1 || true

    msg "🛠️" "Restoring open-source Nouveau drivers and rebuilding initramfs..."
    rm -f /etc/modprobe.d/blacklist-nouveau.conf
    execute update-initramfs -u

    reboot_handler "UNINSTALL"
}

test_compilation() {
    local DRV_VER=$1
    local KERN_VER=$2
    local HEADERS="proxmox-headers-$KERN_VER"
    
    if [ "$VERBOSE" -eq 1 ]; then
        echo "--> Testing compiler on Kernel $KERN_VER..."
        if ! apt-get install -y "$HEADERS" --no-install-recommends; then return 1; fi
        if dkms build -m nvidia-current -v "$DRV_VER" -k "$KERN_VER"; then return 0; else
            apt-get purge -y "$HEADERS"
            return 1
        fi
    else
        if ! apt-get install -y "$HEADERS" --no-install-recommends > /dev/null 2>&1; then return 1; fi
        if dkms build -m nvidia-current -v "$DRV_VER" -k "$KERN_VER" > /dev/null 2>&1; then return 0; else
            apt-get purge -y "$HEADERS" > /dev/null 2>&1
            return 1
        fi
    fi
}

scout_kernels() {
    local CURRENT_DRIVER_VER=$1
    local AVAILABLE_KERNELS
    msg "🕵️" "Initiating Ascending Scout Phase..."
    
    AVAILABLE_KERNELS=$(apt-cache search proxmox-kernel- | grep "^proxmox-kernel-[0-9]" | grep -Ev "\-signed|\-template" | awk '{print $1}' | sed 's/proxmox-kernel-//' | sort -V | uniq)
    
    local TARGET_KERNEL=""
    for KERN in $AVAILABLE_KERNELS; do
        if dpkg --compare-versions "$KERN" "gt" "$CURRENT_KERNEL"; then
            msg "🧪" "Scouting: Testing Driver $CURRENT_DRIVER_VER against Kernel $KERN..."
            if test_compilation "$CURRENT_DRIVER_VER" "$KERN"; then
                TARGET_KERNEL="$KERN"
                msg "✅" "Scout Report: Kernel $TARGET_KERNEL passed! Securing this version..."
            else
                msg "🛑" "Scout Report: Compiler crashed on $KERN."
                msg "🛡️" "Ceiling reached. Halting upward scout to protect system."
                break
            fi
        fi
    done

    if [ -n "$TARGET_KERNEL" ]; then
        msg "📥" "Safe upgrade path locked! Installing Kernel $TARGET_KERNEL..."
        execute apt-get install -yq "proxmox-kernel-$TARGET_KERNEL" "proxmox-headers-$TARGET_KERNEL"
        reboot_handler "NEW_KERNEL"
    else
        msg "🛡️" "System is currently at the highest safe kernel ceiling."
    fi
}

finalize_ecosystem() {
    msg "🛡️" "Blacklisting open-source Nouveau driver and rebuilding initramfs..."
    cat <<EOF > /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF
    execute update-initramfs -u

    msg "⚙️" "Enabling GPU persistence daemon and configuring LXC Passthrough rules..."
    systemctl enable nvidia-persistenced > /dev/null 2>&1 || true
    systemctl start nvidia-persistenced > /dev/null 2>&1 || true

    echo "nvidia-uvm" > /etc/modules-load.d/nvidia-uvm.conf
    cat <<EOF > /etc/udev/rules.d/70-nvidia-lxc.rules
SUBSYSTEM=="video4linux", GROUP="video", MODE="0666"
SUBSYSTEM=="graphics", GROUP="video", MODE="0666"
SUBSYSTEM=="drm", GROUP="video", MODE="0666"
KERNEL=="nvidia", MODE="0666"
KERNEL=="nvidia_uvm", MODE="0666"
KERNEL=="nvidia_uvm_tools", MODE="0666"
KERNEL=="nvidiactl", MODE="0666"
EOF
    udevadm control --reload-rules > /dev/null 2>&1 || true
    udevadm trigger > /dev/null 2>&1 || true
}

# ==============================================================================
# 3. PRE-FLIGHT CHECKS & PROMPTS
# ==============================================================================
check_root

# 1. Ask for Verbosity FIRST, before anything else happens!
read -p "Run in Verbose mode? (Show all background output and disable emojis) [y/N]: " PROMPT_VERBOSE
if [[ "$PROMPT_VERBOSE" =~ ^[Yy]$ ]]; then VERBOSE=1; else VERBOSE=0; fi

# 2. Now we can safely use the 'msg' function to respect your emoji preference!
msg "🔍" "Analyzing current system state..."

# 3. Auto-repair any previously interrupted installations
if [ "$VERBOSE" -eq 1 ]; then
    dpkg --configure -a || true
else
    dpkg --configure -a > /dev/null 2>&1 || true
fi

# 4. Check for existing drivers ONLY AFTER the repair is finished
if dpkg-query -W -f='${Status}' nvidia-driver 2>/dev/null | grep -q "ok installed"; then
    HAS_NVIDIA=1
else
    HAS_NVIDIA=0
fi

# 5. Context-Aware Prompting
if [ "$HAS_NVIDIA" -eq 1 ]; then
    msg "🟢" "NVIDIA ecosystem is currently installed."
    read -p "Do you want to [U]pdate/Verify the installation, or [X] Uninstall the drivers? [U/x]: " ACTION_PROMPT
    
    if [[ "$ACTION_PROMPT" =~ ^[Xx]$ ]]; then
        uninstall_ecosystem
    fi
    STATE="UPDATE"
else
    msg "⚪" "No NVIDIA drivers detected. Proceeding to Fresh Installation."
    STATE="FRESH"
fi

msg "🌐" "Checking Debian repositories for latest NVIDIA drivers..."
if [ "$VERBOSE" -eq 1 ]; then apt-get update; else apt-get update -qq > /dev/null 2>&1; fi

REPO_DRV_VER=$(apt-cache policy nvidia-kernel-dkms | grep Candidate | awk '{print $2}')
INSTALLED_DRV_VER=$(apt-cache policy nvidia-kernel-dkms | grep Installed | awk '{print $2}')

if [ -z "$REPO_DRV_VER" ]; then msg "❌" "Error: Could not detect NVIDIA driver in APT."; exit 1; fi

# ==============================================================================
# 4. START OF THE PIPELINE
# ==============================================================================

if [ "$STATE" == "FRESH" ]; then
    # --------------------------------------------------------------------------
    # FRESH INSTALL PIPELINE
    # --------------------------------------------------------------------------
    
    # DYNAMIC SANITIZATION: Safely find and purge incompatible kernels
    UNWANTED_PKGS=$(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | grep -E '^(proxmox|pve)-(kernel|headers)-(7|6\.17)|proxmox-default' || true)
    
    if [ -n "$UNWANTED_PKGS" ]; then
        msg "🧹" "Sanitizing environment: Removing incompatible future kernels to protect DKMS compiler..."
        # Convert the newlines into a space-separated list for apt-get
        PKGS_TO_PURGE=$(echo $UNWANTED_PKGS | tr '\n' ' ')
        
        if [ "$VERBOSE" -eq 1 ]; then
            apt-get remove --purge -y $PKGS_TO_PURGE
            apt-get autoremove -y
        else
            execute apt-get remove --purge -yq $PKGS_TO_PURGE
            execute apt-get autoremove -yq
        fi
    fi

    # Step A: Check Kernel Alignment
    if [[ "$CURRENT_KERNEL" != *"$STABLE_KERNEL"* ]]; then
        msg "⚠️" "Kernel mismatch. Bootloader alignment required ($STABLE_KERNEL)..."
        
        execute apt-get install -yq "proxmox-kernel-$STABLE_KERNEL" "proxmox-headers-$STABLE_KERNEL"
        proxmox-boot-tool kernel unpin > /dev/null 2>&1 || true
        proxmox-boot-tool refresh > /dev/null 2>&1 || true
        reboot_handler "ALIGNMENT"
    fi

    # Step B: Install Latest Driver
    msg "🏗️" "Installing latest NVIDIA drivers ($REPO_DRV_VER)..."
    execute apt-get full-upgrade -yq
    execute apt-get install -yq build-essential dkms nvidia-driver nvidia-kernel-dkms nvidia-smi nvidia-persistenced

    # Step C: Finalize Ecosystem (LXC, Nouveau)
    finalize_ecosystem

    # Step D: Immediately Scout Upward
    DKMS_SOURCE=$(echo "$REPO_DRV_VER" | cut -d- -f1)
    scout_kernels "$DKMS_SOURCE"
    
    exit_handler "SUCCESS_INSTALL"

elif [ "$STATE" == "UPDATE" ]; then
    # --------------------------------------------------------------------------
    # UPDATE PIPELINE (NVIDIA Installed)
    # --------------------------------------------------------------------------
    msg "🕵️" "Initiating Update & Verification Pipeline..."
    
    if [ "$REPO_DRV_VER" == "$INSTALLED_DRV_VER" ]; then
        msg "🛡️" "No new NVIDIA driver available in repositories."
        exit_handler "NO_UPDATES"
    fi

    msg "📥" "New driver version found! ($INSTALLED_DRV_VER -> $REPO_DRV_VER). Installing..."
    
    execute apt-get install -yq nvidia-driver nvidia-kernel-dkms nvidia-smi nvidia-persistenced

    DKMS_SOURCE=$(echo "$REPO_DRV_VER" | cut -d- -f1)
    scout_kernels "$DKMS_SOURCE"
    
    finalize_ecosystem
    
    exit_handler "SUCCESS_INSTALL"
fi