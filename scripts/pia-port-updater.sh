#!/bin/bash
# PIA Port Forwarding Updater
# Manages dynamic port forwarding for slskd through PIA VPN
#
# This script:
# 1. Authenticates with PIA (reuses cached token if valid)
# 2. Requests/renews a forwarded port
# 3. Updates slskd.yml with the new port
# 4. Restarts slskd if the port changed
# 5. Updates iptables rules for the new port
#
# Designed to run every 14 minutes via systemd timer

set -euo pipefail

# Configuration paths
PIA_STATE_DIR="/home/slskd/.config/pia"
SLSKD_CONFIG="/home/slskd/.local/share/slskd/slskd.yml"

# State files
TOKEN_FILE="$PIA_STATE_DIR/token"
TOKEN_EXPIRY_FILE="$PIA_STATE_DIR/token_expiry"
PAYLOAD_FILE="$PIA_STATE_DIR/payload"
SIGNATURE_FILE="$PIA_STATE_DIR/signature"
PREV_PORT_FILE="$PIA_STATE_DIR/prev_port"

# Ensure state directory exists
mkdir -p "$PIA_STATE_DIR"
chown slskd:slskd "$PIA_STATE_DIR"
chmod 700 "$PIA_STATE_DIR"

# Source PIA credentials from environment file
if [[ ! -f /etc/pia-wg.env ]]; then
    echo "ERROR: /etc/pia-wg.env not found"
    exit 1
fi
source /etc/pia-wg.env

# Verify required variables
for var in PIA_USER PIA_PASS PIA_META_CN PIA_META_IP PIA_SERVER_VIP; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: Required variable $var not set in /etc/pia-wg.env"
        exit 1
    fi
done

# Get WireGuard interface IP (our VPN IP)
WG_IP=$(ip -4 addr show wg0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
if [[ -z "$WG_IP" ]]; then
    echo "ERROR: wg0 interface not found or has no IP address"
    exit 1
fi

# Function: Check if cached token is still valid
token_valid() {
    if [[ ! -f "$TOKEN_FILE" ]] || [[ ! -f "$TOKEN_EXPIRY_FILE" ]]; then
        return 1
    fi
    
    local expiry
    expiry=$(cat "$TOKEN_EXPIRY_FILE")
    local now
    now=$(date +%s)
    
    if (( now >= expiry )); then
        return 1
    fi
    
    return 0
}

# Function: Get new authentication token from PIA
get_token() {
    echo "Authenticating with PIA..."
    
    local auth_response
    auth_response=$(curl -s \
        --resolve "$PIA_META_CN:443:$PIA_META_IP" \
        --cacert /dev/null \
        --insecure \
        -u "$PIA_USER:$PIA_PASS" \
        "https://$PIA_META_CN/authv3/generateToken")
    
    local token
    token=$(echo "$auth_response" | jq -r '.token')
    
    if [[ -z "$token" ]] || [[ "$token" == "null" ]]; then
        echo "ERROR: Failed to authenticate with PIA"
        echo "Response: $auth_response"
        return 1
    fi
    
    # Cache token (valid for 24h, we'll refresh after 20h to be safe)
    echo "$token" > "$TOKEN_FILE"
    echo $(( $(date +%s) + 72000 )) > "$TOKEN_EXPIRY_FILE"  # 20 hours
    chmod 600 "$TOKEN_FILE" "$TOKEN_EXPIRY_FILE"
    
    echo "✓ Authentication successful"
}

# Function: Request a new port from PIA
get_new_port() {
    echo "Requesting new port from PIA..."
    
    local token
    token=$(cat "$TOKEN_FILE")
    
    local pf_response
    pf_response=$(curl -s -G \
        --resolve "$PIA_SERVER_VIP:19999:$WG_IP" \
        --cacert /dev/null \
        --insecure \
        --data-urlencode "token=$token" \
        "https://$PIA_SERVER_VIP:19999/getSignature")
    
    local status
    status=$(echo "$pf_response" | jq -r '.status')
    
    if [[ "$status" != "OK" ]]; then
        echo "ERROR: Failed to get port signature from PIA"
        echo "Response: $pf_response"
        return 1
    fi
    
    # Extract and save payload and signature
    echo "$pf_response" | jq -r '.payload' > "$PAYLOAD_FILE"
    echo "$pf_response" | jq -r '.signature' > "$SIGNATURE_FILE"
    chmod 600 "$PAYLOAD_FILE" "$SIGNATURE_FILE"
    
    local port
    port=$(echo "$pf_response" | jq -r '.payload' | base64 -d | jq -r '.port')
    
    echo "✓ New port assigned: $port"
    echo "$port"
}

# Function: Send heartbeat to maintain existing port binding
send_heartbeat() {
    if [[ ! -f "$PAYLOAD_FILE" ]] || [[ ! -f "$SIGNATURE_FILE" ]]; then
        return 1
    fi
    
    local payload
    local signature
    payload=$(cat "$PAYLOAD_FILE")
    signature=$(cat "$SIGNATURE_FILE")
    
    # Try to bind the port
    local bind_response
    bind_response=$(curl -s -G \
        --resolve "$PIA_SERVER_VIP:19999:$WG_IP" \
        --cacert /dev/null \
        --insecure \
        --data-urlencode "payload=$payload" \
        --data-urlencode "signature=$signature" \
        "https://$PIA_SERVER_VIP:19999/bindPort" 2>&1)
    
    local status
    status=$(echo "$bind_response" | jq -r '.status' 2>/dev/null || echo "error")
    
    if [[ "$status" != "OK" ]]; then
        return 1
    fi
    
    local port
    port=$(echo "$payload" | base64 -d | jq -r '.port')
    
    echo "✓ Port heartbeat successful: $port"
    echo "$port"
}

# Function: Update iptables rules for the forwarded port
update_iptables() {
    local port=$1
    local prev_port=${2:-}
    
    echo "Updating iptables rules for port $port..."
    
    # Remove old rules if previous port exists and is different
    if [[ -n "$prev_port" ]] && [[ "$prev_port" != "$port" ]]; then
        # Check if rule exists before attempting to delete
        if iptables -t nat -C PREROUTING -i wg0 -p tcp --dport "$prev_port" -j DNAT --to-destination "$WG_IP:$prev_port" 2>/dev/null; then
            iptables -t nat -D PREROUTING -i wg0 -p tcp --dport "$prev_port" -j DNAT --to-destination "$WG_IP:$prev_port"
        fi
        if iptables -t nat -C PREROUTING -i wg0 -p udp --dport "$prev_port" -j DNAT --to-destination "$WG_IP:$prev_port" 2>/dev/null; then
            iptables -t nat -D PREROUTING -i wg0 -p udp --dport "$prev_port" -j DNAT --to-destination "$WG_IP:$prev_port"
        fi
    fi
    
    # Add new rules (idempotent - check if exists first)
    if ! iptables -t nat -C PREROUTING -i wg0 -p tcp --dport "$port" -j DNAT --to-destination "$WG_IP:$port" 2>/dev/null; then
        iptables -t nat -A PREROUTING -i wg0 -p tcp --dport "$port" -j DNAT --to-destination "$WG_IP:$port"
    fi
    if ! iptables -t nat -C PREROUTING -i wg0 -p udp --dport "$port" -j DNAT --to-destination "$WG_IP:$port" 2>/dev/null; then
        iptables -t nat -A PREROUTING -i wg0 -p udp --dport "$port" -j DNAT --to-destination "$WG_IP:$port"
    fi
    
    echo "✓ iptables rules updated"
}

# Function: Update slskd.yml with new port
update_slskd_config() {
    local port=$1
    
    echo "Updating slskd config with port $port..."
    
    if [[ ! -f "$SLSKD_CONFIG" ]]; then
        echo "ERROR: slskd config not found at $SLSKD_CONFIG"
        return 1
    fi
    
    # Create backup
    cp "$SLSKD_CONFIG" "${SLSKD_CONFIG}.bak"
    
    # Check if soulseek section exists
    if ! grep -q "^soulseek:" "$SLSKD_CONFIG"; then
        # Add soulseek section with listen_port
        echo "soulseek:" >> "$SLSKD_CONFIG"
        echo "  listen_port: $port" >> "$SLSKD_CONFIG"
    else
        # Check if listen_port exists in soulseek section
        if grep -q "^soulseek:" -A 20 "$SLSKD_CONFIG" | grep -q "listen_port:"; then
            # Update existing listen_port
            sed -i "/^soulseek:/,/^[a-z]/ s/listen_port:.*/listen_port: $port/" "$SLSKD_CONFIG"
        else
            # Add listen_port to existing soulseek section
            sed -i "/^soulseek:/a\  listen_port: $port" "$SLSKD_CONFIG"
        fi
    fi
    
    # Fix ownership
    chown slskd:slskd "$SLSKD_CONFIG"
    
    echo "✓ slskd config updated"
}

# Main execution
echo "=== PIA Port Forwarding Update ==="
echo "Time: $(date)"
echo ""

# Step 1: Ensure we have a valid token
if ! token_valid; then
    if ! get_token; then
        echo "ERROR: Failed to get authentication token"
        exit 1
    fi
else
    echo "✓ Using cached authentication token"
fi

# Step 2: Try to send heartbeat first, fall back to getting new port
PORT=""
if send_heartbeat 2>/dev/null; then
    PORT=$(send_heartbeat)
else
    echo "Heartbeat failed, requesting new port..."
    PORT=$(get_new_port)
fi

if [[ -z "$PORT" ]]; then
    echo "ERROR: Failed to obtain port"
    exit 1
fi

echo ""
echo "Current port: $PORT"

# Step 3: Check if port changed
PREV_PORT=""
if [[ -f "$PREV_PORT_FILE" ]]; then
    PREV_PORT=$(cat "$PREV_PORT_FILE")
fi

PORT_CHANGED=false
if [[ "$PORT" != "$PREV_PORT" ]]; then
    echo "Port changed from ${PREV_PORT:-none} to $PORT"
    PORT_CHANGED=true
else
    echo "Port unchanged: $PORT"
fi

# Step 4: Update configuration
update_slskd_config "$PORT"

# Step 5: Update iptables
update_iptables "$PORT" "$PREV_PORT"

# Step 6: Restart slskd if port changed
if [[ "$PORT_CHANGED" == "true" ]]; then
    echo "Restarting slskd..."
    systemctl restart slskd.service
    echo "✓ slskd restarted"
fi

# Save current port
echo "$PORT" > "$PREV_PORT_FILE"
chmod 600 "$PREV_PORT_FILE"

echo ""
echo "=== Port forwarding update complete ==="
echo "Active port: $PORT"
echo ""
