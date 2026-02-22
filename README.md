# Wake-Claude

A systemd utility running on a Raspberry Pi that sends a trivial `claude -p` prompt each morning at a scheduled time. This starts the 5-hour rolling token window for a Claude Max subscription earlier, so the window resets mid-morning instead of mid-afternoon.

## Why?

With Claude Max (5x plan), you get ~225 messages per 5-hour rolling window. The clock starts when you send your **first** message. If you start at 8 AM, your tokens don't reset until 1 PM.

By sending a throwaway prompt at 6 AM, the window starts 2 hours early and resets at **11 AM** — right in the middle of your most productive hours.

## How It Works

Two systemd timers on the Pi:

| Timer | Time | Action |
|-------|------|--------|
| `wake-claude-update.timer` | 05:00 | `git pull --ff-only` then hot-reload the wake timer if `config.yaml` changed |
| `wake-claude.timer` | 06:00 | Run `wake_claude.py` which executes `claude -p "Good morning..."` |

The `claude -p` command is wrapped in `script -qec` to provide a pseudo-TTY, which is required for headless/systemd environments.

## Quick Setup

### 1. Clone on the Pi

```bash
ssh pi@100.72.153.252
cd ~
git clone https://github.com/<your-username>/wake-claude.git
cd wake-claude
```

### 2. Run the installer

```bash
chmod +x install.sh
./install.sh
```

This installs Node.js 20, Claude Code (via npm), PyYAML, configures systemd timers, and sets the timezone.

### 3. Authenticate Claude Code (one-time, manual)

```bash
claude
```

Claude Code will display an OAuth URL. Open it in any browser, log in with your Claude Max account, then return to the terminal. Type `/exit` when done.

### 4. Verify headless mode works

```bash
script -qec "claude -p 'Hello, test'" /dev/null
```

You should see a response and a clean exit.

## Changing the Wake Time

**Option A** — Edit `config.yaml` directly and push:

```yaml
wake_time: "05:30"   # New time in 24-hour format
```

The next 5 AM git pull on the Pi will pick up the change and hot-reload the timer.

**Option B** — Open a GitHub Issue mentioning `@claude`:

> @claude Change the wake time to 5:30 AM

Claude will create a PR modifying `config.yaml`. After merge, the Pi picks it up automatically.

## Monitoring

```bash
# Did the wake run today?
journalctl -u wake-claude.service --since today

# Did git pull work?
journalctl -u wake-claude-update.service --since today

# Next fire times
systemctl list-timers wake-claude*

# Manual test
sudo systemctl start wake-claude.service
journalctl -u wake-claude.service --no-pager

# Watch logs in real time
journalctl -u wake-claude.service -f
```

## Troubleshooting

### Authentication errors

If you see `AUTHENTICATION ERROR` in the logs, the OAuth token has expired. SSH into the Pi and re-authenticate:

```bash
ssh pi@100.72.153.252
claude
# Follow the OAuth URL, then /exit
```

### Claude hangs (TTY issue)

The `script -qec` wrapper provides a pseudo-TTY for headless environments. If it stops working after a Claude Code update, try the fallback:

```bash
sudo apt install expect
# Then in wake_claude.py, replace the script command with:
# unbuffer claude -p "..." --max-turns 1
```

### Timer not firing

```bash
# Check timer status
systemctl list-timers wake-claude* --no-pager

# Check if timer is enabled
systemctl is-enabled wake-claude.timer

# Re-enable if needed
sudo systemctl enable --now wake-claude.timer
```

### Git pull conflicts

The update service uses `--ff-only`, which fails safely on conflicts (no merge commits). Check logs:

```bash
journalctl -u wake-claude-update.service --since today
```

If conflicted, SSH in and resolve manually:

```bash
cd ~/wake-claude
git reset --hard origin/main
```

## Project Structure

```
wake-claude/
├── config.yaml                  # Wake time, prompt, timezone
├── wake_claude.py               # Python wrapper for claude -p
├── install.sh                   # Pi setup + timer hot-reload
├── systemd/
│   ├── wake-claude.service      # Runs wake_claude.py
│   ├── wake-claude.timer        # Daily at configured time
│   ├── wake-claude-update.service  # git pull + timer reload
│   └── wake-claude-update.timer    # Daily at 05:00
├── .github/workflows/claude.yml # @claude GitHub Action
├── CLAUDE.md                    # Instructions for Claude agents
├── PLAN.md                      # Full implementation reference
└── README.md                    # This file
```

## Key Technical Decisions

- **systemd timers over cron**: `Persistent=true` fires missed jobs on boot. Built-in journald logging.
- **npm install over native installer**: The native Claude Code installer has [known ARM64 bugs](https://github.com/anthropics/claude-code/issues/20490).
- **`script -qec` TTY wrapper**: `claude -p` [hangs without a TTY](https://github.com/anthropics/claude-code/issues/9026) in headless environments.
- **Daily git pull over webhooks**: Zero networking complexity. No exposed ports. Changes take effect next day.
- **`DISABLE_AUTOUPDATER=1`**: Prevents Claude Code from self-updating during automated runs.
