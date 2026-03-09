# Statusline Optimization Design

Date: 2026-03-09
Status: Approved

## Goal

Optimize `statusline.sh` for performance and robustness without changing architecture.

## Changes

### 1. Merge jq calls for `$input` (statusline.sh)

Replace 6 separate `jq` invocations on `$input` with a single call that outputs tab-separated values, read into variables via `IFS=$'\t' read -r`.

Fields: `model_name`, `size`, `input_tokens`, `cache_create`, `cache_read`, `cwd`, `session_start`.

### 2. Merge jq calls for `$usage_data` (statusline.sh)

Replace ~8 separate `jq` invocations on `$usage_data` with a single call.

Fields: `five_hour_pct`, `five_hour_reset_iso`, `seven_day_pct`, `seven_day_reset_iso`, `extra_enabled`, `extra_pct`, `extra_used`, `extra_limit`.

### 3. Atomic cache write (statusline.sh)

Write API response to `${cache_file}.tmp` then `mv` to `${cache_file}`. Prevents multi-window race conditions where one process reads a half-written file.

### 4. Negative cache on API failure (statusline.sh)

When API call fails (no token, HTTP error, timeout), write a marker file `/tmp/claude/statusline-usage-error`. Skip retry for 300 seconds. Clear marker on success. Prevents repeated 5-second curl timeouts when token is invalid or network is down.

### 5. API error feedback (statusline.sh)

Display a dim `⚠` hint in the rate limit area when:
- No OAuth token available
- API returns an error response
- Rate limit data temporarily unavailable

When stale cache exists, still render it (graceful degradation). Only show error hint when no data at all.

### 6. Dynamic User-Agent (statusline.sh)

Replace hardcoded `claude-code/2.1.34` with runtime detection:
```
claude_ver=$(timeout 0.5 claude --version 2>/dev/null | head -1 || echo "unknown")
```

### 7. Cache cleanup on uninstall (install.js)

In `uninstall()`, after removing the statusline script, also delete:
- `/tmp/claude/statusline-usage-cache.json`
- `/tmp/claude/statusline-usage-cache.json.tmp`
- `/tmp/claude/statusline-usage-error`

## Out of Scope

- Rendering logic (colors, progress bar, layout)
- Install flow and config format
- Architecture changes (no background processes)
- New features
