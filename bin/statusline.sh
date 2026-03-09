#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Colors ──────────────────────────────────────────────
# Muted base — only dynamic % values get saturated color
soft='\033[38;2;200;200;210m'       # model name, constants
muted='\033[38;2;130;160;190m'      # directory, secondary info
branch='\033[38;2;80;180;140m'      # git branch
orange='\033[38;2;235;160;70m'      # pct 50-69%
red='\033[38;2;240;80;80m'          # pct 90%+, dirty marker
yellow='\033[38;2;220;190;50m'      # pct 70-89%
green='\033[38;2;80;190;120m'       # pct <50%
accent='\033[38;2;170;130;240m'     # thinking mode active
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

# ── Helpers ─────────────────────────────────────────────
format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
    fi
}

iso_to_epoch() {
    local iso_str="$1"

    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

format_reset_time() {
    local iso_str="$1"
    local style="$2"
    [ -z "$iso_str" ] || [ "$iso_str" = "null" ] && return

    local epoch
    epoch=$(iso_to_epoch "$iso_str")
    [ -z "$epoch" ] && return

    case "$style" in
        time)
            date -j -r "$epoch" +"%l:%M%p" 2>/dev/null | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]' || \
            date -d "@$epoch" +"%l:%M%P" 2>/dev/null | sed 's/^ //; s/\.//g'
            ;;
        datetime)
            date -j -r "$epoch" +"%b %-d, %l:%M%p" 2>/dev/null | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]' || \
            date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null | sed 's/  / /g; s/^ //; s/\.//g'
            ;;
        *)
            date -j -r "$epoch" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]' || \
            date -d "@$epoch" +"%b %-d" 2>/dev/null
            ;;
    esac
}

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
[ "$size" -eq 0 ] 2>/dev/null && size=200000
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi

thinking_on=false
settings_path="$HOME/.claude/settings.json"
if [ -f "$settings_path" ]; then
    thinking_val=$(jq -r '.alwaysThinkingEnabled // false' "$settings_path" 2>/dev/null)
    [ "$thinking_val" = "true" ] && thinking_on=true
fi

# ── LINE 1: Model │ Context % │ Directory (branch) │ Session │ Thinking ──
pct_color=$(color_for_pct "$pct_used")
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

git_branch=""
git_dirty=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

session_duration=""
if [ -n "$session_start" ] && [ "$session_start" != "null" ]; then
    start_epoch=$(iso_to_epoch "$session_start")
    if [ -n "$start_epoch" ]; then
        now_epoch=$(date +%s)
        elapsed=$(( now_epoch - start_epoch ))
        if [ "$elapsed" -ge 3600 ]; then
            session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
        elif [ "$elapsed" -ge 60 ]; then
            session_duration="$(( elapsed / 60 ))m"
        else
            session_duration="${elapsed}s"
        fi
    fi
fi

line1="${soft}${model_name}${reset}"
line1+="${sep}"
line1+="${pct_color}${pct_used}%${reset}"
line1+="${sep}"
line1+="${muted}${dirname}${reset}"
if [ -n "$git_branch" ]; then
    line1+=" ${branch}(${git_branch}${red}${git_dirty}${branch})${reset}"
fi
if [ -n "$session_duration" ]; then
    line1+="${sep}"
    line1+="${dim}${session_duration}${reset}"
fi
line1+="${sep}"
if $thinking_on; then
    line1+="${accent}◐ thinking${reset}"
else
    line1+="${dim}◑ thinking${reset}"
fi

# ── OAuth token resolution ──────────────────────────────
get_oauth_token() {
    local token=""

    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        echo "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi

    if command -v security >/dev/null 2>&1; then
        local blob
        blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    local creds_file="${HOME}/.claude/.credentials.json"
    if [ -f "$creds_file" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            echo "$token"
            return 0
        fi
    fi

    if command -v secret-tool >/dev/null 2>&1; then
        local blob
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    echo ""
}

# ── Fetch usage data (cached) ──────────────────────────
cache_file="/tmp/claude/statusline-usage-cache.json"
cache_max_age=60
err_cache="/tmp/claude/statusline-usage-error"
headers_tmp="/tmp/claude/statusline-headers.tmp"
response_tmp="/tmp/claude/statusline-response.tmp"
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

# Skip refresh if server told us to wait (Retry-After / backoff)
# Format in err_cache: retry_until_epoch<TAB>http_code<TAB>message
# But always retry if this is a new session (started after the error was cached)
if $needs_refresh && [ -f "$err_cache" ]; then
    IFS=$'\t' read -r retry_until_epoch cached_http_code cached_err_msg < "$err_cache"
    if [ -n "$retry_until_epoch" ] && [ "$now" -lt "$retry_until_epoch" ] 2>/dev/null; then
        session_epoch=$(iso_to_epoch "$session_start" 2>/dev/null)
        err_mtime=$(stat -c %Y "$err_cache" 2>/dev/null || stat -f %m "$err_cache" 2>/dev/null)
        if [ -n "$session_epoch" ] && [ -n "$err_mtime" ] && [ "$session_epoch" -gt "$err_mtime" ]; then
            : # New session — allow retry
        else
            needs_refresh=false
            api_error="cached:${cached_http_code}:${cached_err_msg}"
            # Load stale cache so rate bars still display
            if [ -f "$cache_file" ]; then
                usage_data=$(cat "$cache_file" 2>/dev/null)
            fi
        fi
    else
        rm -f "$err_cache"
    fi
fi

if $needs_refresh; then
    # Lock: prevent concurrent requests (thundering herd)
    # mkdir is atomic — only one process succeeds
    lock_file="/tmp/claude/statusline-fetch.lock"
    if ! mkdir "$lock_file" 2>/dev/null; then
        # Stale lock? (curl --max-time is 5s, so 10s is generous)
        lock_mtime=$(stat -c %Y "$lock_file" 2>/dev/null || stat -f %m "$lock_file" 2>/dev/null)
        if [ -n "$lock_mtime" ] && [ $(( now - lock_mtime )) -gt 10 ]; then
            rmdir "$lock_file" 2>/dev/null
            mkdir "$lock_file" 2>/dev/null || needs_refresh=false
        else
            needs_refresh=false
        fi
        if ! $needs_refresh && [ -f "$cache_file" ]; then
            usage_data=$(cat "$cache_file" 2>/dev/null)
        fi
    fi
fi

if $needs_refresh; then
    trap 'rmdir "$lock_file" 2>/dev/null' EXIT
    token=$(get_oauth_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        claude_ver=$(timeout 0.5 claude --version 2>/dev/null | head -1 || echo "unknown")
        http_code=$(curl -s -o "$response_tmp" -D "$headers_tmp" -w '%{http_code}' --max-time 5 \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-statusline/1.0 (claude-code/${claude_ver})" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        response=$(cat "$response_tmp" 2>/dev/null)
        rm -f "$response_tmp"
        if [ "$http_code" = "200" ] && [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
            usage_data="$response"
            echo "$response" > "${cache_file}.tmp" && mv "${cache_file}.tmp" "$cache_file"
            rm -f "$err_cache" "$headers_tmp"
        else
            # Parse Retry-After header (RFC 9110 §10.2.3): seconds or HTTP-date
            retry_after=""
            if [ -f "$headers_tmp" ]; then
                retry_after=$(grep -i '^retry-after:' "$headers_tmp" | head -1 | sed 's/^[^:]*: *//; s/\r$//')
            fi
            rm -f "$headers_tmp"

            # Calculate retry-until epoch from Retry-After
            retry_until=""
            if [ -n "$retry_after" ]; then
                if echo "$retry_after" | grep -qE '^[0-9]+$'; then
                    # Retry-After: <delay-seconds>
                    retry_until=$(( now + retry_after ))
                else
                    # Retry-After: <http-date>  (e.g. "Mon, 09 Mar 2026 12:00:00 GMT")
                    retry_until=$(date -d "$retry_after" +%s 2>/dev/null)
                    [ -z "$retry_until" ] && retry_until=$(date -j -f "%a, %d %b %Y %H:%M:%S %Z" "$retry_after" +%s 2>/dev/null)
                fi
            fi

            # Per-status-code handling with default backoff
            err_msg=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
            case "$http_code" in
                429)
                    api_error="rate_limited"
                    [ -z "$retry_until" ] && retry_until=$(( now + 60 ))
                    ;;
                401)
                    api_error="auth_expired"
                    retry_until=$(( now + 86400 * 365 ))
                    ;;
                403)
                    api_error="forbidden"
                    retry_until=$(( now + 86400 * 365 ))
                    ;;
                5[0-9][0-9])
                    api_error="server_error:${http_code}"
                    [ -z "$retry_until" ] && retry_until=$(( now + 120 ))
                    ;;
                000)
                    api_error="network_error"
                    [ -z "$retry_until" ] && retry_until=$(( now + 30 ))
                    ;;
                *)
                    api_error="http_error:${http_code}"
                    [ -z "$retry_until" ] && retry_until=$(( now + 300 ))
                    ;;
            esac

            # Store: retry_until_epoch<TAB>http_code<TAB>display_message
            printf '%s\t%s\t%s\n' "$retry_until" "$http_code" "${err_msg}" > "$err_cache"
        fi
    else
        api_error="no_token"
    fi
    # Fall back to stale cache if available
    if [ -z "$usage_data" ] && [ -f "$cache_file" ]; then
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi
    rmdir "$lock_file" 2>/dev/null
fi

# ── Rate limit lines ────────────────────────────────────
rate_lines=""

if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then

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
    five_hour_pct_color=$(color_for_pct "$five_hour_pct")

    seven_day_reset=$(format_reset_time "$seven_day_reset_iso" "datetime")
    seven_day_pct_color=$(color_for_pct "$seven_day_pct")

    rate_lines+="${dim}cur${reset} ${five_hour_pct_color}${five_hour_pct}%${reset} ${dim}⟳ ${five_hour_reset}${reset}"
    rate_lines+="${sep}"
    rate_lines+="${dim}wk${reset} ${seven_day_pct_color}${seven_day_pct}%${reset} ${dim}⟳ ${seven_day_reset}${reset}"

    if [ "$extra_enabled" = "true" ]; then
        extra_used=$(printf "%.0f" "$extra_used")
        extra_limit=$(printf "%.0f" "$extra_limit")
        extra_pct_color=$(color_for_pct "$extra_pct")

        extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        [ -z "$extra_reset" ] && extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')

        rate_lines+="${sep}"
        rate_lines+="${extra_pct_color}\$${extra_used}${dim}/\$${extra_limit} ⟳ ${extra_reset}${reset}"
    fi
fi

# ── Output ──────────────────────────────────────────────
printf "%b" "$line1"
if [ -n "$rate_lines" ]; then
    printf "\n\n%b" "$rate_lines"
elif [ -n "$api_error" ]; then
    # Format remaining wait time for display
    _retry_wait_msg() {
        local until_epoch="$1"
        [ -z "$until_epoch" ] && return
        local remaining=$(( until_epoch - $(date +%s) ))
        [ "$remaining" -le 0 ] && return
        if [ "$remaining" -ge 60 ]; then
            printf " (retry in %dm)" $(( remaining / 60 ))
        else
            printf " (retry in %ds)" "$remaining"
        fi
    }

    case "$api_error" in
        no_token)
            printf "\n\n${dim}⚠ no token — rate limits unavailable${reset}" ;;
        rate_limited)
            _wait=$(_retry_wait_msg "$retry_until")
            printf "\n\n${yellow}⚠ 429 rate limited${_wait}${reset}" ;;
        auth_expired)
            printf "\n\n${red}⚠ 401 token expired — re-login may be needed${reset}" ;;
        forbidden)
            printf "\n\n${red}⚠ 403 access denied${reset}" ;;
        server_error:*)
            _code="${api_error#server_error:}"
            _wait=$(_retry_wait_msg "$retry_until")
            printf "\n\n${yellow}⚠ ${_code} server error${_wait}${reset}" ;;
        network_error)
            _wait=$(_retry_wait_msg "$retry_until")
            printf "\n\n${dim}⚠ network error${_wait}${reset}" ;;
        http_error:*)
            _code="${api_error#http_error:}"
            printf "\n\n${dim}⚠ HTTP ${_code}${reset}" ;;
        cached:*)
            # cached:<http_code>:<message>
            IFS=':' read -r _ _code _msg <<< "$api_error"
            case "$_code" in
                429) printf "\n\n${yellow}⚠ rate limited$(_retry_wait_msg "$retry_until_epoch")${reset}" ;;
                401) printf "\n\n${red}⚠ token expired — re-login may be needed${reset}" ;;
                403) printf "\n\n${red}⚠ access denied${reset}" ;;
                5[0-9][0-9]) printf "\n\n${yellow}⚠ server error$(_retry_wait_msg "$retry_until_epoch")${reset}" ;;
                000) printf "\n\n${dim}⚠ network error$(_retry_wait_msg "$retry_until_epoch")${reset}" ;;
                *)   printf "\n\n${dim}⚠ HTTP ${_code}$(_retry_wait_msg "$retry_until_epoch")${reset}" ;;
            esac
            ;;
        *)
            printf "\n\n${dim}⚠ ${api_error}${reset}" ;;
    esac
fi

exit 0
