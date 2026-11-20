#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "${script_dir}/.." && pwd)"

PROJECT="${COMPOSE_PROJECT_NAME:-tolo-machine-session-e2e}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yml:compose.tm.yml:compose.idp.yml:compose.obs.yml:compose.edge.yml:compose.web.yml:compose.idp-web.yml}"

IDP_URL="${IDP_URL:-http://auth.tolo.localhost}"
ROOT_URL="${ROOT_URL:-http://tolo.localhost}"
TENANT_URL="${TENANT_URL:-http://test.tolo.localhost}"
TENANT_ID="${TOLO_TENANT_ID:-0123456789abcdef}"
EVENT_ID="${TOLO_EVENT_ID:-fedcba9876543210}"
IDP_USERNAME="${IDP_USERNAME:-user-owner}"
IDP_PASSWORD="${IDP_PASSWORD:-password}"
IDP_CLIENT_ID="${IDP_CLIENT_ID:-console-ui}"
IDP_REDIRECT_URI="${IDP_REDIRECT_URI:-${ROOT_URL}/api/auth/callback/tolo-idp}"
IDP_RESOURCE_HOST="${IDP_RESOURCE_HOST:-api.example.com}"
SESSION_COOKIE='__Host-tolo.session_token'

for cmd in curl jq openssl docker; do
    command -v "${cmd}" >/dev/null 2>&1 || { printf '%s is required\n' "${cmd}" >&2; exit 1; }
done

compose_args=()
IFS=':' read -r -a compose_files <<< "${COMPOSE_FILE}"
for file in "${compose_files[@]}"; do
    compose_args+=(-f "${file}")
done

compose() {
    (cd "${repo_dir}" && docker compose -p "${PROJECT}" "${compose_args[@]}" "$@")
}

die() {
    printf 'machine-session-e2e: %s\n' "$*" >&2
    if [ "${MACHINE_SESSION_E2E_DEBUG:-0}" = "1" ] && [ -n "${body:-}" ]; then
        printf '%s\n' "${body}" >&2
    fi
    exit 1
}

step() {
    printf '\n=== %s\n' "$*"
}

jar_dir="$(mktemp -d)"
status=''
body=''
location=''

url_host() {
    printf '%s' "$1" | sed -E 's#^[a-z]+://([^/]+).*#\1#'
}

cookie_header() {
    local file="${jar_dir}/$1"
    [ -s "${file}" ] || return 0
    awk -F '\t' '{ printf "%s%s=%s", (NR > 1 ? "; " : ""), $1, $2 }' "${file}"
}

cookie_value() {
    local file="${jar_dir}/$1"
    [ -s "${file}" ] || return 0
    awk -F '\t' -v n="$2" '$1 == n { print $2 }' "${file}"
}

set_cookie() {
    local file="${jar_dir}/$1"
    touch "${file}"
    awk -F '\t' -v n="$2" '$1 != n' "${file}" > "${file}.tmp"
    mv "${file}.tmp" "${file}"
    [ -z "$3" ] || printf '%s\t%s\n' "$2" "$3" >> "${file}"
}

store_cookies() {
    local host="$1" line pair value
    while IFS= read -r line; do
        pair="${line%%;*}"
        value="${pair#*=}"
        if printf '%s' "${line}" | grep -qiE 'max-age=0|expires=thu, 01 jan 1970'; then
            value=''
        fi
        set_cookie "${host}" "${pair%%=*}" "${value}"
    done < <(printf '%s\n' "$2" | tr -d '\r' | sed -n 's/^[Ss][Ee][Tt]-[Cc][Oo][Oo][Kk][Ii][Ee]: //p')
}

request() {
    local method="$1" url="$2"
    shift 2
    local host cookies headers_file body_file headers
    host="$(url_host "${url}")"
    cookies="$(cookie_header "${host}")"
    headers_file="$(mktemp)"
    body_file="$(mktemp)"
    local args=(-sS --connect-timeout 3 --max-time 20 -X "${method}" -D "${headers_file}" -o "${body_file}" -w '%{http_code}')
    [ -z "${cookies}" ] || args+=(-H "Cookie: ${cookies}")
    if ! status="$(curl "${args[@]}" "$@" "${url}")"; then
        rm -f "${headers_file}" "${body_file}"
        die "request failed: ${method} ${url%%\?*}"
    fi
    headers="$(cat "${headers_file}")"
    body="$(cat "${body_file}")"
    rm -f "${headers_file}" "${body_file}"
    store_cookies "${host}" "${headers}"
    location="$(printf '%s\n' "${headers}" | tr -d '\r' | awk 'tolower($1) == "location:" { print $2 }' | tail -1)"
    case "${location}" in
        /*) location="$(printf '%s' "${url}" | sed -E 's#^([a-z]+://[^/]+).*#\1#')${location}" ;;
    esac
    printf '  %s %s -> %s %s\n' "${method}" "${url%%\?*}" "${status}" "${location%%\?*}"
}

follow() {
    local hops=0
    while :; do
        case "${status}" in 301|302|303|307|308) ;; *) return 0 ;; esac
        case "${location}" in *"/login?challenge="*) return 0 ;; esac
        hops=$((hops + 1))
        [ "${hops}" -le 20 ] || die "too many redirects, last: ${location%%\?*}"
        request GET "${location}"
    done
}

idp_login() {
    local challenge
    challenge="$(printf '%s' "${location}" | sed -n 's/.*[?&]challenge=\([^&]*\).*/\1/p')"
    [ -n "${challenge}" ] || die "expected an IdP login challenge, got: ${status} ${location%%\?*}"
    request POST "${IDP_URL}/api/login" \
        -H 'Content-Type: application/json' \
        -H "Origin: ${ROOT_URL}" \
        --data "$(jq -nc --arg u "${IDP_USERNAME}" --arg p "${IDP_PASSWORD}" --arg c "${challenge}" \
            '{username: $u, password: $p, challenge: $c}')"
    [ "${status}" = "200" ] || die "IdP login: expected HTTP 200, got ${status}"
    request GET "${IDP_URL}/oauth2/authorize?challenge=${challenge}"
    follow
}

idp_authorize() {
    local verifier challenge
    verifier="$(openssl rand 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
    challenge="$(printf '%s' "${verifier}" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
    request GET "${IDP_URL}/oauth2/authorize" -G \
        --data-urlencode 'response_type=code' \
        --data-urlencode "client_id=${IDP_CLIENT_ID}" \
        --data-urlencode "redirect_uri=${IDP_REDIRECT_URI}" \
        --data-urlencode 'scope=openid tenant.read' \
        --data-urlencode 'state=probe' \
        --data-urlencode "resource=https://${IDP_RESOURCE_HOST}/tenants/${TENANT_ID}" \
        --data-urlencode "code_challenge=${challenge}" \
        --data-urlencode 'code_challenge_method=S256'
}

rpc() {
    request POST "${TENANT_URL}/rpc/$1" \
        -H 'Content-Type: application/json' \
        -H 'x-csrf-token: orpc' \
        -d "$(jq -nc --argjson input "$2" '{json: $input}')"
}

db() {
    compose exec -T web-auth-db psql -U tolo_web_auth -d tolo_web_auth -tAc "$1" | tr -d '[:space:]'
}

session_token() {
    local value
    value="$(cookie_value "$(url_host "${TENANT_URL}")" "${SESSION_COOKIE}")"
    value="${value//%2E/.}"
    printf '%s' "${value%%.*}"
}

open_management() {
    curl -sS --connect-timeout 3 --max-time 20 -o /dev/null -w '%{http_code} %{redirect_url}' \
        -H "Cookie: ${SESSION_COOKIE}=${staff_cookie}" "${TENANT_URL}/management"
}

wait_for() {
    local url="$1" label="$2" code
    for _ in $(seq 1 90); do
        code="$(curl -sS --connect-timeout 3 --max-time 20 -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || true)"
        if [ "${code}" != "000" ] && [ "${code}" -lt 500 ] 2>/dev/null; then
            printf '  %s ready (HTTP %s)\n' "${label}" "${code}"
            return 0
        fi
        sleep 2
    done
    die "${label} did not become ready: ${url}"
}

preflight() {
    if docker compose -p tolo ps -q 2>/dev/null | grep -q .; then
        die 'the main tolo stack is running; run `task down` first'
    fi
    if docker ps --format '{{.Names}}' | grep -qx 'tolo-fakeidp'; then
        die 'the fake IdP is running; run `task fakeidp:down` first'
    fi
    if [ -z "${TOLO_WEB_IMAGE:-}" ] && [ -z "${NPM_TOKEN:-}" ]; then
        die 'set TOLO_WEB_IMAGE to a tolo-web image, or NPM_TOKEN to build it'
    fi
}

cleanup() {
    local code=$?
    rm -rf "${jar_dir}"
    if [ "${KEEP_STACK:-0}" = "1" ]; then
        printf '\nkeeping the compose stack (KEEP_STACK=1): project=%s\n' "${PROJECT}"
        exit "${code}"
    fi
    printf '\n=== cleanup\n'
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    exit "${code}"
}

preflight
trap cleanup EXIT
cd "${repo_dir}"

printf 'machine-session-e2e: project=%s\n' "${PROJECT}"
printf 'machine-session-e2e: compose=%s\n' "${COMPOSE_FILE}"

step '0. start the real-IdP stack and seed the staff user'
compose down -v --remove-orphans >/dev/null 2>&1 || true
compose up -d --wait \
    keygen server nats push-relay tenant-management \
    idp ingress observation firebase-emulator edge-bridge web
wait_for "${IDP_URL}/oauth2/jwks" 'idp'
wait_for "${TENANT_URL}/" 'web'
staff_sub="$(IDP_BASE_URL="${IDP_URL}" IDP_TENANT_ID="${TENANT_ID}" \
    IDP_USERNAME="${IDP_USERNAME}" IDP_PASSWORD="${IDP_PASSWORD}" \
    "${script_dir}/idp-signup.sh" | tail -1 | tr -d '[:space:]')"
[ -n "${staff_sub}" ] || die 'idp-signup.sh returned no sub'
TOLO_OWNER_SUB="${staff_sub}" compose run --rm tenant-management-seed >/dev/null
printf '  staff sub=%s\n' "${staff_sub}"

step '1. log in as staff through the BFF'
request GET "${TENANT_URL}/auth/login?return=%2Fmanagement"
follow
idp_login
staff_token="$(session_token)"
[ -n "${staff_token}" ] || die 'the staff login set no session cookie on the tenant host'
[ "$(db "SELECT count(*) FROM \"session\" WHERE \"token\" = '${staff_token}' AND \"kind\" = 'staff';")" = "1" ] \
    || die 'the staff session is not in the auth database'
staff_cookie="$(cookie_value "$(url_host "${TENANT_URL}")" "${SESSION_COOKIE}")"
[ "$(open_management)" = "200 " ] || die 'the staff cookie does not open the management page'
printf '  staff session stored and opens the management page\n'

idp_authorize
case "${location}" in
    "${IDP_REDIRECT_URI}?"*code=*) printf '  the IdP issues a code without a login while its session is live\n' ;;
    *) die "expected a code from the live IdP session, got: ${status} ${location%%\?*}" ;;
esac

step '2. register an observation page and call a console procedure as staff'
rpc observation/registerEdgeDevice "$(jq -nc --arg e "${EVENT_ID}" \
    '{eventId: $e, name: "machine-session-e2e-page", observationPointNames: ["machine-session-e2e-point"]}')"
[ "${status}" = "200" ] || die "registerEdgeDevice: expected HTTP 200, got ${status}"
page_id="$(printf '%s' "${body}" | jq -r '.json.device.edgeDeviceId // empty')"
[ -n "${page_id}" ] || die 'registerEdgeDevice returned no edge_device_id'
printf '  page edge_device_id=%s\n' "${page_id}"
rpc observation/listEdgeDevices "$(jq -nc --arg e "${EVENT_ID}" '{eventId: $e}')"
[ "${status}" = "200" ] || die "staff listEdgeDevices: expected HTTP 200, got ${status}"

step '3. set up the observation page on this browser'
return_path="/event/${EVENT_ID}/observation/${page_id}"
request GET "${TENANT_URL}/api/auth/machine/start" -G \
    --data-urlencode "eventId=${EVENT_ID}" \
    --data-urlencode "pageEdgeDeviceId=${page_id}" \
    --data-urlencode "return=${return_path}"
follow
idp_login
[ "${location}" = "" ] && [ "${status}" = "200" ] || die "the setup did not end on the page: ${status} ${location%%\?*}"
machine_token="$(session_token)"
[ -n "${machine_token}" ] && [ "${machine_token}" != "${staff_token}" ] \
    || die 'the setup set no new session cookie'

step '4. check the sessions and the setup record'
[ "$(db "SELECT count(*) FROM \"session\" WHERE \"token\" = '${staff_token}';")" = "0" ] \
    || die 'the staff session of this browser was not deleted'
[ "$(db "SELECT \"kind\" || ':' || \"edgeDeviceId\" FROM \"session\" WHERE \"token\" = '${machine_token}';")" = "machine:${page_id}" ] \
    || die 'the browser does not hold a machine session for the page'
printf '  the staff session was deleted and the browser holds a machine session for %s\n' "${page_id}"
[ "$(db "SELECT count(*) FROM \"machineSetupRecord\" WHERE \"tenantId\" = '${TENANT_ID}' AND \"eventId\" = '${EVENT_ID}' AND \"edgeDeviceId\" = '${page_id}' AND \"subject\" = '${staff_sub}';")" = "1" ] \
    || die 'the setup record for the page and the staff subject is missing'
printf '  the setup record names the page and the staff subject\n'

old_staff="$(open_management)"
case "${old_staff}" in
    *"/auth/login"*) printf '  the old staff cookie is sent to the login\n' ;;
    *) die "the old staff cookie still opens the management page: ${old_staff%%\?*}" ;;
esac

step '5. check what the machine session may call'
rpc observation/listObservationPoints "$(jq -nc --arg e "${EVENT_ID}" --arg d "${page_id}" '{eventId: $e, edgeDeviceId: $d}')"
[ "${status}" = "200" ] || die "machine listObservationPoints: expected HTTP 200, got ${status}"
rpc observation/listEdgeDevices "$(jq -nc --arg e "${EVENT_ID}" '{eventId: $e}')"
[ "${status}" = "403" ] || die "machine listEdgeDevices: expected HTTP 403, got ${status}"
printf '  the machine session reaches its own procedures and is refused a console procedure\n'

step '6. check that the IdP login ended'
idp_authorize
case "${location}" in
    *"/login?challenge="*) printf '  the IdP asks for a login again\n' ;;
    *) die "the IdP did not ask for a login after the setup: ${status} ${location%%\?*}" ;;
esac

printf '\nmachine session e2e passed: tenant=%s event=%s page=%s\n' "${TENANT_ID}" "${EVENT_ID}" "${page_id}"
