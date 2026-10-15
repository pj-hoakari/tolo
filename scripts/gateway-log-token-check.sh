#!/usr/bin/env bash
set -euo pipefail

if docker compose logs --no-color server | grep -nE 'eyJ[A-Za-z0-9_-]{20,}'; then
    printf 'NG: the gateway log contains a token-like string\n' >&2
    exit 1
fi
printf 'ok: no token in the gateway log\n'
