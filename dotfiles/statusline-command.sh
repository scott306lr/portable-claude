#!/bin/bash
# Claude Code statusLine script
# Mirrors Powerlevel10k p10k-classic layout: dir | git branch | model | ctx% | time

input=$(cat)

# --- Extract values from JSON ---
cwd=$(echo "$input" | jq -r '.workspace.current_dir // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
# Subscription rate-limit usage (Pro/Max only; absent for free users
# and until the first API response)
five_h_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_d_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

# Directory – basename only, like p10k dir segment
dir=$(basename "${cwd:-$(pwd)}")

# Git branch – skip optional locks to avoid slowdowns
git_info=""
target_dir="${cwd:-$(pwd)}"
if git -C "$target_dir" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$target_dir" -c core.fsmonitor=false symbolic-ref --short HEAD 2>/dev/null || \
             git -C "$target_dir" -c core.fsmonitor=false rev-parse --short HEAD 2>/dev/null)
    [ -n "$branch" ] && git_info="$branch"
fi

# Time – 24h format matching p10k TIME_FORMAT='%D{%H:%M:%S}'
time_now=$(date +%H:%M:%S)

# --- ANSI 256-color palette (mirrors p10k colors) ---
# DIR_FOREGROUND=31, VCS clean=76, TIME_FOREGROUND=66,
# CONTEXT_FOREGROUND=180, separator=240
c_dir="\033[38;5;31m"
c_git="\033[38;5;76m"
c_info="\033[38;5;66m"
c_lbl="\033[38;5;244m"   # muted label text
c_sep="\033[38;5;240m"
c_reset="\033[0m"

# Threshold color for a percentage: green <50, yellow 50–79, red >=80.
# Emits a literal escape string for the final `printf %b`.
pct_color() {
    local p=${1%%.*}
    [ -z "$p" ] && p=0
    if   [ "$p" -ge 80 ]; then printf '%s' '\033[38;5;203m'   # red
    elif [ "$p" -ge 50 ]; then printf '%s' '\033[38;5;179m'   # amber
    else                       printf '%s' '\033[38;5;108m'   # green
    fi
}

# Context window usage – "ctx 34%"
ctx_part=""
if [ -n "$used_pct" ]; then
    n=$(printf '%.0f' "$used_pct")
    ctx_part="${c_lbl}ctx ${c_reset}$(pct_color "$n")${n}%${c_reset}"
fi

# Subscription usage – "5h 13% · 7d 48%" (5h rolling window + weekly limit)
usage_part=""
if [ -n "$five_h_pct" ]; then
    n5=$(printf '%.0f' "$five_h_pct")
    usage_part="${c_lbl}5h ${c_reset}$(pct_color "$n5")${n5}%${c_reset}"
    if [ -n "$seven_d_pct" ]; then
        n7=$(printf '%.0f' "$seven_d_pct")
        usage_part+=" ${c_sep}·${c_reset} ${c_lbl}7d ${c_reset}$(pct_color "$n7")${n7}%${c_reset}"
    fi
fi

# --- Assemble status line ---
out="${c_dir}${dir}${c_reset}"

[ -n "$git_info" ] && out+=" ${c_sep}on${c_reset} ${c_git}${git_info}${c_reset}"

out+=" ${c_sep}|${c_reset}"

[ -n "$model" ] && out+=" ${c_info}${model}${c_reset}"

[ -n "$ctx_part" ] && out+=" ${c_sep}|${c_reset} ${ctx_part}"

[ -n "$usage_part" ] && out+=" ${c_sep}|${c_reset} ${usage_part}"

out+=" ${c_sep}|${c_reset} ${c_info}${time_now}${c_reset}"

printf "%b" "$out"
