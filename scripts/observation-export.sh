#!/usr/bin/env bash
set -euo pipefail

EVENT_ID="${EVENT_ID:-fedcba9876543210}"
EXPORT_TARGET="${EXPORT_TARGET:-kubectl}"
KUBE_NAMESPACE="${KUBE_NAMESPACE:-tolo}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-tolo}"
OUT_DIR="${OUT_DIR:-observation-export-${EVENT_ID}-$(date -u +%Y%m%dT%H%M%SZ)}"

usage() {
    cat >&2 <<'EOF'
usage: observation-export.sh [-e event_id] [-o out_dir] [-t kubectl|compose] [-n namespace] [-c kube_context]
  -e  event id          (env EVENT_ID,        default fedcba9876543210)
  -o  output directory  (env OUT_DIR,         default observation-export-<event>-<utc time>)
  -t  where the DBs run (env EXPORT_TARGET,   kubectl | compose, default kubectl)
  -n  namespace         (env KUBE_NAMESPACE,  default tolo)
  -c  kube context      (env KUBE_CONTEXT,    default the current context)
EOF
    exit 2
}

while getopts ':e:o:t:n:c:h' opt; do
    case "${opt}" in
        e) EVENT_ID="${OPTARG}" ;;
        o) OUT_DIR="${OPTARG}" ;;
        t) EXPORT_TARGET="${OPTARG}" ;;
        n) KUBE_NAMESPACE="${OPTARG}" ;;
        c) KUBE_CONTEXT="${OPTARG}" ;;
        *) usage ;;
    esac
done

[[ "${EVENT_ID}" =~ ^[0-9a-f]{16}$ ]] || { printf 'event id must be 16 lowercase hex: %s\n' "${EVENT_ID}" >&2; exit 2; }

case "${EXPORT_TARGET}" in
    kubectl) command -v kubectl >/dev/null 2>&1 || { printf 'kubectl is required\n' >&2; exit 1; } ;;
    compose) command -v docker >/dev/null 2>&1 || { printf 'docker is required\n' >&2; exit 1; } ;;
    *) usage ;;
esac

psql_in() {
    local db_service="$1" db_name="$2"
    local psql=(psql -U "${db_name}" -d "${db_name}" -AtqX -v ON_ERROR_STOP=1 -v "event_id=${EVENT_ID}")
    if [ "${EXPORT_TARGET}" = kubectl ]; then
        local kube=(kubectl -n "${KUBE_NAMESPACE}")
        [ -n "${KUBE_CONTEXT}" ] && kube+=(--context "${KUBE_CONTEXT}")
        "${kube[@]}" exec -i "${db_service}-0" -- "${psql[@]}"
    else
        docker compose -p "${COMPOSE_PROJECT}" exec -T "${db_service}" "${psql[@]}"
    fi
}

export_jsonl() {
    local file="$1" db_service="$2" db_name="$3"
    psql_in "${db_service}" "${db_name}" >"${OUT_DIR}/${file}"
    printf '%s: %s lines\n' "${file}" "$(wc -l <"${OUT_DIR}/${file}" | tr -d ' ')"
}

iso() {
    printf "to_char(%s AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')" "$1"
}

mkdir -p "${OUT_DIR}"

export_jsonl measurements.jsonl observation-db observation <<SQL
SELECT json_strip_nulls(json_build_object(
    'eventId', m.event_id,
    'edgeDeviceId', m.edge_device_id,
    'observationPointId', m.observation_point_id,
    'observationPointName', p.name,
    'windowStart', $(iso m.window_start),
    'windowEnd', $(iso m.window_end),
    'countIn', m.count_in,
    'countOut', m.count_out,
    'meanDetectedPeople', m.mean_detected_people,
    'sent', true,
    'receivedAt', $(iso m.received_at)
))
FROM measurements m
LEFT JOIN observation_points p ON p.observation_point_id = m.observation_point_id
WHERE m.event_id = :'event_id'
ORDER BY m.window_start, m.observation_point_id;
SQL

export_jsonl edge-devices.jsonl observation-db observation <<SQL
SELECT json_build_object(
    'edgeDeviceId', d.edge_device_id,
    'name', d.name,
    'kind', d.kind,
    'unregistered', d.unregistered,
    'observationPoints', COALESCE((
        SELECT json_agg(json_build_object(
            'observationPointId', p.observation_point_id,
            'name', p.name,
            'enabled', p.enabled
        ) ORDER BY p.observation_point_id)
        FROM observation_points p
        WHERE p.edge_device_id = d.id
    ), '[]'),
    'linkedObservationPointId', (
        SELECT p.observation_point_id
        FROM camera_links l
        JOIN observation_points p ON p.id = l.observation_point_id
        WHERE l.camera_edge_device_id = d.id
    )
)
FROM edge_devices d
WHERE d.event_id = :'event_id'
ORDER BY d.edge_device_id;
SQL

export_jsonl snapshots.jsonl observation-db observation <<SQL
SELECT json_build_object(
    'snapshotId', snapshot_id,
    'windowStart', $(iso window_start),
    'windowEnd', $(iso window_end),
    'scores', scores,
    'createdAt', $(iso created_at)
)
FROM snapshots
WHERE event_id = :'event_id'
ORDER BY window_start;
SQL

export_jsonl optimization-results.jsonl observation-db observation <<SQL
SELECT json_build_object(
    'snapshotId', snapshot_id,
    'verdict', verdict,
    'detectionState', detection_state,
    'optimizationResult', optimization_result,
    'createdAt', $(iso created_at)
)
FROM optimization_results
WHERE event_id = :'event_id'
ORDER BY id;
SQL

export_jsonl graph-revisions.jsonl graph-authoring-db graph_authoring <<SQL
SELECT json_build_object(
    'revisionId', revision_id,
    'lastPublishedAt', $(iso last_published_at),
    'kernel', kernel,
    'labels', labels,
    'placements', placements
)
FROM graph_revisions
WHERE event_public_id = :'event_id'
ORDER BY last_published_at;
SQL

export_jsonl observation-point-mappings.jsonl graph-authoring-db graph_authoring <<SQL
SELECT json_strip_nulls(json_build_object(
    'observationPointId', observation_point_id,
    'anchorKind', anchor_kind,
    'anchorElementId', anchor_element_id,
    'routePosition', route_position,
    'updatedAt', $(iso updated_at)
))
FROM observation_point_mappings
WHERE event_public_id = :'event_id'
ORDER BY observation_point_id;
SQL

printf 'exported event %s to %s\n' "${EVENT_ID}" "${OUT_DIR}"
