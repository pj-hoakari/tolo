BEGIN;

INSERT INTO tenants (id, public_id, name, contract_plan, ownership_state, subdomain)
VALUES (gen_random_uuid(), :'tenant_id', 'tolo-dev-' || :'tenant_id', 'standard', 'owned', :'tenant_subdomain')
ON CONFLICT (public_id) DO NOTHING;

INSERT INTO events (id, public_id, tenant_id, tenant_public_id, name, status)
SELECT gen_random_uuid(), :'event_id', t.id, t.public_id, 'tolo-dev-' || :'event_id', 'draft'
FROM tenants t
WHERE t.public_id = :'tenant_id'
ON CONFLICT (public_id) DO NOTHING;

INSERT INTO tenant_memberships (tenant_id, user_id, tenant_role)
SELECT t.id, :'owner_sub', 'owner'
FROM tenants t
WHERE t.public_id = :'tenant_id'
ON CONFLICT (tenant_id, user_id) DO NOTHING;

INSERT INTO event_roles (event_id, tenant_id, user_id, role)
SELECT e.id, e.tenant_id, :'owner_sub', 'owner'
FROM events e
WHERE e.public_id = :'event_id'
ON CONFLICT (event_id, user_id) DO NOTHING;

SELECT t.public_id AS tenant_id, e.public_id AS event_id
FROM events e
JOIN tenants t ON t.id = e.tenant_id
WHERE e.public_id = :'event_id' AND t.public_id = :'tenant_id';

COMMIT;
