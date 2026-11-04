#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "${script_dir}/.." && pwd)"

PROJECT="${COMPOSE_PROJECT_NAME:-tolo-camera-e2e}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yml:compose.idp.yml:compose.obs.yml:compose.edge.yml:compose.web.yml:compose.camera.yml}"

IDP_URL="${IDP_URL:-http://localhost:18080}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:18090}"
BRIDGE_URL="${BRIDGE_URL:-http://localhost:18787}"
FIRESTORE_URL="${FIRESTORE_URL:-http://localhost:18086}"
AUTH_URL="${AUTH_URL:-http://localhost:19099}"
WEB_URL="${WEB_URL:-http://localhost:13000}"
WEB_HOST="${WEB_HOST:-test.localhost:13000}"
WEB_MACHINE_URL="${WEB_MACHINE_URL:-http://localhost:13001}"
WEB_MACHINE_HOST="${WEB_MACHINE_HOST:-test.localhost:13001}"

TENANT_ID="${TOLO_TENANT_ID:-0123456789abcdef}"
EVENT_ID="${TOLO_EVENT_ID:-fedcba9876543210}"
IDP_CLIENT_ID="${IDP_CLIENT_ID:-console-ui}"
IDP_CLIENT_SECRET="${IDP_CLIENT_SECRET:-${TOLO_IDP_SEED_CLIENT_SECRET:-secret}}"
IDP_REDIRECT_URI="${IDP_REDIRECT_URI:-http://127.0.0.1:13001/api/auth/callback/console-ui}"
IDP_USERNAME="${IDP_USERNAME:-user-123}"
IDP_PASSWORD="${IDP_PASSWORD:-password}"
CONNECTION_CLIENT_ID="${CONNECTION_CLIENT_ID:-observation-connection}"
CONNECTION_REDIRECT_URI="${CONNECTION_REDIRECT_URI:-http://localhost:13000/api/auth/connection/callback}"
WEB_DB_USER="${WEB_DB_USER:-tolo_web}"
WEB_DB_NAME="${WEB_DB_NAME:-tolo_web}"

DOCUMENTS="${FIRESTORE_URL}/v1/projects/demo-tolo/databases/(default)/documents"

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

status=''
body=''

die() {
    printf 'camera-e2e: %s\n' "$*" >&2
    if [ "${CAMERA_E2E_DEBUG:-0}" = "1" ] && [ -n "${body}" ]; then
        printf '%s\n' "${body}" | jq . 2>/dev/null || printf '%s\n' "${body}"
    fi
    exit 1
}

step() {
    printf '\n=== %s\n' "$*"
}

call() {
    local method="$1" url="$2"
    shift 2

    local response
    response="$(curl -sS --connect-timeout 3 --max-time 20 -X "${method}" -w $'\n%{http_code}' "$@" "${url}")" \
        || die "request failed: ${method} ${url}"

    status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    printf '  HTTP %s\n' "${status}"
}

call_redirect() {
    local method="$1" url="$2"
    shift 2
    local response
    response="$(curl -sS --connect-timeout 3 --max-time 20 -X "${method}" -D - -o /dev/null -w $'\n%{http_code}' "$@" "${url}")" \
        || die "request failed: ${method} ${url}"
    status="${response##*$'\n'}"
    body=""
    last_headers="${response%$'\n'*}"
    location="$(printf '%s' "${last_headers}" | tr -d '\r' | awk 'tolower($1) == "location:" { print $2 }' | tail -1)"
    printf '  HTTP %s\n' "${status}"
}

expect_status() {
    local expected="$1" label="$2"
    [ "${status}" = "${expected}" ] || die "${label}: expected HTTP ${expected}, got ${status}"
}

expect_not_status() {
    local unexpected="$1" label="$2"
    [ "${status}" != "${unexpected}" ] || die "${label}: expected a failure, got HTTP ${status}"
}

jwt_claims() {
    local token="$1" payload
    payload="$(printf '%s' "${token}" | awk -F. '{ print $2 }')"
    [ -n "${payload}" ] || die 'the token is not a JWT'
    case $((${#payload} % 4)) in
        2) payload="${payload}==" ;;
        3) payload="${payload}=" ;;
    esac
    printf '%s' "${payload}" | tr '_-' '/+' | openssl base64 -d -A
}

claim() {
    jwt_claims "$1" | jq -r --arg name "$2" '
        if has($name) then .[$name] else (.claims[$name] // empty) end
    '
}

assert_claim() {
    local token="$1" name="$2" expected="$3"
    local actual
    actual="$(claim "${token}" "${name}")"
    [ "${actual}" = "${expected}" ] || die "claim ${name} = '${actual}', want '${expected}'"
}

assert_missing_claim() {
    local token="$1" name="$2"
    jwt_claims "${token}" | jq -e --arg name "${name}" '
        ((has($name)) or ((.claims // {}) | has($name))) | not
    ' >/dev/null || die "claim ${name} is present, want it absent"
}

wait_for_http() {
    local url="$1" label="$2" attempts="${3:-60}"
    local attempt code
    for attempt in $(seq 1 "${attempts}"); do
        code="$(curl -sS --connect-timeout 3 --max-time 20 -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || true)"
        if [ "${code}" -ge 200 ] 2>/dev/null && [ "${code}" -lt 300 ]; then
            printf '  %s ready (HTTP %s)\n' "${label}" "${code}"
            return 0
        fi
        sleep 2
    done
    die "${label} did not become ready: ${url}"
}

idp_login() {
    local cookies="$1"
    local response
    response="$(curl -sS --connect-timeout 3 --max-time 20 -o /dev/null -w '%{http_code}' -c "${cookies}" \
        -H 'Content-Type: application/json' \
        --data "$(jq -nc --arg u "${IDP_USERNAME}" --arg p "${IDP_PASSWORD}" --arg t "${TENANT_ID}" \
            '{username: $u, password: $p, tenantId: $t}')" \
        "${IDP_URL}/api/login")"
    [ "${response}" = "200" ] || die "IdP login for the connection flow failed with HTTP ${response}"
}

tenant_web_url() {
    printf '%s%s' "${WEB_MACHINE_URL}" "$(printf '%s' "$1" | sed -E 's#^[a-z]+://[^/]+##')"
}

cookie_header() {
    local dir="$1" file out=''
    for file in "${dir}"/*; do
        [ -e "${file}" ] || continue
        out="${out}$(basename "${file}")=$(cat "${file}"); "
    done
    printf '%s' "${out%; }"
}

absorb_cookies() {
    local dir="$1" line pair name value
    [ -n "${last_headers:-}" ] || return 0
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$(printf '%s' "${line}" | tr '[:upper:]' '[:lower:]')" in
            set-cookie:*)
                pair="${line#*: }"
                pair="${pair%%;*}"
                name="${pair%%=*}"
                value="${pair#*=}"
                [ -n "${name}" ] && printf '%s' "${value}" > "${dir}/${name}"
                ;;
        esac
    done <<< "${last_headers}"
}

machine_login() {
    local cookies="$1"
    local return_encoded
    return_encoded="$(jq -rn --arg v "/management" '$v|@uri')"
    machine_cookie_header="$(cookie_header "${cookies}")"

    call_redirect POST "${IDP_URL}/api/login" \
        -H 'Content-Type: application/json' \
        --data "$(jq -nc --arg u "${IDP_USERNAME}" --arg p "${IDP_PASSWORD}" --arg t "${TENANT_ID}" \
            '{username: $u, password: $p, tenantId: $t}')" \
        -H "Cookie: ${machine_cookie_header}"
    absorb_cookies "${cookies}"
    expect_status 200 'IdP login for the machine flow'

    machine_cookie_header="$(cookie_header "${cookies}")"
    call_redirect GET "${WEB_MACHINE_URL}/auth/login?return=${return_encoded}" \
        -H "Host: ${WEB_MACHINE_HOST}" -H "Cookie: ${machine_cookie_header}"
    absorb_cookies "${cookies}"
    expect_status 302 'BFF machine login start'
    [ -n "${location}" ] || die 'BFF machine login start returned no Location'

    machine_cookie_header="$(cookie_header "${cookies}")"
    call_redirect GET "${location}" -H "Cookie: ${machine_cookie_header}"
    absorb_cookies "${cookies}"
    expect_status 302 'BFF machine login begin'
    [ -n "${location}" ] || die 'BFF machine login begin returned no Location'

    local authorize_path
    authorize_path="$(printf '%s' "${location}" | sed -E 's#^[a-z]+://[^/]+##')"
    machine_cookie_header="$(cookie_header "${cookies}")"
    call_redirect GET "${IDP_URL}${authorize_path}" -H "Cookie: ${machine_cookie_header}"
    absorb_cookies "${cookies}"
    expect_status 302 'IdP login authorize'

    local callback_path callback_url
    callback_path="$(printf '%s' "${location}" | sed -E 's#^[a-z]+://[^/]+##')"
    callback_url="${WEB_MACHINE_URL}${callback_path}"
    machine_cookie_header="$(cookie_header "${cookies}")"
    call_redirect GET "${callback_url}" -H "Cookie: ${machine_cookie_header}"
    absorb_cookies "${cookies}"
    expect_status 302 'BFF machine login callback'
    [ -n "${location}" ] || die 'BFF machine login callback returned no Location'

    local handoff_url
    handoff_url="$(tenant_web_url "${location}")"
    machine_cookie_header="$(cookie_header "${cookies}")"
    call_redirect GET "${handoff_url}" -H "Host: ${WEB_MACHINE_HOST}" -H "Cookie: ${machine_cookie_header}"
    absorb_cookies "${cookies}"
    expect_status 200 'BFF machine login handoff'
    printf '  staff session created through the BFF login flow\n'
}

machine_authorize_connection() {
    local cookies="$1" page_id="$2"
    local return_path="/event/${EVENT_ID}/observation"
    local return_encoded
    return_encoded="$(jq -rn --arg v "${return_path}" '$v|@uri')"
    machine_cookie_header="$(cookie_header "${cookies}")"

    call_redirect GET "${WEB_MACHINE_URL}/api/auth/connection/start?eventId=${EVENT_ID}&pageEdgeDeviceId=${page_id}&return=${return_encoded}" \
        -H "Host: ${WEB_MACHINE_HOST}" -H "Cookie: ${machine_cookie_header}"
    absorb_cookies "${cookies}"
    expect_status 302 'BFF machine connection start'
    [ -n "${location}" ] || die 'BFF machine connection start returned no Location'

    local authorize_path
    authorize_path="$(printf '%s' "${location}" | sed -E 's#^[a-z]+://[^/]+##')"
    machine_cookie_header="$(cookie_header "${cookies}")"
    call_redirect GET "${IDP_URL}${authorize_path}" -H "Cookie: ${machine_cookie_header}"
    absorb_cookies "${cookies}"
    expect_status 302 'IdP machine connection authorize'
    [ -n "${location}" ] || die 'IdP machine connection authorize returned no Location'

    local callback_path callback_url
    callback_path="$(printf '%s' "${location}" | sed -E 's#^[a-z]+://[^/]+##')"
    callback_url="${WEB_MACHINE_URL}${callback_path}"
    machine_cookie_header="$(cookie_header "${cookies}")"
    call_redirect GET "${callback_url}" -H "Host: ${WEB_MACHINE_HOST}" -H "Cookie: ${machine_cookie_header}"
    absorb_cookies "${cookies}"
    expect_status 302 'BFF machine connection callback'
    printf '%s' "${location}" | grep -q 'cameraConnection=authorized' \
        || die "the machine flow connection was not authorized: ${location}"
    printf '  machine connection authorization stored for page %s\n' "${page_id}"
}

machine_start() {
    local cookies="$1" page_id="$2"
    local return_path="/event/${EVENT_ID}/observation/${page_id}"
    local return_encoded
    return_encoded="$(jq -rn --arg v "${return_path}" '$v|@uri')"
    machine_cookie_header="$(cookie_header "${cookies}")"

    call_redirect GET "${WEB_MACHINE_URL}/api/auth/machine/start?eventId=${EVENT_ID}&pageEdgeDeviceId=${page_id}&return=${return_encoded}" \
        -H "Host: ${WEB_MACHINE_HOST}" -H "Cookie: ${machine_cookie_header}"
    absorb_cookies "${cookies}"
    expect_status 302 'BFF machine start'
    [ -n "${location}" ] || die 'BFF machine start returned no Location'
    printf '  BFF machine start redirected to %s\n' "${location}"

    local authorize_path
    authorize_path="$(printf '%s' "${location}" | sed -E 's#^[a-z]+://[^/]+##')"
    machine_cookie_header="$(cookie_header "${cookies}")"
    call_redirect GET "${IDP_URL}${authorize_path}" -H "Cookie: ${machine_cookie_header}"
    absorb_cookies "${cookies}"
    expect_status 302 'IdP machine authorize'
    [ -n "${location}" ] || die 'IdP machine authorize returned no Location'

    local callback_path callback_url
    callback_path="$(printf '%s' "${location}" | sed -E 's#^[a-z]+://[^/]+##')"
    callback_url="${WEB_MACHINE_URL}${callback_path}"
    machine_cookie_header="$(cookie_header "${cookies}")"
    call_redirect GET "${callback_url}" -H "Cookie: ${machine_cookie_header}"
    absorb_cookies "${cookies}"
    expect_status 302 'BFF machine callback'
    [ -n "${location}" ] || die 'BFF machine callback returned no Location'
    printf '  BFF machine callback redirected to %s\n' "${location}"

    local handoff_url
    handoff_url="$(tenant_web_url "${location}")"
    machine_cookie_header="$(cookie_header "${cookies}")"
    call_redirect GET "${handoff_url}" -H "Host: ${WEB_MACHINE_HOST}" -H "Cookie: ${machine_cookie_header}"
    absorb_cookies "${cookies}"
    expect_status 302 'BFF machine handoff'
    [ "${location}" = "${return_path}" ] \
        || die "machine handoff landed on ${location}, want ${return_path}"
    printf '  machine session handed to the observation page\n'
}

machine_rpc() {
    local procedure="$1" payload="$2" cookies="$3"
    machine_cookie_header="$(cookie_header "${cookies}")"
    call POST "${WEB_MACHINE_URL}/rpc/${procedure}" \
        -H 'Content-Type: application/json' \
        -H 'x-csrf-token: orpc' \
        -H "Host: ${WEB_MACHINE_HOST}" \
        -H "Cookie: ${machine_cookie_header}" \
        -d "${payload}"
}

authorize_connection() {
    local cookies="$1" page_id="$2"
    local web_url="${3:-$WEB_URL}" web_host="${4:-$WEB_HOST}"
    local return_path="/event/${EVENT_ID}/observation"
    local return_encoded
    return_encoded="$(jq -rn --arg v "${return_path}" '$v|@uri')"

    call_redirect GET "${web_url}/api/auth/connection/start?eventId=${EVENT_ID}&pageEdgeDeviceId=${page_id}&return=${return_encoded}" \
        -H "Host: ${web_host}" -b "${cookies}" -c "${cookies}"
    expect_status 302 'BFF connection start'
    [ -n "${location}" ] || die 'BFF connection start returned no Location'
    printf '  BFF connection start redirected to %s\n' "${location}"

    local authorize_path
    authorize_path="$(printf '%s' "${location}" | sed -E 's#^[a-z]+://[^/]+##')"
    call_redirect GET "${IDP_URL}${authorize_path}" -b "${cookies}" -c "${cookies}"
    expect_status 302 'IdP connection authorize'
    [ -n "${location}" ] || die 'IdP connection authorize returned no Location'
    printf '  IdP authorize redirected to %s\n' "${location}"

    local callback_path code state
    callback_path="$(printf '%s' "${location}" | sed -E 's#^[a-z]+://[^/]+##')"
    code="$(printf '%s' "${callback_path}" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')"
    state="$(printf '%s' "${callback_path}" | sed -n 's/.*[?&]state=\([^&]*\).*/\1/p')"
    [ -n "${code}" ] && [ -n "${state}" ] || die "IdP authorize returned no code/state: ${location}"

    call_redirect GET "${WEB_URL}${callback_path}" -H "Host: ${WEB_HOST}" -b "${cookies}" -c "${cookies}"
    expect_status 302 'BFF connection callback'
    printf '%s' "${location}" | grep -q 'cameraConnection=authorized' \
        || die "the BFF connection callback did not report an authorized delegation: ${location}"
    printf '  connection authorization stored for page %s\n' "${page_id}"
}

db_count() {
    compose exec -T web-db psql -U "${WEB_DB_USER}" -d "${WEB_DB_NAME}" -tAc "$1" | tr -d '[:space:]'
}

wait_for_web() {
    local attempt code
    for attempt in $(seq 1 90); do
        code="$(curl -sS --connect-timeout 3 --max-time 20 -o /dev/null -w '%{http_code}' -H "Host: ${WEB_HOST}" "${WEB_URL}/" 2>/dev/null || true)"
        if [ "${code}" != "000" ] && [ "${code}" -lt 500 ]; then
            printf '  web ready (HTTP %s)\n' "${code}"
            return 0
        fi
        sleep 2
    done
    die "tolo-web did not become ready: ${WEB_URL}"
}

idp_token() {
    IDP_BASE_URL="${IDP_URL}" \
    IDP_TENANT_ID="${TENANT_ID}" \
    IDP_CLIENT_ID="${IDP_CLIENT_ID}" \
    IDP_CLIENT_SECRET="${IDP_CLIENT_SECRET}" \
    IDP_REDIRECT_URI="${IDP_REDIRECT_URI}" \
        "${script_dir}/idp-token.sh" "$@"
}

connection_cookies="$(mktemp)"
machine_cookies="$(mktemp -d)"
cleanup() {
    local code=$?
    rm -f "${connection_cookies}"
    rm -rf "${machine_cookies}" "${machine_cookies}.staff"
    if [ "${KEEP_STACK:-0}" = "1" ]; then
        printf '\nkeeping the compose stack (KEEP_STACK=1): project=%s\n' "${PROJECT}"
        exit "${code}"
    fi
    printf '\n=== cleanup\n'
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    exit "${code}"
}
trap cleanup EXIT

cd "${repo_dir}"

printf 'camera-e2e: project=%s\n' "${PROJECT}"
printf 'camera-e2e: compose=%s\n' "${COMPOSE_FILE}"

step '0. start the camera stack (fresh volumes)'
compose down -v --remove-orphans >/dev/null 2>&1 || true
compose build server idp idp-relation-stub observation observation-migrate firebase-emulator edge-bridge
compose up -d --wait \
    keygen server nats idp idp-db idp-redis idp-relation-stub idp-seed-secret \
    idp-camera-user-seed observation-db observation-migrate observation \
    firebase-emulator edge-bridge web-db

wait_for_http "${IDP_URL}/oauth2/jwks" 'idp'
wait_for_http "${GATEWAY_URL}/readyz" 'service gateway'
wait_for_http "${BRIDGE_URL}/healthz" 'edge bridge'
wait_for_http "${FIRESTORE_URL}/" 'firestore emulator'
wait_for_http "${AUTH_URL}/" 'auth emulator'

step '1. obtain staff tenant_access and event_access from the real IdP'
staff_token="$(idp_token -s 'openid tenant.read events.read events.manage')"
[ -n "${staff_token}" ] || die 'tenant_access is empty'
event_token="$(idp_token -s 'openid tenant.read events.read events.manage' -e "${EVENT_ID}")"
[ -n "${event_token}" ] || die 'event_access is empty'
assert_claim "${staff_token}" token_use tenant_access
assert_claim "${staff_token}" tenant_id "${TENANT_ID}"
assert_claim "${event_token}" token_use event_access
assert_claim "${event_token}" tenant_id "${TENANT_ID}"
assert_claim "${event_token}" event_id "${EVENT_ID}"
assert_claim "${event_token}" client_id "${IDP_CLIENT_ID}"
printf '  tenant_access: token_use=tenant_access tenant_id=%s client_id=%s\n' "${TENANT_ID}" "${IDP_CLIENT_ID}"
printf '  event_access:  token_use=event_access event_id=%s scope=%s\n' "${EVENT_ID}" "$(claim "${event_token}" scope)"

step '2. register an observation page, its point, and a linked camera'
call POST "${GATEWAY_URL}/tolo.observation.v1.EdgeDeviceService/RegisterEdgeDevice" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${event_token}" \
    -d "$(jq -nc --arg e "${EVENT_ID}" '{
        eventId: $e,
        name: "camera-e2e-page",
        observationPointNames: ["camera-e2e-point", "camera-e2e-other-point"]
    }')"
expect_status 200 'RegisterEdgeDevice(page)'
page_id="$(printf '%s' "${body}" | jq -r '.device.edgeDeviceId')"
point_id="$(printf '%s' "${body}" | jq -r '.device.observationPoints[] | select(.name == "camera-e2e-point") | .observationPointId')"
other_point_id="$(printf '%s' "${body}" | jq -r '.device.observationPoints[] | select(.name == "camera-e2e-other-point") | .observationPointId')"
[ -n "${page_id}" ] && [ "${page_id}" != "null" ] || die 'page edge_device_id is empty'
[ -n "${point_id}" ] && [ "${point_id}" != "null" ] || die 'observation point is empty'
printf '  page edge_device_id=%s observation point=%s\n' "${page_id}" "${point_id}"

call POST "${GATEWAY_URL}/tolo.observation.v1.EdgeDeviceService/RegisterEdgeDevice" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${event_token}" \
    -d "$(jq -nc --arg e "${EVENT_ID}" --arg p "${point_id}" '{
        eventId: $e,
        name: "camera-e2e-camera",
        kind: "EDGE_DEVICE_KIND_CAMERA",
        linkedObservationPointId: $p
    }')"
expect_status 200 'RegisterEdgeDevice(camera)'
camera_id="$(printf '%s' "${body}" | jq -r '.device.edgeDeviceId')"
[ -n "${camera_id}" ] && [ "${camera_id}" != "null" ] || die 'camera edge_device_id is empty'
printf '%s' "${body}" | jq -e --arg c "${camera_id}" '
    .device.kind == "EDGE_DEVICE_KIND_CAMERA"
    and (.device.observationPoints // [] | length) == 0
    and (.device.observationPagePath // "") == ""
    and .device.edgeDeviceId == $c
' >/dev/null || die 'the camera was not registered as a camera without observation points'
printf '  camera edge_device_id=%s (kind=CAMERA, observation points=0)\n' "${camera_id}"

call POST "${GATEWAY_URL}/tolo.observation.v1.EdgeDeviceService/RegisterEdgeDevice" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${event_token}" \
    -d "$(jq -nc --arg e "${EVENT_ID}" '{
        eventId: $e,
        name: "camera-e2e-other-page",
        observationPointNames: ["camera-e2e-other-page-point"]
    }')"
expect_status 200 'RegisterEdgeDevice(other page)'
other_page_id="$(printf '%s' "${body}" | jq -r '.device.edgeDeviceId')"
other_page_point_id="$(printf '%s' "${body}" | jq -r '.device.observationPoints[0].observationPointId')"
call POST "${GATEWAY_URL}/tolo.observation.v1.EdgeDeviceService/RegisterEdgeDevice" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${event_token}" \
    -d "$(jq -nc --arg e "${EVENT_ID}" --arg p "${other_page_point_id}" '{
        eventId: $e,
        name: "camera-e2e-unlinked-camera",
        kind: "EDGE_DEVICE_KIND_CAMERA",
        linkedObservationPointId: $p
    }')"
expect_status 200 'RegisterEdgeDevice(unlinked camera)'
unlinked_camera_id="$(printf '%s' "${body}" | jq -r '.device.edgeDeviceId')"
printf '  other page=%s unlinked camera=%s\n' "${other_page_id}" "${unlinked_camera_id}"

call POST "${GATEWAY_URL}/tolo.observation.v1.EdgeDeviceService/ListEdgeDevices" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${event_token}" \
    -d "$(jq -nc --arg e "${EVENT_ID}" '{eventId: $e}')"
expect_status 200 'ListEdgeDevices'
printf '%s' "${body}" | jq -e --arg p "${page_id}" --arg c "${camera_id}" --arg point "${point_id}" '
    (.devices[] | select(.edgeDeviceId == $p)
        | .kind == "EDGE_DEVICE_KIND_OBSERVATION_PAGE"
        and (.cameraLinks | any(.cameraEdgeDeviceId == $c and .observationPointId == $point)))
    and (.devices[] | select(.edgeDeviceId == $c)
        | .kind == "EDGE_DEVICE_KIND_CAMERA"
        and (.observationPoints // [] | length) == 0)
' >/dev/null || die 'ListEdgeDevices did not return the camera link on the observation page'
printf '  ListEdgeDevices returned the page -> camera link (%s -> %s)\n' "${page_id}" "${camera_id}"

step '3. device authorization for esp-camera with events.stream'
call POST "${IDP_URL}/oauth2/device_authorization" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'client_id=esp-camera' \
    --data-urlencode 'scope=events.stream'
expect_status 200 'device authorization'
device_code="$(printf '%s' "${body}" | jq -r '.device_code')"
user_code="$(printf '%s' "${body}" | jq -r '.user_code')"
[ -n "${device_code}" ] && [ "${device_code}" != "null" ] || die 'device_code is empty'
[ -n "${user_code}" ] && [ "${user_code}" != "null" ] || die 'user_code is empty'
printf '  pending device_code issued, user_code=%s\n' "${user_code}"

call POST "${IDP_URL}/oauth2/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'client_id=esp-camera' \
    --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:device_code' \
    --data-urlencode "device_code=${device_code}"
expect_status 400 'pending device authorization poll'
printf '%s' "${body}" | jq -e '.error == "authorization_pending"' >/dev/null \
    || die 'the pending poll did not return authorization_pending'
printf '  pending poll returned authorization_pending\n'

call POST "${IDP_URL}/api/device-authorization/approve" \
    -H 'Content-Type: application/json' \
    -u "${IDP_CLIENT_ID}:${IDP_CLIENT_SECRET}" \
    -H "X-Tolo-Staff-Token: ${staff_token}" \
    -d "$(jq -nc --arg u "${user_code}" --arg e "${EVENT_ID}" --arg d "${camera_id}" '{
        user_code: $u, event_id: $e, edge_device_id: $d
    }')"
expect_status 200 'device authorization approve'
printf '  approved user_code=%s for edge_device_id=%s\n' "${user_code}" "${camera_id}"

call POST "${IDP_URL}/oauth2/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'client_id=esp-camera' \
    --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:device_code' \
    --data-urlencode "device_code=${device_code}"
expect_status 200 'device code exchange'
camera_token="$(printf '%s' "${body}" | jq -r '.access_token')"
camera_refresh_token="$(printf '%s' "${body}" | jq -r '.refresh_token')"
[ -n "${camera_token}" ] && [ "${camera_token}" != "null" ] || die 'camera access_token is empty'
[ -n "${camera_refresh_token}" ] && [ "${camera_refresh_token}" != "null" ] || die 'camera refresh_token is empty'
assert_claim "${camera_token}" client_id esp-camera
assert_claim "${camera_token}" scope events.stream
assert_claim "${camera_token}" tenant_id "${TENANT_ID}"
assert_claim "${camera_token}" event_id "${EVENT_ID}"
assert_claim "${camera_token}" edge_device_id "${camera_id}"
assert_claim "${camera_token}" token_use event_access
printf '  camera event_access: client_id=esp-camera scope=events.stream edge_device_id=%s\n' "${camera_id}"

call POST "${IDP_URL}/oauth2/device_authorization" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'client_id=esp-camera' \
    --data-urlencode 'scope=events.report'
expect_status 400 'camera events.report request'
printf '%s' "${body}" | jq -e '.error == "invalid_scope"' >/dev/null \
    || die 'the camera client did not reject events.report'
printf '  events.report was rejected for esp-camera (invalid_scope)\n'

step '4. IssueFirestoreToken with the camera token'
call POST "${BRIDGE_URL}/tolo.edgebridge.v1.SignalingService/IssueFirestoreToken" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${camera_token}" \
    -d '{}'
expect_status 200 'camera IssueFirestoreToken'
camera_custom_token="$(printf '%s' "${body}" | jq -r '.firebaseCustomToken')"
[ -n "${camera_custom_token}" ] && [ "${camera_custom_token}" != "null" ] || die 'camera firebaseCustomToken is empty'
assert_claim "${camera_custom_token}" edge_device_id "${camera_id}"
assert_claim "${camera_custom_token}" peer_role edge
assert_claim "${camera_custom_token}" token_use signaling
assert_missing_claim "${camera_custom_token}" session_id
printf '  camera custom token: edge_device_id=%s session_id=absent\n' "${camera_id}"

step '5. authorize the observation connection client and connect through the BFF'
TENANT_ACCESS_TOKEN="${staff_token}" GRAPH_ACCESS_TOKEN="${event_token}" \
    compose build web
TENANT_ACCESS_TOKEN="${staff_token}" GRAPH_ACCESS_TOKEN="${event_token}" \
    compose up -d --wait web web-machine
wait_for_web
wait_for_http "${WEB_MACHINE_URL}/auth/error" 'web-machine'
idp_login "${connection_cookies}"
authorize_connection "${connection_cookies}" "${page_id}"

call POST "${WEB_URL}/rpc/signaling/requestCameraConnection" \
    -H 'Content-Type: application/json' \
    -H 'x-csrf-token: orpc' \
    -H "Host: ${WEB_HOST}" \
    -d "$(jq -nc --arg e "${EVENT_ID}" --arg p "${page_id}" --arg c "${camera_id}" '{
        json: { eventId: $e, pageEdgeDeviceId: $p, cameraEdgeId: $c }
    }')"
expect_status 200 'BFF requestCameraConnection'
connection_session_id="$(printf '%s' "${body}" | jq -r '.json.sessionId // empty')"
connection_custom_token="$(printf '%s' "${body}" | jq -r '.json.firestoreToken // empty')"
[ -n "${connection_session_id}" ] || die 'the BFF returned no sessionId'
[ -n "${connection_custom_token}" ] || die 'the BFF returned no firestoreToken'
printf '%s' "${body}" | jq -e '(.json.event_access? // null) == null and (.json.access_token? // null) == null' >/dev/null \
    || die 'the BFF returned an event access token to the caller'
assert_claim "${connection_custom_token}" edge_device_id "${camera_id}"
assert_claim "${connection_custom_token}" session_id "${connection_session_id}"
assert_claim "${connection_custom_token}" peer_role console
assert_claim "${connection_custom_token}" token_use signaling
printf '  connection session_id=%s, custom token bound to camera=%s\n' "${connection_session_id}" "${camera_id}"

connection_exchange_log="$(compose logs idp 2>/dev/null | grep -F 'Token Exchange completed' | tail -1 || true)"
printf '%s' "${connection_exchange_log}" | grep -q 'observation-connection' \
    || die "the IdP did not record a token exchange for ${CONNECTION_CLIENT_ID}: ${connection_exchange_log}"
printf '  IdP log shows the connection client (%s) token exchange\n' "${CONNECTION_CLIENT_ID}"

call POST "${WEB_URL}/rpc/signaling/requestCameraConnection" \
    -H 'Content-Type: application/json' \
    -H 'x-csrf-token: orpc' \
    -H "Host: ${WEB_HOST}" \
    -d "$(jq -nc --arg e "${EVENT_ID}" --arg p "${page_id}" --arg c "${unlinked_camera_id}" '{
        json: { eventId: $e, pageEdgeDeviceId: $p, cameraEdgeId: $c }
    }')"
expect_status 412 'BFF non-linked camera'
printf '%s' "${body}" | jq -e '.data.code == "CAMERA_NOT_DELEGATED"' >/dev/null \
    || die 'non-linked camera did not return CAMERA_NOT_DELEGATED'
printf '  non-linked camera rejected before Edge Bridge (HTTP %s)\n' "${status}"

call GET "${DOCUMENTS}/tenants/${TENANT_ID}/events/${EVENT_ID}/edgeDevices/${unlinked_camera_id}/sessions" \
    -H 'Authorization: Bearer owner'
expect_status 200 'unlinked camera session lookup'
printf '%s' "${body}" | jq -e '(.documents // []) | length == 0' >/dev/null \
    || die 'the rejected non-linked camera still got an Edge Bridge session'
printf '  unlinked camera has no Edge Bridge session\n'

step '6. Firebase Auth sign-in and Firestore security rules'
call POST "${AUTH_URL}/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=any" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg t "${camera_custom_token}" '{token: $t, returnSecureToken: true}')"
expect_status 200 'camera signInWithCustomToken'
camera_id_token="$(printf '%s' "${body}" | jq -r '.idToken // empty')"
[ -n "${camera_id_token}" ] || die 'the camera sign-in returned no idToken'

call POST "${AUTH_URL}/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=any" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg t "${connection_custom_token}" '{token: $t, returnSecureToken: true}')"
expect_status 200 'connection signInWithCustomToken'
connection_id_token="$(printf '%s' "${body}" | jq -r '.idToken // empty')"
[ -n "${connection_id_token}" ] || die 'the connection sign-in returned no idToken'

session_path="tenants/${TENANT_ID}/events/${EVENT_ID}/edgeDevices/${camera_id}/sessions/${connection_session_id}"
call GET "${DOCUMENTS}/${session_path}" -H "Authorization: Bearer ${camera_id_token}"
expect_status 200 'camera reads its own session'
call GET "${DOCUMENTS}/${session_path}" -H "Authorization: Bearer ${connection_id_token}"
expect_status 200 'connection token reads its bound session'
printf '  camera and connection tokens can read %s\n' "${session_path}"

call GET "${DOCUMENTS}/tenants/${TENANT_ID}/events/${EVENT_ID}/edgeDevices/${page_id}/sessions/${connection_session_id}" \
    -H "Authorization: Bearer ${camera_id_token}"
expect_status 403 'camera reads another edge session'
call GET "${DOCUMENTS}/tenants/${TENANT_ID}/events/${EVENT_ID}/edgeDevices/${camera_id}/sessions/00000000000000000000" \
    -H "Authorization: Bearer ${connection_id_token}"
expect_status 403 'connection token reads another session'
printf '  mismatched edge and session reads were rejected\n'

call POST "${DOCUMENTS}:commit" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${camera_id_token}" \
    -d "$(jq -nc --arg name "projects/demo-tolo/databases/(default)/documents/${session_path}/signals/camera-offer" '{
        writes: [{
            update: {
                name: $name,
                fields: {
                    from: {stringValue: "edge"},
                    payload: {mapValue: {fields: {type: {stringValue: "offer"}}}}
                }
            },
            updateTransforms: [{fieldPath: "createdAt", setToServerValue: "REQUEST_TIME"}],
            currentDocument: {exists: false}
        }]
    }')"
expect_status 200 'camera writes a signal on its session'

call POST "${DOCUMENTS}:commit" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${connection_id_token}" \
    -d "$(jq -nc --arg name "projects/demo-tolo/databases/(default)/documents/${session_path}/signals/console-answer" '{
        writes: [{
            update: {
                name: $name,
                fields: {
                    from: {stringValue: "console"},
                    payload: {mapValue: {fields: {type: {stringValue: "answer"}}}}
                }
            },
            updateTransforms: [{fieldPath: "createdAt", setToServerValue: "REQUEST_TIME"}],
            currentDocument: {exists: false}
        }]
    }')"
expect_status 200 'connection token writes a signal on its session'
printf '  camera and connection tokens can write signals on the matching path\n'

call POST "${DOCUMENTS}:commit" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${camera_id_token}" \
    -d "$(jq -nc --arg name "projects/demo-tolo/databases/(default)/documents/tenants/${TENANT_ID}/events/${EVENT_ID}/edgeDevices/${page_id}/sessions/${connection_session_id}/signals/camera-wrong-edge" '{
        writes: [{
            update: {
                name: $name,
                fields: {
                    from: {stringValue: "edge"},
                    payload: {mapValue: {fields: {type: {stringValue: "offer"}}}}
                }
            },
            updateTransforms: [{fieldPath: "createdAt", setToServerValue: "REQUEST_TIME"}],
            currentDocument: {exists: false}
        }]
    }')"
expect_status 403 'camera writes another edge session'
call POST "${DOCUMENTS}:commit" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${connection_id_token}" \
    -d "$(jq -nc --arg name "projects/demo-tolo/databases/(default)/documents/tenants/${TENANT_ID}/events/${EVENT_ID}/edgeDevices/${camera_id}/sessions/00000000000000000000/signals/connection-wrong-session" '{
        writes: [{
            update: {
                name: $name,
                fields: {
                    from: {stringValue: "console"},
                    payload: {mapValue: {fields: {type: {stringValue: "answer"}}}}
                }
            },
            updateTransforms: [{fieldPath: "createdAt", setToServerValue: "REQUEST_TIME"}],
            currentDocument: {exists: false}
        }]
    }')"
expect_status 403 'connection token writes another session'
printf '  mismatched edge and session writes were rejected\n'

step '7. machine session with the real IdP and AUTH_MOCKING disabled'
machine_login "${machine_cookies}"
machine_authorize_connection "${machine_cookies}" "${page_id}"
cp -R "${machine_cookies}" "${machine_cookies}.staff"
machine_start "${machine_cookies}" "${page_id}"

staff_sessions="$(db_count "SELECT count(*) FROM \"session\" WHERE kind = 'staff';")"
[ "${staff_sessions}" = "0" ] \
    || die "the staff session survived the machine handoff (staff sessions=${staff_sessions})"
machine_sessions="$(db_count "SELECT count(*) FROM \"session\" WHERE kind = 'machine' AND \"tenantId\" = '${TENANT_ID}' AND \"eventId\" = '${EVENT_ID}' AND \"edgeDeviceId\" = '${page_id}';")"
[ "${machine_sessions}" = "1" ] \
    || die "the machine session is not bound to the page (rows=${machine_sessions})"
printf '  staff session gone; machine session bound to event=%s page=%s\n' "${EVENT_ID}" "${page_id}"

machine_rpc camera/listDelegatedCameras \
    "$(jq -nc --arg e "${EVENT_ID}" --arg p "${page_id}" '{json:{eventId:$e,pageEdgeDeviceId:$p}}')" \
    "${machine_cookies}"
expect_status 200 'machine camera.listDelegatedCameras'
printf '%s' "${body}" | jq -e --arg c "${camera_id}" --arg u "${unlinked_camera_id}" '
    (.json.cameras | length) == 1
    and (.json.cameras[0].edgeDeviceId == $c)
    and (.json.cameras | all(.edgeDeviceId != $u))
' >/dev/null || die "listDelegatedCameras did not return only the page camera: ${body}"
printf '  listDelegatedCameras returned only camera %s\n' "${camera_id}"

machine_rpc camera/listDelegatedCameras \
    "$(jq -nc --arg e "${EVENT_ID}" --arg p "${page_id}" '{json:{eventId:$e,pageEdgeDeviceId:$p}}')" \
    "${machine_cookies}.staff"
expect_status 401 'old staff cookie after the machine handoff'
printf '  the old staff cookie is no longer accepted\n'

machine_cookie_header="$(cookie_header "${machine_cookies}")"
call_redirect GET "${WEB_MACHINE_URL}/management" \
    -H "Host: ${WEB_MACHINE_HOST}" -H "Cookie: ${machine_cookie_header}"
expect_not_status 200 'machine session opens the staff management page'
printf '%s' "${location}" | grep -q '/auth/error?error=machine_session_forbidden' \
    || die "the machine session was not sent to the forbidden error page: ${location}"
if printf '%s' "${location}" | grep -q '/auth/login'; then
    die "the machine session was sent to the staff login: ${location}"
fi
printf '  the machine session cannot open the management page as staff\n'

machine_cookie_header="$(cookie_header "${machine_cookies}")"
call_redirect GET "${WEB_MACHINE_URL}/auth/login?return=%2Fmanagement" \
    -H "Host: ${WEB_MACHINE_HOST}" -H "Cookie: ${machine_cookie_header}"
expect_status 403 'machine session staff login start'
printf '  the machine session cannot start a staff login\n'

machine_cookie_header="$(cookie_header "${machine_cookies}.staff")"
call_redirect GET "${WEB_MACHINE_URL}/management" \
    -H "Host: ${WEB_MACHINE_HOST}" -H "Cookie: ${machine_cookie_header}"
expect_not_status 200 'old staff session after the machine handoff'
printf '  the old staff session cannot be recovered\n'

staff_sessions="$(db_count "SELECT count(*) FROM \"session\" WHERE kind = 'staff';")"
[ "${staff_sessions}" = "0" ] \
    || die "a staff session was recovered after the machine handoff (staff sessions=${staff_sessions})"

machine_rpc signaling/requestCameraConnection \
    "$(jq -nc --arg e "${EVENT_ID}" --arg p "${page_id}" --arg c "${camera_id}" '{json:{eventId:$e,pageEdgeDeviceId:$p,cameraEdgeId:$c}}')" \
    "${machine_cookies}"
expect_status 200 'machine requestCameraConnection'
machine_connection_session_id="$(printf '%s' "${body}" | jq -r '.json.sessionId // empty')"
machine_connection_token="$(printf '%s' "${body}" | jq -r '.json.firestoreToken // empty')"
[ -n "${machine_connection_session_id}" ] || die 'the machine session got no connection sessionId'
[ -n "${machine_connection_token}" ] || die 'the machine session got no firestoreToken'
printf '%s' "${body}" | jq -e '(.json.event_access? // null) == null and (.json.access_token? // null) == null' >/dev/null \
    || die 'the machine camera connection returned an external access token'
assert_claim "${machine_connection_token}" edge_device_id "${camera_id}"
assert_claim "${machine_connection_token}" session_id "${machine_connection_session_id}"
printf '  machine connection session=%s bound to camera=%s\n' "${machine_connection_session_id}" "${camera_id}"

machine_rpc observation/heartbeat \
    "$(jq -nc --arg e "${EVENT_ID}" --arg d "${page_id}" '{json:{eventId:$e,edgeDeviceId:$d,activeObservationPointIds:[]}}')" \
    "${machine_cookies}"
expect_status 200 'machine Heartbeat'

window_end="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
window_start="$(date -u -v-1M +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%S.000Z)"
machine_rpc observation/reportMeasurements \
    "$(jq -nc --arg e "${EVENT_ID}" --arg d "${page_id}" --arg p "${point_id}" --arg s "${window_start}" --arg t "${window_end}" '{
        json:{eventId:$e,edgeDeviceId:$d,measurements:[{observationPointId:$p,windowStart:$s,windowEnd:$t,countIn:1,countOut:0}]}
    }')" \
    "${machine_cookies}"
expect_status 200 'machine ReportMeasurements'

machine_rpc observation/listObservationPoints \
    "$(jq -nc --arg e "${EVENT_ID}" --arg d "${page_id}" '{json:{eventId:$e,edgeDeviceId:$d}}')" \
    "${machine_cookies}"
expect_status 200 'machine ListEdgeDeviceObservationPoints'
printf '%s' "${body}" | jq -e '(.json.observationPoints | length) > 0' >/dev/null \
    || die "ListEdgeDeviceObservationPoints returned no points: ${body}"
printf '  Heartbeat, ReportMeasurements, and ListEdgeDeviceObservationPoints succeeded\n'

machine_rpc observation/listEdgeDevices \
    "$(jq -nc --arg e "${EVENT_ID}" '{json:{eventId:$e}}')" \
    "${machine_cookies}"
expect_status 403 'machine ListEdgeDevices'
printf '%s' "${body}" | grep -q 'FORBIDDEN' \
    || die "the machine session was not refused ListEdgeDevices with FORBIDDEN: ${body}"
printf '  the machine session cannot call ListEdgeDevices\n'

machine_rpc signaling/requestCameraConnection \
    "$(jq -nc --arg e "${EVENT_ID}" --arg p "${other_page_id}" --arg c "${unlinked_camera_id}" '{json:{eventId:$e,pageEdgeDeviceId:$p,cameraEdgeId:$c}}')" \
    "${machine_cookies}"
expect_status 403 'machine connection for another page'
printf '  the machine session cannot connect another page\n'

edge_exchange_log="$(compose logs idp 2>/dev/null | grep -F 'Token Exchange completed' | grep -F 'edge-page' | tail -1 || true)"
printf '%s' "${edge_exchange_log}" | grep -q 'edge-page' \
    || die "the IdP did not record a token exchange for edge-page: ${edge_exchange_log}"
printf '  IdP log shows the edge-page token exchange\n'

step '8. revoke the device authorization and the connection delegation'
call POST "${WEB_URL}/rpc/camera/revokeDeviceAuthorization" \
    -H 'Content-Type: application/json' \
    -H 'x-csrf-token: orpc' \
    -H "Host: ${WEB_HOST}" \
    -d "$(jq -nc --arg e "${EVENT_ID}" --arg d "${camera_id}" '{
        json: { eventId: $e, edgeDeviceId: $d }
    }')"
expect_status 200 'BFF camera.revokeDeviceAuthorization'
printf '  revoked the device authorization for %s through the BFF\n' "${camera_id}"

delegation_count="$(db_count "SELECT count(*) FROM \"connectionAuthorization\" WHERE \"eventId\" = '${EVENT_ID}' AND \"pageEdgeDeviceId\" = '${page_id}';")"
[ "${delegation_count}" = "0" ] \
    || die "the connection delegation was not deleted (rows=${delegation_count})"
printf '  connection delegation rows for page %s were deleted\n' "${page_id}"

call POST "${IDP_URL}/oauth2/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'client_id=esp-camera' \
    --data-urlencode 'grant_type=refresh_token' \
    --data-urlencode "refresh_token=${camera_refresh_token}"
expect_status 400 'camera refresh after revoke'
printf '%s' "${body}" | jq -e '.error == "invalid_grant"' >/dev/null \
    || die 'the revoked camera refresh did not return invalid_grant'
printf '  camera refresh returned invalid_grant\n'

call POST "${WEB_URL}/rpc/signaling/requestCameraConnection" \
    -H 'Content-Type: application/json' \
    -H 'x-csrf-token: orpc' \
    -H "Host: ${WEB_HOST}" \
    -d "$(jq -nc --arg e "${EVENT_ID}" --arg p "${page_id}" --arg c "${camera_id}" '{
        json: { eventId: $e, pageEdgeDeviceId: $p, cameraEdgeId: $c }
    }')"
expect_not_status 200 'BFF requestCameraConnection after revoke'
printf '%s' "${body}" | grep -q 'CONNECTION_AUTHORIZATION_REQUIRED' \
    || die "the BFF did not require reauthorization after revoke: ${body}"
printf '  camera connection failed until reauthorization\n'

authorize_connection "${connection_cookies}" "${page_id}"
call POST "${WEB_URL}/rpc/signaling/requestCameraConnection" \
    -H 'Content-Type: application/json' \
    -H 'x-csrf-token: orpc' \
    -H "Host: ${WEB_HOST}" \
    -d "$(jq -nc --arg e "${EVENT_ID}" --arg p "${page_id}" --arg c "${camera_id}" '{
        json: { eventId: $e, pageEdgeDeviceId: $p, cameraEdgeId: $c }
    }')"
expect_status 200 'BFF requestCameraConnection after reauthorization'
reauthorized_session_id="$(printf '%s' "${body}" | jq -r '.json.sessionId // empty')"
reauthorized_custom_token="$(printf '%s' "${body}" | jq -r '.json.firestoreToken // empty')"
[ -n "${reauthorized_session_id}" ] || die 'the BFF returned no sessionId after reauthorization'
[ -n "${reauthorized_custom_token}" ] || die 'the BFF returned no firestoreToken after reauthorization'
assert_claim "${reauthorized_custom_token}" edge_device_id "${camera_id}"
assert_claim "${reauthorized_custom_token}" session_id "${reauthorized_session_id}"
printf '  camera connection succeeded after reauthorization (session=%s)\n' "${reauthorized_session_id}"
connection_session_id="${reauthorized_session_id}"

call POST "${IDP_URL}/oauth2/device_authorization" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'client_id=esp-camera' \
    --data-urlencode 'scope=events.stream'
expect_status 200 'device authorization after revoke'
device_code_after_revoke="$(printf '%s' "${body}" | jq -r '.device_code')"
user_code_after_revoke="$(printf '%s' "${body}" | jq -r '.user_code')"
call POST "${IDP_URL}/api/device-authorization/approve" \
    -H 'Content-Type: application/json' \
    -u "${IDP_CLIENT_ID}:${IDP_CLIENT_SECRET}" \
    -H "X-Tolo-Staff-Token: ${staff_token}" \
    -d "$(jq -nc --arg u "${user_code_after_revoke}" --arg e "${EVENT_ID}" --arg d "${camera_id}" '{
        user_code: $u, event_id: $e, edge_device_id: $d
    }')"
expect_status 400 'approval of a revoked edge_device_id'
printf '  revoked edge_device_id is rejected for a new approval\n'

printf '\ncamera e2e passed: tenant=%s event=%s page=%s camera=%s session=%s\n' \
    "${TENANT_ID}" "${EVENT_ID}" "${page_id}" "${camera_id}" "${connection_session_id}"
