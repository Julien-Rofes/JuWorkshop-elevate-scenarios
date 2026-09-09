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

SERVERS=("win-server-krk01" "win-server-krk02" "win-server-krk03")
USERS=("bob" "alice" "tom" "lukas")
WORKSTATIONS=("DESKTOP-FINANCE01" "DESKTOP-HR02" "LAPTOP-SALES03" "DESKTOP-IT04" "LAPTOP-MGMT05")
FAILURE_REASONS=("Unknown user name or bad password." "Account locked out." "Account disabled.")
SUB_STATUSES=("0xc000006a" "0xc0000064" "0xc0000072")

random_ip() {
  echo "$((RANDOM % 200 + 10)).$((RANDOM % 256)).$((RANDOM % 256)).$((RANDOM % 253 + 1))"
}

to_upper() {
  echo "$1" | tr '[:lower:]' '[:upper:]'
}

send_to_all_targets() {
  local payload="$1"
  local target key suffix response_file http_status response_body

  while IFS= read -r target; do
    key="$(jq -r '.intake_key' <<< "$target")"
    suffix="$(jq -r '.suffix // "unknown"' <<< "$target")"
    response_file="$(mktemp)"

    http_status="$(curl -sS -o "$response_file" -w "%{http_code}" -X POST "$INTAKE_URL" \
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

echo "Starting Windows event simulator for $(jq 'length' <<< "$TARGETS_JSON") communities. Press Ctrl+C to stop."

count=0

while true; do
  server="${SERVERS[$((RANDOM % 3))]}"
  user="${USERS[$((RANDOM % 4))]}"
  workstation="${WORKSTATIONS[$((RANDOM % 5))]}"
  ip=$(random_ip)
  port=$((RANDOM % 16383 + 49152))
  now=$(date '+%Y-%m-%d %H:%M:%S')
  server_upper=$(to_upper "$server")
  logon_type="3"
  [ $((RANDOM % 5)) -eq 0 ] && logon_type="10"

  if [ $((RANDOM % 100)) -lt 65 ]; then
    event_id=4624
    outcome="SUCCESS (4624)"
    logon_id="0x$(printf '%06x' $((RANDOM * 32 + RANDOM)))"
    extra_fields="\"TargetLogonId\":\"${logon_id}\",\"LogonGuid\":\"{00000000-0000-0000-0000-000000000000}\""
  else
    event_id=4625
    outcome="FAILURE (4625)"
    failure="${FAILURE_REASONS[$((RANDOM % 3))]}"
    substatus="${SUB_STATUSES[$((RANDOM % 3))]}"
    extra_fields="\"Status\":\"0xc000006d\",\"SubStatus\":\"${substatus}\",\"FailureReason\":\"${failure}\""
  fi

  payload="{\"EventTime\":\"${now}\",\"Hostname\":\"${server}\",\"EventID\":${event_id},\"SourceName\":\"Microsoft-Windows-Security-Auditing\",\"ProviderGuid\":\"{54849625-5478-4994-a5ba-3e3b0328c30d}\",\"Version\":0,\"Channel\":\"Security\",\"Computer\":\"${server}\",\"SubjectUserSid\":\"S-1-0-0\",\"SubjectUserName\":\"-\",\"SubjectDomainName\":\"-\",\"SubjectLogonId\":\"0x0\",\"TargetUserName\":\"${user}\",\"TargetDomainName\":\"${server_upper}\",\"LogonType\":\"${logon_type}\",\"LogonProcessName\":\"NtLmSsp\",\"AuthenticationPackageName\":\"NTLM\",\"WorkstationName\":\"${workstation}\",\"ProcessId\":\"0x0\",\"ProcessName\":\"-\",\"IpAddress\":\"${ip}\",\"IpPort\":\"${port}\",${extra_fields}}"

  count=$((count + 1))
  echo "[${count}] ${now} ${outcome} user=${user} server=${server} src=${ip}"
  send_to_all_targets "$payload"

  delay=$((RANDOM % 21 + 10))
  sleep "$delay"
done
