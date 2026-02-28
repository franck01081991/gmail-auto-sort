#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/gmail-sort.sh"

DRY_RUN="${DRY_RUN:-true}"

labels_to_json() {
  local labels_json="$1"

  jq -nc \
    --argjson labels "$labels_json" \
    '
      [ $labels[] ]
    ' \
    | while IFS= read -r label_names; do
        jq -r '.[]' <<<"$label_names" | while IFS= read -r label_name; do
          [[ -n "$label_name" ]] || continue
          ensure_label "$label_name"
        done >/tmp/gmail-label-ids.$$
        jq -Rsc 'split("\n")[:-1]' </tmp/gmail-label-ids.$$
        rm -f /tmp/gmail-label-ids.$$
      done
}

existing_labels_to_json() {
  local labels_json="$1"

  jq -r '.[]' <<<"$labels_json" | while IFS= read -r label_name; do
    [[ -n "$label_name" ]] || continue
    lookup_label_id "$label_name"
  done | jq -Rsc 'split("\n")[:-1] | map(select(length > 0))'
}

mutate_query() {
  local operation_name="$1"
  local query="$2"
  local add_labels_json="${3:-[]}"
  local remove_labels_json="${4:-[]}"
  local trash="${5:-false}"
  local max_messages="${6:-0}"
  local total_messages=0
  local page_token=""
  local ids_json message_count remaining_messages payload
  local add_ids_json remove_ids_json

  add_ids_json="$(labels_to_json "$add_labels_json")"
  remove_ids_json="$(existing_labels_to_json "$remove_labels_json")"

  while true; do
    if (( max_messages > 0 && total_messages >= max_messages )); then
      break
    fi

    local url
    url="$GMAIL_API_BASE/messages?maxResults=500&q=$(urlencode "$query")"
    if [[ -n "$page_token" ]]; then
      url="${url}&pageToken=$(urlencode "$page_token")"
    fi

    api_request GET "$url"
    ids_json="$(jq -c '[.messages[]?.id]' <<<"$RESPONSE_BODY")"
    message_count="$(jq 'length' <<<"$ids_json")"

    if (( message_count > 0 )); then
      if (( max_messages > 0 )); then
        remaining_messages=$((max_messages - total_messages))
        if (( message_count > remaining_messages )); then
          ids_json="$(jq -c --argjson limit "$remaining_messages" '.[:$limit]' <<<"$ids_json")"
          message_count="$remaining_messages"
        fi
      fi

      total_messages=$((total_messages + message_count))

      if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN][$operation_name] $total_messages messages détectés"
      else
        if [[ "$trash" == "true" ]]; then
          while IFS= read -r message_id; do
            [[ -n "$message_id" ]] || continue
            api_request POST "$GMAIL_API_BASE/messages/$message_id/trash" '{}'
          done < <(jq -r '.[]' <<<"$ids_json")
        else
          payload="$(
            jq -nc \
              --argjson ids "$ids_json" \
              --argjson add_ids "$add_ids_json" \
              --argjson remove_ids "$remove_ids_json" \
              '{
                ids: $ids,
                addLabelIds: $add_ids,
                removeLabelIds: $remove_ids
              }'
          )"
          api_request POST "$GMAIL_API_BASE/messages/batchModify" "$payload"
        fi
        log "[$operation_name] $total_messages messages traités"
      fi
    fi

    page_token="$(jq -r '.nextPageToken // empty' <<<"$RESPONSE_BODY")"
    if [[ -z "$page_token" ]] || (( max_messages > 0 && total_messages >= max_messages )); then
      break
    fi
  done

  if (( total_messages == 0 )); then
    log "[$operation_name] aucun message correspondant"
  elif [[ "$DRY_RUN" == "true" ]]; then
    log "[$operation_name] simulation terminée: $total_messages messages"
  elif [[ "$trash" == "true" ]]; then
    log "[$operation_name] terminé: $total_messages messages envoyés à la corbeille"
  else
    log "[$operation_name] terminé: $total_messages messages migrés"
  fi
}

main() {
  require_command curl
  require_command jq
  load_env_file
  require_env GOOGLE_CLIENT_ID
  require_env GOOGLE_CLIENT_SECRET
  require_env GMAIL_REFRESH_TOKEN

  refresh_access_token
  fetch_labels

  mutate_query \
    "☁️ Cloud notifications" \
    'from:PlatformNotifications-noreply@google.com -label:"☁️ Cloud"' \
    '["☁️ Cloud"]' \
    '["📰 Newsletters","📅 À Traiter"]' \
    false \
    2000

  mutate_query \
    "Reclassement alertes emploi" \
    '((label:"💼 Recrutement" OR label:"📌 Administratif") (from:linkedin.com OR from:hellowork.com OR from:collective.work OR from:notify-noreply@google.com)) OR (label:"💼 Recrutement" from:jobs-noreply@linkedin.com)' \
    '["🔎 Alertes Emploi"]' \
    '["💼 Recrutement","📌 Administratif","📅 À Traiter","UNREAD","INBOX"]' \
    false \
    5000

  mutate_query \
    "Reclassement ATS utiles" \
    'label:"📌 Administratif" (from:indeed.com OR from:recruitee.com OR from:greenhouse.io OR from:lever.co OR from:teamtailor.com OR from:smartrecruiters.com OR from:workday.com)' \
    '["💼 Recrutement"]' \
    '["📌 Administratif"]' \
    false \
    2000

  mutate_query \
    "Nettoyage À Traiter bruit et ancien" \
    'label:"📅 À Traiter" (older_than:14d OR label:"📰 Newsletters" OR label:"🔎 Alertes Emploi" OR label:"🛒 Commandes" OR label:"📺 Streaming/Loisirs" OR label:"☁️ Cloud" OR from:franck.sembin.apou@gmail.com)' \
    '[]' \
    '["📅 À Traiter"]' \
    false \
    10000

  mutate_query \
    "Marquage lu historique bruit" \
    '(label:"📰 Newsletters" OR label:"🔎 Alertes Emploi" OR label:"🛒 Commandes" OR label:"📺 Streaming/Loisirs") is:unread older_than:7d' \
    '[]' \
    '["UNREAD"]' \
    false \
    20000

  log 'Migration de la boîte terminée.'
}

main "$@"
