# Wake-Claude: Implementation Plan

> **For future agents**: This document contains everything you need to build this project from scratch. Read it fully before starting. The companion file `Jarvis_Configuration.md` in this directory has networking and service details about the target Raspberry Pi.

---

## Problem Statement

The user has a **Claude Max 5x plan** ($100/mo, ~225 messages per 5-hour rolling window). They start work at 8am but exhaust tokens by noon. The 5-hour window is **rolling from first usage** — tokens used at 8am expire at 1pm. Afternoons and evenings go underutilized.

**The hack**: A Raspberry Pi sends a trivial `claude -p "Good morning"` at **6:00 AM** daily. This starts the 5-hour clock 2 hours early. The window now resets at **11:00 AM** instead of 1:00 PM, giving the user a fresh batch of tokens right in the middle of their most productive morning hours.

**Important**: There is also a 7-day rolling weekly cap (introduced August 2025). This trick shifts *when* the 5-hour window resets, not how many total weekly tokens are available.

---

## Target Environment

### Raspberry Pi 5 "Jarvis"
- **Architecture**: aarch64 (ARM64, 64-bit)
- **OS**: Debian GNU/Linux (Raspberry Pi OS Bookworm)
- **Username**: `pi`
- **LAN IP (static)**: `192.168.7.15`
- **MeshNet IP**: `100.72.153.252` (NordVPN, works from anywhere)
- **SSH**: `ssh pi@100.72.153.252` (preferred) or `ssh pi@192.168.7.15` (LAN only)
- **Existing services**: Docker (Pi-hole), webcam streamer, planned n8n
- **Uptime**: Stable, 63+ days observed, stable power supply
- **Router**: Eero (landlord-controlled, no admin access)

### Current state on the Pi
- **Claude Code**: NOT installed
- **Node.js**: Unknown (may or may not be installed)
- **Python 3**: Pre-installed on Pi OS
- **git**: Pre-installed on Pi OS
- **Docker**: Installed (used for Pi-hole)

### User's workstation
- Windows with WSL2 (where this repo lives)
- Path: `/mnt/c/Users/lpsha/Documents/ai_notes/wake-claude/`
- Has `gh` CLI for GitHub operations
- Has Claude Code installed and authenticated

### User's accounts
- **Claude Max 5x** subscription (claude.ai account, used for Claude Code auth)
- **Anthropic Console API key** (already exists, used for @claude GitHub Action on another repo — can be reused here)
- **GitHub account** with `gh` CLI authenticated

---

## Architecture

```
┌──────────────────────────────────────────────────┐
│          Raspberry Pi 5 "Jarvis"                 │
│          pi@192.168.7.15 / 100.72.153.252        │
│                                                  │
│  05:00  wake-claude-update.timer                 │
│         → git pull --ff-only origin main         │
│         → install.sh --update-timer-only         │
│           (hot-reloads timer if config changed)  │
│                                                  │
│  06:00  wake-claude.timer                        │
│         → wake_claude.py                         │
│         → claude -p "Good morning" --max-turns 1 │
│                                                  │
│  Logs:  journalctl -u wake-claude*               │
└──────────────────────────────────────────────────┘
         ▲  git pull (daily 5am)
         │
┌────────┴────────────────────┐
│  GitHub: wake-claude repo   │
│  config.yaml  ← @claude     │
│  modifies via Issues/PRs    │
└─────────────────────────────┘
```

**Flow**:
1. At 5:00 AM, systemd fires `wake-claude-update.service` which does `git pull --ff-only` and then runs `install.sh --update-timer-only` to hot-reload the wake timer if `config.yaml` changed.
2. At 6:00 AM, systemd fires `wake-claude.service` which runs `wake_claude.py`.
3. `wake_claude.py` reads `config.yaml`, then executes `claude -p "<prompt>" --max-turns 1` wrapped in `script -qec` for TTY support.
4. The trivial Claude response starts the 5-hour rolling window. Tokens reset at 11:00 AM.
5. To change the schedule: user opens a GitHub Issue mentioning `@claude`, which creates a PR modifying `config.yaml`. After merge, the 5 AM git pull picks it up.

---

## Repository Structure (Files to Create)

```
wake-claude/
├── PLAN.md                            # THIS FILE - implementation reference
├── CLAUDE.md                          # Instructions for @claude GitHub Action
├── README.md                          # Human documentation
├── Jarvis_Configuration.md            # EXISTING - Pi reference doc (don't modify)
├── config.yaml                        # Wake time, prompt, timezone config
├── wake_claude.py                     # Python wrapper script
├── install.sh                         # Pi setup script + timer hot-reload
├── systemd/
│   ├── wake-claude.service            # Oneshot: runs wake_claude.py
│   ├── wake-claude.timer              # Daily at 06:00 (configurable)
│   ├── wake-claude-update.service     # Oneshot: git pull + timer reload
│   └── wake-claude-update.timer       # Daily at 05:00
└── .github/
    └── workflows/
        └── claude.yml                 # @claude GitHub Action workflow
```

---

## Detailed File Specifications

### File 1: `config.yaml`

```yaml
# Wake-Claude Configuration
# ─────────────────────────
# This file controls when and how the daily Claude wake prompt fires.
# To change the schedule, edit wake_time and push to GitHub.
# Changes take effect after the 5:00 AM git pull on the Pi.

wake_time: "06:00"          # 24-hour format, local time
timezone: "America/Chicago" # IANA timezone (Pi's local time)
prompt: "Good morning. This is an automated wake ping to start my token window."
max_turns: 1                # Keep minimal - one turn, no tool use
timeout_seconds: 30         # Kill claude process if it hangs
log_level: "INFO"           # DEBUG, INFO, WARNING, ERROR
```

### File 2: `wake_claude.py`

**Purpose**: Reads config.yaml, executes `claude -p` with appropriate flags.

**Key implementation details**:
- Use `PyYAML` (`import yaml`) to parse config
- **CRITICAL**: Wrap the `claude -p` command in `script -qec "claude -p ..." /dev/null` to provide a pseudo-TTY. Without this, `claude -p` is known to hang in headless/non-TTY environments ([GitHub Issue #9026](https://github.com/anthropics/claude-code/issues/9026)). The `script` command is from `util-linux` (pre-installed on Debian).
  - `-q` = quiet (no "Script started" header)
  - `-e` = return child's exit code
  - `-c` = run command (next arg)
  - `/dev/null` = discard the typescript output file
- Set environment variable `DISABLE_AUTOUPDATER=1` to prevent Claude Code auto-update during the wake call
- Use `subprocess.run()` with `timeout=config["timeout_seconds"]` (30s default)
- Log to stdout — systemd captures this to journald automatically
- On timeout, log error and exit with code 1
- On auth errors (check stderr for "auth", "login", "unauthorized"), log a clear ERROR message

**Pseudocode**:
```python
#!/usr/bin/env python3
import subprocess, sys, os, yaml, logging
from pathlib import Path
from datetime import datetime

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "config.yaml"

def load_config():
    with open(CONFIG_PATH) as f:
        config = yaml.safe_load(f)
    required = ["wake_time", "timezone", "prompt", "max_turns", "timeout_seconds"]
    for key in required:
        if key not in config:
            raise ValueError(f"Missing config key: {key}")
    return config

def run_claude(config):
    cmd = [
        "script", "-qec",
        f'claude -p "{config["prompt"]}" --max-turns {config["max_turns"]}',
        "/dev/null"
    ]
    logging.info(f"Executing wake prompt at {datetime.now().isoformat()}")
    logging.debug(f"Command: {' '.join(cmd)}")

    env = os.environ.copy()
    env["DISABLE_AUTOUPDATER"] = "1"

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True,
            timeout=config["timeout_seconds"], env=env
        )
        logging.info(f"Claude exit code: {result.returncode}")
        logging.info(f"Response: {result.stdout[:500]}")
        if result.stderr:
            stderr_lower = result.stderr.lower()
            if any(word in stderr_lower for word in ["auth", "login", "unauthorized", "token"]):
                logging.error(f"AUTHENTICATION ERROR - re-run 'claude' on the Pi to re-authenticate: {result.stderr[:300]}")
            else:
                logging.warning(f"stderr: {result.stderr[:300]}")
        return result.returncode
    except subprocess.TimeoutExpired:
        logging.error(f"Claude timed out after {config['timeout_seconds']}s")
        return 1

def main():
    config = load_config()
    log_level = getattr(logging, config.get("log_level", "INFO"))
    logging.basicConfig(level=log_level, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stdout)
    logging.info("wake-claude starting")
    exit_code = run_claude(config)
    logging.info(f"wake-claude finished with exit code {exit_code}")
    sys.exit(exit_code)

if __name__ == "__main__":
    main()
```

### File 3: `install.sh`

**Purpose**: One-command setup on the Pi. Also supports `--update-timer-only` mode for hot-reloading the timer after git pull.

**Full install mode** (run once during setup: `./install.sh`):
1. Check/install Python 3 (should be pre-installed)
2. Check/install PyYAML: `sudo apt install -y python3-yaml`
3. Check/install Node.js 20: `curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs`
4. Configure npm global directory (no sudo for npm): `mkdir -p ~/.npm-global && npm config set prefix "$HOME/.npm-global"` and add to PATH in `~/.bashrc`
5. Install Claude Code: `npm install -g @anthropic-ai/claude-code` (with `DISABLE_AUTOUPDATER=1`)
6. Parse `wake_time` from `config.yaml` using Python one-liner: `python3 -c "import yaml; print(yaml.safe_load(open('config.yaml'))['wake_time'])"`
7. Parse `timezone` similarly and set it: `sudo timedatectl set-timezone "America/Chicago"`
8. Copy systemd units to `/etc/systemd/system/`, substituting `OnCalendar` in wake-claude.timer with the parsed wake_time
9. Install sudoers rule at `/etc/sudoers.d/wake-claude` for timer hot-reload (narrow scope: only sed on the timer file + systemctl daemon-reload + systemctl restart)
10. `sudo systemctl daemon-reload && sudo systemctl enable --now wake-claude.timer wake-claude-update.timer`
11. Print status and auth instructions

**`--update-timer-only` mode** (called by ExecStartPost after git pull):
1. Parse `wake_time` from `config.yaml`
2. Read current `OnCalendar` from `/etc/systemd/system/wake-claude.timer`
3. If different: `sudo sed -i "s/^OnCalendar=.*/OnCalendar=*-*-* ${WAKE_TIME}:00/" /etc/systemd/system/wake-claude.timer` + `sudo systemctl daemon-reload` + `sudo systemctl restart wake-claude.timer`
4. If same: log "no change" and exit

### File 4: `systemd/wake-claude.service`

```ini
[Unit]
Description=Wake Claude Code - daily token window trigger
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=pi
Group=pi
WorkingDirectory=/home/pi/wake-claude
ExecStart=/usr/bin/python3 /home/pi/wake-claude/wake_claude.py
TimeoutStartSec=60
Environment=HOME=/home/pi
Environment=PATH=/home/pi/.npm-global/bin:/home/pi/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=DISABLE_AUTOUPDATER=1
StandardOutput=journal
StandardError=journal
SyslogIdentifier=wake-claude
```

### File 5: `systemd/wake-claude.timer`

```ini
[Unit]
Description=Timer for Wake Claude Code

[Timer]
OnCalendar=*-*-* 06:00:00
Persistent=true
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
```

- `Persistent=true`: If Pi was off at 6am, fires immediately on boot
- `RandomizedDelaySec=30`: Minor jitter (good practice)
- The `OnCalendar` line gets rewritten by `install.sh` from `config.yaml`

### File 6: `systemd/wake-claude-update.service`

```ini
[Unit]
Description=Git pull wake-claude repo for config updates
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=pi
Group=pi
WorkingDirectory=/home/pi/wake-claude
ExecStart=/usr/bin/git pull --ff-only origin main
ExecStartPost=/bin/bash -c '/home/pi/wake-claude/install.sh --update-timer-only'
TimeoutStartSec=30
Environment=HOME=/home/pi
StandardOutput=journal
StandardError=journal
SyslogIdentifier=wake-claude-update
```

- `--ff-only`: Fails safely on conflicts instead of creating merge commits
- `ExecStartPost`: Only runs if `ExecStart` (git pull) succeeded

### File 7: `systemd/wake-claude-update.timer`

```ini
[Unit]
Description=Timer for wake-claude git pull

[Timer]
OnCalendar=*-*-* 05:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

### File 8: `CLAUDE.md`

```markdown
# CLAUDE.md

## Repository Purpose

This is a systemd-based automation utility that runs on a Raspberry Pi 5 ("Jarvis").
It sends a trivial prompt to Claude Code at a configured time each morning to start
the 5-hour rolling token window for a Claude Max subscription.

## Key Files

- `config.yaml` - The wake schedule configuration. The `wake_time` field controls
  when the daily prompt fires. Format: "HH:MM" in 24-hour time.
- `wake_claude.py` - Python wrapper that reads config.yaml and executes `claude -p`.
- `install.sh` - Setup script. Also supports `--update-timer-only` for hot-reloading
  the systemd timer after config changes.
- `systemd/` - Contains .service and .timer unit files.

## Rules for Modifications

1. When modifying `config.yaml`, only change values the user explicitly requests.
2. The `wake_time` must be in "HH:MM" 24-hour format.
3. Valid timezone values are IANA timezone strings (e.g., "America/Chicago").
4. Do not modify `install.sh` unless the user explicitly asks for infrastructure changes.
5. Do not modify systemd unit files directly — they are templated by install.sh.
6. When creating PRs, include a clear description of what changed and why.
7. Always validate that YAML syntax is correct before committing.
```

### File 9: `.github/workflows/claude.yml`

```yaml
name: Claude Code
on:
  issue_comment:
    types: [created]
  issues:
    types: [opened, assigned]
  pull_request_review_comment:
    types: [created]

jobs:
  claude:
    if: |
      (github.event_name == 'issue_comment' && contains(github.event.comment.body, '@claude')) ||
      (github.event_name == 'issues' && contains(github.event.issue.body, '@claude')) ||
      (github.event_name == 'pull_request_review_comment' && contains(github.event.comment.body, '@claude'))
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
      issues: write
    steps:
      - uses: actions/checkout@v4
      - uses: anthropics/claude-code-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          claude_args: "--max-turns 10"
```

### File 10: `README.md`

Write a README covering:
- What this project does and why (the token window shift trick)
- Quick setup instructions (clone on Pi, run install.sh, authenticate)
- How to change the wake time (edit config.yaml or use GitHub Issues with @claude)
- How to check logs (`journalctl -u wake-claude*`)
- How to test manually (`sudo systemctl start wake-claude.service`)
- Troubleshooting (auth errors, TTY hangs, timer not firing)

---

## Installation Procedure (Step by Step)

### Phase A: Build on workstation (WSL2)

**Step 1**: Create all files listed above in `/mnt/c/Users/lpsha/Documents/ai_notes/wake-claude/`

**Step 2**: Initialize git repo and push to GitHub:
```bash
cd /mnt/c/Users/lpsha/Documents/ai_notes/wake-claude
git init
git add .
git commit -m "Initial commit: wake-claude utility"
gh repo create wake-claude --public --source=. --push
```

**Step 3**: Configure GitHub repo:
- Go to repo Settings > Secrets and variables > Actions > New repository secret
- Name: `ANTHROPIC_API_KEY`, Value: your existing Console API key (same one used for your other repo)
- Go to https://github.com/apps/claude and install it on the `wake-claude` repository (if not already installed org-wide, it can be installed per-repo)

### Phase B: Set up Raspberry Pi

**Step 4**: SSH into Jarvis:
```bash
ssh pi@100.72.153.252
```

**Step 5**: Clone the repo:
```bash
cd ~
git clone https://github.com/<your-username>/wake-claude.git
cd wake-claude
```

**Step 6**: Run the installer:
```bash
chmod +x install.sh
./install.sh
```
This handles: Node.js 20, npm global config, Claude Code, PyYAML, timezone, systemd units, timers.

**Step 7**: Authenticate Claude Code (MANUAL, ONE-TIME):
```bash
claude
```
- Claude Code will display an OAuth URL
- Copy the URL and open it in any browser (your workstation, phone, etc.)
- Log in with your Claude Max account
- Return to the SSH terminal — it should detect the auth
- Type `/exit` to quit

**Step 8**: Verify auth works in headless mode:
```bash
script -qec "claude -p 'Hello, this is a test'" /dev/null
```
You should see a response and the command should exit cleanly.

### Phase C: Verify

**Step 9**: Test the wake service:
```bash
sudo systemctl start wake-claude.service
journalctl -u wake-claude.service --no-pager
```

**Step 10**: Check timer schedule:
```bash
systemctl list-timers wake-claude* --no-pager
```
Expected: `wake-claude.timer` next fire at 06:00, `wake-claude-update.timer` next fire at 05:00.

**Step 11**: Test git pull service:
```bash
sudo systemctl start wake-claude-update.service
journalctl -u wake-claude-update.service --no-pager
```

**Step 12**: Test @claude integration:
- Open a GitHub Issue with body: `@claude What files are in this repo?`
- Verify Claude responds with a comment or PR

**Step 13**: Wait for next morning, then check:
```bash
ssh pi@100.72.153.252
journalctl -u wake-claude.service --since today
```

---

## Key Technical Decisions & Rationale

| Decision | Why |
|----------|-----|
| **systemd timers** (not cron) | `Persistent=true` fires missed jobs on boot — critical for a Pi that may occasionally reboot. Built-in journald logging. Overlap prevention. |
| **npm install** (not native installer) | The native Claude Code installer has [known ARM64 bugs](https://github.com/anthropics/claude-code/issues/20490) — it silently fails on Pi. npm works reliably. |
| **`script -qec` TTY wrapper** | `claude -p` hangs without a TTY in headless environments ([Issue #9026](https://github.com/anthropics/claude-code/issues/9026)). The `script` command (from util-linux, pre-installed) provides a pseudo-TTY. |
| **Daily git pull** (not webhooks) | Zero networking complexity. No need to expose the Pi to the internet. No Cloudflare Tunnel, no open ports. Schedule changes aren't urgent — they take effect next day. |
| **No Docker** for this utility | systemd handles scheduling + logging natively. Docker would add auth complexity (mounting ~/.claude) and resource overhead for no benefit. Pi-hole already uses Docker. |
| **No Python venv** | Only dependency is PyYAML (available as system package `python3-yaml`). No version conflicts. Keeps it simple. |
| **`--max-turns 1`** | Ensures the wake call is a single trivial exchange. No tool calls, no multi-turn. Uses ~1 of 225 available messages. |
| **`DISABLE_AUTOUPDATER=1`** | Prevents Claude Code from trying to self-update during the automated wake call. |

---

## Known Risks & Mitigations

### 1. Claude Code TTY hang (Medium likelihood)
The `script -qec` workaround may break in future Claude Code versions.
- **Mitigation**: 30-second Python timeout + 60-second systemd `TimeoutStartSec`
- **Fallback**: Install `expect` package and use `unbuffer claude -p "..."` instead

### 2. OAuth token expiration (Unknown likelihood)
Anthropic doesn't document token lifetime. It may expire after weeks/months.
- **Mitigation**: `wake_claude.py` checks stderr for auth-related keywords and logs ERROR level
- **Recovery**: SSH in, run `claude`, re-authenticate

### 3. npm install fails on ARM64 (Medium likelihood)
Some Claude Code npm versions have ARM issues.
- **Mitigation**: If latest fails, pin to known-working version: `npm install -g @anthropic-ai/claude-code@0.2.114`
- **Detection**: `install.sh` verifies the `claude` command exists after install

### 4. Git pull conflicts (Low likelihood)
Single user, single branch — conflicts are unlikely.
- **Mitigation**: `--ff-only` fails safely. Error appears in `journalctl -u wake-claude-update.service`

### 5. Wake message consuming meaningful tokens (Low)
- **Mitigation**: `--max-turns 1` with a trivial prompt. Uses ~1 of 225 messages.

---

## Monitoring Commands (Quick Reference)

```bash
# Check if the wake ran today
journalctl -u wake-claude.service --since today

# Watch in real time
journalctl -u wake-claude.service -f

# Check timer status and next fire time
systemctl list-timers wake-claude*

# Check git pull status
journalctl -u wake-claude-update.service --since today

# Full log history
journalctl -u wake-claude.service --since "7 days ago"

# Manual test
sudo systemctl start wake-claude.service && journalctl -u wake-claude.service -f
```

---

## Dependencies (All Free & Open Source)

| Tool | Purpose | Install Method |
|------|---------|---------------|
| Python 3 | Wrapper script runtime | Pre-installed on Pi OS |
| PyYAML | Parse config.yaml | `sudo apt install python3-yaml` |
| Node.js 20 | Claude Code runtime | NodeSource apt repo |
| npm | Package manager | Comes with Node.js |
| Claude Code | The CLI tool | `npm install -g @anthropic-ai/claude-code` |
| systemd | Scheduling & logging | Pre-installed on Pi OS |
| util-linux (`script`) | PTY wrapper for headless | Pre-installed on Debian |
| git | Repo sync | Pre-installed on Pi OS |

---

## Future Enhancements (Out of Scope for v1)

- **Failure notifications**: n8n workflow on the Pi sends push notification on wake failure
- **Usage tracking**: Log response metadata to track actual token consumption
- **Multi-window**: Send a second wake message at a different time for a second work session
- **Health dashboard**: Simple web page showing wake history and next scheduled run
