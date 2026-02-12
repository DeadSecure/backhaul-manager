#!/bin/bash
# ============================================================
# IPsec Cipher Switcher
# Switches between AES-256-CBC+SHA256 and AES-128-GCM
# Usage: bash ipsec_cipher_switch.sh [gcm|default|status]
# ============================================================

set -e

CONF_DIR="/etc/swanctl/conf.d"
BACKUP_DIR="/etc/swanctl/.cipher-backup"

# --- Original (Default) Proposals ---
OLD_IKE_PROPOSALS='proposals = aes256-sha256-modp2048,aes128-sha1-modp1024'
OLD_ESP_PROPOSALS='esp_proposals = aes256-sha256,aes128-sha1'

# --- GCM (Optimized) Proposals ---
GCM_IKE_PROPOSALS='proposals = aes128gcm128-sha256-modp2048,aes256-sha256-modp2048'
GCM_ESP_PROPOSALS='esp_proposals = aes128gcm128,aes256-sha256'

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Functions ---

show_status() {
    echo ""
    echo "========================================"
    echo "   IPsec Cipher Status"
    echo "========================================"

    local conf_count=$(ls "$CONF_DIR"/*.conf 2>/dev/null | wc -l)
    if [ "$conf_count" -eq 0 ]; then
        log_warn "No config files found in $CONF_DIR"
        return
    fi

    log_info "Config files found: $conf_count"
    echo ""

    local gcm_count=$(grep -rl 'aes128gcm128' "$CONF_DIR"/*.conf 2>/dev/null | wc -l)
    local default_count=$(grep -rl 'aes256-sha256-modp2048' "$CONF_DIR"/*.conf 2>/dev/null | wc -l)

    if [ "$gcm_count" -gt 0 ] && [ "$default_count" -eq "$gcm_count" ]; then
        log_ok "Current Mode: GCM (aes128gcm128) - Optimized"
    elif [ "$gcm_count" -eq 0 ]; then
        log_info "Current Mode: Default (aes256-sha256)"
    else
        log_warn "Mixed mode detected! Some files are GCM, some are default."
    fi

    echo ""
    echo "--- Per-file details ---"
    for f in "$CONF_DIR"/*.conf; do
        local fname=$(basename "$f")
        if grep -q 'aes128gcm128' "$f" 2>/dev/null; then
            echo -e "  ${GREEN}[GCM]${NC} $fname"
        else
            echo -e "  ${CYAN}[DEFAULT]${NC} $fname"
        fi
    done
    echo ""
}

backup_configs() {
    mkdir -p "$BACKUP_DIR"
    for f in "$CONF_DIR"/*.conf; do
        cp "$f" "$BACKUP_DIR/$(basename "$f").bak"
    done
    log_ok "Backup created in $BACKUP_DIR"
}

switch_to_gcm() {
    echo ""
    echo "========================================"
    echo "   Switching to AES-128-GCM"
    echo "========================================"

    local conf_count=$(ls "$CONF_DIR"/*.conf 2>/dev/null | wc -l)
    if [ "$conf_count" -eq 0 ]; then
        log_err "No config files found!"
        exit 1
    fi

    # Check if already GCM
    if grep -q 'aes128gcm128' "$CONF_DIR"/*.conf 2>/dev/null; then
        log_warn "Already using GCM cipher. Nothing to do."
        show_status
        return
    fi

    # Backup first
    log_info "Creating backup..."
    backup_configs

    # Replace IKE proposals
    log_info "Updating IKE proposals..."
    sed -i "s|proposals = aes256-sha256-modp2048,aes128-sha1-modp1024|proposals = aes128gcm128-sha256-modp2048,aes256-sha256-modp2048|g" "$CONF_DIR"/*.conf 2>/dev/null || true

    # Replace ESP proposals
    log_info "Updating ESP proposals..."
    sed -i "s|esp_proposals = aes256-sha256,aes128-sha1|esp_proposals = aes128gcm128,aes256-sha256|g" "$CONF_DIR"/*.conf 2>/dev/null || true

    # Reload configs
    log_info "Reloading strongSwan configs..."
    swanctl --load-all 2>&1 || true

    log_ok "Cipher switched to AES-128-GCM!"
    echo ""
    log_info "Tunnels will renegotiate with new cipher on next reconnect."
    log_info "To force immediate renegotiation, restart the service:"
    echo "  systemctl restart strongswan-swanctl"
    echo ""

    show_status
}

switch_to_default() {
    echo ""
    echo "========================================"
    echo "   Reverting to Default Cipher"
    echo "========================================"

    local conf_count=$(ls "$CONF_DIR"/*.conf 2>/dev/null | wc -l)
    if [ "$conf_count" -eq 0 ]; then
        log_err "No config files found!"
        exit 1
    fi

    # Check if backup exists
    if [ -d "$BACKUP_DIR" ] && ls "$BACKUP_DIR"/*.bak >/dev/null 2>&1; then
        log_info "Restoring from backup..."
        for f in "$BACKUP_DIR"/*.bak; do
            local orig_name=$(basename "$f" .bak)
            cp "$f" "$CONF_DIR/$orig_name"
        done
        log_ok "Configs restored from backup."
    else
        # Manual revert via sed
        log_warn "No backup found. Reverting via sed..."
        sed -i "s|proposals = aes128gcm128-sha256-modp2048,aes256-sha256-modp2048|proposals = aes256-sha256-modp2048,aes128-sha1-modp1024|g" "$CONF_DIR"/*.conf 2>/dev/null || true
        sed -i "s|esp_proposals = aes128gcm128,aes256-sha256|esp_proposals = aes256-sha256,aes128-sha1|g" "$CONF_DIR"/*.conf 2>/dev/null || true
        log_ok "Configs reverted via text replacement."
    fi

    # Reload configs
    log_info "Reloading strongSwan configs..."
    swanctl --load-all 2>&1 || true

    log_ok "Cipher reverted to default (AES-256-SHA256)!"
    echo ""

    show_status
}

# --- Main ---

show_help() {
    echo ""
    echo "Usage: bash $0 [command]"
    echo ""
    echo "Commands:"
    echo "  gcm       Switch to AES-128-GCM (lower CPU)"
    echo "  default   Revert to AES-256-SHA256 (original)"
    echo "  status    Show current cipher status"
    echo "  help      Show this help"
    echo ""
}

case "${1:-}" in
    gcm)
        switch_to_gcm
        ;;
    default|revert)
        switch_to_default
        ;;
    status)
        show_status
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_err "Unknown command: ${1:-<empty>}"
        show_help
        exit 1
        ;;
esac
