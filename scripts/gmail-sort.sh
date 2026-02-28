#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES_FILE="${GMAIL_RULES_FILE:-$ROOT_DIR/config/rules.json}"
DRY_RUN="${DRY_RUN:-false}"
TOKEN_URL="https://oauth2.googleapis.com/token"
GMAIL_API_BASE="https://gmail.googleapis.com/gmail/v1/users/me"

ACCESS_TOKEN=""
RESPONSE_BODY=""
RESPONSE_STATUS=""

declare -A LABEL_CACHE=()

log() {
  printf '%s\n' "$*"
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Commande requise absente: %s\n' "$command_name" >&2
    exit 1
  fi
}

load_env_file() {
  if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$ROOT_DIR/.env"
    set +a
  fi
}

require_env() {
  local variable_name="$1"
  if [[ -z "${!variable_name:-}" ]]; then
    printf 'Variable d environnement manquante: %s\n' "$variable_name" >&2
    exit 1
  fi
}

urlencode() {
  jq -rn --arg value "$1" '$value | @uri'
}

oauth_request() {
  local response_file
  response_file="$(mktemp)"
  RESPONSE_STATUS="$(
    curl -sS \
      -o "$response_file" \
      -w '%{http_code}' \
      -X POST \
      "$TOKEN_URL" \
      --data-urlencode "client_id=$GOOGLE_CLIENT_ID" \
      --data-urlencode "client_secret=$GOOGLE_CLIENT_SECRET" \
      --data-urlencode "refresh_token=$GMAIL_REFRESH_TOKEN" \
      --data-urlencode 'grant_type=refresh_token'
  )"
  RESPONSE_BODY="$(<"$response_file")"
  rm -f "$response_file"
}

refresh_access_token() {
  oauth_request
  if [[ "$RESPONSE_STATUS" != "200" ]]; then
    printf 'Echec OAuth (%s): %s\n' "$RESPONSE_STATUS" "$RESPONSE_BODY" >&2
    exit 1
  fi

  ACCESS_TOKEN="$(jq -r '.access_token // empty' <<<"$RESPONSE_BODY")"
  if [[ -z "$ACCESS_TOKEN" ]]; then
    printf 'Réponse OAuth invalide: %s\n' "$RESPONSE_BODY" >&2
    exit 1
  fi
}

api_request() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local attempt=0
  local retry_delay=1

  while true; do
    local response_file
    response_file="$(mktemp)"

    if [[ "$method" == "GET" ]]; then
      RESPONSE_STATUS="$(
        curl -sS \
          -o "$response_file" \
          -w '%{http_code}' \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          "$url"
      )"
    else
      RESPONSE_STATUS="$(
        curl -sS \
          -o "$response_file" \
          -w '%{http_code}' \
          -X "$method" \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          -H 'Content-Type: application/json' \
          "$url" \
          -d "$body"
      )"
    fi

    RESPONSE_BODY="$(<"$response_file")"
    rm -f "$response_file"

    if [[ "$RESPONSE_STATUS" =~ ^2 ]]; then
      return 0
    fi

    if [[ "$RESPONSE_STATUS" == "401" && "$attempt" -eq 0 ]]; then
      log 'Token expiré, renouvellement en cours'
      refresh_access_token
      attempt=1
      continue
    fi

    if [[ "$RESPONSE_STATUS" =~ ^(429|500|503)$ && "$retry_delay" -le 16 ]]; then
      log "API Gmail saturée ($RESPONSE_STATUS), nouvelle tentative dans ${retry_delay}s"
      sleep "$retry_delay"
      retry_delay=$((retry_delay * 2))
      continue
    fi

    printf 'Echec Gmail API %s %s (%s): %s\n' "$method" "$url" "$RESPONSE_STATUS" "$RESPONSE_BODY" >&2
    exit 1
  done
}

fetch_labels() {
  api_request GET "$GMAIL_API_BASE/labels"
  while IFS=$'\t' read -r label_name label_id; do
    [[ -n "$label_name" && -n "$label_id" ]] || continue
    LABEL_CACHE["$label_name"]="$label_id"
  done < <(jq -r '.labels[]? | [.name, .id] | @tsv' <<<"$RESPONSE_BODY")
}

ensure_label() {
  local label_name="$1"

  if [[ -n "${LABEL_CACHE[$label_name]:-}" ]]; then
    printf '%s\n' "${LABEL_CACHE[$label_name]}"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[DRY RUN] création simulée du libellé: %s\n' "$label_name" >&2
    printf '\n'
    return 0
  fi

  local payload
  payload="$(
    jq -nc \
      --arg name "$label_name" \
      '{
        name: $name,
        labelListVisibility: "labelShow",
        messageListVisibility: "show"
      }'
  )"
  api_request POST "$GMAIL_API_BASE/labels" "$payload"
  local label_id
  label_id="$(jq -r '.id // empty' <<<"$RESPONSE_BODY")"

  if [[ -z "$label_id" ]]; then
    printf 'Création de libellé invalide pour %s: %s\n' "$label_name" "$RESPONSE_BODY" >&2
    exit 1
  fi

  LABEL_CACHE["$label_name"]="$label_id"
  printf 'Libellé créé: %s\n' "$label_name" >&2
  printf '%s\n' "$label_id"
}

apply_rule() {
  local rule_json="$1"
  local label_name query archive label_id page_token total_messages message_count ids_json payload remove_json

  label_name="$(jq -r '.label' <<<"$rule_json")"
  query="$(jq -r '.query' <<<"$rule_json")"
  archive="$(jq -r '.archive' <<<"$rule_json")"
  label_id="$(ensure_label "$label_name")"
  total_messages=0
  page_token=""

  while true; do
    local url
    url="$GMAIL_API_BASE/messages?maxResults=500&q=$(urlencode "$query")"
    if [[ -n "$page_token" ]]; then
      url="${url}&pageToken=$(urlencode "$page_token")"
    fi

    api_request GET "$url"
    ids_json="$(jq -c '[.messages[]?.id]' <<<"$RESPONSE_BODY")"
    message_count="$(jq 'length' <<<"$ids_json")"

    if (( message_count > 0 )); then
      total_messages=$((total_messages + message_count))
      if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN][$label_name] $total_messages messages détectés"
      else
        if [[ "$archive" == "true" ]]; then
          remove_json='["INBOX"]'
        else
          remove_json='[]'
        fi

        payload="$(
          jq -nc \
            --argjson ids "$ids_json" \
            --arg label_id "$label_id" \
            --argjson remove_ids "$remove_json" \
            '{
              ids: $ids,
              addLabelIds: [$label_id],
              removeLabelIds: $remove_ids
            }'
        )"
        api_request POST "$GMAIL_API_BASE/messages/batchModify" "$payload"
        log "[$label_name] $total_messages messages traités"
      fi
    fi

    page_token="$(jq -r '.nextPageToken // empty' <<<"$RESPONSE_BODY")"
    if [[ -z "$page_token" ]]; then
      break
    fi
  done

  if (( total_messages == 0 )); then
    log "[$label_name] aucun message correspondant"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[$label_name] simulation terminée: $total_messages messages"
  elif [[ "$archive" == "true" ]]; then
    log "[$label_name] terminé: $total_messages messages archivés"
  else
    log "[$label_name] terminé: $total_messages messages classés"
  fi
}

main() {
  require_command curl
  require_command jq
  load_env_file
  require_env GOOGLE_CLIENT_ID
  require_env GOOGLE_CLIENT_SECRET
  require_env GMAIL_REFRESH_TOKEN

  if [[ ! -f "$RULES_FILE" ]]; then
    printf 'Fichier de règles introuvable: %s\n' "$RULES_FILE" >&2
    exit 1
  fi

  refresh_access_token
  fetch_labels

  while IFS= read -r rule_json; do
    apply_rule "$rule_json"
  done < <(jq -c '.[]' "$RULES_FILE")

  log 'Tri des emails terminé.'
}

main "$@"
