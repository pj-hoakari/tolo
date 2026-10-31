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

expect_rejected() {
    case "${status}" in 2??) printf 'expected a rejection, got HTTP %s\n' "${status}" >&2; exit 1 ;; esac
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
registration_token="$(token -k registration -b "${OWNER_SUB}" -s 'tenant.join')"
call tolo.tenant.v1.TenantService/ClaimTenantOwnership \
    "$(jq -nc --arg t "${tenant_id}" --arg c "${claim_token}" --arg s "${TENANT_SUBDOMAIN}" '{tenantId: $t, ownershipClaimToken: $c, subdomain: $s, displayName: "owner"}')" \
    "${registration_token}"
expect 200
[ "$(printf '%s' "${body}" | jq -r '.tenant.subdomain')" = "${TENANT_SUBDOMAIN}" ] || { printf 'claimed tenant does not carry the subdomain\n' >&2; exit 1; }

printf '\n# 3. tenant subdomain\n'
call tolo.tenant.v1.TenantService/ResolveTenantSubdomain \
    "$(jq -nc --arg s "${TENANT_SUBDOMAIN}" '{subdomain: $s}')"
expect 200
[ "$(printf '%s' "${body}" | jq -r '.tenantId')" = "${tenant_id}" ] || { printf 'anonymous resolve returned another tenant\n' >&2; exit 1; }

call tolo.tenant.v1.TenantService/StartTenantRegistration \
    "$(jq -nc --arg n "${TENANT_NAME}" '{name: $n, contractPlan: "standard"}')"
expect 200
rival_id="$(printf '%s' "${body}" | jq -r '.tenant.tenantId')"
rival_claim_token="$(printf '%s' "${body}" | jq -r '.ownershipClaimToken')"
call tolo.tenant.v1.TenantService/ClaimTenantOwnership \
    "$(jq -nc --arg t "${rival_id}" --arg c "${rival_claim_token}" --arg s "${TENANT_SUBDOMAIN}" '{tenantId: $t, ownershipClaimToken: $c, subdomain: $s, displayName: "owner"}')" \
    "${registration_token}"
expect 409
[ "$(printf '%s' "${body}" | jq -r '.code')" = "already_exists" ] || { printf 'expected already_exists for a taken subdomain\n' >&2; exit 1; }

printf '\n# 4. tenant_access flow\n'
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
printf '%s' "${body}" | jq -e --arg u "${OWNER_SUB}" --arg e "${event_id}" \
    'any(.memberships[]; .userId == $u and any(.eventRoles[]?; .eventId == $e and .role == "ROLE_OWNER"))' >/dev/null \
    || { printf 'the creator of the event has no owner event role\n' >&2; exit 1; }

printf '\n# 4.1 invitation\n'
call tolo.relation.v1.RelationAdminService/CreateTenantInvitation \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t, tenantRole: "ROLE_STAFF", displayName: "staff"}')" \
    "${owner_token}"
expect 200
invitation_token="$(printf '%s' "${body}" | jq -r '.invitationToken')"

call tolo.relation.v1.RelationAdminService/ListTenantInvitations \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t}')" "${owner_token}"
expect 200
[ "$(printf '%s' "${body}" | jq '.invitations | length')" = 1 ] || { printf 'expected one pending invitation\n' >&2; exit 1; }

member_registration_token="$(token -k registration -b "${MEMBER_SUB}" -s 'tenant.join')"
call tolo.relation.v1.RelationAdminService/AcceptTenantInvitation \
    "$(jq -nc --arg t "${tenant_id}" --arg i "${invitation_token}" '{tenantId: $t, invitationToken: $i}')" \
    "${member_registration_token}"
expect 200
[ "$(printf '%s' "${body}" | jq -r '.membership.userId')" = "${MEMBER_SUB}" ] || { printf 'the accepted membership belongs to another user\n' >&2; exit 1; }

call tolo.relation.v1.RelationAdminService/ListMemberships \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t}')" "${owner_token}"
expect 200
printf '%s' "${body}" | jq -e --arg u "${MEMBER_SUB}" \
    'any(.memberships[]; .userId == $u and .tenantRole == "ROLE_STAFF" and .displayName == "staff")' >/dev/null \
    || { printf 'the invited user did not join as staff\n' >&2; exit 1; }

call tolo.relation.v1.RelationAdminService/ListTenantInvitations \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t}')" "${owner_token}"
expect 200
[ "$(printf '%s' "${body}" | jq '.invitations | length')" = 0 ] || { printf 'the accepted invitation is still pending\n' >&2; exit 1; }

outsider_registration_token="$(token -k registration -b "${OUTSIDER_SUB}" -s 'tenant.join')"
call tolo.relation.v1.RelationAdminService/AcceptTenantInvitation \
    "$(jq -nc --arg t "${tenant_id}" --arg i "${invitation_token}" '{tenantId: $t, invitationToken: $i}')" \
    "${outsider_registration_token}"
expect_rejected

call tolo.relation.v1.RelationAdminService/ListMemberships \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t}')" "${owner_token}"
expect 200
printf '%s' "${body}" | jq -e --arg u "${OUTSIDER_SUB}" 'all(.memberships[]; .userId != $u)' >/dev/null \
    || { printf 'a used invitation let another user join\n' >&2; exit 1; }

printf '\n# 5. permission boundaries\n'
outsider_token="$(token -k tenant_access -b "${OUTSIDER_SUB}" -t "${tenant_id}" -s 'tenant.read tenant.write events.read events.manage')"
call tolo.relation.v1.RelationAdminService/CreateTenantInvitation \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t, tenantRole: "ROLE_STAFF", displayName: "x"}')" \
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

printf '\n# 6. revocation\n'
revoked_token="$(token -k tenant_access -b "${OWNER_SUB}" -t "${tenant_id}" -s 'tenant.read tenant.write events.read events.manage')"
curl -sS -o /dev/null -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg t "${revoked_token}" '{token: $t}')" "${FAKEIDP_BASE_URL}/revoke"

call tolo.relation.v1.RelationAdminService/CreateTenantInvitation \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t, tenantRole: "ROLE_STAFF", displayName: "z"}')" \
    "${revoked_token}"
expect 401

call tolo.tenant.v1.TenantService/ListEvents \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t}')" "${revoked_token}"
expect 200

printf '\n# 7. internal-only RPC with an external token\n'
call tolo.tenant.v1.TenantService/GetEvent \
    "$(jq -nc --arg e "${event_id}" '{eventId: $e}')" "${owner_token}"
expect 403

call tolo.relation.v1.RelationAdminService/AddTenantMember \
    "$(jq -nc --arg t "${tenant_id}" '{tenantId: $t, userId: "user-y", tenantRole: "ROLE_STAFF", displayName: "y"}')" \
    "${owner_token}"
expect 403

printf '\nall steps behaved as expected (tenant_id=%s event_id=%s)\n' "${tenant_id}" "${event_id}"
