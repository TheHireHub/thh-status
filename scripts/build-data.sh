#!/usr/bin/env bash
# Builds site/data.json for status.thehirehub.ai from Upptime's outputs:
#   history/summary.json   – per-site uptime %, dailyMinutesDown (status only as fallback)
#   history/<slug>.yml     – live status; its git history gives a 24h response-time series
#   GitHub issues (label "status") – the incident log
#   last successful uptime.yml run – checkedAt, the probe clock behind "Last checked"
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
      # AUDIT-DECISION(AUD-STAT-2c7ed1bb): coerce in jq so bash $(( )) only sees an integer; round, not floor,
      # so a sub-minute outage still shows as 1 min down. Non-numeric values count as 0.
      m=$(jq -r --arg d "$d" '(.dailyMinutesDown[$d] // 0) | (tonumber? // 0) | round' <<<"$site")
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

  # AUDIT-DECISION(AUD-STAT-50360681): status comes from history/<slug>.yml (uptime.yml rewrites it within 5 min of a change),
  # not summary.json (daily summary.yml), so the banner turns red on the next build; missing/unknown value keeps summary's.
  live_status=""
  if [ -f "$hist" ]; then live_status=$(awk '/^status:/{gsub(/["\r]/, "", $2); print $2; exit}' "$hist"); fi
  sites_json=$(jq -c --argjson s "$site" --argjson days "$days" --argjson spark "$spark" --arg u "$uptime90" \
    --arg live "$live_status" \
    '. + [$s + {days:$days, spark:$spark, uptime90:$u}
      + (if ($live | IN("up", "down", "degraded")) then {status:$live} else {} end)
      | del(.icon, .url, .dailyMinutesDown)]' <<<"$sites_json")
done < <(jq -c '.[]' history/summary.json)

# --- incidents: GitHub issues labelled "status": all open + closed in last 30 days
# GitHub's `since` filters on updated_at, so it would drop an open incident nobody touched for 30 days
# and re-list an old one somebody edited. Open issues are fetched without it; closed ones are kept by
# closed_at (fallback created_at). --paginate prints one issue per line across every page.
since=$(date -u -d "@$((NOW - 30*86400))" +%FT%TZ)
fetch_issues() { gh api --paginate "repos/$REPO/issues?labels=status&per_page=100&$1" --jq '.[]'; }
# AUDIT-DECISION(AUD-STAT-2e65099a): a failed fetch keeps what did load and sets incidentsError (page says history is
# unavailable) instead of a silent [] that reads "No incidents"; gh stderr stays in the job log. Undo: exit 1 instead.
incidents_error=false
raw=""
for query in "state=open" "state=closed&since=$since"; do
  if chunk=$(fetch_issues "$query"); then raw+="$chunk"$'\n'
  else incidents_error=true; echo "::warning::incident fetch failed ($query); data.json gets incidentsError=true"; fi
done
# AUDIT-DECISION(AUD-STAT-734b53bd): strip URLs (and the empty "()" they leave) from title and body, finishing ed4c04d's
# hostname hiding for Upptime bot issues; url (the public GitHub issue link) stays.
if ! incidents=$(jq -cs --arg since "$since" '
    def nourl: gsub("https?://[^\\s)\\]>`]+"; "") | gsub("\\(\\s*\\)"; "");
    [.[] | select(.pull_request == null)
      | select(.state == "open" or ((.closed_at // .created_at) >= $since))]
    | unique_by(.html_url) | map({
      title: ((.title // "") | nourl), url: .html_url, state, createdAt: .created_at, closedAt: .closed_at,
      labels: [.labels[].name], body: ((.body // "") | nourl)
    })' <<<"$raw"); then
  incidents='[]'; incidents_error=true
  echo "::warning::incident data could not be parsed; data.json gets incidentsError=true"
fi

# --- probe clock: when uptime.yml last finished a successful check ----------
# AUDIT-DECISION(AUD-STAT-a3346cb0): history/<slug>.yml lastUpdated only moves on status/response changes, so it is no
# probe clock; the last successful uptime.yml run is. Failure -> null (page falls back to generatedAt).
checked_at=$(gh api "repos/$REPO/actions/workflows/uptime.yml/runs?status=success&per_page=1" \
  --jq '.workflow_runs[0].updated_at // empty' 2>/dev/null || true)
[ -n "$checked_at" ] || echo "::warning::could not read the last successful uptime.yml run; checkedAt=null"

jq -n --argjson sites "$sites_json" --argjson incidents "$incidents" --argjson incidentsError "$incidents_error" \
  --arg generatedAt "$(date -u -d "@$NOW" +%FT%TZ)" --arg checkedAt "$checked_at" \
  '{generatedAt:$generatedAt,
    checkedAt:(if ($checkedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}")) then $checkedAt else null end),
    sites:$sites, incidents:$incidents, incidentsError:$incidentsError}' > site/data.json
echo "wrote site/data.json ($(jq '.sites|length' site/data.json) sites, $(jq '.incidents|length' site/data.json) incidents)"
