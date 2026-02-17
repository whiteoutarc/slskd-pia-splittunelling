#!/bin/bash
# PIA WireGuard Bootstrap Script
# One-time setup to generate WireGuard credentials and fetch PIA server details
# 
# Usage:
#   PIA_USER='p1234567' PIA_PASS='yourpassword' PIA_REGION='us_seattle' ./pia-wireguard-bootstrap.sh
#
# This script will:
# 1. Generate a WireGuard keypair
# 2. Fetch PIA server list and find the specified region
# 3. Authenticate with PIA and register the WireGuard public key
# 4. Output configuration blocks ready to paste into wg0.conf and pia-wg.env

set -euo pipefail

# Check required environment variables
if [[ -z "${PIA_USER:-}" ]] || [[ -z "${PIA_PASS:-}" ]] || [[ -z "${PIA_REGION:-}" ]]; then
    echo "ERROR: Required environment variables not set."
    echo "Usage: PIA_USER='p1234567' PIA_PASS='yourpassword' PIA_REGION='us_seattle' $0"
    exit 1
fi

# Check for required commands
for cmd in wg curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required command '$cmd' not found. Please install it."
        exit 1
    fi
done

echo "=== PIA WireGuard Bootstrap ==="
echo "Region: $PIA_REGION"
echo ""

# Generate WireGuard keypair
echo "Generating WireGuard keypair..."
WG_PRIVKEY=$(wg genkey)
WG_PUBKEY=$(echo "$WG_PRIVKEY" | wg pubkey)
echo "✓ WireGuard keypair generated"
echo ""

# Fetch PIA server list
echo "Fetching PIA server list..."
SERVER_LIST=$(curl -s 'https://serverlist.piaservers.net/vpninfo/servers/v6')

# Extract and verify server list
if [[ -z "$SERVER_LIST" ]]; then
    echo "ERROR: Failed to fetch PIA server list"
    exit 1
fi

# Find the requested region
REGION_DATA=$(echo "$SERVER_LIST" | jq -r ".regions[] | select(.id == \"$PIA_REGION\")")

if [[ -z "$REGION_DATA" ]]; then
    echo "ERROR: Region '$PIA_REGION' not found."
    echo ""
    echo "Available regions with port forwarding support:"
    echo "$SERVER_LIST" | jq -r '.regions[] | select(.port_forward == true) | "  " + .id + " - " + .name'
    exit 1
fi

# Check if region supports port forwarding
PF_SUPPORT=$(echo "$REGION_DATA" | jq -r '.port_forward')
if [[ "$PF_SUPPORT" != "true" ]]; then
    echo "WARNING: Region '$PIA_REGION' does not support port forwarding!"
    echo "Port forwarding is required for slskd. Consider choosing a different region."
    echo ""
    echo "Regions with port forwarding support:"
    echo "$SERVER_LIST" | jq -r '.regions[] | select(.port_forward == true) | "  " + .id + " - " + .name'
    exit 1
fi

echo "✓ Region found: $(echo "$REGION_DATA" | jq -r '.name')"

# Extract server information
META_IP=$(echo "$REGION_DATA" | jq -r '.servers.meta[0].ip')
META_CN=$(echo "$REGION_DATA" | jq -r '.servers.meta[0].cn')
WG_IP=$(echo "$REGION_DATA" | jq -r '.servers.wg[0].ip')
WG_CN=$(echo "$REGION_DATA" | jq -r '.servers.wg[0].cn')

if [[ -z "$META_IP" ]] || [[ -z "$WG_IP" ]]; then
    echo "ERROR: Failed to extract server IPs from region data"
    exit 1
fi

echo "  Meta Server: $META_CN ($META_IP)"
echo "  WG Server: $WG_CN ($WG_IP)"
echo ""

# Authenticate with PIA
echo "Authenticating with PIA..."
AUTH_RESPONSE=$(curl -s \
    --resolve "$META_CN:443:$META_IP" \
    --cacert /dev/null \
    --insecure \
    -u "$PIA_USER:$PIA_PASS" \
    "https://$META_CN/authv3/generateToken")

TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.token')
if [[ -z "$TOKEN" ]] || [[ "$TOKEN" == "null" ]]; then
    echo "ERROR: Authentication failed. Check your credentials."
    echo "Response: $AUTH_RESPONSE"
    exit 1
fi
echo "✓ Authentication successful"
echo ""

# Register WireGuard key
echo "Registering WireGuard public key with PIA..."
WG_RESPONSE=$(curl -s -G \
    --resolve "$WG_CN:1337:$WG_IP" \
    --cacert /dev/null \
    --insecure \
    --data-urlencode "pt=$TOKEN" \
    --data-urlencode "pubkey=$WG_PUBKEY" \
    "https://$WG_CN:1337/addKey")

STATUS=$(echo "$WG_RESPONSE" | jq -r '.status')
if [[ "$STATUS" != "OK" ]]; then
    echo "ERROR: Failed to register WireGuard key"
    echo "Response: $WG_RESPONSE"
    exit 1
fi

PEER_IP=$(echo "$WG_RESPONSE" | jq -r '.peer_ip')
SERVER_PUBKEY=$(echo "$WG_RESPONSE" | jq -r '.server_key')
SERVER_PORT=$(echo "$WG_RESPONSE" | jq -r '.server_port')
SERVER_VIP=$(echo "$WG_RESPONSE" | jq -r '.server_vip')
DNS_SERVERS=$(echo "$WG_RESPONSE" | jq -r '.dns_servers[0:2] | join(",")')

echo "✓ WireGuard key registered"
echo "  Peer IP: $PEER_IP"
echo "  Server: $WG_IP:$SERVER_PORT"
echo ""

# Output configuration blocks
echo "========================================"
echo "BLOCK A: WireGuard Configuration (wg0.conf)"
echo "========================================"
echo ""
echo "Copy these values into /etc/wireguard/wg0.conf:"
echo ""
cat <<EOF
[Interface]
PrivateKey = $WG_PRIVKEY
Address = $PEER_IP
DNS = $DNS_SERVERS

[Peer]
PublicKey = $SERVER_PUBKEY
Endpoint = $WG_IP:$SERVER_PORT
AllowedIPs = 0.0.0.0/0
EOF

echo ""
echo "========================================"
echo "BLOCK B: PIA Environment Variables (pia-wg.env)"
echo "========================================"
echo ""
echo "Copy these values into /etc/pia-wg.env:"
echo ""
cat <<EOF
PIA_USER='$PIA_USER'
PIA_PASS='$PIA_PASS'
PIA_REGION='$PIA_REGION'
PIA_WG_CN='$WG_CN'
PIA_WG_IP='$WG_IP'
PIA_META_CN='$META_CN'
PIA_META_IP='$META_IP'
PIA_SERVER_VIP='$SERVER_VIP'
WG_PRIVKEY='$WG_PRIVKEY'
WG_PUBKEY='$WG_PUBKEY'
EOF

echo ""
echo "========================================"
echo "Setup Complete!"
echo "========================================"
echo ""
echo "Next steps:"
echo "1. Create /etc/wireguard/wg0.conf using BLOCK A values and the split-tunnel PostUp/PostDown rules"
echo "2. Create /etc/pia-wg.env using BLOCK B values and set permissions: chmod 600 /etc/pia-wg.env"
echo "3. Continue with the main setup guide"
echo ""
