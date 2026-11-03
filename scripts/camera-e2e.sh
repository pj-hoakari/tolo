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

TENANT_ID="${TOLO_TENANT_ID:-0123456789abcdef}"
EVENT_ID="${TOLO_EVENT_ID:-fedcba9876543210}"
IDP_CLIENT_ID="${IDP_CLIENT_ID:-console-ui}"
IDP_CLIENT_SECRET="${IDP_CLIENT_SECRET:-secret}"
IDP_REDIRECT_URI="${IDP_REDIRECT_URI:-http://127.0.0.1:3000/api/auth/callback/console-ui}"
IDP_USERNAME="${IDP_USERNAME:-user-123}"
IDP_PASSWORD="${IDP_PASSWORD:-password}"
CONNECTION_CLIENT_ID="${CONNECTION_CLIENT_ID:-observation-connection}"
CONNECTION_REDIRECT_URI="${CONNECTION_REDIRECT_URI:-http://localhost:3000/api/auth/connection/callback}"
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
    response="$(curl -sS -X "${method}" -w $'\n%{http_code}' "$@" "${url}")" \
        || die "request failed: ${method} ${url}"

    status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    printf '  HTTP %s\n' "${status}"
}

call_redirect() {
    local method="$1" url="$2"
    shift 2
    local response
    response="$(curl -sS -X "${method}" -D - -o /dev/null -w $'\n%{http_code}' "$@" "${url}")" \
        || die "request failed: ${method} ${url}"
    status="${response##*$'\n'}"
    body=""
    location="$(printf '%s' "${response%$'\n'*}" | tr -d '\r' | awk 'tolower($1) == "location:" { print $2 }' | tail -1)"
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
        code="$(curl -sS -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || true)"
        if [ "${code}" != "000" ] && [ "${code}" -lt 500 ]; then
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
    response="$(curl -sS -o /dev/null -w '%{http_code}' -c "${cookies}" \
        -H 'Content-Type: application/json' \
        --data "$(jq -nc --arg u "${IDP_USERNAME}" --arg p "${IDP_PASSWORD}" --arg t "${TENANT_ID}" \
            '{username: $u, password: $p, tenantId: $t}')" \
        "${IDP_URL}/api/login")"
    [ "${response}" = "200" ] || die "IdP login for the connection flow failed with HTTP ${response}"
}

authorize_connection() {
    local cookies="$1" page_id="$2"
    local return_path="/event/${EVENT_ID}/observation"
    local return_encoded
    return_encoded="$(jq -rn --arg v "${return_path}" '$v|@uri')"

    call_redirect GET "${WEB_URL}/api/auth/connection/start?eventId=${EVENT_ID}&pageEdgeDeviceId=${page_id}&return=${return_encoded}" \
        -H "Host: ${WEB_HOST}" -b "${cookies}" -c "${cookies}"
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
        code="$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: ${WEB_HOST}" "${WEB_URL}/" 2>/dev/null || true)"
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
cleanup() {
    local code=$?
    rm -f "${connection_cookies}"
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
    compose up -d --wait web
wait_for_web
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
expect_not_status 200 'BFF non-linked camera'
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

step '7. revoke the device authorization and the connection delegation'
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
