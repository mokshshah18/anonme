# Kali Anonymity Script

This script provides anonymity by changing the MAC address, configuring DNS settings, and routing traffic through the Tor network. It also includes features to revert changes and manage configurations.

## Features
- **Default mode**: Automatically configures anonymity settings with one command.
- **Interactive mode**: Prompts for individual settings like MAC address, DNS, and Tor routing.
- **Round-robin DNS**: Configures DNS to cycle through multiple international servers for enhanced privacy.
- **Revert mode**: Restores network settings to the last saved configuration.

## Prerequisites
- **Kali Linux** or any compatible Linux distribution.
- **Root privileges**: The script must be run with `sudo`.
- **Tor**: Automatically installed if not present.

## Usage
### Default Mode
Use the `--default` flag to apply anonymity settings with default configurations:
```bash
sudo ./script.sh --default
```

### Interactive Mode
Run the script without flags to configure settings interactively:
```bash
sudo ./script.sh
```
The script will prompt for:
1. Network interface to modify.
2. Custom or random MAC address.
3. DNS settings (Anonymous or Round-robin).
4. Tor routing.

### Revert Changes
To revert all changes to the last saved configuration, use the `--revert` flag:
```bash
sudo ./script.sh --revert
```

### Help
Display usage instructions with the `--help` flag:
```bash
sudo ./script.sh --help
```

## Backup System
The script saves the network configuration to a unique backup file before making changes. These files are stored as `/etc/netconf*.txt`, ensuring no existing backups are overwritten.

## Verification
The script verifies each step to ensure:
- MAC address changes are applied.
- DNS settings are correctly configured.
- Traffic is routed through Tor.

If any step fails, the script provides detailed error messages.

## Round-Robin DNS
The script cycles through the following international DNS servers:
- **Cloudflare**: 1.1.1.1, 1.0.0.1
- **Google**: 8.8.8.8
- **Quad9**: 9.9.9.9
- **Yandex**: 77.88.8.8
- **OpenDNS**: 208.67.222.222
- **114DNS**: 114.114.114.114

## Example Commands
1. Apply default settings:
   ```bash
   sudo ./script.sh --default
   ```
2. Configure settings interactively:
   ```bash
   sudo ./script.sh
   ```
3. Revert changes:
   ```bash
   sudo ./script.sh --revert
   ```

## Notes
- Always run the script as root or with `sudo`.
- Ensure Tor is installed and running for traffic routing.
- Backup files are stored in `/etc/` and named `netconf*.txt`.

## Disclaimer
This script is provided "as-is." Use it responsibly and ensure compliance with applicable laws and policies when using anonymity tools.

For questions or support, feel free to contact the author.

