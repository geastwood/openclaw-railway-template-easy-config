#!/usr/bin/env bash

set -u -o pipefail

REAL_BIN="/usr/local/bin/goplaces-real"

if [[ ! -x "$REAL_BIN" ]]; then
  echo "goplaces real binary not found at $REAL_BIN" >&2
  exit 127
fi

command="${1:-unknown}"
normalized_endpoint="unknown"

case "$command" in
  search)
    normalized_endpoint="search_text"
    ;;
  details)
    normalized_endpoint="details"
    ;;
  resolve)
    normalized_endpoint="resolve"
    ;;
  reviews)
    normalized_endpoint="reviews"
    ;;
esac

"$REAL_BIN" "$@"
status=$?

if [[ $status -eq 0 && -n "${CLAWCLAW_USAGE_URL:-}" && -n "${CLAWCLAW_USAGE_SECRET:-}" ]]; then
  payload=$(
    cat <<JSON
{"apiKey":"${CLAWCLAW_USAGE_SECRET}","events":[{"provider":"google_places","skill":"goplaces","eventType":"places_lookup","unit":"request","quantity":1,"metadata":{"endpoint":"${normalized_endpoint}"}}]}
JSON
  )

  curl --max-time 3 --retry 1 --silent --show-error \
    -H "Content-Type: application/json" \
    -X POST \
    --data "$payload" \
    "$CLAWCLAW_USAGE_URL" >/dev/null 2>&1 || true
fi

exit $status
