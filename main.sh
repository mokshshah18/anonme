#!/usr/bin/env bash

# -------------------------------------------------------------------------
#  Kali Anonymity Script
#  This script changes MAC address, configures DNS, and routes traffic
#  through Tor. It can also revert changes to the last saved backup,
#  stored locally in the script’s directory.
# -------------------------------------------------------------------------

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please use sudo." >&2
   exit 1
fi

# -------------------------------------------------------------------------
# Determine the directory of this script (for local backups)
# -------------------------------------------------------------------------
SCRIPTDIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)"

# ---------------------------
# Usage function
# ---------------------------
usage() {
    echo "Usage: $0 [--default | --revert | --help]"
    echo
    echo "  --default   Apply default anonymity settings automatically."
    echo "  --revert    Revert all changes to the last saved state."
    echo "  --help      Display this help message."
    echo
    echo "If no flags are provided, you'll be prompted interactively."
}

# Global variables
INTERFACE=""
NEW_MAC=""
ORIGINAL_MAC=""
CUSTOM_DNS=""
ROUND_ROBIN_PID=""
TOR_PID=""
USE_DNS=false
USE_TOR=false
ROUND_ROBIN=false
DEFAULT_MODE=false
REVERT_MODE=false

# List of DNS servers for round-robin
DNS_SERVERS=(
    "1.1.1.1"        # Cloudflare (US)
    "8.8.8.8"        # Google (US)
    "9.9.9.9"        # Quad9 (US)
    "77.88.8.8"      # Yandex (Russia)
    "208.67.222.222" # OpenDNS (Global)
    "114.114.114.114" # 114DNS (China)
    "1.0.0.1"        # Cloudflare Backup
)

# --------------------------------------------------------------------------
# create_backup()
# Creates a unique backup file in the local directory (same as script)
# and stores:
#   - INTERFACE name
#   - ORIGINAL_MAC address
#   - Current resolv.conf (base64-encoded)
# --------------------------------------------------------------------------
# Function to create a backup
create_backup() {
    local iface="$1"
    local orig_mac="$2"

    local base_name="${SCRIPTDIR}/netconf"
    local i=1

    # Find a unique name e.g. netconf1.txt, netconf2.txt ...
    while [[ -e "${base_name}${i}.txt" ]]; do
        ((i++))
    done
    local backup_file="${base_name}${i}.txt"

    echo "Creating backup: $backup_file"

    {
        echo "INTERFACE=$iface"
        echo "MAC_ADDRESS=$orig_mac"
        echo "RESOLV_CONF=$(cat /etc/resolv.conf)"
        echo "IFCONFIG_OUTPUT=$(ifconfig "$iface" 2>/dev/null)"
        echo "ROUND_ROBIN_PID=$ROUND_ROBIN_PID"
    } > "$backup_file"

    echo "$backup_file"
}

# Function to append additional data to the backup file
append_to_backup() {
    local backup_file
    backup_file=$(ls -t "${SCRIPTDIR}"/netconf*.txt 2>/dev/null | head -n 1)

    if [[ -f "$backup_file" ]]; then
        echo "Appending PIDs to $backup_file..."
        {
            echo "ROUND_ROBIN_PID=$ROUND_ROBIN_PID"
            echo "TOR_PID=$TOR_PID"
        } >> "$backup_file"
        echo "PIDs appended successfully."
    else
        echo "Error: Backup file $backup_file does not exist."
    fi
}

# --------------------------------------------------------------------------
# restore_backup()
# Restores the most recently created backup from netconf*.txt in local dir
# and forcefully stops any running processes based on stored PIDs.
# --------------------------------------------------------------------------
restore_backup() {
    local backup_file
    backup_file=$(ls -t "${SCRIPTDIR}"/netconf*.txt 2>/dev/null | head -n 1)
    if [[ -z $backup_file ]]; then
        echo "No backup file found in '${SCRIPTDIR}'. Cannot revert."
        exit 1
    fi

    echo "Restoring from backup: $backup_file"
    # shellcheck disable=SC1090
    source "$backup_file"

    # Force kill Tor process
    if [[ -n "$TOR_PID" ]] && kill -0 "$TOR_PID" 2>/dev/null; then
        echo "Force killing Tor process with PID: $TOR_PID"
        kill -9 "$TOR_PID" && echo "Tor process forcefully stopped."
    else
        echo "No valid Tor process found (PID: $TOR_PID)."
    fi

    # Force kill roundrobin process
    if [[ -n "$ROUND_ROBIN_PID" ]] && kill -0 "$ROUND_ROBIN_PID" 2>/dev/null; then
        echo "Force killing roundrobin process with PID: $ROUND_ROBIN_PID"
        kill -9 "$ROUND_ROBIN_PID" && echo "Roundrobin process forcefully stopped."
    else
        echo "No valid roundrobin process found (PID: $ROUND_ROBIN_PID)."
    fi

    # Flush iptables rules (in case they've been set)
    echo "Flushing iptables rules..."
    iptables -F
    iptables -t nat -F

    # Restore MAC address
    echo "Restoring interface '$INTERFACE' MAC to '$MAC_ADDRESS'..."
    ip link set dev "$INTERFACE" down
    ip link set dev "$INTERFACE" address "$MAC_ADDRESS"
    ip link set dev "$INTERFACE" up

    # Restore /etc/resolv.conf
    echo "Restoring /etc/resolv.conf..."
    echo "$RESOLV_CONF" > /etc/resolv.conf

    echo "Changes reverted successfully."
}

# ---------------------------
# Parse arguments
# ---------------------------
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

# ---------------------------
# Handle revert mode
# ---------------------------
if $REVERT_MODE; then
    restore_backup
    exit 0
fi

# ---------------------------
# Default mode configuration
# ---------------------------
if $DEFAULT_MODE; then
    echo "Enabling default anonymity settings..."

    # Pick the first non-lo, non-virtual, non-wireless interface
    INTERFACE=$(ip -o link | awk -F': ' '/^[0-9]/ && $2 !~ /lo|vir|wl/ {print $2; exit}')
    if [[ -z "$INTERFACE" ]]; then
      echo "No suitable interface found for default mode."
      exit 1
    fi

    # Capture original MAC
    ORIGINAL_MAC=$(ip link show "$INTERFACE" | awk '/link\/ether/ {print $2}')
    # Generate new random MAC
    NEW_MAC=$(openssl rand -hex 6 | sed 's/\(..\)/\1:/g; s/:$//')

    USE_DNS=true
    USE_TOR=true
    ROUND_ROBIN=true

else
# ---------------------------
# Interactive mode
# ---------------------------
    echo "Welcome to the AnonMe - An Convinient Anonymity Setup"
    echo "==========================================="

    # Build an array of candidate interfaces
    INTERFACES=($(ip -o link | awk -F': ' '/^[0-9]/ && $2 !~ /lo|vir|wl/ {print $2}'))
    if [[ ${#INTERFACES[@]} -eq 0 ]]; then
        echo "No suitable wired interfaces found."
        exit 1
    fi

    echo "Please select the network interface to modify:"
    for i in "${!INTERFACES[@]}"; do
        echo "$((i+1))) ${INTERFACES[$i]}"
    done
    read -rp "Enter the interface number: " choice
    (( choice-- ))  # Convert to zero-based index

    if [[ -z "${INTERFACES[choice]}" ]]; then
        echo "Invalid choice."
        exit 1
    fi
    INTERFACE="${INTERFACES[choice]}"
    echo "Selected interface: $INTERFACE"

    # Capture the original MAC
    ORIGINAL_MAC=$(ip link show "$INTERFACE" | awk '/link\/ether/ {print $2}')

    # MAC address
    read -rp "Do you want to set a custom MAC address? (y/n): " SET_MAC
    if [[ "$SET_MAC" =~ ^[Yy]$ ]]; then
        read -rp "Enter the custom MAC address (e.g. 00:11:22:33:44:55): " NEW_MAC
    else
        # Generate random MAC
        NEW_MAC=$(openssl rand -hex 6 | sed 's/\(..\)/\1:/g; s/:$//')
        echo "Using random MAC address: $NEW_MAC"
    fi

    # DNS
    read -rp "Do you want to enable anonymous DNS? (y/n): " DNS_CHOICE
    if [[ "$DNS_CHOICE" =~ ^[Yy]$ ]]; then
        USE_DNS=true
        read -rp "Do you want to use a custom DNS server? (y/n): " CUSTOM_CHOICE
    	if [[ "$CUSTOM_CHOICE" =~ ^[Yy]$ ]]; then
    	    read -rp "Enter your custom DNS server (e.g., 8.8.8.8): " $CUSTOM_DNS
    	else
        	# Default DNS (e.g., Cloudflare)
        	$CUSTOM_DNS="1.1.1.1"
    	fi
    fi

    # Round-robin DNS
    read -rp "Do you want to use round-robin DNS with international servers? (y/n): " RR_CHOICE
    if [[ "$RR_CHOICE" =~ ^[Yy]$ ]]; then
        ROUND_ROBIN=true
    fi

    # Tor
    read -rp "Do you want to route all traffic through Tor? (y/n): " TOR_CHOICE
    if [[ "$TOR_CHOICE" =~ ^[Yy]$ ]]; then
        USE_TOR=true
    fi
fi

# ---------------------------
# Create a backup of current state (storing in local dir)
# ---------------------------
BACKUP_FILE=$(create_backup "$INTERFACE" "$ORIGINAL_MAC")

# ---------------------------
# Change MAC address
# ---------------------------
echo "Changing MAC address for $INTERFACE..."
ip link set dev "$INTERFACE" down
ip link set dev "$INTERFACE" address "$NEW_MAC"
ip link set dev "$INTERFACE" up

# ---------------------------
# Configure DNS
# ---------------------------
if $USE_DNS; then
    echo "Setting anonymous DNS (e.g., Cloudflare 1.1.1.1)..."
    # Basic example of overwriting resolv.conf
    echo $CUSTOM_DNS > /etc/resolv.conf
fi

# ---------------------------
# Round-robin DNS
#fix me - also add an option in the main menu to add custom round robin servers
# ---------------------------
if $ROUND_ROBIN; then
    echo "Configuring round-robin DNS with multiple servers..."
    > /etc/resolv.conf
    for SERVER in "${DNS_SERVERS[@]}"; do
        echo "nameserver $SERVER" >> /etc/resolv.conf
    done
    echo "Round-robin DNS servers configured."

    # Verify
    RESOLV_CONTENT=$(cat /etc/resolv.conf)
    for SERVER in "${DNS_SERVERS[@]}"; do
        if ! grep -q "$SERVER" <<< "$RESOLV_CONTENT"; then
            echo "DNS server $SERVER is missing in /etc/resolv.conf!"
            exit 1
        fi
    done
    echo "Round-robin DNS configuration verification passed."
fi

# ---------------------------
# Route traffic through Tor
# ---------------------------
if $USE_TOR; then
    if ! systemctl is-active --quiet tor; then
        echo "Tor is not running. Starting Tor..."
        systemctl start tor
    fi
    echo "Routing all traffic through Tor..."
    # Install Tor if not present
    if ! command -v tor &>/dev/null; then
        echo "Tor is not installed. Installing Tor..."
        apt update && apt install -y tor
    fi

    systemctl start tor 2>/dev/null || service tor start 2>/dev/null

    # Flush existing rules
    iptables -F
    iptables -t nat -F

    # Do not redirect Tor's own traffic
    iptables -t nat -A OUTPUT -m owner --uid-owner debian-tor -j RETURN
    # Redirect DNS queries to Tor's DNS port
    iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 9053
    # Redirect TCP traffic to Tor's TransPort (9040 by default)
    iptables -t nat -A OUTPUT -p tcp --syn -j REDIRECT --to-ports 9040
    # Allow established/related connections
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    # Allow Tor user
    iptables -A OUTPUT -m owner --uid-owner debian-tor -j ACCEPT
    # Reject everything else
    iptables -A OUTPUT -j REJECT

    # Tor verification (may be unreliable if the site changes)
    echo "Verifying Tor connection..."
    TOR_CHECK=$(curl --socks5-hostname 127.0.0.1:9050 -s https://check.torproject.org \
                | grep -o "Congratulations. This browser is configured to use Tor")

    if [[ -n "$TOR_CHECK" ]]; then
        echo "Tor routing verification passed."
    else
        echo "Tor routing verification may have failed. (check.torproject.org not matching)"
        echo "Nevertheless, iptables rules and tor service are configured."
    fi
fi

# ---------------------------
#also make sure to call the appened function here to appened the pids
# Print Summary of Current Settings
# ---------------------------
echo "---- Current Settings ----"
echo "Network Interface: $INTERFACE"
echo "MAC Address: $(ip link show "$INTERFACE" | awk '/link\/ether/ {print $2}')"
echo "DNS Servers in use:"
grep '^nameserver' /etc/resolv.conf
if $USE_TOR; then
    echo "Traffic Routing: Through Tor"
else
    echo "Traffic Routing: Direct (not routed through Tor)"
fi

echo "Anonymity setup complete."
echo "Backup file created in local directory: $BACKUP_FILE"
exit 0
