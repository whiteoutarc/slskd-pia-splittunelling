# slskd + PIA VPN Split-Tunnel Setup Guide

Complete implementation guide for running **slskd** (Soulseek daemon) natively on Ubuntu with **Private Internet Access (PIA)** VPN using **WireGuard** and **split-tunnel routing**.

## What This Does

This setup creates a secure, high-performance file-sharing system where:
- **Only** the `slskd` user's traffic routes through the PIA VPN
- All other system traffic (SSH, system updates, etc.) uses the direct internet connection
- PIA port forwarding is automatically managed for optimal connectivity
- A kill switch prevents traffic leaks if the VPN drops
- WireGuard is optimized for 1Gbps upload speeds

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                          Ubuntu Server                           │
│                                                                  │
│  ┌──────────────┐                        ┌──────────────┐        │
│  │ ubuntu user  │────────────────────────▶│     eth0     │──────┼──▶ Direct Internet
│  │ (SSH, etc.)  │                        │  (Physical)  │        │
│  └──────────────┘                        └──────────────┘        │
│                                                  ▲               │
│  ┌──────────────┐       ┌──────────────┐         │               │
│  │ slskd user   │─────▶│      wg0     │─────────┘               │
│  │ (Soulseek)   │       │  (VPN Tunnel)│                         │
│  └──────────────┘       └──────┬───────┘                         │
│         ▲                      │                                 │
│         │                      └─────────────────────────────────┼──▶ PIA VPN ──▶ Internet
│         │                                                        │
│  ┌──────┴────────────┐                                           │
│  │ Port Updater      │  Every 14 minutes:                        │
│  │ (systemd timer)   │  1. Authenticate with PIA                 │
│  └───────────────────┘  2. Request/renew forwarded port          │
│                         3. Update slskd.yml                      │
│                         4. Restart slskd if port changed         │
└──────────────────────────────────────────────────────────────────┘
```

## Time Estimate

- **Smooth run**: 25-35 minutes
- **Budget**: 45 minutes to 1 hour (to account for troubleshooting)

---

## Table of Contents

1. [Prerequisites & Package Installation](#1-prerequisites--package-installation)
2. [Stop Existing slskd](#2-stop-existing-slskd)
3. [Create Dedicated slskd User](#3-create-dedicated-slskd-user)
4. [Migrate Existing Installation](#4-migrate-existing-installation)
5. [PIA WireGuard Bootstrap](#5-pia-wireguard-bootstrap)
6. [Save PIA Credentials](#6-save-pia-credentials)
7. [WireGuard Configuration](#7-wireguard-configuration)
8. [Install Port Forwarding Script](#8-install-port-forwarding-script)
9. [Install Systemd Units](#9-install-systemd-units)
10. [Bring It All Up](#10-bring-it-all-up)
11. [Verification & Troubleshooting](#11-verification--troubleshooting)

---

## 1. Prerequisites & Package Installation

Install required packages:

```bash
sudo apt update
sudo apt install -y wireguard wireguard-tools curl jq iptables iproute2
```

**Verify WireGuard kernel module:**
```bash
sudo modprobe wireguard
lsmod | grep wireguard
```

If WireGuard module isn't available, you may need to install kernel headers and rebuild:
```bash
sudo apt install -y linux-headers-$(uname -r)
```

---

## 2. Stop Existing slskd

If you have slskd running under your user account, stop and disable it:

```bash
# Stop the service
sudo systemctl stop slskd.service

# Disable it from starting on boot
sudo systemctl disable slskd.service

# Verify it's stopped
sudo systemctl status slskd.service
```

---

## 3. Create Dedicated slskd User

Create a system user for slskd with no login shell:

```bash
sudo useradd -r -m -d /home/slskd -s /usr/sbin/nologin slskd
```

**Flags explained:**
- `-r`: Create system account
- `-m`: Create home directory
- `-d /home/slskd`: Set home directory path
- `-s /usr/sbin/nologin`: No login shell (security)

**Verify user creation:**
```bash
id slskd
# Should output: uid=XXX(slskd) gid=XXX(slskd) groups=XXX(slskd)
```

---

## 4. Migrate Existing Installation

### 4.1 Move slskd Binary

```bash
# Create binary directory
sudo mkdir -p /home/slskd/slskd-bin

# Move the slskd binary (adjust source path if different)
sudo mv ~/slskd/slskd /home/slskd/slskd-bin/

# Or if you need to download it fresh:
# cd /home/slskd/slskd-bin
# sudo wget https://github.com/slskd/slskd/releases/latest/download/slskd-<version>-linux-x64.tar.gz
# sudo tar -xzf slskd-*.tar.gz
# sudo rm slskd-*.tar.gz
```

### 4.2 Migrate Configuration and Data

```bash
# Create config directory structure
sudo mkdir -p /home/slskd/.local/share

# Move existing slskd data (config, database, downloads)
sudo mv ~/.local/share/slskd /home/slskd/.local/share/

# If .local/share/slskd doesn't exist, create it:
# sudo mkdir -p /home/slskd/.local/share/slskd
```

### 4.3 Create Symlink for Music

Instead of copying your music library, create a symlink:

```bash
# Create symlink to your music directory
sudo ln -s /home/ubuntu/music /home/slskd/music

# Verify symlink
ls -la /home/slskd/music
```

### 4.4 Update Paths in slskd.yml

Update file paths in the config to use the new locations:

```bash
# Backup original config
sudo cp /home/slskd/.local/share/slskd/slskd.yml /home/slskd/.local/share/slskd/slskd.yml.backup

# Update paths (adjust if your paths differ)
sudo sed -i 's|/home/ubuntu/slskd|/home/slskd/slskd-bin|g' /home/slskd/.local/share/slskd/slskd.yml
sudo sed -i 's|/home/ubuntu/.local/share/slskd|/home/slskd/.local/share/slskd|g' /home/slskd/.local/share/slskd/slskd.yml
sudo sed -i 's|/home/ubuntu/music|/home/slskd/music|g' /home/slskd/.local/share/slskd/slskd.yml
sudo sed -i 's|/home/ubuntu/downloads|/home/slskd/downloads|g' /home/slskd/.local/share/slskd/slskd.yml
```

Alternatively, use the example config from this repo:
```bash
sudo cp config/slskd.yml.example /home/slskd/.local/share/slskd/slskd.yml
# Then edit it with your Soulseek credentials and preferences
sudo nano /home/slskd/.local/share/slskd/slskd.yml
```

### 4.5 Create Downloads Directory

```bash
sudo mkdir -p /home/slskd/downloads/incomplete
```

### 4.6 Fix Ownership and Permissions

```bash
# Set ownership for all slskd files
sudo chown -R slskd:slskd /home/slskd

# Make binary executable
sudo chmod +x /home/slskd/slskd-bin/slskd

# Set proper permissions for config directory
sudo chmod 700 /home/slskd/.local/share/slskd
sudo chmod 600 /home/slskd/.local/share/slskd/slskd.yml
```

---

## 5. PIA WireGuard Bootstrap

The bootstrap script generates WireGuard keys and fetches PIA server information.

### 5.1 Copy Bootstrap Script

```bash
sudo cp scripts/pia-wireguard-bootstrap.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/pia-wireguard-bootstrap.sh
```

### 5.2 Choose a PIA Region

PIA port forwarding only works in certain regions. To see available regions:

```bash
# This will fail but show you all port-forwarding-capable regions:
PIA_USER='dummy' PIA_PASS='dummy' PIA_REGION='invalid' \
    /usr/local/bin/pia-wireguard-bootstrap.sh
```

**Popular port-forwarding regions:**
- `us_seattle` - Seattle, USA
- `us_east` - US East
- `ca_toronto` - Toronto, Canada
- `de_frankfurt` - Frankfurt, Germany
- `uk_london` - London, UK
- `swiss` - Switzerland

### 5.3 Run Bootstrap Script

Replace with your actual PIA credentials and chosen region:

```bash
PIA_USER='p1234567' \
PIA_PASS='your_pia_password' \
PIA_REGION='us_seattle' \
    /usr/local/bin/pia-wireguard-bootstrap.sh
```

**The script will output two blocks:**

**BLOCK A** - WireGuard config values (you'll use these in step 7)
```
[Interface]
PrivateKey = <your_key>
Address = 10.x.x.x/32
DNS = 10.0.0.243

[Peer]
PublicKey = <server_key>
Endpoint = 1.2.3.4:1337
AllowedIPs = 0.0.0.0/0
```

**BLOCK B** - Environment variables (you'll use these in step 6)
```
PIA_USER='p1234567'
PIA_PASS='yourpass'
PIA_REGION='us_seattle'
...
```

**Save both blocks** - you'll need them in the next steps.

---

## 6. Save PIA Credentials

Create the environment file with values from BLOCK B:

```bash
sudo nano /etc/pia-wg.env
```

Paste the entire BLOCK B output from the bootstrap script.

**Set secure permissions:**
```bash
sudo chmod 600 /etc/pia-wg.env
sudo chown root:root /etc/pia-wg.env
```

**Verify:**
```bash
sudo cat /etc/pia-wg.env
# Should show your PIA credentials and server info
```

---

## 7. WireGuard Configuration

### 7.1 Create WireGuard Config

```bash
sudo nano /etc/wireguard/wg0.conf
```

Start with the example from this repo:
```bash
sudo cp config/wg0.conf.example /etc/wireguard/wg0.conf
```

### 7.2 Replace Placeholders

Edit `/etc/wireguard/wg0.conf` and replace these placeholders with values from BLOCK A:

- `<PRIVKEY>` → Your WireGuard private key
- `<PEER_IP>` → Your assigned peer IP (e.g., `10.x.x.x/32`)
- `<DNS>` → PIA DNS server (e.g., `10.0.0.243`)
- `<SERVER_PUBKEY>` → PIA server's public key
- `<ENDPOINT_IP:PORT>` → PIA server endpoint (e.g., `1.2.3.4:1337`)

### 7.3 Understanding the Split-Tunnel Rules

The `PostUp` rules in `wg0.conf` implement split-tunnel routing:

| Rule | Purpose | What It Does |
|------|---------|--------------|
| `ip rule add uidrange $(id -u slskd)...` | User-based routing | Routes only traffic from the `slskd` user to custom routing table 42 |
| `ip route add default dev %i table 42` | VPN default route | Sets table 42's default route to go through wg0 interface |
| `ip route add .../32 via $GW` | Endpoint routing | Ensures WireGuard endpoint is reachable via physical NIC (prevents routing loop) |
| `iptables -t nat ... MASQUERADE` | NAT | Translates slskd's private IP to the VPN IP for outbound traffic |
| `iptables ... REJECT` | Kill switch | Blocks slskd from using physical NIC (except LAN and loopback), ensuring no leaks |
| `sysctl -w net.core.rmem_max=...` | Performance tuning | Increases socket buffers for 1Gbps upload performance |

### 7.4 Set Permissions

```bash
sudo chmod 600 /etc/wireguard/wg0.conf
sudo chown root:root /etc/wireguard/wg0.conf
```

---

## 8. Install Port Forwarding Script

### 8.1 Copy Script

```bash
sudo cp scripts/pia-port-updater.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/pia-port-updater.sh
```

### 8.2 Create PIA State Directory

```bash
sudo mkdir -p /home/slskd/.config/pia
sudo chown slskd:slskd /home/slskd/.config/pia
sudo chmod 700 /home/slskd/.config/pia
```

### 8.3 How the Port Forwarding Works

The `pia-port-updater.sh` script runs every 14 minutes and:

1. **Authenticates** with PIA (caches token for 20 hours)
2. **Requests/renews** a forwarded port:
   - First tries to send a heartbeat to maintain existing port
   - If heartbeat fails, requests a new port
3. **Updates** `/home/slskd/.local/share/slskd/slskd.yml` with the new port
4. **Restarts** slskd only if the port changed
5. **Updates** iptables rules for the new port (idempotent)

**State files** are stored in `/home/slskd/.config/pia/`:
- `token` - Cached authentication token
- `token_expiry` - Token expiration timestamp
- `payload` - Port forwarding payload
- `signature` - Port forwarding signature
- `prev_port` - Previously assigned port

---

## 9. Install Systemd Units

### 9.1 Install slskd Service

```bash
sudo cp systemd/slskd.service /etc/systemd/system/
```

**Key features:**
- Runs as `slskd` user
- Depends on `wg-quick@wg0.service` (won't start without VPN)
- Security hardening enabled
- High file descriptor limit for many connections

### 9.2 Install Port Updater Service

```bash
sudo cp systemd/pia-port-updater.service /etc/systemd/system/
```

**Key features:**
- Oneshot service (runs to completion then exits)
- Loads `/etc/pia-wg.env` for credentials
- Depends on wg0 being up

### 9.3 Install Port Updater Timer

```bash
sudo cp systemd/pia-port-updater.timer /etc/systemd/system/
```

**Key features:**
- Runs 30 seconds after boot
- Repeats every 14 minutes
- 30-second random delay (prevents thundering herd)
- Persists across reboots

### 9.4 Reload Systemd

```bash
sudo systemctl daemon-reload
```

---

## 10. Bring It All Up

Follow these steps **in order**:

### 10.1 Enable and Start WireGuard

```bash
# Enable wg0 to start on boot
sudo systemctl enable wg-quick@wg0

# Start wg0
sudo systemctl start wg-quick@wg0

# Check status
sudo systemctl status wg-quick@wg0
```

**Verify tunnel is up:**
```bash
sudo wg show
# Should show interface wg0 with peer information

ip addr show wg0
# Should show your peer IP (10.x.x.x/32)
```

### 10.2 Verify Split Tunnel

**Test as ubuntu user (should use physical NIC):**
```bash
curl -4 ifconfig.me
# Should show your ISP's public IP
```

**Test as slskd user (should use VPN):**
```bash
sudo -u slskd curl -4 ifconfig.me
# Should show a PIA VPN IP (different from above)
```

If both show the same IP, the split tunnel isn't working. See [Troubleshooting](#common-issues).

### 10.3 Test Port Forwarding Manually

```bash
# Run the port updater script manually
sudo /usr/local/bin/pia-port-updater.sh

# Check the assigned port
cat /home/slskd/.config/pia/prev_port

# Verify it was written to config
grep listen_port /home/slskd/.local/share/slskd/slskd.yml
```

### 10.4 Enable and Start Port Updater Timer

```bash
# Enable timer to start on boot
sudo systemctl enable pia-port-updater.timer

# Start timer
sudo systemctl start pia-port-updater.timer

# Check status
sudo systemctl status pia-port-updater.timer

# List all timers
sudo systemctl list-timers pia-port-updater.timer
```

### 10.5 Enable and Start slskd

```bash
# Enable slskd to start on boot
sudo systemctl enable slskd.service

# Start slskd
sudo systemctl start slskd.service

# Check status
sudo systemctl status slskd.service
```

**Check slskd logs:**
```bash
sudo journalctl -u slskd.service -f
```

### 10.6 Access Web UI

Open your browser and navigate to:
```
http://your-server-ip:5030
```

Login with the credentials from your `slskd.yml`.

---

## 11. Verification & Troubleshooting

### Split Tunnel Test

Verify that only slskd uses the VPN:

```bash
# Ubuntu user should show ISP IP
curl -4 ifconfig.me

# slskd user should show PIA VPN IP
sudo -u slskd curl -4 ifconfig.me

# These IPs should be DIFFERENT
```

### Kill Switch Test

Verify that slskd cannot leak traffic if VPN drops:

```bash
# Stop VPN
sudo systemctl stop wg-quick@wg0

# Try to access internet as slskd user (should FAIL)
sudo -u slskd curl -4 --max-time 5 ifconfig.me
# Should timeout or fail

# Restart VPN
sudo systemctl start wg-quick@wg0

# Now it should work
sudo -u slskd curl -4 ifconfig.me
```

### Port Forwarding Check

```bash
# Check current port
cat /home/slskd/.config/pia/prev_port

# Verify it matches slskd.yml
grep listen_port /home/slskd/.local/share/slskd/slskd.yml

# Check port updater logs
sudo journalctl -u pia-port-updater.service -n 50

# Manually trigger port update
sudo systemctl start pia-port-updater.service
```

### Routing Table Inspection

```bash
# Show routing rules
ip rule show

# Should include:
# 100:	from all uidrange X-X lookup 42
# where X is the slskd UID

# Show table 42 routes
ip route show table 42

# Should show:
# default dev wg0 scope link
```

### Check WireGuard Connection

```bash
# Show WireGuard status
sudo wg show

# Should show:
# - interface: wg0
# - peer with endpoint and allowed IPs
# - latest handshake (should be recent)
# - transfer data (rx/tx)

# Check wg0 interface
ip addr show wg0

# Ping through VPN (as slskd user)
sudo -u slskd ping -c 3 10.0.0.243
```

### Common Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| Split tunnel not working | slskd UID not in routing rule | Verify `ip rule show` includes correct UID range |
| Port forwarding fails | Token expired | Delete `/home/slskd/.config/pia/token*` and retry |
| slskd can't connect | Port not updated | Check `pia-port-updater.service` logs |
| VPN won't start | Incorrect wg0.conf | Verify all placeholders replaced with actual values |
| Permission denied errors | Wrong file ownership | Run `sudo chown -R slskd:slskd /home/slskd` |
| Kill switch not working | iptables rules not applied | Check PostUp executed: `sudo iptables -L -v -n` |
| Connection drops | MTU issues | Try MTU 1280 or 1420 in wg0.conf |
| Slow upload speed | Buffer sizes too small | Verify sysctl values: `sysctl net.core.rmem_max` |

### Log Files to Check

```bash
# slskd application logs
sudo journalctl -u slskd.service -f

# Port updater logs
sudo journalctl -u pia-port-updater.service -n 100

# WireGuard logs
sudo journalctl -u wg-quick@wg0 -n 50

# System logs
sudo dmesg | tail -50
```

### Useful Commands

```bash
# Restart everything
sudo systemctl restart wg-quick@wg0
sudo systemctl restart slskd
sudo systemctl restart pia-port-updater.timer

# Check all services
sudo systemctl status wg-quick@wg0 slskd pia-port-updater.timer

# Monitor logs
sudo journalctl -f -u slskd -u pia-port-updater -u wg-quick@wg0

# Check iptables rules
sudo iptables -L -v -n
sudo iptables -t nat -L -v -n

# Test network as slskd user
sudo -u slskd bash -c 'curl -4 ifconfig.me; echo'
```

---

## Updating slskd

To update slskd to a newer version:

```bash
# Stop slskd
sudo systemctl stop slskd

# Download new version
cd /tmp
wget https://github.com/slskd/slskd/releases/download/vX.Y.Z/slskd-X.Y.Z-linux-x64.tar.gz

# Extract and replace binary
tar -xzf slskd-*.tar.gz
sudo cp slskd /home/slskd/slskd-bin/
sudo chown slskd:slskd /home/slskd/slskd-bin/slskd
sudo chmod +x /home/slskd/slskd-bin/slskd

# Start slskd
sudo systemctl start slskd

# Verify
sudo systemctl status slskd
```

---

## Maintenance

### Regular Checks

**Weekly:**
- Verify VPN is connected: `sudo wg show`
- Check slskd is running: `sudo systemctl status slskd`
- Review logs for errors: `sudo journalctl -u slskd -u pia-port-updater --since "7 days ago"`

**Monthly:**
- Check for slskd updates
- Review disk space for downloads
- Verify port forwarding is working

### Backup Important Files

```bash
# Backup slskd config and database
sudo tar -czf slskd-backup-$(date +%Y%m%d).tar.gz \
    /home/slskd/.local/share/slskd/slskd.yml \
    /home/slskd/.local/share/slskd/*.db

# Backup PIA credentials and state
sudo tar -czf pia-backup-$(date +%Y%m%d).tar.gz \
    /etc/pia-wg.env \
    /etc/wireguard/wg0.conf \
    /home/slskd/.config/pia/
```

---

## Uninstalling

If you need to remove this setup:

```bash
# Stop and disable services
sudo systemctl stop slskd pia-port-updater.timer wg-quick@wg0
sudo systemctl disable slskd pia-port-updater.timer wg-quick@wg0

# Remove systemd units
sudo rm /etc/systemd/system/slskd.service
sudo rm /etc/systemd/system/pia-port-updater.service
sudo rm /etc/systemd/system/pia-port-updater.timer
sudo systemctl daemon-reload

# Remove WireGuard config
sudo rm /etc/wireguard/wg0.conf

# Remove PIA config
sudo rm /etc/pia-wg.env

# Remove scripts
sudo rm /usr/local/bin/pia-wireguard-bootstrap.sh
sudo rm /usr/local/bin/pia-port-updater.sh

# Remove slskd user and data (WARNING: deletes all slskd data)
# sudo userdel -r slskd
```

---

## Security Considerations

### What This Setup Protects

✅ **VPN Kill Switch**: slskd cannot leak traffic if VPN drops
✅ **Split Tunnel**: Only slskd uses VPN, SSH remains on direct connection
✅ **Credential Protection**: PIA credentials secured with 600 permissions
✅ **Service Isolation**: slskd runs as dedicated user with no login shell
✅ **Systemd Hardening**: Security features enabled (NoNewPrivileges, ProtectSystem, etc.)

### What You Should Also Do

- **Use strong passwords** for PIA, slskd web UI, and Soulseek
- **Keep system updated**: `sudo apt update && sudo apt upgrade`
- **Enable firewall** (ufw) to restrict access:
  ```bash
  sudo ufw allow ssh
  sudo ufw allow 5030/tcp  # slskd web UI
  sudo ufw enable
  ```
- **Use HTTPS** for slskd web UI if exposing to internet
- **Monitor logs** regularly for suspicious activity
- **Rotate PIA password** periodically

---

## Performance Tuning

### For Gigabit Speeds

The config includes optimizations for 1Gbps upload, but you can further tune:

```bash
# Increase socket buffers even more
sudo sysctl -w net.core.rmem_max=134217728
sudo sysctl -w net.core.wmem_max=134217728

# Make permanent in /etc/sysctl.conf
echo "net.core.rmem_max=134217728" | sudo tee -a /etc/sysctl.conf
echo "net.core.wmem_max=134217728" | sudo tee -a /etc/sysctl.conf
```

### Adjust MTU

If you experience connection issues or poor performance:

```bash
# Try different MTU values in /etc/wireguard/wg0.conf
# Common values: 1280, 1380 (default), 1420

# After changing MTU:
sudo systemctl restart wg-quick@wg0
```

---

## FAQ

**Q: Can I use a different PIA region later?**

A: Yes, run the bootstrap script again with a new region, update `/etc/pia-wg.env` and `/etc/wireguard/wg0.conf`, then restart wg0.

**Q: What happens if my PIA subscription expires?**

A: VPN tunnel will fail to connect. slskd will be blocked by the kill switch (cannot leak traffic). Renew subscription and restart wg0.

**Q: Can I run multiple applications through the VPN?**

A: Yes, create additional system users and add their UIDs to the routing rule in wg0.conf PostUp.

**Q: How do I change the port forwarding update interval?**

A: Edit `/etc/systemd/system/pia-port-updater.timer`, change `OnUnitActiveSec=14min` to your preferred interval, then `sudo systemctl daemon-reload && sudo systemctl restart pia-port-updater.timer`.

**Q: Is IPv6 supported?**

A: This guide uses IPv4 only. PIA supports IPv6, but you'll need to modify the configs accordingly.

**Q: Can I use this with Docker?**

A: This guide is specifically for native (non-Docker) installation. Docker setup would be different.

**Q: Why does the port change?**

A: PIA assigns ports dynamically and they can expire. The updater script maintains the port binding, but occasionally PIA may assign a different port.

---

## Credits & Resources

- **slskd**: https://github.com/slskd/slskd
- **PIA Manual Connections**: https://github.com/pia-foss/manual-connections
- **WireGuard**: https://www.wireguard.com/
- **This guide**: https://github.com/whiteoutarc/slskd-pia-splittunelling

---

## Support

If you encounter issues:

1. Check the [Troubleshooting](#common-issues) section
2. Review logs: `sudo journalctl -u slskd -u pia-port-updater -u wg-quick@wg0`
3. Verify each step was completed correctly
4. Open an issue on this repository with:
   - Output of `sudo systemctl status slskd wg-quick@wg0 pia-port-updater.timer`
   - Relevant log excerpts
   - Your Ubuntu version: `lsb_release -a`

---

## License

This guide and associated scripts are provided as-is under the MIT License.

**Disclaimer**: Use at your own risk. This guide is for educational purposes. Ensure you comply with PIA's Terms of Service and your local laws regarding VPN usage and file sharing.
