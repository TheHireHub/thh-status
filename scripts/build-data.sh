#!/usr/bin/env bash
# Builds site/data.json for status.thehirehub.ai from Upptime's outputs:
#   history/summary.json   – per-site status, uptime %, dailyMinutesDown
#   history/<slug>.yml     – git history gives a 24h response-time series
#   GitHub issues (label "status") – the incident log
# Runs inside pages.yml on ubuntu-latest (bash, jq, git, gh).
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${GITHUB_REPOSITORY:-TheHireHub/thh-status}"
NOW=$(date -u +%s)
DAYS=90

# --- per-site: daily bars + 24h response sparkline -------------------------
sites_json="[]"
while IFS= read -r site; do
  slug=$(jq -r .slug <<<"$site")
  hist="history/$slug.yml"
  start=$(grep -m1 '^startTime:' "$hist" 2>/dev/null | awk '{print $2}' || true)
  start_ts=$([ -n "$start" ] && date -u -d "$start" +%s || echo "$NOW")

  # 90 daily buckets, oldest first. null = not yet monitored that day.
  days="[]"
  down_total=0; days_counted=0
  for ((i=DAYS-1; i>=0; i--)); do
    d=$(date -u -d "@$((NOW - i*86400))" +%F)
    d_ts=$(date -u -d "$d" +%s)
    if (( d_ts + 86400 < start_ts )); then
      days=$(jq -c --arg d "$d" '. + [{date:$d, down:null}]' <<<"$days")
    else
      m=$(jq -r --arg d "$d" '.dailyMinutesDown[$d] // 0' <<<"$site")
      down_total=$((down_total + m)); days_counted=$((days_counted + 1))
      days=$(jq -c --arg d "$d" --argjson m "$m" '. + [{date:$d, down:$m}]' <<<"$days")
    fi
  done
  if (( days_counted > 0 )); then
    uptime90=$(awk -v d="$down_total" -v n="$days_counted" 'BEGIN{printf "%.2f", 100 - d/(n*1440)*100}')
  else
    uptime90="100.00"
  fi

  # Response times from the last 24h of commits to this site's history file.
  spark="[]"
  if [ -f "$hist" ]; then
    spark=$(git log --since="24 hours ago" --reverse --format=%H -- "$hist" \
      | while read -r sha; do git show "$sha:$hist" 2>/dev/null | awk '/^responseTime:/{print $2}'; done \
      | jq -cs '.')
  fi

  sites_json=$(jq -c --argjson s "$site" --argjson days "$days" --argjson spark "$spark" --arg u "$uptime90" \
    '. + [$s + {days:$days, spark:$spark, uptime90:$u} | del(.icon, .url, .dailyMinutesDown)]' <<<"$sites_json")
done < <(jq -c '.[]' history/summary.json)

# --- incidents: GitHub issues labelled "status", last 30 days ---------------
since=$(date -u -d "@$((NOW - 30*86400))" +%FT%TZ)
incidents=$(gh api "repos/$REPO/issues?labels=status&state=all&since=$since&per_page=50" \
  --jq '[.[] | select(.pull_request == null) | {
      title, url: .html_url, state, createdAt: .created_at, closedAt: .closed_at,
      labels: [.labels[].name], body: (.body // "")
    }]' 2>/dev/null || echo '[]')

jq -n --argjson sites "$sites_json" --argjson incidents "$incidents" \
  --arg generatedAt "$(date -u -d "@$NOW" +%FT%TZ)" \
  '{generatedAt:$generatedAt, sites:$sites, incidents:$incidents}' > site/data.json
echo "wrote site/data.json ($(jq '.sites|length' site/data.json) sites, $(jq '.incidents|length' site/data.json) incidents)"
