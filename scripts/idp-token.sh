#!/usr/bin/env bash
set -euo pipefail

IDP_BASE_URL="${IDP_BASE_URL:-http://localhost:18080}"
IDP_TENANT_ID="${IDP_TENANT_ID:-0123456789abcdef}"
IDP_SCOPE="${IDP_SCOPE:-openid tenant.read events.read}"
IDP_USERNAME="${IDP_USERNAME:-user-123}"
IDP_PASSWORD="${IDP_PASSWORD:-password}"
IDP_CLIENT_ID="${IDP_CLIENT_ID:-client-123}"
IDP_CLIENT_SECRET="${IDP_CLIENT_SECRET:-secret}"
IDP_REDIRECT_URI="${IDP_REDIRECT_URI:-http://127.0.0.1:8080/login/oauth2/code/client-123}"
IDP_AUDIENCE="${IDP_AUDIENCE:-backend-api}"
IDP_EVENT_ID="${IDP_EVENT_ID:-}"
IDP_RESOURCE_HOST="${IDP_RESOURCE_HOST:-api.example.com}"

usage() {
    cat >&2 <<'EOF'
usage: idp-token.sh [-u base_url] [-t tenant_id] [-s scope] [-e event_id]
  -u  IdP base URL            (env IDP_BASE_URL,   default http://localhost:18080)
  -t  tenant id               (env IDP_TENANT_ID,  default 0123456789abcdef)
  -s  space separated scopes  (env IDP_SCOPE,      default "openid tenant.read events.read")
  -e  event id                (env IDP_EVENT_ID,   exchanges the token for an event_access token)
EOF
    exit 2
}

while getopts ':u:t:s:e:h' opt; do
    case "${opt}" in
        u) IDP_BASE_URL="${OPTARG}" ;;
        t) IDP_TENANT_ID="${OPTARG}" ;;
        s) IDP_SCOPE="${OPTARG}" ;;
        e) IDP_EVENT_ID="${OPTARG}" ;;
        *) usage ;;
    esac
done

for cmd in curl openssl jq; do
    command -v "${cmd}" >/dev/null 2>&1 || { printf '%s is required\n' "${cmd}" >&2; exit 1; }
done

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

die() { printf 'idp-token: %s\n' "$*" >&2; exit 1; }

cookies="$(mktemp)"
trap 'rm -f "${cookies}"' EXIT

verifier="$(openssl rand 32 | b64url)"
challenge="$(printf '%s' "${verifier}" | openssl dgst -sha256 -binary | b64url)"

login_status="$(
    curl -sS -o /dev/null -w '%{http_code}' -c "${cookies}" \
        -H 'Content-Type: application/json' \
        --data "$(jq -nc --arg u "${IDP_USERNAME}" --arg p "${IDP_PASSWORD}" --arg t "${IDP_TENANT_ID}" \
            '{username: $u, password: $p, tenantId: $t}')" \
        "${IDP_BASE_URL}/api/login"
)"
[ "${login_status}" = "200" ] || die "login failed with HTTP ${login_status}"

location="$(
    curl -sS -o /dev/null -D - -b "${cookies}" -c "${cookies}" -G \
        --data-urlencode 'response_type=code' \
        --data-urlencode "client_id=${IDP_CLIENT_ID}" \
        --data-urlencode "redirect_uri=${IDP_REDIRECT_URI}" \
        --data-urlencode "scope=${IDP_SCOPE}" \
        --data-urlencode 'state=state' \
        --data-urlencode 'nonce=nonce' \
        --data-urlencode "audience=${IDP_AUDIENCE}" \
        --data-urlencode "code_challenge=${challenge}" \
        --data-urlencode 'code_challenge_method=S256' \
        "${IDP_BASE_URL}/oauth2/authorize" |
        tr -d '\r' | awk 'tolower($1) == "location:" { print $2 }' | tail -1
)"
[ -n "${location}" ] || die 'authorize returned no Location header'

code="$(printf '%s' "${location}" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')"
[ -n "${code}" ] || die "authorize returned no code: ${location}"

token_response="$(
    curl -sS -u "${IDP_CLIENT_ID}:${IDP_CLIENT_SECRET}" \
        --data-urlencode 'grant_type=authorization_code' \
        --data-urlencode "code=${code}" \
        --data-urlencode "redirect_uri=${IDP_REDIRECT_URI}" \
        --data-urlencode "code_verifier=${verifier}" \
        "${IDP_BASE_URL}/oauth2/token"
)"
access_token="$(printf '%s' "${token_response}" | jq -r '.access_token // empty')"
[ -n "${access_token}" ] || die "token request failed: ${token_response}"

if [ -n "${IDP_EVENT_ID}" ]; then
    exchange_scope="$(printf '%s\n' ${IDP_SCOPE} | grep -v '^openid$' | tr '\n' ' ' | sed 's/ *$//')"
    exchange_response="$(
        curl -sS -u "${IDP_CLIENT_ID}:${IDP_CLIENT_SECRET}" \
            --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
            --data-urlencode 'subject_token_type=urn:ietf:params:oauth:token-type:access_token' \
            --data-urlencode "subject_token=${access_token}" \
            --data-urlencode "audience=${IDP_AUDIENCE}" \
            --data-urlencode "resource=https://${IDP_RESOURCE_HOST}/tenants/${IDP_TENANT_ID}/events/${IDP_EVENT_ID}" \
            --data-urlencode "scope=${exchange_scope}" \
            "${IDP_BASE_URL}/oauth2/token"
    )"
    access_token="$(printf '%s' "${exchange_response}" | jq -r '.access_token // empty')"
    [ -n "${access_token}" ] || die "token exchange failed: ${exchange_response}"
fi

printf '%s\n' "${access_token}"
