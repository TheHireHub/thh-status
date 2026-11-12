#!/usr/bin/env bash
# Offline test for scripts/build-data.sh: checkedAt (the probe clock behind the status page's
# "Last checked") comes from the last successful uptime.yml run, and a gh failure never fails the build;
# fractional dailyMinutesDown never aborts the build; incidents follow open state / closed_at, not updated_at;
# a failed issue fetch publishes incidentsError=true; URLs never reach incident text; history/<slug>.yml status wins.
# Runs in a throwaway copy with a stubbed gh, so no network and no change to site/data.json here.
# Needs GNU date like build-data.sh itself (on macOS: brew install coreutils, gdate is used).
# Usage: bash scripts/test-build-data.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo/scripts" "$tmp/repo/history" "$tmp/repo/site" "$tmp/bin"
cp "$here/build-data.sh" "$tmp/repo/scripts/"
echo '[]' > "$tmp/repo/history/summary.json"

if ! date -u -d @0 >/dev/null 2>&1; then
  command -v gdate >/dev/null || { echo "FAIL: GNU date (or gdate) is required"; exit 1; }
  ln -s "$(command -v gdate)" "$tmp/bin/date"
fi

# gh stub: prints what the real gh would print after --jq.
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *actions/workflows/uptime.yml/runs*)
    if [ "${STUB_RUNS_FAIL:-}" = 1 ]; then echo "HTTP 403: Resource not accessible" >&2; exit 1; fi
    printf '%s\n' "${STUB_RUN_AT:-}" ;;
  # --paginate --jq '.[]' prints one issue per line; fixtures exist only for the incident cases.
  # STUB_ISSUES_FAIL=all fails both issue fetches, =closed only the closed one.
  *issues*state=open*)
    if [ "${STUB_ISSUES_FAIL:-}" = all ]; then echo "HTTP 502: Bad Gateway" >&2; exit 1; fi
    cat "$FIXTURES/open.jsonl" 2>/dev/null || true ;;
  *issues*state=closed*)
    case "${STUB_ISSUES_FAIL:-}" in all|closed) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;; esac
    cat "$FIXTURES/closed.jsonl" 2>/dev/null || true ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
export FIXTURES="$tmp"

fail=0
data="$tmp/repo/site/data.json"
build() {
  rm -f "$data"
  env PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=example/status "$@" bash "$tmp/repo/scripts/build-data.sh" >/dev/null
}
expect() { # <case name> <expected checkedAt or null>
  local got
  got=$(jq -r '.checkedAt // "null"' "$data" 2>/dev/null || echo "missing data.json")
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: checkedAt=$got, want $2"; fail=1; fi
}

build STUB_RUN_AT=2026-11-12T10:05:31Z
expect "checkedAt = last successful uptime.yml run" 2026-11-12T10:05:31Z

if build STUB_RUNS_FAIL=1; then expect "gh failure -> checkedAt null, build still exits 0" null
else echo "FAIL gh failure made build-data.sh exit non-zero"; fail=1; fi

build STUB_RUN_AT=
expect "no successful run yet -> checkedAt null" null

build STUB_RUN_AT=not-a-timestamp
expect "non-ISO value -> checkedAt null" null

# --- dailyMinutesDown rounding + incident lifecycle (no history/<slug>.yml: only today is monitored)
gdate_() { env PATH="$tmp/bin:$PATH" date "$@"; }
today=$(gdate_ -u +%F)
ago() { gdate_ -u -d "@$(( $(gdate_ -u +%s) - $1 * 86400 ))" +%FT%TZ; }
cat > "$tmp/repo/history/summary.json" <<EOF
[{"name": "Website", "slug": "website", "status": "up", "dailyMinutesDown": {"$today": 12.5}},
 {"name": "API", "slug": "api", "status": "up", "dailyMinutesDown": {"$today": "n/a"}}]
EOF
issue() { # <n> <title> <state> <created> <updated> <closed|null> [pull_request]
  jq -cn --arg n "$1" --arg t "$2" --arg s "$3" --arg c "$4" --arg u "$5" --arg x "$6" --arg pr "${7:-}" \
    '{title: $t, html_url: ("https://example.test/i/" + $n), state: $s, created_at: $c, updated_at: $u,
      closed_at: (if $x == "null" then null else $x end), labels: [{name: "status"}], body: null}
     + (if $pr == "" then {} else {pull_request: {}} end)'
}
issue 1 "Open long outage" open "$(ago 45)" "$(ago 40)" null > "$tmp/open.jsonl"
{ issue 2 "Old resolved, edited yesterday" closed "$(ago 90)" "$(ago 1)" "$(ago 89)"
  issue 3 "Recent resolved" closed "$(ago 5)" "$(ago 4)" "$(ago 4)"
  issue 4 "A pull request" closed "$(ago 5)" "$(ago 4)" "$(ago 4)" pr; } > "$tmp/closed.jsonl"
check() { # <case name> <jq assertion on data.json>
  if jq -e "$2" "$data" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
if build STUB_RUN_AT=2026-11-12T10:05:31Z; then echo "ok   fractional dailyMinutesDown -> build exits 0"
else echo "FAIL fractional dailyMinutesDown made build-data.sh exit non-zero"; fail=1; fi
check "12.5 min rounds to 13 on today's bar" '.sites[0].days[-1].down == 13'
check "uptime uses the rounded minutes" '.sites[0].uptime90 == "99.10"'
check "non-numeric minutes count as 0" '.sites[1].days[-1].down == 0'
check "open incident idle for 40 days is kept" 'any(.incidents[]; .title == "Open long outage" and .state == "open")'
check "closed incident resolved in window is kept" 'any(.incidents[]; .title == "Recent resolved")'
check "old incident edited yesterday stays out" 'all(.incidents[]; .title != "Old resolved, edited yesterday")'
check "pull requests are not incidents" 'all(.incidents[]; .title != "A pull request")'
check "exactly two incidents" '.incidents | length == 2'
check "fetch ok -> incidentsError false" '.incidentsError == false'

# --- issue fetch failures: build still publishes, with incidentsError
if build STUB_RUN_AT=2026-11-12T10:05:31Z STUB_ISSUES_FAIL=all; then echo "ok   gh issue failure -> build exits 0"
else echo "FAIL gh issue failure made build-data.sh exit non-zero"; fail=1; fi
check "both fetches fail -> incidentsError true, no incidents" '.incidentsError == true and .incidents == []'
check "both fetches fail -> service status still published" '.sites | length == 2'
build STUB_RUN_AT=2026-11-12T10:05:31Z STUB_ISSUES_FAIL=closed
check "closed fetch fails -> open incident kept, incidentsError true" \
  '.incidentsError == true and [.incidents[].title] == ["Open long outage"]'

# --- monitor URLs never reach incident title/body
jq -cn --arg c "$(ago 1)" '{title: "Media down (https://media-host.example/x)", html_url: "https://example.test/i/9",
  state: "open", created_at: $c, updated_at: $c, closed_at: null, labels: [{name: "status"}],
  body: "In [`abc1234`](https://example.test/c/abc1234), Media (https://media-host.example/x) was **down**:\n- HTTP code: 0"}' \
  > "$tmp/open.jsonl"
build STUB_RUN_AT=2026-11-12T10:05:31Z
check "no URL in incident title or body" 'all(.incidents[]; (.title + .body) | test("http|media-host") | not)'
check "incident text otherwise kept" 'any(.incidents[]; .body | test("Media  was \\*\\*down"))'
check "public issue link kept" 'any(.incidents[]; .url == "https://example.test/i/9")'

# --- live status: history/<slug>.yml beats summary.json (needs a git repo for the response-time scan)
git -C "$tmp/repo" init -q
git -C "$tmp/repo" -c user.name=test -c user.email=test@example.test -c commit.gpgsign=false \
  commit -q --allow-empty -m init
printf 'url: https://api-host.example/health\nstatus: down\ncode: 0\nstartTime: %s\n' "$(ago 2)" \
  > "$tmp/repo/history/api.yml"
printf 'status: maybe\nstartTime: %s\n' "$(ago 2)" > "$tmp/repo/history/website.yml"
build STUB_RUN_AT=2026-11-12T10:05:31Z
check "summary up + history down -> api status down" '.sites[1].status == "down"'
check "unknown history status keeps summary status" '.sites[0].status == "up"'

exit "$fail"
