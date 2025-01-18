#!/bin/bash

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please use sudo." >&2
   exit 1
fi

# Function to display usage
usage() {
    echo "Usage: $0 [--default | --revert]"
    echo "Options will be prompted interactively if --default is not used."
    echo "  --default   Apply default anonymity settings."
    echo "  --revert    Revert all changes to the last saved state."
}

# Check if Tor is installed
if ! command -v tor &> /dev/null; then
    echo "Tor is not installed. Installing Tor..."
    apt update && apt install -y tor
fi

# Variables
INTERFACE=""
MAC_ADDRESS=""
USE_DNS=false
USE_TOR=false
ROUND_ROBIN=false
DEFAULT_MODE=false
REVERT_MODE=false

DNS_SERVERS=(
    "1.1.1.1" # Cloudflare (US)
    "8.8.8.8" # Google (US)
    "9.9.9.9" # Quad9 (US)
    "77.88.8.8" # Yandex (Russia)
    "208.67.222.222" # OpenDNS (Global)
    "114.114.114.114" # 114DNS (China)
    "1.0.0.1" # Cloudflare Backup
)

# Create a unique backup file
create_backup() {
    local backup_file="/etc/netconf"
    local i=1
    while [[ -e "${backup_file}${i}.txt" ]]; do
        ((i++))
    done
    backup_file="${backup_file}${i}.txt"
    echo "Creating backup: $backup_file"

    echo "INTERFACE=$INTERFACE" > "$backup_file"
    echo "MAC_ADDRESS=$CURRENT_MAC" >> "$backup_file"
    echo "RESOLV_CONF=$(cat /etc/resolv.conf | base64)" >> "$backup_file"
    echo "$backup_file"
}

# Restore from the latest backup
restore_backup() {
    local backup_file=$(ls -t /etc/netconf*.txt 2>/dev/null | head -n 1)
    if [[ -z $backup_file ]]; then
        echo "No backup file found. Cannot revert."
        exit 1
    fi
    echo "Restoring from backup: $backup_file"

    source "$backup_file"
    ifconfig $INTERFACE down
    ifconfig $INTERFACE hw ether $MAC_ADDRESS
    ifconfig $INTERFACE up
    echo "$RESOLV_CONF" | base64 -d > /etc/resolv.conf

    echo "Changes reverted successfully."
}

# Parse arguments
if [[ $# -gt 0 ]]; then
    case $1 in
        --default)
            DEFAULT_MODE=true
            ;;
        --revert)
            REVERT_MODE=true
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
fi

# Handle revert mode
if $REVERT_MODE; then
    restore_backup
    exit 0
fi

# Default mode configuration
if $DEFAULT_MODE; then
    echo "Enabling default anonymity settings..."
    INTERFACE=$(ip link | awk -F: '$0 !~ "lo|vir|wl" {print $2; getline}' | xargs | head -n1)
    MAC_ADDRESS=$(openssl rand -hex 6 | sed 's/\(..\)/\1:/g; s/:$//')
    USE_DNS=true
    USE_TOR=true
    ROUND_ROBIN=true
else
    echo "Welcome to the Interactive Anonymity Setup"
    echo "==========================================="
    echo "Please select the network interface to modify:"
    ip link | awk -F: '$0 !~ "lo|vir|wl" {print NR ")" $2; getline}'
    read -p "Enter the interface number (or name): " INTERFACE

    echo "Do you want to set a custom MAC address? (y/n): "
    read -n 1 SET_MAC
    echo
    if [[ $SET_MAC == "y" || $SET_MAC == "Y" ]]; then
        read -p "Enter the custom MAC address: " MAC_ADDRESS
    else
        MAC_ADDRESS=$(openssl rand -hex 6 | sed 's/\(..\)/\1:/g; s/:$//')
        echo "Using random MAC address: $MAC_ADDRESS"
    fi

    echo "Do you want to enable anonymous DNS? (y/n): "
    read -n 1 DNS_CHOICE
    echo
    if [[ $DNS_CHOICE == "y" || $DNS_CHOICE == "Y" ]]; then
        USE_DNS=true
    fi

    echo "Do you want to use round-robin DNS with international servers? (y/n): "
    read -n 1 RR_CHOICE
    echo
    if [[ $RR_CHOICE == "y" || $RR_CHOICE == "Y" ]]; then
        ROUND_ROBIN=true
    fi

    echo "Do you want to route all traffic through Tor? (y/n): "
    read -n 1 TOR_CHOICE
    echo
    if [[ $TOR_CHOICE == "y" || $TOR_CHOICE == "Y" ]]; then
        USE_TOR=true
    fi
fi

# Backup the current network state
BACKUP_FILE=$(create_backup)

# Change MAC address
echo "Changing MAC address for $INTERFACE to $MAC_ADDRESS..."
ifconfig $INTERFACE down
ifconfig $INTERFACE hw ether $MAC_ADDRESS
ifconfig $INTERFACE up

# Verify MAC address change
CURRENT_MAC=$(ifconfig $INTERFACE | grep -oE "([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}")
if [[ $CURRENT_MAC == $MAC_ADDRESS ]]; then
    echo "MAC address verification passed: $CURRENT_MAC"
else
    echo "MAC address verification failed. Current MAC: $CURRENT_MAC"
    exit 1
fi

# Configure anonymous DNS
if $USE_DNS; then
    echo "Setting anonymous DNS (e.g., Cloudflare 1.1.1.1)..."
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 1.0.0.1" >> /etc/resolv.conf
    echo "Anonymous DNS configured."

    # Verify DNS change
    if grep -q "1.1.1.1" /etc/resolv.conf && grep -q "1.0.0.1" /etc/resolv.conf; then
        echo "DNS configuration verification passed."
    else
        echo "DNS configuration verification failed."
        exit 1
    fi
fi

# Round-robin DNS configuration
if $ROUND_ROBIN; then
    echo "Configuring round-robin DNS with international servers..."
    > /etc/resolv.conf
    for SERVER in "${DNS_SERVERS[@]}"; do
        echo "nameserver $SERVER" >> /etc/resolv.conf
    done
    echo "Round-robin DNS servers configured: ${DNS_SERVERS[*]}"

    # Verify DNS change
    RESOLV_CONTENT=$(cat /etc/resolv.conf)
    for SERVER in "${DNS_SERVERS[@]}"; do
        if ! grep -q "$SERVER" <<< "$RESOLV_CONTENT"; then
            echo "DNS server $SERVER missing in resolv.conf. Verification failed."
            exit 1
        fi
    done
    echo "Round-robin DNS configuration verification passed."
fi

# Route traffic through Tor
if $USE_TOR; then
    echo "Routing all traffic through Tor..."
    service tor start

    iptables -F
    iptables -t nat -F
    iptables -t nat -A OUTPUT -m owner --uid-owner debian-tor -j RETURN
    iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 9053
    iptables -t nat -A OUTPUT -p tcp --syn -j REDIRECT --to-ports 9040
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m owner --uid-owner debian-tor -j ACCEPT
    iptables -A OUTPUT -j REJECT

    echo "Traffic is now routed through Tor."

    # Verify Tor routing
    TOR_CHECK=$(curl --socks5-hostname 127.0.0.1:9050 -s https://check.torproject.org | grep -o "Congratulations. This browser is configured to use Tor")
    if [[ -n $TOR_CHECK ]]; then
        echo "Tor routing verification passed."
    else
        echo "Tor routing verification failed. Ensure Tor is running and correctly configured."
        exit 1
    fi
fi

echo "Anonymity setup complete."
