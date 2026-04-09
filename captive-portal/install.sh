#!/usr/bin/env bash
# install.sh — Install MT7902 captive portal detection
# Run as root: sudo ./install.sh
# License: GPL-2.0

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Must be root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo ./install.sh)"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check dependencies
for cmd in curl notify-send nmcli; do
    if ! command -v "$cmd" &>/dev/null; then
        warn "Missing dependency: $cmd"
        case "$cmd" in
            curl) warn "  Install with: sudo pacman -S curl" ;;
            notify-send) warn "  Install with: sudo pacman -S libnotify" ;;
            nmcli) warn "  NetworkManager is required" ;;
        esac
    fi
done

# Check for at least one supported browser
BROWSER_FOUND=false
for browser in firefox brave chromium google-chrome-stable; do
    if command -v "$browser" &>/dev/null; then
        info "Found browser: $browser"
        BROWSER_FOUND=true
        break
    fi
done
if ! $BROWSER_FOUND; then
    warn "No supported browser found (firefox, brave, chromium)"
fi

# Install the main script
info "Installing captive portal detector..."
mkdir -p /usr/local/lib/mt7902
cp "$SCRIPT_DIR/mt7902-captive-portal.sh" /usr/local/lib/mt7902/
chmod 755 /usr/local/lib/mt7902/mt7902-captive-portal.sh

# Install NetworkManager dispatcher script
info "Installing NetworkManager dispatcher hook..."
cp "$SCRIPT_DIR/90-captive-portal" /etc/NetworkManager/dispatcher.d/
chmod 755 /etc/NetworkManager/dispatcher.d/90-captive-portal

# Restart NetworkManager dispatcher to pick up the new script
info "Reloading NetworkManager dispatcher..."
systemctl restart NetworkManager-dispatcher.service 2>/dev/null || true

info ""
info "Installation complete!"
info ""
info "How it works:"
info "  1. When you connect to a WiFi network, NetworkManager triggers the detector"
info "  2. It probes known connectivity check endpoints to detect captive portals"
info "  3. If a portal is found, the redirect URL is validated for safety:"
info "     - Only http:// and https:// URLs are allowed"
info "     - Suspicious patterns (credential attacks, obfuscation, etc.) are blocked"
info "     - You get a desktop notification showing the URL"
info "  4. If safe, the portal login page opens in your browser"
info "  5. If suspicious, you get a warning and the URL is NOT opened"
info ""
info "Logs: /tmp/mt7902-captive-portal.log"
info ""
info "To test manually:"
info "  sudo /usr/local/lib/mt7902/mt7902-captive-portal.sh wlan0 check"
info ""
info "To uninstall:"
info "  sudo rm /etc/NetworkManager/dispatcher.d/90-captive-portal"
info "  sudo rm -rf /usr/local/lib/mt7902"
