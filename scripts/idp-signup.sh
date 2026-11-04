#!/usr/bin/env bash
set -euo pipefail

IDP_BASE_URL="${IDP_BASE_URL:-http://auth.tolo.localhost}"
IDP_TENANT_ID="${IDP_TENANT_ID:-0123456789abcdef}"
IDP_USERNAME="${IDP_USERNAME:-user-owner}"
IDP_PASSWORD="${IDP_PASSWORD:-password}"
IDP_CLIENT_ID="${IDP_CLIENT_ID:-client-123}"
IDP_REDIRECT_URI="${IDP_REDIRECT_URI:-http://127.0.0.1:8080/login/oauth2/code/client-123}"
IDP_RESOURCE_HOST="${IDP_RESOURCE_HOST:-api.example.com}"
IDP_WEB_ORIGIN="${IDP_WEB_ORIGIN:-http://tolo.localhost}"

usage() {
    cat >&2 <<'USAGE'
usage: idp-signup.sh [-u base_url] [-t tenant_id]
  -u  IdP base URL  (env IDP_BASE_URL,  default http://auth.tolo.localhost)
  -t  tenant id     (env IDP_TENANT_ID, default 0123456789abcdef)
USAGE
    exit 2
}

while getopts ':u:t:h' opt; do
    case "${opt}" in
        u) IDP_BASE_URL="${OPTARG}" ;;
        t) IDP_TENANT_ID="${OPTARG}" ;;
        *) usage ;;
    esac
done

for cmd in curl openssl jq; do
    command -v "${cmd}" >/dev/null 2>&1 || { printf '%s is required\n' "${cmd}" >&2; exit 1; }
done

die() { printf 'idp-signup: %s\n' "$*" >&2; exit 1; }

cookies="$(mktemp)"
body="$(mktemp)"
trap 'rm -f "${cookies}" "${body}"' EXIT

login_challenge() {
    local location
    location="$(
        curl -sS -o /dev/null -D - -b "${cookies}" -c "${cookies}" -G \
            --data-urlencode 'response_type=code' \
            --data-urlencode "client_id=${IDP_CLIENT_ID}" \
            --data-urlencode "redirect_uri=${IDP_REDIRECT_URI}" \
            --data-urlencode "scope=$1" \
            --data-urlencode 'state=state' \
            --data-urlencode "resource=https://${IDP_RESOURCE_HOST}/tenants/${IDP_TENANT_ID}" \
            --data-urlencode "code_challenge=$(openssl rand 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=')" \
            --data-urlencode 'code_challenge_method=S256' \
            "${IDP_BASE_URL}/oauth2/authorize" |
            tr -d '\r' | awk 'tolower($1) == "location:" { print $2 }' | tail -1
    )"
    printf '%s' "${location}" | sed -n 's/.*[?&]challenge=\([^&]*\).*/\1/p'
}

post() {
    curl -sS -o "${body}" -w '%{http_code}' -b "${cookies}" -c "${cookies}" \
        -H 'Content-Type: application/json' \
        -H "Origin: ${IDP_WEB_ORIGIN}" \
        --data "$(jq -nc --arg u "${IDP_USERNAME}" --arg p "${IDP_PASSWORD}" --arg c "$2" \
            '{username: $u, password: $p, challenge: $c}')" \
        "${IDP_BASE_URL}$1"
}

challenge="$(login_challenge tenant.join)"
[ -n "${challenge}" ] || die 'authorize returned no signup challenge'

status="$(post /api/signup "${challenge}")"
if [ "${status}" = "409" ]; then
    challenge="$(login_challenge openid)"
    [ -n "${challenge}" ] || die 'authorize returned no login challenge'
    status="$(post /api/login "${challenge}")"
    [ "${status}" = "200" ] || die "login failed with HTTP ${status}"
elif [ "${status}" != "201" ]; then
    die "signup failed with HTTP ${status}: $(cat "${body}")"
fi

jq -er '.sub' "${body}"
