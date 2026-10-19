#!/usr/bin/env bash
set -euo pipefail

GATEWAY_BASE_URL="${GATEWAY_BASE_URL:-http://localhost:8080}"
TENANT_ID="${TOLO_TENANT_ID:-0123456789abcdef}"
TENANT_SUBDOMAIN="${TOLO_TENANT_SUBDOMAIN:-test}"

for cmd in curl jq; do
    command -v "${cmd}" >/dev/null 2>&1 || { printf '%s is required\n' "${cmd}" >&2; exit 1; }
done

printf '# anonymous ResolveTenantSubdomain for the seed subdomain\n'
response="$(curl -sS -X POST -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg s "${TENANT_SUBDOMAIN}" '{subdomain: $s}')" \
    -w '\n%{http_code}' "${GATEWAY_BASE_URL}/tolo.tenant.v1.TenantService/ResolveTenantSubdomain")"
status="${response##*$'\n'}"
body="${response%$'\n'*}"
printf '%s -> HTTP %s %s\n' "${TENANT_SUBDOMAIN}" "${status}" "${body}"

[ "${status}" = "200" ] || { printf 'expected HTTP 200, got %s\n' "${status}" >&2; exit 1; }
resolved="$(printf '%s' "${body}" | jq -r '.tenantId')"
[ "${resolved}" = "${TENANT_ID}" ] || { printf 'subdomain %s resolved to %s, expected %s\n' "${TENANT_SUBDOMAIN}" "${resolved}" "${TENANT_ID}" >&2; exit 1; }

printf 'subdomain %s resolves to the seed tenant %s\n' "${TENANT_SUBDOMAIN}" "${TENANT_ID}"
