#!/usr/bin/env bash
set -euo pipefail

GATEWAY_BASE_URL="${GATEWAY_BASE_URL:-http://localhost:8080}"
FAKEIDP_BASE_URL="${FAKEIDP_BASE_URL:-http://localhost:8082}"
OWNER_SUB="${OWNER_SUB:-user-owner}"
TENANT_NAME="${TENANT_NAME:-observation-$$-${RANDOM}}"
TENANT_SUBDOMAIN="${TENANT_SUBDOMAIN:-observation-$$-${RANDOM}}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
token_script="${script_dir}/fakeidp-token.sh"

for cmd in curl jq docker; do
    command -v "${cmd}" >/dev/null 2>&1 || { printf '%s is required\n' "${cmd}" >&2; exit 1; }
done

body=''
status=''

call() {
    local procedure="$1" payload="$2" token="${3:-}"
    local args=(-sS -X POST -H 'Content-Type: application/json' -d "${payload}" -w '\n%{http_code}')
    [ -n "${token}" ] && args+=(-H "Authorization: Bearer ${token}")

    local response
    response="$(curl "${args[@]}" "${GATEWAY_BASE_URL}/${procedure}")"
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    printf '\n=== %s -> HTTP %s\n' "${procedure}" "${status}"
    printf '%s\n' "${body}" | jq . 2>/dev/null || printf '%s\n' "${body}"
}

expect() {
    [ "${status}" = "$1" ] || { printf 'expected HTTP %s, got %s\n' "$1" "${status}" >&2; exit 1; }
}

token() {
    FAKEIDP_BASE_URL="${FAKEIDP_BASE_URL}" "${token_script}" "$@"
}

printf '# 1. a tenant with an open event and a published graph\n'
call tolo.tenant.v1.TenantService/StartTenantRegistration \
    "$(jq -nc --arg n "${TENANT_NAME}" '{name: $n, contractPlan: "standard"}')"
expect 200
tenant_id="$(printf '%s' "${body}" | jq -r '.tenant.tenantId')"
claim_token="$(printf '%s' "${body}" | jq -r '.ownershipClaimToken')"

registration_token="$(token -k registration -b "${OWNER_SUB}" -s 'tenant.join')"
call tolo.tenant.v1.TenantService/ClaimTenantOwnership \
    "$(jq -nc --arg t "${tenant_id}" --arg c "${claim_token}" --arg s "${TENANT_SUBDOMAIN}" '{tenantId: $t, ownershipClaimToken: $c, subdomain: $s, displayName: "owner"}')" \
    "${registration_token}"
expect 200

owner_token="$(token -k tenant_access -b "${OWNER_SUB}" -t "${tenant_id}" -s 'tenant.read tenant.write events.read events.manage')"
call tolo.tenant.v1.TenantService/CreateEvent \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t, name: "observation-expo"}')" \
    "${owner_token}"
expect 200
event_id="$(printf '%s' "${body}" | jq -r '.event.eventId')"

manage_token="$(token -k event_access -b "${OWNER_SUB}" -t "${tenant_id}" -e "${event_id}" -s 'events.manage')"
call tolo.graph.v1.GraphAuthoringService/SaveGraph "$(jq -nc --arg e "${event_id}" '{
    eventId: $e,
    document: {
        nodes: [
            {nodeId: "outside", nodeType: "NODE_TYPE_EXTERNAL", labels: {ja: "会場の外"}, layout: {x: -120, y: 0}},
            {nodeId: "gate", nodeType: "NODE_TYPE_TRANSIT_ONLY", labels: {ja: "入場ゲート"}, layout: {x: 0, y: 0}},
            {nodeId: "hall", nodeType: "NODE_TYPE_GOAL", labels: {ja: "ホール"}, layout: {x: 120, y: 0}}
        ],
        edges: [
            {edgeId: "outside-gate", sourceNodeId: "outside", targetNodeId: "gate", direction: "EDGE_DIRECTION_ONE_WAY"},
            {edgeId: "gate-hall", sourceNodeId: "gate", targetNodeId: "hall", direction: "EDGE_DIRECTION_ONE_WAY"}
        ]
    }
}')" "${manage_token}"
expect 200
call tolo.graph.v1.GraphAuthoringService/PublishRevision "$(jq -nc --arg e "${event_id}" '{eventId: $e}')" "${manage_token}"
expect 200

printf '\n# 2. an edge device registered with Observation\n'
call tolo.observation.v1.EdgeDeviceService/RegisterEdgeDevice \
    "$(jq -nc --arg e "${event_id}" '{eventId: $e, name: "gate-counter", observationPointNames: ["gate"]}')" \
    "${manage_token}"
expect 200
device_id="$(printf '%s' "${body}" | jq -r '.device.edgeDeviceId')"
point_id="$(printf '%s' "${body}" | jq -r '.device.observationPoints[0].observationPointId')"
printf '%s' "${body}" | jq -e '.observationPagePath | type == "string" and length > 0' >/dev/null \
    || { printf 'RegisterEdgeDevice did not return observationPagePath\n' >&2; exit 1; }

printf '\n# 3. Heartbeat and ReportMeasurements from the device\n'
report_token="$(token -k event_access -b "${OWNER_SUB}" -t "${tenant_id}" -e "${event_id}" -s 'events.report')"
call tolo.observation.v1.EdgeDeviceService/Heartbeat \
    "$(jq -nc --arg e "${event_id}" --arg d "${device_id}" --arg p "${point_id}" '{eventId: $e, edgeDeviceId: $d, activeObservationPointIds: [$p]}')" \
    "${report_token}"
expect 200

window_end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
window_start="$(date -u -d '-30 seconds' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-30S +%Y-%m-%dT%H:%M:%SZ)"
call tolo.observation.v1.MeasurementIngestService/ReportMeasurements \
    "$(jq -nc --arg e "${event_id}" --arg d "${device_id}" --arg p "${point_id}" --arg s "${window_start}" --arg t "${window_end}" \
        '{eventId: $e, edgeDeviceId: $d, measurements: [{observationPointId: $p, windowStart: $s, windowEnd: $t, countIn: 3, countOut: 1, source: "MEASUREMENT_SOURCE_EDGE"}]}')" \
    "${report_token}"
expect 200

printf '\n# 4. Observation called GraphSupply through the internal listener\n'
for procedure in GetCurrentRevision GetObservationPointMappings; do
    method="/tolo.graph.v1.GraphSupplyService/${procedure}"
    found="$(docker compose logs --no-log-prefix server 2>/dev/null | jq -rc --arg m "${method}" '
        select(.audit.method? == $m and .audit.caller_service == "tolo-observation") | .audit.http_status' 2>/dev/null | tail -n 1)"
    printf '%s -> HTTP %s\n' "${method}" "${found:-none}"
    [ "${found}" = "200" ] || { printf 'no successful %s from tolo-observation in the gateway audit log\n' "${method}" >&2; exit 1; }
done

printf '\n# 5. UpdateObservationSettings and GetObservationSettings through the public listener\n'
settings_token="$(token -k event_access -b "${OWNER_SUB}" -t "${tenant_id}" -e "${event_id}" -s 'events.read events.manage')"
call tolo.observation.v1.ObservationSettingsService/UpdateObservationSettings \
    "$(jq -nc --arg e "${event_id}" '{eventId: $e, settings: {historyWindowDays: 14, eventType: "EVENT_TYPE_LONG_TERM"}}')" \
    "${settings_token}"
expect 200
call tolo.observation.v1.ObservationSettingsService/GetObservationSettings \
    "$(jq -nc --arg e "${event_id}" '{eventId: $e}')" \
    "${settings_token}"
expect 200
printf '%s' "${body}" | jq -e '.settings.historyWindowDays == 14 and .settings.eventType == "EVENT_TYPE_LONG_TERM"' >/dev/null \
    || { printf 'GetObservationSettings did not return the stored settings\n' >&2; exit 1; }

printf '\nall steps behaved as expected (tenant_id=%s event_id=%s edge_device_id=%s)\n' "${tenant_id}" "${event_id}" "${device_id}"
