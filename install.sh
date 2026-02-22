#!/usr/bin/env bash
# install.sh — Full setup for wake-claude on Raspberry Pi 5, or timer-only hot-reload.
#
# Usage:
#   ./install.sh                    Full install (run once on fresh Pi)
#   ./install.sh --update-timer-only   Hot-reload wake timer from config.yaml
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"
SYSTEMD_DIR="/etc/systemd/system"
TIMER_UNIT="wake-claude.timer"

# ── Helpers ──────────────────────────────────────────────────────────
log()  { echo "[wake-claude install] $*"; }
die()  { echo "[wake-claude install] ERROR: $*" >&2; exit 1; }

parse_config_key() {
    # Extract a top-level scalar from config.yaml via python3+PyYAML
    python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG_FILE'))['$1'])"
}

# ── Timer-only hot-reload mode ───────────────────────────────────────
update_timer_only() {
    log "Running in --update-timer-only mode"

    WAKE_TIME=$(parse_config_key wake_time)
    NEW_CALENDAR="*-*-* ${WAKE_TIME}:00"
    log "Desired OnCalendar: $NEW_CALENDAR"

    CURRENT_CALENDAR=$(grep '^OnCalendar=' "$SYSTEMD_DIR/$TIMER_UNIT" | head -1 | cut -d= -f2)
    log "Current OnCalendar: $CURRENT_CALENDAR"

    if [ "$NEW_CALENDAR" = "$CURRENT_CALENDAR" ]; then
        log "No change — timer already set to $WAKE_TIME. Nothing to do."
        exit 0
    fi

    log "Updating timer: $CURRENT_CALENDAR → $NEW_CALENDAR"
    sudo sed -i "s|^OnCalendar=.*|OnCalendar=${NEW_CALENDAR}|" "$SYSTEMD_DIR/$TIMER_UNIT"
    sudo systemctl daemon-reload
    sudo systemctl restart "$TIMER_UNIT"
    log "Timer hot-reloaded successfully. Next fire:"
    systemctl list-timers "$TIMER_UNIT" --no-pager
    exit 0
}

# Dispatch early if flag is set
if [[ "${1:-}" == "--update-timer-only" ]]; then
    update_timer_only
fi

# ── Full install ─────────────────────────────────────────────────────
log "Starting full install..."

# 1. Python 3 (should be pre-installed)
if command -v python3 &>/dev/null; then
    log "Python 3 found: $(python3 --version)"
else
    die "Python 3 not found — install it first"
fi

# 2. PyYAML (system package)
log "Installing python3-yaml..."
sudo apt-get update -qq
sudo apt-get install -y python3-yaml

# 3. Node.js 20 (via NodeSource)
if command -v node &>/dev/null; then
    log "Node.js already installed: $(node --version)"
else
    log "Installing Node.js 20 via NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
    log "Node.js installed: $(node --version)"
fi

# 4. npm global directory (no sudo needed for npm install -g)
NPM_GLOBAL="$HOME/.npm-global"
if [ ! -d "$NPM_GLOBAL" ]; then
    log "Configuring npm global prefix → $NPM_GLOBAL"
    mkdir -p "$NPM_GLOBAL"
    npm config set prefix "$NPM_GLOBAL"
fi

# Ensure PATH includes npm-global in .bashrc
if ! grep -q '.npm-global/bin' "$HOME/.bashrc" 2>/dev/null; then
    log "Adding $NPM_GLOBAL/bin to PATH in .bashrc"
    echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.bashrc"
fi
export PATH="$NPM_GLOBAL/bin:$PATH"

# 5. Install Claude Code via npm
log "Installing Claude Code..."
DISABLE_AUTOUPDATER=1 npm install -g @anthropic-ai/claude-code

if command -v claude &>/dev/null; then
    log "Claude Code installed: $(claude --version 2>/dev/null || echo 'version check skipped')"
else
    die "Claude Code install failed — 'claude' command not found in PATH"
fi

# 6. Parse config values
WAKE_TIME=$(parse_config_key wake_time)
TIMEZONE=$(parse_config_key timezone)
log "Config: wake_time=$WAKE_TIME  timezone=$TIMEZONE"

# 7. Set timezone
log "Setting timezone to $TIMEZONE"
sudo timedatectl set-timezone "$TIMEZONE"

# 8. Install systemd units
log "Installing systemd units..."
for unit in wake-claude.service wake-claude.timer wake-claude-update.service wake-claude-update.timer; do
    sudo cp "$SCRIPT_DIR/systemd/$unit" "$SYSTEMD_DIR/$unit"
done

# Substitute OnCalendar in wake-claude.timer with configured wake_time
sudo sed -i "s|^OnCalendar=.*|OnCalendar=*-*-* ${WAKE_TIME}:00|" "$SYSTEMD_DIR/$TIMER_UNIT"
log "Set $TIMER_UNIT OnCalendar to *-*-* ${WAKE_TIME}:00"

# 9. Install sudoers rule for timer hot-reload (passwordless, narrow scope)
SUDOERS_FILE="/etc/sudoers.d/wake-claude"
log "Installing sudoers rule for timer hot-reload..."
sudo tee "$SUDOERS_FILE" > /dev/null << 'EOF'
# Allow pi user to hot-reload wake-claude timer without password
pi ALL=(root) NOPASSWD: /usr/bin/sed -i s|^OnCalendar=.*|OnCalendar=*| /etc/systemd/system/wake-claude.timer
pi ALL=(root) NOPASSWD: /usr/bin/systemctl daemon-reload
pi ALL=(root) NOPASSWD: /usr/bin/systemctl restart wake-claude.timer
EOF
sudo chmod 0440 "$SUDOERS_FILE"

# 10. Enable and start timers
log "Enabling and starting timers..."
sudo systemctl daemon-reload
sudo systemctl enable --now wake-claude.timer wake-claude-update.timer

# 11. Status report
log ""
log "════════════════════════════════════════════════════"
log "  Installation complete!"
log "════════════════════════════════════════════════════"
log ""
log "  Timers active:"
systemctl list-timers wake-claude* --no-pager
log ""
log "  NEXT STEP: Authenticate Claude Code (one-time):"
log "    claude"
log "  Then follow the OAuth URL in your browser."
log "  After auth, test headless mode:"
log "    script -qec \"claude -p 'Hello, test'\" /dev/null"
log ""
