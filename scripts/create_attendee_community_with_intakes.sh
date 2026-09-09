#!/usr/bin/env bash

set -euo pipefail

SEKOIA_API_BASE="${SEKOIA_API_BASE:-https://app.sekoia.io/api/v1}"
OUTPUT_FILE="${OUTPUT_FILE:-}"

ENTITY_NAME="Main infrastructure"
ENTITY_ID="main-infrastructure"
ENTITY_DESCRIPTION="Main infrastructure entity"
ALERTS_GENERATION_UUID="e54510b7-13dc-4773-ad0d-f8b13b9a939d"

INTAKE_NAME_1="Fortigate NGFW"
FORMAT_UUID_1="5702ae4e-7d8a-455f-a47b-ef64dd87c981"

INTAKE_NAME_2="Apache Web Server"
FORMAT_UUID_2="6c2a44e3-a86a-4d98-97a6-d575ffcb29f7"

INTAKE_NAME_3="Windows Server"
FORMAT_UUID_3="9281438c-f7c3-4001-9bcc-45fd108ba1be"

INTAKE_NAME_4="Sekoia.io Endpoint Agent"
FORMAT_UUID_4="250e4095-fa08-4101-bb02-e72f870fcbd1"

COMMUNITY_API_KEY="${COMMUNITY_API_KEY:-}"
INTAKE_API_KEY="${INTAKE_API_KEY:-}"
WORKSPACE_UUID="${WORKSPACE_UUID:-}"
COMMUNITY_COUNT="${COMMUNITY_COUNT:-}"
STARTING_SUFFIX="${STARTING_SUFFIX:-}"

if [[ -z "$COMMUNITY_API_KEY" ]]; then
  read -r -s -p "Enter the API key for community creation: " COMMUNITY_API_KEY
  echo
fi

if [[ -z "$WORKSPACE_UUID" ]]; then
  read -r -p "Enter the workspace UUID where communities will be created: " WORKSPACE_UUID
fi

if [[ -z "$INTAKE_API_KEY" ]]; then
  read -r -s -p "Enter the workspace-level API key for entity and intake creation: " INTAKE_API_KEY
  echo
fi

if [[ -z "$COMMUNITY_COUNT" ]]; then
  read -r -p "Enter the number of communities to create: " COMMUNITY_COUNT
fi

if [[ -z "$STARTING_SUFFIX" ]]; then
  read -r -p "Enter the starting attendee suffix (for example 1, 100, or 001): " STARTING_SUFFIX
fi

if [[ -z "$COMMUNITY_API_KEY" || -z "$WORKSPACE_UUID" || -z "$INTAKE_API_KEY" ]]; then
  echo "Error: community API key, workspace UUID, and intake API key are required." >&2
  exit 1
fi

if ! [[ "$COMMUNITY_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: community count must be a positive integer." >&2
  exit 1
fi

if (( COMMUNITY_COUNT > 30 )); then
  echo "Error: community count cannot exceed 30 because each community uses three repository secrets." >&2
  exit 1
fi

if ! [[ "$STARTING_SUFFIX" =~ ^[0-9]+$ ]]; then
  echo "Error: starting suffix must contain digits only." >&2
  exit 1
fi

if [[ -z "$OUTPUT_FILE" ]]; then
  OUTPUT_FILE="$(mktemp)"
fi

: > "$OUTPUT_FILE"
chmod 600 "$OUTPUT_FILE" 2>/dev/null || true

CURRENT_DATE="$(date -u +%d-%m-%Y)"
DATE_KEY="$(date -u +%d_%m_%Y)"
SUFFIX_WIDTH="${#STARTING_SUFFIX}"
STARTING_NUMBER=$((10#$STARTING_SUFFIX))

create_intake() {
  local community_uuid="$1"
  local entity_uuid="$2"
  local intake_name="$3"
  local format_uuid="$4"
  local output_variable="$5"

  echo "Creating intake: ${intake_name}..."

  local intake_response
  local intake_uuid
  local intake_key

  intake_response="$(
    jq -n \
      --arg name "$intake_name" \
      --arg entity_uuid "$entity_uuid" \
      --arg format_uuid "$format_uuid" \
      --arg community_uuid "$community_uuid" \
      '{
        name: $name,
        entity_uuid: $entity_uuid,
        format_uuid: $format_uuid,
        community_uuid: $community_uuid
      }' |
    curl --fail-with-body -sS -X POST \
      "${SEKOIA_API_BASE}/sic/conf/intakes" \
      -H "Authorization: Bearer ${INTAKE_API_KEY}" \
      -H "Content-Type: application/json" \
      --data @-
  )"

  intake_uuid="$(echo "$intake_response" | jq -er '.uuid')"
  intake_key="$(echo "$intake_response" | jq -er '.intake_key')"

  printf -v "$output_variable" '%s' "$intake_key"
  echo "Intake created successfully: ${intake_uuid}"
}

for ((index=0; index<COMMUNITY_COUNT; index++)); do
  suffix_number=$((STARTING_NUMBER + index))
  attendee_suffix="$(printf "%0${SUFFIX_WIDTH}d" "$suffix_number")"
  community_name="${CURRENT_DATE}- Attendee ${attendee_suffix} Community"
  community_description="$community_name"
  secret_prefix="A_${DATE_KEY}_ATTENDEE_${attendee_suffix}"

  echo
  echo "Creating community ${index}/${COMMUNITY_COUNT}: ${community_name}..."

  community_response="$(
    jq -n \
      --arg name "$community_name" \
      --arg description "$community_description" \
      '{name: $name, description: $description}' |
    curl --fail-with-body -sS -X POST \
      "${SEKOIA_API_BASE}/communities/${WORKSPACE_UUID}/sub-communities" \
      -H "Authorization: Bearer ${COMMUNITY_API_KEY}" \
      -H "Content-Type: application/json" \
      --data @-
  )"

  community_uuid="$(echo "$community_response" | jq -er '.uuid')"
  echo "Community created successfully: ${community_uuid}"

  echo "Assigning default trial license..."
  jq -n '{}' |
    curl --fail-with-body -sS -X POST \
      "${SEKOIA_API_BASE}/communities/${community_uuid}/licenses/trial" \
      -H "Authorization: Bearer ${COMMUNITY_API_KEY}" \
      -H "Content-Type: application/json" \
      --data @- \
      > /dev/null
  echo "Trial license assigned successfully."

  echo "Creating entity..."
  entity_response="$(
    jq -n \
      --arg name "$ENTITY_NAME" \
      --arg entity_id "$ENTITY_ID" \
      --arg description "$ENTITY_DESCRIPTION" \
      --arg alerts_generation "$ALERTS_GENERATION_UUID" \
      --arg community_uuid "$community_uuid" \
      '{
        name: $name,
        entity_id: $entity_id,
        description: $description,
        alerts_generation: $alerts_generation,
        community_uuid: $community_uuid
      }' |
    curl --fail-with-body -sS -X POST \
      "${SEKOIA_API_BASE}/sic/conf/entities" \
      -H "Authorization: Bearer ${INTAKE_API_KEY}" \
      -H "Content-Type: application/json" \
      --data @-
  )"

  entity_uuid="$(echo "$entity_response" | jq -er '.uuid')"
  echo "Entity created successfully: ${entity_uuid}"

  fortigate_intake_key=""
  http_intake_key=""
  windows_intake_key=""
  reveal_intake_key=""

  create_intake "$community_uuid" "$entity_uuid" "$INTAKE_NAME_1" "$FORMAT_UUID_1" fortigate_intake_key
  create_intake "$community_uuid" "$entity_uuid" "$INTAKE_NAME_2" "$FORMAT_UUID_2" http_intake_key
  create_intake "$community_uuid" "$entity_uuid" "$INTAKE_NAME_3" "$FORMAT_UUID_3" windows_intake_key
  create_intake "$community_uuid" "$entity_uuid" "$INTAKE_NAME_4" "$FORMAT_UUID_4" reveal_intake_key

  fortigate_secret_name="${secret_prefix}_FORTIGATE_INTAKEKEY"
  http_secret_name="${secret_prefix}_HTTP_INTAKE"
  windows_secret_name="${secret_prefix}_WINDOWS_INTAKE"

  # JSONL is temporary runner-local data consumed immediately by the workflow.
  # Intake keys are never printed or written to the GitHub summary.
  jq -nc \
    --arg suffix "$attendee_suffix" \
    --arg community_name "$community_name" \
    --arg community_uuid "$community_uuid" \
    --arg entity_uuid "$entity_uuid" \
    --arg fortigate_secret_name "$fortigate_secret_name" \
    --arg fortigate_key "$fortigate_intake_key" \
    --arg http_secret_name "$http_secret_name" \
    --arg http_key "$http_intake_key" \
    --arg windows_secret_name "$windows_secret_name" \
    --arg windows_key "$windows_intake_key" \
    --arg reveal_key "$reveal_intake_key" \
    '{
      suffix: $suffix,
      community_name: $community_name,
      community_uuid: $community_uuid,
      entity_uuid: $entity_uuid,
      fortigate_secret_name: $fortigate_secret_name,
      fortigate_key: $fortigate_key,
      http_secret_name: $http_secret_name,
      http_key: $http_key,
      windows_secret_name: $windows_secret_name,
      windows_key: $windows_key,
      reveal_key: $reveal_key
    }' >> "$OUTPUT_FILE"

done

echo
echo "Created ${COMMUNITY_COUNT} communities, each with one entity and three intakes."
echo "Provisioning manifest written to the temporary runner file."
