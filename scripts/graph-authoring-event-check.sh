#!/usr/bin/env bash
set -euo pipefail

GATEWAY_BASE_URL="${GATEWAY_BASE_URL:-http://localhost:8080}"
FAKEIDP_BASE_URL="${FAKEIDP_BASE_URL:-http://localhost:8082}"
OWNER_SUB="${OWNER_SUB:-user-owner}"
TENANT_NAME="${TENANT_NAME:-graph-$$-${RANDOM}}"
TENANT_SUBDOMAIN="${TENANT_SUBDOMAIN:-graph-$$-${RANDOM}}"
MISSING_EVENT_ID="${MISSING_EVENT_ID:-deadbeefdeadbeef}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
token_script="${script_dir}/fakeidp-token.sh"

for cmd in curl jq; do
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

expect_code() {
    local code
    code="$(printf '%s' "${body}" | jq -r '.code // empty')"
    [ "${code}" = "$1" ] || { printf 'expected code %s, got %s\n' "$1" "${code:-none}" >&2; exit 1; }
}

token() {
    FAKEIDP_BASE_URL="${FAKEIDP_BASE_URL}" "${token_script}" "$@"
}

save_graph_payload() {
    jq -nc --arg e "$1" '{
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
    }'
}

printf '# 1. a tenant with an open event\n'
call tolo.tenant.v1.TenantService/StartTenantRegistration \
    "$(jq -nc --arg n "${TENANT_NAME}" '{name: $n, contractPlan: "standard"}')"
expect 200
tenant_id="$(printf '%s' "${body}" | jq -r '.tenant.tenantId')"
claim_token="$(printf '%s' "${body}" | jq -r '.ownershipClaimToken')"

registration_token="$(token -k registration -b "${OWNER_SUB}" -s 'tenant.claim')"
call tolo.tenant.v1.TenantService/ClaimTenantOwnership \
    "$(jq -nc --arg t "${tenant_id}" --arg c "${claim_token}" --arg s "${TENANT_SUBDOMAIN}" '{tenantId: $t, ownershipClaimToken: $c, subdomain: $s}')" \
    "${registration_token}"
expect 200

owner_token="$(token -k tenant_access -b "${OWNER_SUB}" -t "${tenant_id}" -s 'tenant.read tenant.write events.read events.manage')"
call tolo.tenant.v1.TenantService/CreateEvent \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t, name: "graph-expo"}')" \
    "${owner_token}"
expect 200
event_id="$(printf '%s' "${body}" | jq -r '.event.eventId')"

printf '\n# 2. SaveGraph for an event Tenant Management does not know\n'
missing_token="$(token -k event_access -b "${OWNER_SUB}" -t "${tenant_id}" -e "${MISSING_EVENT_ID}" -s 'events.manage')"
call tolo.graph.v1.GraphAuthoringService/SaveGraph "$(save_graph_payload "${MISSING_EVENT_ID}")" "${missing_token}"
expect 400
expect_code failed_precondition

printf '\n# 3. SaveGraph for the open event\n'
event_token="$(token -k event_access -b "${OWNER_SUB}" -t "${tenant_id}" -e "${event_id}" -s 'events.manage')"
call tolo.graph.v1.GraphAuthoringService/SaveGraph "$(save_graph_payload "${event_id}")" "${event_token}"
expect 200

printf '\nall steps behaved as expected (tenant_id=%s event_id=%s)\n' "${tenant_id}" "${event_id}"
