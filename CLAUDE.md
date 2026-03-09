# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Claude Code statusline plugin that displays model info, context usage, rate limits, git branch, session duration, and thinking mode in the CLI status bar. Distributed as an npm package (`@kamranahmedse/claude-statusline`) and installed via `npx`.

## Architecture

Two files make up the entire tool:

- **`bin/install.js`** — Node.js installer/uninstaller (run via `npx`). Copies the statusline script to `~/.claude/statusline.sh`, backs up any existing one, and configures `~/.claude/settings.json` with the `statusLine` command entry. Supports `--uninstall` flag.

- **`bin/statusline.sh`** — Bash script that Claude Code invokes to render the status bar. Reads JSON from stdin (provided by Claude Code with model, context window, session info), extracts data with `jq`, and outputs ANSI-colored text. Fetches rate limit data from `https://api.anthropic.com/api/oauth/usage` using the user's OAuth token (resolved from env var, macOS Keychain, credentials file, or Linux secret-tool). Caches API responses in `/tmp/claude/statusline-usage-cache.json` for 60 seconds.

## Key Details

- No build step, no tests, no linter — the package ships raw JS and bash
- Runtime dependencies: `jq`, `curl`, `git` (checked by installer)
- The statusline script handles both macOS (`date -j`, `stat -f`) and Linux (`date -d`, `stat -c`) date/stat variants
- OAuth token resolution order: `$CLAUDE_CODE_OAUTH_TOKEN` env var → macOS Keychain (`security`) → `~/.claude/.credentials.json` → Linux `secret-tool`
