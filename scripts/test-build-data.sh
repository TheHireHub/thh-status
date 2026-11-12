#!/usr/bin/env bash
# Offline test for scripts/build-data.sh: checkedAt (the probe clock behind the status page's
# "Last checked") comes from the last successful uptime.yml run, and a gh failure never fails the build.
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
  *issues*) echo '[]' ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"

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

exit "$fail"
