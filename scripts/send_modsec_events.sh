#!/usr/bin/env bash

set -euo pipefail

INTAKE_URL="https://intake.sekoia.io/plain"
TARGETS_JSON="${TARGETS_JSON:-}"

if [[ -z "$TARGETS_JSON" && -n "${INTAKE_KEY:-}" ]]; then
  TARGETS_JSON="$(jq -nc --arg key "$INTAKE_KEY" '[{suffix:"single", intake_key:$key}]')"
fi

if [[ -z "$TARGETS_JSON" ]]; then
  read -r -s -p "Enter the JSON target list or intake key: " TARGETS_JSON
  echo
fi

if ! jq -e 'type == "array" and length > 0 and all(.[]; (.intake_key | type == "string" and length > 0))' <<< "$TARGETS_JSON" >/dev/null; then
  echo "Error: TARGETS_JSON must be a non-empty JSON array containing intake_key values." >&2
  exit 1
fi

EVENT_1='[security2:error] [pid 11852:tid 4036848496] [client 192.168.1.100:35323] [client 192.168.1.100] ModSecurity: Warning. Pattern match "..." at ARGS:search. [file "/usr/apache/conf/waf/modsecurity_crs_sql_injection_attacks.conf"] [line "64"] [id "950001"] [rev "1"] [msg "SQL Injection Attack Detected"] [data "Matched Data: SELECT found within ARGS:search: SELECT * FROM users WHERE id=1 OR 1=1"] [severity "CRITICAL"] [ver "OWASP_CRS/3.3.0"] [hostname "apache-server.corp.local"] [uri "/search.php"] [unique_id "YkX2vlKC-YX738FovDc0GkwAAAAb"], referer: http://apache-server.corp.local/index.php'
EVENT_2='[security2:error] [pid 11852:tid 4036848496] [client 192.168.1.112:35323] [client 192.168.1.112] ModSecurity: Warning. Pattern match "..." at ARGS:search. [file "/usr/apache/conf/waf/modsecurity_crs_sql_injection_attacks.conf"] [line "64"] [id "950001"] [rev "1"] [msg "SQL Injection Attack Detected"] [data "Matched Data: SELECT found within ARGS:search: SELECT * FROM users WHERE id=1 OR 1=1"] [severity "CRITICAL"] [ver "OWASP_CRS/3.3.0"] [hostname "apache-server.corp.local"] [uri "/search.php"] [unique_id "YkX2vlKC-YX738FovDc0GkwAAAAb"], referer: http://apache-server.corp.local/index.php'

send_to_all_targets() {
  local payload="$1"
  local target key suffix response_file http_status response_body

  while IFS= read -r target; do
    key="$(jq -r '.intake_key' <<< "$target")"
    suffix="$(jq -r '.suffix // "unknown"' <<< "$target")"
    response_file="$(mktemp)"

    http_status="$(curl -sS -o "$response_file" -w "%{http_code}" \
      -X POST "$INTAKE_URL" \
      -H "X-SEKOIAIO-INTAKE-KEY: ${key}" \
      -H "Content-Type: text/plain" \
      --data-raw "$payload")"

    response_body="$(cat "$response_file")"
    rm -f "$response_file"

    echo "Target ${suffix}: HTTP ${http_status}"
    if [[ "$http_status" != "200" && "$http_status" != "202" ]]; then
      echo "Target ${suffix} response: ${response_body}"
    fi
  done < <(jq -c '.[]' <<< "$TARGETS_JSON")
}

echo "Starting ModSecurity event sender for $(jq 'length' <<< "$TARGETS_JSON") communities. Press Ctrl+C to stop."

count=0
while true; do
  if (( RANDOM % 2 == 0 )); then
    payload="$EVENT_1"
    label="Event #1 (client 192.168.1.100)"
  else
    payload="$EVENT_2"
    label="Event #2 (client 192.168.1.112)"
  fi

  count=$((count + 1))
  echo "[Event ${count}] ${label}"
  send_to_all_targets "$payload"
  sleep $(( RANDOM % 31 + 30 ))
done
