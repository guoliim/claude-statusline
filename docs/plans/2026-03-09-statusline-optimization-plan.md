# Statusline Optimization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Optimize `statusline.sh` for performance (reduce fork/exec count) and robustness (atomic writes, negative cache, error feedback), plus minor cleanup in `install.js`.

**Architecture:** No architecture changes. All optimizations are in-place modifications to the existing two files. The statusline remains a single bash script invoked by Claude Code via stdin JSON.

**Tech Stack:** Bash, jq, Node.js (installer only)

---

### Task 1: Merge `$input` jq calls (6→1)

**Files:**
- Modify: `bin/statusline.sh:118-127` (Extract JSON data section)
- Modify: `bin/statusline.sh:147` (cwd extraction)
- Modify: `bin/statusline.sh:161` (session_start extraction)

**Step 1: Replace lines 118-127 and remove lines 147, 161**

Replace the six separate `jq` calls on `$input` with a single tab-separated extraction. Also remove the later standalone `cwd` and `session_start` extractions since they'll be included in the single call.

Replace `bin/statusline.sh:118-127` with:

```bash
# ── Extract JSON data ───────────────────────────────────
IFS=$'\t' read -r model_name size input_tokens cache_create cache_read cwd session_start <<< \
  "$(echo "$input" | jq -r '[
    (.model.display_name // "Claude"),
    (.context_window.context_window_size // 200000 | tostring),
    (.context_window.current_usage.input_tokens // 0 | tostring),
    (.context_window.current_usage.cache_creation_input_tokens // 0 | tostring),
    (.context_window.current_usage.cache_read_input_tokens // 0 | tostring),
    (.cwd // ""),
    (.session.start_time // "")
  ] | join("\t")')"
```

Then at line 147, replace:
```bash
cwd=$(echo "$input" | jq -r '.cwd // ""')
```
with:
```bash
# cwd already extracted above
```
(Just remove the line; `cwd` is already set.)

At line 161, replace:
```bash
session_start=$(echo "$input" | jq -r '.session.start_time // empty')
```
with nothing (remove the line; `session_start` is already set).

**Step 2: Verify script still parses correctly**

Run manually:
```bash
echo '{"model":{"display_name":"Claude Opus 4"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":5000,"cache_creation_input_tokens":100,"cache_read_input_tokens":200}},"cwd":"/tmp","session":{"start_time":"2026-03-09T10:00:00Z"}}' | bash bin/statusline.sh
```
Expected: Output with "Claude Opus 4", a percentage, "/tmp" directory info.

**Step 3: Commit**

```bash
git add bin/statusline.sh
git commit -m "perf: merge input JSON jq calls from 6 to 1"
```

---

### Task 2: Merge `$usage_data` jq calls (8→1)

**Files:**
- Modify: `bin/statusline.sh:282-320` (Rate limit lines section)

**Step 1: Replace lines 282-320**

Replace the multiple jq calls on `$usage_data` with a single extraction, then use the pre-extracted variables for rendering.

Replace `bin/statusline.sh:282-320` with:

```bash
if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
    bar_width=10

    IFS=$'\t' read -r five_hour_pct five_hour_reset_iso seven_day_pct seven_day_reset_iso \
        extra_enabled extra_pct extra_used extra_limit <<< \
      "$(echo "$usage_data" | jq -r '[
        (.five_hour.utilization // 0 | round | tostring),
        (.five_hour.resets_at // ""),
        (.seven_day.utilization // 0 | round | tostring),
        (.seven_day.resets_at // ""),
        (.extra_usage.is_enabled // false | tostring),
        (.extra_usage.utilization // 0 | round | tostring),
        (.extra_usage.used_credits // 0 | . / 100 | tostring),
        (.extra_usage.monthly_limit // 0 | . / 100 | tostring)
      ] | join("\t")')"

    five_hour_reset=$(format_reset_time "$five_hour_reset_iso" "time")
    five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width")
    five_hour_pct_color=$(color_for_pct "$five_hour_pct")
    five_hour_pct_fmt=$(printf "%3d" "$five_hour_pct")

    rate_lines+="${white}current${reset} ${five_hour_bar} ${five_hour_pct_color}${five_hour_pct_fmt}%${reset} ${dim}⟳${reset} ${white}${five_hour_reset}${reset}"

    seven_day_reset=$(format_reset_time "$seven_day_reset_iso" "datetime")
    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width")
    seven_day_pct_color=$(color_for_pct "$seven_day_pct")
    seven_day_pct_fmt=$(printf "%3d" "$seven_day_pct")

    rate_lines+="\n${white}weekly${reset}  ${seven_day_bar} ${seven_day_pct_color}${seven_day_pct_fmt}%${reset} ${dim}⟳${reset} ${white}${seven_day_reset}${reset}"

    if [ "$extra_enabled" = "true" ]; then
        extra_bar=$(build_bar "$extra_pct" "$bar_width")
        extra_pct_color=$(color_for_pct "$extra_pct")

        extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if [ -z "$extra_reset" ]; then
            extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        fi

        extra_col="${white}extra${reset}   ${extra_bar} ${extra_pct_color}\$${extra_used}${dim}/${reset}${white}\$${extra_limit}${reset}"
        extra_reset_line="${dim}resets ${reset}${white}${extra_reset}${reset}"
        rate_lines+="\n${extra_col}"
        rate_lines+="\n${extra_reset_line}"
    fi
fi
```

Key change: `awk '{printf "%.0f", $1}'` is replaced by jq's `round` and `(. / 100)` to do all number formatting inside jq.

**Step 2: Verify**

Same manual test as Task 1. Rate limit area will be empty without a real token, but the script should not error.

**Step 3: Commit**

```bash
git add bin/statusline.sh
git commit -m "perf: merge usage data jq calls from 8 to 1"
```

---

### Task 3: Atomic cache write + negative cache

**Files:**
- Modify: `bin/statusline.sh:241-277` (Fetch usage data section)

**Step 1: Add negative cache variables and atomic write logic**

Replace `bin/statusline.sh:241-277` with:

```bash
# ── Fetch usage data (cached) ──────────────────────────
cache_file="/tmp/claude/statusline-usage-cache.json"
cache_max_age=60
err_cache="/tmp/claude/statusline-usage-error"
err_max_age=300
mkdir -p /tmp/claude

needs_refresh=true
usage_data=""
api_error=""
now=$(date +%s)

if [ -f "$cache_file" ]; then
    cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
    cache_age=$(( now - cache_mtime ))
    if [ "$cache_age" -lt "$cache_max_age" ]; then
        needs_refresh=false
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi
fi

# Skip refresh if in negative cache period (recent API failure)
if $needs_refresh && [ -f "$err_cache" ]; then
    err_mtime=$(stat -c %Y "$err_cache" 2>/dev/null || stat -f %m "$err_cache" 2>/dev/null)
    if [ -n "$err_mtime" ]; then
        err_age=$(( now - err_mtime ))
        if [ "$err_age" -lt "$err_max_age" ]; then
            needs_refresh=false
            api_error="cached"
        fi
    fi
fi

if $needs_refresh; then
    token=$(get_oauth_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        claude_ver=$(timeout 0.5 claude --version 2>/dev/null | head -1 || echo "unknown")
        response=$(curl -s --max-time 5 \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-statusline/1.0 (claude-code/${claude_ver})" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
            usage_data="$response"
            echo "$response" > "${cache_file}.tmp" && mv "${cache_file}.tmp" "$cache_file"
            rm -f "$err_cache"
        elif [ -n "$response" ] && echo "$response" | jq -e '.error' >/dev/null 2>&1; then
            api_error=$(echo "$response" | jq -r '.error.type // "unknown"')
            touch "$err_cache"
        else
            api_error="request_failed"
            touch "$err_cache"
        fi
    else
        api_error="no_token"
    fi
    # Fall back to stale cache if available
    if [ -z "$usage_data" ] && [ -f "$cache_file" ]; then
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi
fi
```

This combines Task 3 (atomic write), Task 4 (negative cache), Task 5 (error tracking via `$api_error`), and Task 6 (dynamic User-Agent) into a single coherent rewrite of the fetch section.

**Step 2: Verify atomic write**

```bash
ls -la /tmp/claude/  # should not have .tmp file lingering after successful write
```

**Step 3: Commit**

```bash
git add bin/statusline.sh
git commit -m "fix: atomic cache write, negative cache, dynamic user-agent"
```

---

### Task 4: API error feedback in output

**Files:**
- Modify: `bin/statusline.sh:323-327` (Output section)

**Step 1: Add error hint to output section**

Replace `bin/statusline.sh:323-327` (the Output section) with:

```bash
# ── Output ──────────────────────────────────────────────
printf "%b" "$line1"
if [ -n "$rate_lines" ]; then
    printf "\n\n%b" "$rate_lines"
elif [ -n "$api_error" ]; then
    case "$api_error" in
        no_token)  printf "\n\n${dim}⚠ no token — rate limits unavailable${reset}" ;;
        cached)    printf "\n\n${dim}⚠ rate limits temporarily unavailable${reset}" ;;
        *)         printf "\n\n${dim}⚠ api error (${api_error})${reset}" ;;
    esac
fi

exit 0
```

Error hints only appear when there is no usage data at all (no cache, no API response). If stale cache exists, it renders normally with no error shown.

**Step 2: Verify with empty input**

```bash
echo '{}' | bash bin/statusline.sh
```
Expected: First line renders with defaults, no crash, possibly an error hint if no token.

**Step 3: Commit**

```bash
git add bin/statusline.sh
git commit -m "feat: show dim error hint when rate limit data unavailable"
```

---

### Task 5: Cache cleanup on uninstall

**Files:**
- Modify: `bin/install.js:60-98` (uninstall function)

**Step 1: Add cache cleanup after settings cleanup**

In `bin/install.js`, add the following block after the settings cleanup (after line 93, before the "Done" log):

```js
  // Clean up runtime cache files
  const tmpDir = path.join(os.tmpdir(), "claude");
  const cacheFiles = [
    path.join(tmpDir, "statusline-usage-cache.json"),
    path.join(tmpDir, "statusline-usage-cache.json.tmp"),
    path.join(tmpDir, "statusline-usage-error"),
  ];
  let cleaned = 0;
  for (const f of cacheFiles) {
    if (fs.existsSync(f)) {
      fs.unlinkSync(f);
      cleaned++;
    }
  }
  if (cleaned > 0) {
    success(`Cleaned up ${cleaned} cache file${cleaned > 1 ? "s" : ""}`);
  }
```

**Step 2: Verify uninstall still works**

```bash
node bin/install.js --uninstall
```
Expected: Uninstall completes, shows cache cleanup message if files existed.

**Step 3: Commit**

```bash
git add bin/install.js
git commit -m "fix: clean up cache files on uninstall"
```

---

### Task 6: Final verification

**Step 1: Full end-to-end test**

```bash
# Test with realistic input
echo '{"model":{"display_name":"Claude Opus 4"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000,"cache_creation_input_tokens":1000,"cache_read_input_tokens":2000}},"cwd":"/Users/test/myproject","session":{"start_time":"2026-03-09T10:00:00Z"}}' | bash bin/statusline.sh
```

**Step 2: Test empty/malformed input**

```bash
echo '' | bash bin/statusline.sh        # Should output "Claude"
echo '{}' | bash bin/statusline.sh      # Should output defaults, no crash
echo 'not json' | bash bin/statusline.sh # Should output "Claude" (jq fails, empty input path)
```

**Step 3: Verify no regressions in install/uninstall**

```bash
node bin/install.js          # Should install normally
node bin/install.js --uninstall  # Should uninstall + clean cache
```
