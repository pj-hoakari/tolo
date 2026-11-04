#!/usr/bin/env bash
set -euo pipefail

for cmd in docker jq; do
    command -v "${cmd}" >/dev/null 2>&1 || { printf '%s is required\n' "${cmd}" >&2; exit 1; }
done

probe_image="$(docker compose config --format json | jq -r '.services.keygen.image')"
running="$(docker compose ps --services --status running)"

failures=0
probes=()
containers="$(for svc in ${running}; do
    cid="$(docker compose ps -q "${svc}")"
    printf '%s %s %s\n' "${svc}" "${cid}" "$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${cid}")"
done)"

cid_of() {
    printf '%s\n' "${containers}" | awk -v s="$1" '$1 == s { print $2 }'
}

addrs_of() {
    printf '%s\n' "${containers}" | awk -v s="$1" '$1 == s { $2 = ""; print }'
}

is_running() {
    printf '%s\n' "${running}" | grep -qx "$1"
}

fail() {
    printf 'NG: %s\n' "$1" >&2
    failures=$((failures + 1))
}

expect_reachable() {
    probes+=("reachable $1 $(cid_of "$1") $2 $3 $2")
}

expect_unreachable() {
    probes+=("unreachable $1 $(cid_of "$1") $2 $3 $(addrs_of "$2")")
}

probe() {
    local expect="$1" from="$2" cid="$3" to="$4" port="$5" addr
    shift 5
    for addr in "$@"; do
        if docker run --rm --network "container:${cid}" --entrypoint nc "${probe_image}" -z -w 2 "${addr}" "${port}" >/dev/null 2>&1; then
            if [ "${expect}" = reachable ]; then
                printf 'ok: %s -> %s:%s reachable\n' "${from}" "${to}" "${port}"
                return 0
            fi
            printf 'NG: %s -> %s:%s (%s) should be unreachable\n' "${from}" "${to}" "${port}" "${addr}"
            return 1
        fi
    done
    if [ "${expect}" = reachable ]; then
        printf 'NG: %s -> %s:%s should be reachable\n' "${from}" "${to}" "${port}"
        return 1
    fi
    printf 'ok: %s -> %s:%s unreachable\n' "${from}" "${to}" "${port}"
}

backends=''
for svc in testbackend tenant-management graph-authoring observation operation guest realtime; do
    is_running "${svc}" && backends="${backends} ${svc}"
done
stores="$(printf '%s\n' "${running}" | grep -E -- '-db$|^flow-control$' || true)"

if docker compose port server 8090 >/dev/null 2>&1; then
    fail 'server:8090 is published to the host'
fi
for svc in ${backends} ${stores} nats push-relay; do
    if [ -n "$(docker compose ps --format json "${svc}" | jq -r '.Publishers[]? | select(.PublishedPort > 0) | .PublishedPort')" ]; then
        fail "${svc} publishes a port to the host"
    fi
done

for from in ${backends}; do
    expect_reachable "${from}" server 8090
    for to in ${backends}; do
        [ "${from}" = "${to}" ] || expect_unreachable "${from}" "${to}" 8080
    done
    if is_running flow-control && [ "${from}" != observation ]; then
        expect_unreachable "${from}" flow-control 8080
    fi
done

if is_running observation && is_running flow-control; then
    expect_reachable observation flow-control 8080
fi

for from in ${stores}; do
    expect_unreachable "${from}" server 8080
    expect_unreachable "${from}" server 8090
done

expect_reachable push-relay nats 4222
for to in ${backends}; do
    case "${to}" in
        guest | realtime) expect_reachable push-relay "${to}" 8080 ;;
        *) expect_unreachable push-relay "${to}" 8080 ;;
    esac
done
for from in ${backends} ${stores}; do
    case "${from}" in
        operation | observation) expect_reachable "${from}" nats 4222 ;;
        *) expect_unreachable "${from}" nats 4222 ;;
    esac
done

if is_running realtime && is_running firebase-emulator; then
    expect_reachable realtime firebase-emulator 8080
fi

export probe_image
export -f probe
results="$(printf '%s\n' "${probes[@]}" | xargs -P 16 -L 1 bash -c 'probe "$@"' _ | sort || true)"
printf '%s\n' "${results}" | grep -v '^NG: ' || true
ng="$(printf '%s\n' "${results}" | grep '^NG: ' || true)"
if [ -n "${ng}" ]; then
    printf '%s\n' "${ng}" >&2
    failures=$((failures + $(printf '%s\n' "${ng}" | wc -l)))
fi
if [ "$(printf '%s\n' "${results}" | grep -cE '^(ok|NG): ')" -ne "${#probes[@]}" ]; then
    fail "only some of the ${#probes[@]} probes reported a result"
fi

if [ "${failures}" -ne 0 ]; then
    printf '%d reachability check(s) failed\n' "${failures}" >&2
    exit 1
fi
printf 'all reachability checks passed\n'
