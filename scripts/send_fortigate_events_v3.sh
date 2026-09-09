#!/usr/bin/env bash

set -euo pipefail

INTAKE_URL="https://intake.sekoia.io/plain"
TARGETS_JSON="${TARGETS_JSON:-}"
IOC_INPUT="${IOC_INPUT:-}"

if [[ -z "$TARGETS_JSON" && -n "${INTAKE_KEY:-}" ]]; then
  TARGETS_JSON="$(jq -nc --arg key "$INTAKE_KEY" '[{suffix:"single", intake_key:$key}]')"
fi

if [[ -z "$TARGETS_JSON" ]]; then
  read -r -s -p "Enter the JSON target list or intake key: " TARGETS_JSON
  echo
fi

if [[ -z "$IOC_INPUT" ]]; then
  read -r -p "Enter the IOC IP address to simulate traffic towards: " IOC_INPUT
fi

if ! jq -e 'type == "array" and length > 0 and all(.[]; (.intake_key | type == "string" and length > 0))' <<< "$TARGETS_JSON" >/dev/null; then
  echo "Error: TARGETS_JSON must be a non-empty JSON array containing intake_key values." >&2
  exit 1
fi

if [[ -z "$IOC_INPUT" ]]; then
  echo "Error: IOC IP address cannot be empty." >&2
  exit 1
fi

rand_int() {
  local min=$1
  local max=$2
  echo $(( RANDOM % (max - min + 1) + min ))
}

random_internal_ip() {
  local class=$(( RANDOM % 3 ))
  case $class in
    0) echo "10.$(rand_int 0 255).$(rand_int 0 255).$(rand_int 1 254)" ;;
    1) echo "172.$(rand_int 16 31).$(rand_int 0 255).$(rand_int 1 254)" ;;
    2) echo "192.168.$(rand_int 0 255).$(rand_int 1 254)" ;;
  esac
}

random_external_ip() {
  while true; do
    local a=$(rand_int 1 223)
    local b=$(rand_int 0 255)
    local c=$(rand_int 0 255)
    local d=$(rand_int 1 254)
    if [[ $a -eq 10 ]]; then continue
    elif [[ $a -eq 127 ]]; then continue
    elif [[ $a -eq 169 && $b -eq 254 ]]; then continue
    elif [[ $a -eq 172 && $b -ge 16 && $b -le 31 ]]; then continue
    elif [[ $a -eq 192 && $b -eq 168 ]]; then continue
    elif [[ $a -eq 100 && $b -ge 64 && $b -le 127 ]]; then continue
    elif [[ $a -eq 198 && ($b -eq 18 || $b -eq 19) ]]; then continue
    fi
    echo "${a}.${b}.${c}.${d}"
    break
  done
}

send_event_to_all_targets() {
  local srcip="$1"
  local dstip="$2"
  local ts dt tm payload target key suffix response_file http_status response_body

  ts=$(date -u +%s)
  dt=$(date -u +"%Y-%m-%d")
  tm=$(date -u +"%H:%M:%S")
  payload="date=${dt} time=${tm} logid=\"0000000013\" type=\"traffic\" subtype=\"forward\" level=\"notice\" vd=\"root\" eventtime=${ts} srcip=${srcip} srcport=54321 srcintf=\"port2\" srcintfrole=\"lan\" dstip=${dstip} dstport=443 dstintf=\"port1\" dstintfrole=\"wan\" proto=6 action=\"accept\" policyid=1 service=\"HTTPS\" dstcountry=\"Germany\" srccountry=\"Reserved\" trandisp=\"snat\" transip=198.51.100.1 transport=54321 app=\"HTTPS\" appcat=\"Network.Service\" apprisk=\"low\" duration=12 sentbyte=512 rcvdbyte=256 sentpkt=8 rcvdpkt=5"

  while IFS= read -r target; do
    key="$(jq -r '.intake_key' <<< "$target")"
    suffix="$(jq -r '.suffix // "unknown"' <<< "$target")"
    response_file="$(mktemp)"

    http_status="$(curl -sS -o "$response_file" -w "%{http_code}" -X POST "$INTAKE_URL" \
      -H "X-SEKOIAIO-INTAKE-KEY: ${key}" \
      -H "Content-Type: text/plain" \
      -d "$payload")"

    response_body="$(cat "$response_file")"
    rm -f "$response_file"

    echo "Target ${suffix}: HTTP ${http_status}"
    if [[ "$http_status" != "200" && "$http_status" != "202" ]]; then
      echo "Target ${suffix} response: ${response_body}"
    fi
  done < <(jq -c '.[]' <<< "$TARGETS_JSON")
}

IOC_INTERNAL_IPS=("192.168.1.100" "192.168.1.112")
IOC_EXTERNAL_IP="$IOC_INPUT"
PHASE1_DURATION=900
START_TIME=$(date -u +%s)
NEXT_IOC_TIME=$(( START_TIME + $(rand_int 30 120) ))

echo "Starting FortiGate event sender for $(jq 'length' <<< "$TARGETS_JSON") communities. IOC target: ${IOC_EXTERNAL_IP}"
echo "Press Ctrl+C to stop."

while true; do
  NOW=$(date -u +%s)
  ELAPSED=$(( NOW - START_TIME ))
  SRCIP=$(random_internal_ip)
  DSTIP=$(random_external_ip)

  send_event_to_all_targets "$SRCIP" "$DSTIP"
  echo "Event sent, ${SRCIP} -> ${DSTIP}"

  if [[ $NOW -ge $NEXT_IOC_TIME ]]; then
    IOC_SRC="${IOC_INTERNAL_IPS[$(( RANDOM % 2 ))]}"
    send_event_to_all_targets "$IOC_SRC" "$IOC_EXTERNAL_IP"
    echo "IOC sent, ${IOC_SRC} -> ${IOC_EXTERNAL_IP}"

    if [[ $ELAPSED -lt $PHASE1_DURATION ]]; then
      INTERVAL=$(rand_int 30 120)
    else
      INTERVAL=$(rand_int 600 800)
    fi

    NEXT_IOC_TIME=$(( NOW + INTERVAL ))
  fi

  sleep 3
done
