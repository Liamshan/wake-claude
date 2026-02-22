# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Systemd-based utility running on a Raspberry Pi 5 ("Jarvis", aarch64, Debian Bookworm) that sends a trivial `claude -p` prompt at a scheduled time each morning. This starts the 5-hour rolling token window for a Claude Max subscription earlier, so the window resets mid-morning instead of afternoon.

## Architecture

Two systemd timers on the Pi:
1. **05:00** — `wake-claude-update.timer` runs `git pull --ff-only` then `install.sh --update-timer-only` to hot-reload the wake timer if `config.yaml` changed
2. **06:00** — `wake-claude.timer` runs `wake_claude.py` which wraps `claude -p` in `script -qec` (pseudo-TTY workaround for headless environments)

Schedule changes flow: GitHub Issue with @claude → PR modifying `config.yaml` → merge → next 5am git pull on Pi → timer hot-reload.

## Key Files

- `config.yaml` — Wake time, prompt, timezone. The `wake_time` field (HH:MM, 24h) is the primary thing users change.
- `wake_claude.py` — Reads config, executes `claude -p` via `script -qec` wrapper, logs to stdout (captured by journald).
- `install.sh` — Full Pi setup (default) or `--update-timer-only` mode for hot-reloading the timer's `OnCalendar` after config changes.
- `systemd/` — Four unit files (.service + .timer for both wake and update). The wake timer's `OnCalendar` is templated by `install.sh` from `config.yaml`.

## Rules for Modifications

- `config.yaml`: Only change values explicitly requested. `wake_time` must be "HH:MM" 24-hour format. `timezone` must be a valid IANA timezone string.
- `systemd/` unit files: Do not edit `OnCalendar` directly — it's overwritten by `install.sh` from `config.yaml`.
- `install.sh`: Only modify if explicitly asked for infrastructure changes.
- `Jarvis_Configuration.md`: Reference only — do not modify.
- Always validate YAML syntax before committing.

## Critical Technical Context

- **TTY requirement**: `claude -p` hangs without a TTY in headless/systemd contexts. The `script -qec "..." /dev/null` wrapper (util-linux) provides a pseudo-TTY. If this breaks, fallback is `unbuffer` from the `expect` package.
- **ARM64 install**: Use `npm install -g @anthropic-ai/claude-code`, NOT the native installer (has [known ARM64 bugs](https://github.com/anthropics/claude-code/issues/20490)).
- **npm globals without sudo**: Installed to `~/.npm-global/bin` via `npm config set prefix "$HOME/.npm-global"`.
- **`DISABLE_AUTOUPDATER=1`**: Set in both the systemd service and wake_claude.py to prevent Claude Code self-update during automated runs.

## Target Environment

- **Pi**: Raspberry Pi 5, user `pi`, Debian Bookworm, static IP `192.168.7.15`, MeshNet `100.72.153.252`
- **Deployed to**: `/home/pi/wake-claude/`
- **SSH**: `ssh pi@100.72.153.252` (MeshNet, works anywhere) or `ssh pi@192.168.7.15` (LAN only)
- **Full Pi details**: See `Jarvis_Configuration.md`

## Monitoring

```bash
journalctl -u wake-claude.service --since today    # Did the wake run?
journalctl -u wake-claude-update.service --since today  # Did git pull work?
systemctl list-timers wake-claude*                  # Next fire times
sudo systemctl start wake-claude.service            # Manual test
```

## Deployment Status

- **Deployed**: 2026-02-22. All phases (A, B, C) complete.
- **GitHub repo**: https://github.com/Liamshan/wake-claude
- **Pi status**: Both timers active, Claude Code authenticated, headless mode verified.
- **@claude GitHub Action**: Working (required `id-token: write` permission — added in second commit).

## Setup Lessons Learned

- `install.sh` ran successfully but the npm global PATH wasn't picked up until manually running `source ~/.bashrc`. On fresh installs, may need to reload the shell.
- The `claude-code-action` requires `id-token: write` in workflow permissions for OIDC authentication — not documented in PLAN.md originally.
- `DISABLE_AUTOUPDATER=1` is only needed during automated systemd runs (already set in the service unit). Interactive `claude` sessions on the Pi can auto-update normally.

## Implementation Reference

See `PLAN.md` for complete file specifications, install procedure, rationale for all technical decisions, and known risks with mitigations.
