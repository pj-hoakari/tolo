#!/usr/bin/env bash
set -euo pipefail

GATEWAY_BASE_URL="${GATEWAY_BASE_URL:-http://localhost:8080}"
FAKEIDP_BASE_URL="${FAKEIDP_BASE_URL:-http://localhost:8082}"
OWNER_SUB="${OWNER_SUB:-user-owner}"
OUTSIDER_SUB="${OUTSIDER_SUB:-user-outsider}"
MEMBER_SUB="${MEMBER_SUB:-user-staff}"
TENANT_NAME="${TENANT_NAME:-acme-$$-${RANDOM}}"
TENANT_SUBDOMAIN="${TENANT_SUBDOMAIN:-onb-$$-${RANDOM}}"

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

token() {
    FAKEIDP_BASE_URL="${FAKEIDP_BASE_URL}" "${token_script}" "$@"
}

printf '# 1. anonymous StartTenantRegistration\n'
call tolo.tenant.v1.TenantService/StartTenantRegistration \
    "$(jq -nc --arg n "${TENANT_NAME}" '{name: $n, contractPlan: "standard"}')"
expect 200
tenant_id="$(printf '%s' "${body}" | jq -r '.tenant.tenantId')"
claim_token="$(printf '%s' "${body}" | jq -r '.ownershipClaimToken')"
printf 'tenant_id=%s\n' "${tenant_id}"

printf '\n# 2. ClaimTenantOwnership with a registration token\n'
registration_token="$(token -k registration -b "${OWNER_SUB}" -s 'tenant.claim')"
call tolo.tenant.v1.TenantService/ClaimTenantOwnership \
    "$(jq -nc --arg t "${tenant_id}" --arg c "${claim_token}" --arg s "${TENANT_SUBDOMAIN}" '{tenantId: $t, ownershipClaimToken: $c, subdomain: $s}')" \
    "${registration_token}"
expect 200

printf '\n# 3. tenant_access flow\n'
owner_token="$(token -k tenant_access -b "${OWNER_SUB}" -t "${tenant_id}" -s 'tenant.read tenant.write events.read events.manage')"

call tolo.tenant.v1.TenantService/CreateEvent \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t, name: "spring-expo"}')" \
    "${owner_token}"
expect 200
event_id="$(printf '%s' "${body}" | jq -r '.event.eventId')"

call tolo.tenant.v1.TenantService/ListEvents \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t}')" "${owner_token}"
expect 200

call tolo.relation.v1.RelationAdminService/ListMemberships \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t}')" "${owner_token}"
expect 200

call tolo.relation.v1.RelationAdminService/AddTenantMember \
    "$(jq -nc --arg t "${tenant_id}" --arg u "${MEMBER_SUB}" '{tenantId: $t, userId: $u, tenantRole: "ROLE_STAFF"}')" \
    "${owner_token}"
expect 200

call tolo.relation.v1.RelationAdminService/ListMemberships \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t}')" "${owner_token}"
expect 200

printf '\n# 4. permission boundaries\n'
outsider_token="$(token -k tenant_access -b "${OUTSIDER_SUB}" -t "${tenant_id}" -s 'tenant.read tenant.write events.read events.manage')"
call tolo.relation.v1.RelationAdminService/AddTenantMember \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t, userId: "user-x", tenantRole: "ROLE_STAFF"}')" \
    "${outsider_token}"
expect 403

ghost_token="$(token -k tenant_access -b "${OWNER_SUB}" -t deadbeefdeadbeef -s 'tenant.read events.read')"
call tolo.tenant.v1.TenantService/ListEvents '{"tenantId":"deadbeefdeadbeef"}' "${ghost_token}"
expect 404

call tolo.tenant.v1.TenantService/ListEvents \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t}')" "${ghost_token}"
expect 403

readonly_token="$(token -k tenant_access -b "${OWNER_SUB}" -t "${tenant_id}" -s 'tenant.read')"
call tolo.tenant.v1.TenantService/CreateEvent \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t, name: "denied"}')" "${readonly_token}"
expect 403

printf '\n# 5. revocation\n'
revoked_token="$(token -k tenant_access -b "${OWNER_SUB}" -t "${tenant_id}" -s 'tenant.read tenant.write events.read events.manage')"
curl -sS -o /dev/null -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg t "${revoked_token}" '{token: $t}')" "${FAKEIDP_BASE_URL}/revoke"

call tolo.relation.v1.RelationAdminService/AddTenantMember \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t, userId: "user-z", tenantRole: "ROLE_STAFF"}')" \
    "${revoked_token}"
expect 401

call tolo.tenant.v1.TenantService/ListEvents \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t}')" "${revoked_token}"
expect 200

printf '\n# 6. internal-only RPC with an external token\n'
call tolo.tenant.v1.TenantService/GetEvent \
    "$(jq -nc --arg e "${event_id}" '{eventId: $e}')" "${owner_token}"
expect 403

printf '\nall steps behaved as expected (tenant_id=%s event_id=%s)\n' "${tenant_id}" "${event_id}"
