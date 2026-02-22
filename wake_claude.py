#!/usr/bin/env python3
"""Wake Claude Code — sends a trivial prompt to start the 5-hour token window."""

import logging
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import yaml

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "config.yaml"


def load_config():
    """Load and validate config.yaml."""
    with open(CONFIG_PATH) as f:
        config = yaml.safe_load(f)

    required = ["wake_time", "timezone", "prompt", "max_turns", "timeout_seconds"]
    for key in required:
        if key not in config:
            raise ValueError(f"Missing config key: {key}")

    return config


def run_claude(config):
    """Execute claude -p wrapped in script(1) for pseudo-TTY support."""
    prompt = config["prompt"]
    max_turns = config["max_turns"]

    # Build the claude command — shell-quoted inside script -c
    claude_cmd = f"claude -p \"{prompt}\" --max-turns {max_turns}"
    cmd = ["script", "-qec", claude_cmd, "/dev/null"]

    logging.info("Executing wake prompt at %s", datetime.now().isoformat())
    logging.debug("Command: %s", " ".join(cmd))

    env = os.environ.copy()
    env["DISABLE_AUTOUPDATER"] = "1"

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=config["timeout_seconds"],
            env=env,
        )

        logging.info("Claude exit code: %d", result.returncode)
        logging.info("Response: %s", result.stdout[:500])

        if result.stderr:
            stderr_lower = result.stderr.lower()
            auth_keywords = ["auth", "login", "unauthorized", "token"]
            if any(word in stderr_lower for word in auth_keywords):
                logging.error(
                    "AUTHENTICATION ERROR — re-run 'claude' on the Pi to "
                    "re-authenticate: %s",
                    result.stderr[:300],
                )
            else:
                logging.warning("stderr: %s", result.stderr[:300])

        return result.returncode

    except subprocess.TimeoutExpired:
        logging.error(
            "Claude timed out after %ds", config["timeout_seconds"]
        )
        return 1


def main():
    config = load_config()

    log_level = getattr(logging, config.get("log_level", "INFO"))
    logging.basicConfig(
        level=log_level,
        format="%(asctime)s [%(levelname)s] %(message)s",
        stream=sys.stdout,
    )

    logging.info("wake-claude starting")
    exit_code = run_claude(config)
    logging.info("wake-claude finished with exit code %d", exit_code)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
