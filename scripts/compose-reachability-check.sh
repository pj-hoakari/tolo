#!/usr/bin/env bash
set -euo pipefail

for cmd in docker jq; do
    command -v "${cmd}" >/dev/null 2>&1 || { printf '%s is required\n' "${cmd}" >&2; exit 1; }
done

probe_image="$(docker compose config --format json | jq -r '.services.keygen.image')"
running="$(docker compose ps --services --status running)"

failures=0

is_running() {
    printf '%s\n' "${running}" | grep -qx "$1"
}

fail() {
    printf 'NG: %s\n' "$1" >&2
    failures=$((failures + 1))
}

can_connect() {
    docker run --rm --network "container:$(docker compose ps -q "$1")" --entrypoint nc "${probe_image}" -z -w 2 "$2" "$3" >/dev/null 2>&1
}

target_addrs() {
    printf '%s\n' "$1"
    docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' "$(docker compose ps -q "$1")" | sed '/^$/d'
}

expect_reachable() {
    if can_connect "$1" "$2" "$3"; then
        printf 'ok: %s -> %s:%s reachable\n' "$1" "$2" "$3"
    else
        fail "$1 -> $2:$3 should be reachable"
    fi
}

expect_unreachable() {
    local addr
    for addr in $(target_addrs "$2"); do
        if can_connect "$1" "${addr}" "$3"; then
            fail "$1 -> $2:$3 (${addr}) should be unreachable"
            return
        fi
    done
    printf 'ok: %s -> %s:%s unreachable\n' "$1" "$2" "$3"
}

backends=''
for svc in testbackend tenant-management graph-authoring observation operation; do
    is_running "${svc}" && backends="${backends} ${svc}"
done
stores="$(printf '%s\n' "${running}" | grep -E -- '-db$|^flow-control$' || true)"

if docker compose port server 8090 >/dev/null 2>&1; then
    fail 'server:8090 is published to the host'
fi
for svc in ${backends} ${stores} nats push-relay push-receiver; do
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
expect_reachable push-relay push-receiver 8080
for from in ${backends} ${stores}; do
    case "${from}" in
        operation | observation) expect_reachable "${from}" nats 4222 ;;
        *) expect_unreachable "${from}" nats 4222 ;;
    esac
    expect_unreachable "${from}" push-receiver 8080
done

if [ "${failures}" -ne 0 ]; then
    printf '%d reachability check(s) failed\n' "${failures}" >&2
    exit 1
fi
printf 'all reachability checks passed\n'
