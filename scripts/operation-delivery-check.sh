#!/usr/bin/env bash
set -euo pipefail

GATEWAY_BASE_URL="${GATEWAY_BASE_URL:-http://localhost:8080}"
FAKEIDP_BASE_URL="${FAKEIDP_BASE_URL:-http://localhost:8082}"
TENANT_ID="${TOLO_TENANT_ID:-0123456789abcdef}"
EVENT_ID="${TOLO_EVENT_ID:-fedcba9876543210}"
SENDER_SUB="${SENDER_SUB:-staff-sender}"
SURGE_START="${SURGE_START:-0}"
FIRESTORE_BASE_URL="${FIRESTORE_BASE_URL:-http://localhost:8081}"
FIREBASE_AUTH_BASE_URL="${FIREBASE_AUTH_BASE_URL:-http://localhost:9099}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
token_script="${script_dir}/fakeidp-token.sh"

for cmd in curl jq docker; do
    command -v "${cmd}" >/dev/null 2>&1 || { printf '%s is required\n' "${cmd}" >&2; exit 1; }
done

since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
body=''
status=''
found=''

call() {
    local procedure="$1" payload="$2" token="$3"
    local response
    local auth=()
    [ -z "${token}" ] || auth=(-H "Authorization: Bearer ${token}")
    response="$(curl -sS -X POST -H 'Content-Type: application/json' ${auth[@]+"${auth[@]}"} \
        -d "${payload}" -w '\n%{http_code}' "${GATEWAY_BASE_URL}/${procedure}")"
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    printf '\n=== %s -> HTTP %s\n' "${procedure}" "${status}"
    printf '%s\n' "${body}" | jq . 2>/dev/null || printf '%s\n' "${body}"
}

expect() {
    [ "${status}" = "$1" ] || { printf 'expected HTTP %s, got %s\n' "$1" "${status}" >&2; exit 1; }
}

logs() {
    docker compose logs --no-log-prefix --since "${since}" "$1" 2>/dev/null | jq -cR 'fromjson? | select(type == "object")'
}

require_log() {
    local service="$1" label="$2" filter="$3"
    found=''
    for _ in $(seq 1 10); do
        found="$(logs "${service}" | jq -c "${filter}" | tail -n 1)"
        [ -n "${found}" ] && break
        sleep 1
    done
    [ -n "${found}" ] || { printf 'NG: %s not found in the %s log\n' "${label}" "${service}" >&2; exit 1; }
    printf 'ok: %s\n%s\n' "${label}" "${found}"
}

printf '# 1. a GUEST staff message through the public listener\n'
operator_token="$(FAKEIDP_BASE_URL="${FAKEIDP_BASE_URL}" "${token_script}" -k event_access -b "${SENDER_SUB}" -c console-ui \
    -t "${TENANT_ID}" -e "${EVENT_ID}" -s 'events.read events.operate')"
call tolo.operation.v1.StaffCommunicationService/SendStaffMessage \
    "$(jq -nc --arg t "${TENANT_ID}" --arg e "${EVENT_ID}" '{tenantId: $t, eventId: $e, audience: "AUDIENCE_GUEST", body: "Gate B is open"}')" \
    "${operator_token}"
expect 200
message_id="$(printf '%s' "${body}" | jq -r '.messageId')"

call tolo.operation.v1.StaffCommunicationService/ListStaffMessages \
    "$(jq -nc --arg t "${TENANT_ID}" --arg e "${EVENT_ID}" '{tenantId: $t, eventId: $e, audience: "AUDIENCE_GUEST"}')" \
    "${operator_token}"
expect 200
printf '%s' "${body}" | jq -e --arg m "${message_id}" 'any(.messages[]?; .messageId == $m)' >/dev/null \
    || { printf 'ListStaffMessages did not return message %s\n' "${message_id}" >&2; exit 1; }

printf '\n# 2. Observation reports a proposal; runn sets staff-online connected and staff-offline disconnected\n'
docker compose --profile runn run --rm -T runn run --var "surgeStart:${SURGE_START}" integration-proposal.yml

printf '\n# 3. Observation called Operation through the internal listener\n'
for procedure in RequestProposalDelivery RecordFeedbackValues; do
    require_log server "${procedure} from tolo-observation" \
        "select(.audit.method? == \"/tolo.operation.v1.DeliveryCoordinationService/${procedure}\" and .audit.caller_service == \"tolo-observation\" and .audit.http_status == 200) | .audit"
done

printf '\n# 4. the SendPush log-only skeleton\n'
require_log operation 'SendPush to staff-offline' \
    'select(.message == "notification SendPush (log-only skeleton)" and .recipient_user_ids == ["staff-offline"])'
delivery_id="$(printf '%s' "${found}" | jq -r '.data.delivery_id')"
proposal_event_id="$(printf '%s' "${found}" | jq -r '.event_id')"

printf '\n# 5. the relay pushed the published messages from NATS JetStream to Guest Service and Realtime\n'
eventually() {
    local label="$1" filter="$2"
    shift 2
    for _ in $(seq 1 20); do
        call "$@"
        [ "${status}" = 200 ] && printf '%s' "${body}" | jq -e "${filter}" >/dev/null && { printf 'ok: %s\n' "${label}"; return; }
        sleep 1
    done
    printf 'NG: %s\n' "${label}" >&2
    exit 1
}
eventually "Guest Service lists the GUEST message ${message_id}" \
    "any(.messages[]?; .messageId == \"${message_id}\" and .body == \"Gate B is open\")" \
    tolo.guest.v1.GuestPageService/ListGuestMessages "$(jq -nc --arg e "${EVENT_ID}" '{eventId: $e}')" ''
eventually "Guest Service has the guest status of ${proposal_event_id}" \
    '.takenAt | length > 0' \
    tolo.guest.v1.GuestPageService/GetCrowd "$(jq -nc --arg e "${proposal_event_id}" '{eventId: $e}')" ''
staff_token="$(FAKEIDP_BASE_URL="${FAKEIDP_BASE_URL}" "${token_script}" -k event_access -b staff-online -c console-ui \
    -t "${TENANT_ID}" -e "${proposal_event_id}" -s 'events.read')"
eventually "Realtime returns delivery ${delivery_id} to staff-online" \
    "any(.envelopes[]?; .deliveryId == \"${delivery_id}\")" \
    tolo.realtime.v1.RealtimeFetchService/FetchDeliveries "$(jq -nc --arg e "${proposal_event_id}" '{eventId: $e}')" "${staff_token}"

printf '\n# 6. the staff app reads the delivery notification under the production-equivalent Firestore rules\n'
call tolo.realtime.v1.RealtimeFetchService/IssueFirestoreToken "$(jq -nc --arg e "${proposal_event_id}" '{eventId: $e}')" "${staff_token}"
expect 200
custom_token="$(printf '%s' "${body}" | jq -r '.firebaseCustomToken')"
id_token="$(curl -sS -X POST -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg t "${custom_token}" '{token: $t, returnSecureToken: true}')" \
    "${FIREBASE_AUTH_BASE_URL}/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=e2e" | jq -r '.idToken')"
[ -n "${id_token}" ] && [ "${id_token}" != null ] || { printf 'NG: signInWithCustomToken returned no idToken\n' >&2; exit 1; }
read_notification() {
    curl -sS -o /tmp/tolo-delivery-notification.json -w '%{http_code}' -H "Authorization: Bearer ${id_token}" \
        "${FIRESTORE_BASE_URL}/v1/projects/demo-tolo/databases/(default)/documents/deliveryNotifications/$1"
}
notification_status="$(read_notification "${proposal_event_id}")"
latest="$(jq -r '.fields.latestDeliveryId.stringValue // empty' /tmp/tolo-delivery-notification.json)"
[ "${notification_status}" = 200 ] && [ "${latest}" = "${delivery_id}" ] \
    || { printf 'NG: deliveryNotifications/%s -> HTTP %s latestDeliveryId=%s\n' "${proposal_event_id}" "${notification_status}" "${latest}" >&2; exit 1; }
printf 'ok: deliveryNotifications/%s is readable and its latestDeliveryId is %s\n' "${proposal_event_id}" "${delivery_id}"
other_status="$(read_notification "${EVENT_ID}")"
[ "${other_status}" = 403 ] || { printf 'NG: deliveryNotifications/%s of another event -> HTTP %s, want 403\n' "${EVENT_ID}" "${other_status}" >&2; exit 1; }
printf 'ok: deliveryNotifications/%s of another event is denied\n' "${EVENT_ID}"

printf '\nall steps behaved as expected (message_id=%s delivery_id=%s)\n' "${message_id}" "${delivery_id}"
