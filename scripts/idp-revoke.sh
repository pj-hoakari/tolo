#!/usr/bin/env bash
set -euo pipefail

IDP_BASE_URL="${IDP_BASE_URL:-http://localhost:18080}"
IDP_CLIENT_ID="${IDP_CLIENT_ID:-client-123}"
IDP_CLIENT_SECRET="${IDP_CLIENT_SECRET:-secret}"

if [ "$#" -ne 1 ]; then
    printf 'usage: idp-revoke.sh <access-token>\n' >&2
    exit 2
fi

status="$(
    curl -sS -o /dev/null -w '%{http_code}' \
        -u "${IDP_CLIENT_ID}:${IDP_CLIENT_SECRET}" \
        --data-urlencode "token=$1" \
        --data-urlencode 'token_type_hint=access_token' \
        "${IDP_BASE_URL}/oauth2/revoke"
)"
printf 'HTTP %s\n' "${status}"
[ "${status}" = "200" ]
