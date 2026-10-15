#!/usr/bin/env bash
set -euo pipefail

FAKEIDP_BASE_URL="${FAKEIDP_BASE_URL:-http://localhost:8082}"
FAKEIDP_TOKEN_USE="${FAKEIDP_TOKEN_USE:-tenant_access}"
FAKEIDP_SUB="${FAKEIDP_SUB:-user-123}"
FAKEIDP_CLIENT_ID="${FAKEIDP_CLIENT_ID:-client-123}"
FAKEIDP_SCOPE="${FAKEIDP_SCOPE:-tenant.read tenant.write events.read events.manage}"
FAKEIDP_TENANT_ID="${FAKEIDP_TENANT_ID:-}"
FAKEIDP_EVENT_ID="${FAKEIDP_EVENT_ID:-}"
FAKEIDP_TTL_SECONDS="${FAKEIDP_TTL_SECONDS:-0}"

usage() {
    cat >&2 <<'EOF'
usage: fakeidp-token.sh [-u base_url] [-k token_use] [-b sub] [-s scope] [-t tenant_id] [-e event_id] [-c client_id] [-l ttl_seconds]
  -u  fakeidp base URL  (env FAKEIDP_BASE_URL,   default http://localhost:8082)
  -k  token_use         (env FAKEIDP_TOKEN_USE,  tenant_access | event_access | registration)
  -b  subject           (env FAKEIDP_SUB,        default user-123)
  -s  space separated scopes (env FAKEIDP_SCOPE)
  -t  tenant id         (env FAKEIDP_TENANT_ID,  16 lowercase hex; omit for registration)
  -e  event id          (env FAKEIDP_EVENT_ID)
  -c  client id         (env FAKEIDP_CLIENT_ID,  default client-123)
  -l  ttl seconds       (env FAKEIDP_TTL_SECONDS, 0 leaves the fakeidp default)
EOF
    exit 2
}

while getopts ':u:k:b:s:t:e:c:l:h' opt; do
    case "${opt}" in
        u) FAKEIDP_BASE_URL="${OPTARG}" ;;
        k) FAKEIDP_TOKEN_USE="${OPTARG}" ;;
        b) FAKEIDP_SUB="${OPTARG}" ;;
        s) FAKEIDP_SCOPE="${OPTARG}" ;;
        t) FAKEIDP_TENANT_ID="${OPTARG}" ;;
        e) FAKEIDP_EVENT_ID="${OPTARG}" ;;
        c) FAKEIDP_CLIENT_ID="${OPTARG}" ;;
        l) FAKEIDP_TTL_SECONDS="${OPTARG}" ;;
        *) usage ;;
    esac
done

for cmd in curl jq; do
    command -v "${cmd}" >/dev/null 2>&1 || { printf '%s is required\n' "${cmd}" >&2; exit 1; }
done

body="$(
    jq -nc \
        --arg token_use "${FAKEIDP_TOKEN_USE}" \
        --arg sub "${FAKEIDP_SUB}" \
        --arg client_id "${FAKEIDP_CLIENT_ID}" \
        --arg scope "${FAKEIDP_SCOPE}" \
        --arg tenant_id "${FAKEIDP_TENANT_ID}" \
        --arg event_id "${FAKEIDP_EVENT_ID}" \
        --argjson ttl "${FAKEIDP_TTL_SECONDS}" \
        '{token_use: $token_use, sub: $sub, client_id: $client_id, scope: $scope}
         + (if $tenant_id == "" then {} else {tenant_id: $tenant_id} end)
         + (if $event_id == "" then {} else {event_id: $event_id} end)
         + (if $ttl == 0 then {} else {ttl_seconds: $ttl} end)'
)"

response="$(curl -sS -H 'Content-Type: application/json' -d "${body}" "${FAKEIDP_BASE_URL}/token")"
token="$(printf '%s' "${response}" | jq -r '.access_token // empty')"
[ -n "${token}" ] || { printf 'fakeidp-token: token request failed: %s\n' "${response}" >&2; exit 1; }

printf '%s\n' "${token}"
