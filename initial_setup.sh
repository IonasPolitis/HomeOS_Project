#!/bin/bash
#/#/#/#/ HOST SETUP: /#/#/#/#
### Variables:
OS_NAME="HomeOS"
VERSION=0.1

HOSTNAME=$OS_NAME
DEFAULT_USER="Default-User"
DEFAULT_PASSWORD="password"

### Script:
##Update
#apt update
#apt upgrade -y
apt install wget -y

##Locale Fix
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
echo LANG=en_US.UTF-8 >> /etc/environment
echo LC_ALL=en_US.UTF-8 >> /etc/environment
sed -i 's/^AcceptEnv LANG LC_\*/#AcceptEnv LANG LC_*/g' /etc/ssh/sshd_config
systemctl restart ssh

#No Valid Subscription
cp /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js.bak && sed -i '/checked_command: function (orig_cmd) {$/a\    return (typeof orig_cmd === "function" && (orig_cmd(), true));' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js && systemctl restart pveproxy.service

## Bash Setup
echo "" >> /etc/bash.bashrc
echo "alias x=exit" >> /etc/bash.bashrc

## HomeOS Directory Setup
OS_DIR=/opt/$OS_NAME
OS_BIN_DIR=$OS_DIR/bin
OS_TMP_DIR=$OS_DIR/tmp
OS_TMP_RAM=$OS_TMP_DIR/ram
mkdir $OS_DIR
mkdir $OS_DIR/bin
mkdir $OS_DIR/tmp
mkdir $OS_TMP_RAM
chmod 755 $OS_DIR
chmod 755 $OS_BIN_DIR
chmod 755 $OS_TMP_DIR
echo "$VERSION" > $OS_DIR/version

# Protect SSD: Mount a 16MB RAM disk specifically for the 5-second telemetry loop
if ! mountpoint -q "$OS_TMP_RAM"; then
    echo "      Mounting tmpfs (RAM disk) at $OS_TMP_RAM to protect SSD..."
    mount -t tmpfs -o size=16M tmpfs "$OS_TMP_RAM"
    # Ensure it persists across Proxmox reboots
    if ! grep -q "$OS_TMP_RAM" /etc/fstab; then
        echo "tmpfs $OS_TMP_RAM tmpfs defaults,noatime,size=16M 0 0" >> /etc/fstab
    fi
fi

## Terminal Startup MOTD
cat << EOF > $OS_BIN_DIR/motd.sh
#!/bin/bash
FLAG_FILE="/var/lib/$OS_NAME/pw_check/\$USER"
echo "  ____  _____ ______     _______ ____  "
echo " / ___|| ____|  _ \\\\ \\\\   / / ____|  _ \\\\ "
echo " \\\\___ \\\\|  _| | |_) \\\\ \\\\ / /|  _| | |_) |"
echo "  ___) | |___|  _ < \\\\ V / | |___|  _ < "
echo " |____/|_____|_| \\\\_\\\\ \\\\_/  |_____|_| \\\\_\\\\"
echo ""
# Grab Dynamic System Information
VERSION=\$(<$OS_DIR/version)
CURRENT_HOSTNAME=\$(hostname)
IP_ADDRESS=\$(hostname -I | awk '{print \$1}')
SYS_UPTIME=\$(uptime -p)
CURRENT_USER=\$(whoami)

# Print the Information Box
echo "OS:               ${OS_NAME} v\${VERSION}"
echo "Hostname:         \${CURRENT_HOSTNAME}"
echo "User:             \${CURRENT_USER}"
echo "Network IP:       \${IP_ADDRESS}"
echo "System Uptime:    \${SYS_UPTIME}"

if [ ! -f "\$FLAG_FILE" ]; then
    # Try the default password check
    echo "$DEFAULT_PASSWORD" | timeout 2 su -c "exit" "\$USER" > /dev/null 2>&1
    if [ \$? -eq 0 ]; then
        # Failed assessment: Show warning
        echo -e "\e[31m"
        echo "############################################################"
        echo "SECURITY WARNING: You are still using the default password!"
        echo "Please change it now by typing: passwd"
        echo "############################################################"
        echo -e "\e[0m"
    else
        # Passed assessment: Create the persistent flag
        touch "\$FLAG_FILE" 2>/dev/null
    fi
fi
EOF
chmod +x $OS_BIN_DIR/motd.sh
cat << EOF >> /etc/skel/.bashrc
echo ""
#MOTD:
alias clear="clear && $OS_BIN_DIR/motd.sh"
clear
EOF
mkdir -p /var/lib/$OS_NAME/pw_check
chmod 1777 /var/lib/$OS_NAME/pw_check

## Creating new home user
useradd -m -s /bin/bash $DEFAULT_USER
echo "$DEFAULT_USER:$DEFAULT_PASSWORD" | chpasswd
usermod -aG sudo $DEFAULT_USER
mkdir -p /etc/systemd/system/getty@tty1.service.d/
tee /etc/systemd/system/getty@tty1.service.d/override.conf > /dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $DEFAULT_USER --noclear %I \$TERM
EOF
systemctl daemon-reload

#/#/#/#/ DASHBOARD_LXC SETUP: /#/#/#/#
systemctl restart chrony || systemctl restart systemd-timesyncd


## Changing hostname
#hostnamectl set-hostname $HOSTNAME
#sed -Ei '2s|^([^[:space:]]+[[:space:]]+)[^[:space:]]+[[:space:]]+[^[:space:]]+|\1'"$HOSTNAME.internal"' '"$HOSTNAME"'|' /etc/hosts

## Refreshing Terminal Session to New User and makes things take effect
#su - $DEFAULT_USER
#clear