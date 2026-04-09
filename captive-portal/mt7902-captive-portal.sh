#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes in su -c are intentional (expand on target user's shell)
# mt7902-captive-portal.sh — Secure captive portal detection and handler
# Part of the MT7902 WiFi driver project
# License: GPL-2.0
#
# Detects captive portals after WiFi connection and safely opens the
# login page in the user's browser after strict URL validation.
#
# Security model:
#   - Only HTTP/HTTPS URLs are allowed (no file://, javascript:, data:, etc.)
#   - URLs are validated against known attack patterns
#   - The redirect URL is shown to the user via desktop notification
#   - Suspicious URLs trigger a warning instead of opening
#   - Browser is invoked directly (not via xdg-open) to prevent scheme hijacking
#   - Rate-limited to prevent portal-spam loops

set -euo pipefail

# --- Configuration -----------------------------------------------------------

# Well-known captive portal detection endpoints. These return a known response
# when internet is available, and redirect (or modify content) behind a portal.
# We probe multiple to reduce false positives.
PROBE_URLS=(
    "http://detectportal.firefox.com/canonical.html"
    "http://connectivitycheck.gstatic.com/generate_204"
    "http://nmcheck.gnome.org/check_network_status.txt"
)
PROBE_EXPECTED=(
    "<meta http-equiv=\"refresh\" content=\"0;url=https://support.mozilla.org/kb/captive-portal\"/>"
    ""   # expects HTTP 204 (no content)
    "NetworkManager is online"
)
PROBE_EXPECTED_CODES=(
    "200"
    "204"
    "200"
)

LOCKFILE="/tmp/mt7902-captive-portal.lock"
LOGFILE="/tmp/mt7902-captive-portal.log"
MAX_RETRIES=3
RETRY_DELAY=2
PROBE_TIMEOUT=5
# Minimum seconds between portal opens (prevents spam)
COOLDOWN=30
COOLDOWN_FILE="/tmp/mt7902-captive-portal.last"

# --- Logging -----------------------------------------------------------------

log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOGFILE"
}

# --- Locking (prevent parallel runs) ----------------------------------------

acquire_lock() {
    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
        log "INFO" "Another instance is running, exiting"
        exit 0
    fi
}

# --- Cooldown (prevent spam) -------------------------------------------------

check_cooldown() {
    if [[ -f "$COOLDOWN_FILE" ]]; then
        local last
        last=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        if (( now - last < COOLDOWN )); then
            log "INFO" "Cooldown active ($(( now - last ))s < ${COOLDOWN}s), skipping"
            return 1
        fi
    fi
    return 0
}

set_cooldown() {
    date +%s > "$COOLDOWN_FILE"
}

# --- Network readiness -------------------------------------------------------

wait_for_ip() {
    local iface="$1"
    local attempts=10
    for (( i=1; i<=attempts; i++ )); do
        if ip addr show "$iface" 2>/dev/null | grep -q 'inet '; then
            log "INFO" "Interface $iface has an IP address"
            return 0
        fi
        sleep 1
    done
    log "WARN" "Interface $iface did not get an IP after ${attempts}s"
    return 1
}

# --- Captive portal detection ------------------------------------------------

# Returns 0 if a captive portal is detected, sets PORTAL_URL to the redirect target.
# Returns 1 if no portal (internet works fine).
# Returns 2 if network is down / unreachable.
detect_portal() {
    PORTAL_URL=""

    for idx in "${!PROBE_URLS[@]}"; do
        local url="${PROBE_URLS[$idx]}"
        local expected_body="${PROBE_EXPECTED[$idx]}"
        local expected_code="${PROBE_EXPECTED_CODES[$idx]}"

        log "INFO" "Probing: $url (expect HTTP $expected_code)"

        local response_file header_file
        response_file=$(mktemp /tmp/captive-probe-XXXXXX)
        header_file=$(mktemp /tmp/captive-headers-XXXXXX)

        local http_code
        http_code=$(curl \
            --silent \
            --max-time "$PROBE_TIMEOUT" \
            --max-redirs 0 \
            --output "$response_file" \
            --write-out '%{http_code}' \
            -D "$header_file" \
            "$url" 2>/dev/null) || {
            log "WARN" "Probe to $url failed (curl error)"
            rm -f "$response_file" "$header_file"
            continue
        }

        # Check for redirect (3xx) — this is the clearest captive portal signal
        if [[ "$http_code" =~ ^3[0-9]{2}$ ]]; then
            # Extract the Location header
            local location
            location=$(grep -i '^Location:' "$header_file" | head -1 | sed 's/^[Ll]ocation:[[:space:]]*//' | tr -d '\r\n')
            rm -f "$response_file" "$header_file"

            if [[ -n "$location" ]]; then
                log "INFO" "Portal detected via redirect: $location"
                PORTAL_URL="$location"
                return 0
            fi
        fi

        # Check for content modification (portal injected its own page)
        if [[ "$http_code" == "200" && "$expected_code" == "204" ]]; then
            # We expected 204 but got 200 — portal is serving its own page
            # Try to extract a redirect URL from the response body
            local body_url
            body_url=$(extract_url_from_body "$response_file")
            rm -f "$response_file" "$header_file"

            if [[ -n "$body_url" ]]; then
                log "INFO" "Portal detected via content injection: $body_url"
                PORTAL_URL="$body_url"
            else
                log "INFO" "Portal detected (got 200 instead of 204) but no URL found"
                # Use the probe URL itself — the browser will get redirected
                PORTAL_URL="$url"
            fi
            return 0
        fi

        if [[ "$http_code" == "200" && -n "$expected_body" ]]; then
            local body
            body=$(cat "$response_file")
            rm -f "$response_file" "$header_file"

            if [[ "$body" != *"$expected_body"* ]]; then
                # Content was modified — portal is injecting its page
                log "INFO" "Portal detected via content mismatch on $url"
                PORTAL_URL="$url"
                return 0
            fi
        else
            rm -f "$response_file" "$header_file"
        fi

        # If we got the expected response, internet is working
        if [[ "$http_code" == "$expected_code" ]]; then
            log "INFO" "Probe $url returned expected $expected_code — no portal"
            return 1
        fi
    done

    # All probes failed — network might be down
    log "WARN" "All probes inconclusive"
    return 2
}

# Try to extract a URL from an HTML body (common portal redirect patterns)
extract_url_from_body() {
    local file="$1"
    # Look for meta refresh, window.location, or href patterns
    grep -oP '(?:url=|URL=|window\.location\s*=\s*["\x27]|http-equiv="refresh"[^>]*url=)["\x27]?\K(https?://[^"\x27\s<>]+)' \
        "$file" 2>/dev/null | head -1 || true
}

# --- URL security validation -------------------------------------------------

# Validates a URL for safety. Returns 0 if safe, 1 if suspicious.
# Sets VALIDATION_MSG on failure explaining what's wrong.
validate_url() {
    local url="$1"
    VALIDATION_MSG=""

    # 1. Must not be empty
    if [[ -z "$url" ]]; then
        VALIDATION_MSG="Empty URL"
        return 1
    fi

    # 2. Must start with http:// or https:// — NOTHING ELSE
    if [[ ! "$url" =~ ^https?:// ]]; then
        VALIDATION_MSG="Blocked non-HTTP scheme: ${url%%:*}"
        return 1
    fi

    # 3. No javascript: or data: anywhere (encoded or not)
    local lower_url
    lower_url=$(echo "$url" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower_url" =~ (javascript|data|vbscript|file|ftp|smb|ssh): ]]; then
        VALIDATION_MSG="Blocked dangerous scheme embedded in URL"
        return 1
    fi

    # 4. No null bytes or control characters
    if [[ "$url" =~ [[:cntrl:]] ]]; then
        VALIDATION_MSG="URL contains control characters"
        return 1
    fi

    # 5. No @ sign in authority (credential-based URL confusion attacks)
    #    e.g. http://legitimate.com@evil.com/
    local authority
    authority=$(echo "$url" | sed -n 's|^https\?://\([^/]*\).*|\1|p')
    if [[ "$authority" == *"@"* ]]; then
        VALIDATION_MSG="URL contains @ in authority (possible credential/confusion attack): $authority"
        return 1
    fi

    # 6. Extract hostname and check it
    local hostname
    hostname="${authority%%:*}"  # strip port

    # No empty hostname
    if [[ -z "$hostname" ]]; then
        VALIDATION_MSG="Empty hostname"
        return 1
    fi

    # 7. Check for localhost / loopback — portals should never point here
    if [[ "$hostname" =~ ^(localhost|127\.|0\.|::1$|0\.0\.0\.0) ]]; then
        VALIDATION_MSG="URL points to localhost/loopback: $hostname"
        return 1
    fi

    # 8. Check for private/link-local IP ranges used in LAN attacks
    #    10.x.x.x, 172.16-31.x.x, 192.168.x.x are EXPECTED for captive portals
    #    (the gateway often hosts the portal), so we ALLOW these but flag them.
    #    169.254.x.x (link-local) is suspicious though.
    if [[ "$hostname" =~ ^169\.254\. ]]; then
        VALIDATION_MSG="URL points to link-local address: $hostname"
        return 1
    fi

    # 9. Excessively long URL (>2048 chars is suspicious)
    if (( ${#url} > 2048 )); then
        VALIDATION_MSG="URL suspiciously long (${#url} chars)"
        return 1
    fi

    # 10. Check for excessive percent-encoding (obfuscation)
    local pct_count
    pct_count=$(echo "$url" | grep -o '%' | wc -l)
    if (( pct_count > 20 )); then
        VALIDATION_MSG="URL has excessive percent-encoding ($pct_count occurrences) — possible obfuscation"
        return 1
    fi

    # 11. Check port if present — non-standard ports get a warning (not blocked)
    local port
    port=$(echo "$authority" | grep -oP ':\K[0-9]+$' || true)
    if [[ -n "$port" ]]; then
        case "$port" in
            80|443|8080|8443|8888|3128) ;; # common portal ports
            *)
                VALIDATION_MSG="Non-standard port $port"
                # Return special code 2 for "warn but allow"
                return 2
                ;;
        esac
    fi

    return 0
}

# --- Safe browser launch -----------------------------------------------------

# Opens a URL in the browser directly (not via xdg-open).
# Finds the user's actual browser and invokes it.
open_in_browser() {
    local url="$1"
    local browser=""

    # Find the display user (not root, since dispatcher runs as root)
    local display_user
    display_user=$(who | grep -oP '^\S+' | head -1)
    local user_home
    user_home=$(getent passwd "$display_user" | cut -d: -f6)

    # Detect the user's preferred browser from environment or common locations
    # Priority: BROWSER env, then firefox, then brave, then chromium
    local user_browser
    user_browser=$(su - "$display_user" -c 'echo $BROWSER' 2>/dev/null || true)

    if [[ -n "$user_browser" && -x "$(command -v "$user_browser" 2>/dev/null)" ]]; then
        browser="$user_browser"
    elif command -v firefox &>/dev/null; then
        browser="firefox"
    elif command -v brave &>/dev/null; then
        browser="brave"
    elif command -v chromium &>/dev/null; then
        browser="chromium"
    elif command -v google-chrome-stable &>/dev/null; then
        browser="google-chrome-stable"
    fi

    if [[ -z "$browser" ]]; then
        log "ERROR" "No supported browser found"
        notify_user "Captive Portal" "Login required but no browser found.\nURL: $url" "critical"
        return 1
    fi

    log "INFO" "Opening portal in $browser: $url"

    # Run as the display user, not root
    # Pass through DISPLAY/WAYLAND_DISPLAY for GUI access
    local display
    display=$(su - "$display_user" -c 'echo $DISPLAY' 2>/dev/null || echo ":0")
    local wayland_display
    wayland_display=$(su - "$display_user" -c 'echo $WAYLAND_DISPLAY' 2>/dev/null || true)
    local xauthority
    xauthority=$(su - "$display_user" -c 'echo $XAUTHORITY' 2>/dev/null || echo "$user_home/.Xauthority")
    local dbus_addr
    dbus_addr=$(su - "$display_user" -c 'echo $DBUS_SESSION_BUS_ADDRESS' 2>/dev/null || true)

    local env_vars="DISPLAY=$display"
    [[ -n "$wayland_display" ]] && env_vars="$env_vars WAYLAND_DISPLAY=$wayland_display"
    [[ -n "$xauthority" ]] && env_vars="$env_vars XAUTHORITY=$xauthority"
    [[ -n "$dbus_addr" ]] && env_vars="$env_vars DBUS_SESSION_BUS_ADDRESS=$dbus_addr"

    # Open in browser — the URL is already validated, pass it as a single argument
    # Using env to set display variables, su to drop privileges
    su - "$display_user" -c "env $env_vars $browser '$url'" &>/dev/null &
    disown

    return 0
}

# --- Desktop notifications ---------------------------------------------------

notify_user() {
    local title="$1"
    local body="$2"
    local urgency="${3:-normal}"  # low, normal, critical

    local display_user
    display_user=$(who | grep -oP '^\S+' | head -1)

    local display
    display=$(su - "$display_user" -c 'echo $DISPLAY' 2>/dev/null || echo ":0")
    local dbus_addr
    dbus_addr=$(su - "$display_user" -c 'echo $DBUS_SESSION_BUS_ADDRESS' 2>/dev/null || true)
    local xauthority
    xauthority=$(su - "$display_user" -c 'echo $XAUTHORITY' 2>/dev/null || true)

    local env_vars="DISPLAY=$display"
    [[ -n "$dbus_addr" ]] && env_vars="$env_vars DBUS_SESSION_BUS_ADDRESS=$dbus_addr"
    [[ -n "$xauthority" ]] && env_vars="$env_vars XAUTHORITY=$xauthority"

    su - "$display_user" -c "env $env_vars notify-send -u '$urgency' -a 'MT7902 WiFi' '$title' '$body'" 2>/dev/null || true
}

# --- Main flow ---------------------------------------------------------------

main() {
    local interface="${1:-}"
    local action="${2:-}"

    # Only act on interface-up events for wireless interfaces
    if [[ "$action" != "up" && "$action" != "connectivity-change" && "$action" != "check" ]]; then
        exit 0
    fi

    acquire_lock
    log "INFO" "=== Captive portal check triggered (interface=$interface, action=$action) ==="

    # Cooldown check
    if ! check_cooldown; then
        exit 0
    fi

    # Wait for IP if interface specified
    if [[ -n "$interface" ]]; then
        if ! wait_for_ip "$interface"; then
            log "WARN" "No IP on $interface, aborting"
            exit 0
        fi
    fi

    # Retry loop for portal detection
    local attempt
    for (( attempt=1; attempt<=MAX_RETRIES; attempt++ )); do
        local result=0
        detect_portal || result=$?

        case $result in
            0)  # Portal detected
                log "INFO" "Captive portal detected (attempt $attempt)"

                # Validate the URL
                local validation_result=0
                validate_url "$PORTAL_URL" || validation_result=$?

                case $validation_result in
                    0)  # Safe
                        log "INFO" "URL validated as safe: $PORTAL_URL"
                        notify_user "WiFi Login Required" "Opening captive portal login page:\n$PORTAL_URL"
                        set_cooldown
                        open_in_browser "$PORTAL_URL"
                        exit 0
                        ;;
                    2)  # Warning (non-standard port etc) — still open but warn
                        log "WARN" "URL has warning: $VALIDATION_MSG — opening anyway"
                        notify_user "WiFi Login — Unusual URL" "Portal URL uses $VALIDATION_MSG:\n$PORTAL_URL\n\nOpening anyway — verify this is your expected network." "normal"
                        set_cooldown
                        open_in_browser "$PORTAL_URL"
                        exit 0
                        ;;
                    1)  # Blocked — something is fishy
                        log "SECURITY" "URL BLOCKED: $VALIDATION_MSG — $PORTAL_URL"
                        notify_user "⚠ WiFi Portal Blocked" "Something looks fishy!\n\n$VALIDATION_MSG\n\nURL: $PORTAL_URL\n\nThis does not look like a legitimate captive portal. The URL was NOT opened." "critical"
                        set_cooldown
                        exit 0
                        ;;
                esac
                ;;
            1)  # No portal — internet is working
                log "INFO" "No captive portal detected — internet is working"
                exit 0
                ;;
            2)  # Inconclusive — retry
                if (( attempt < MAX_RETRIES )); then
                    log "INFO" "Probe inconclusive, retrying in ${RETRY_DELAY}s (attempt $attempt/$MAX_RETRIES)"
                    sleep "$RETRY_DELAY"
                fi
                ;;
        esac
    done

    log "WARN" "All detection attempts inconclusive — giving up"
    exit 0
}

main "$@"
