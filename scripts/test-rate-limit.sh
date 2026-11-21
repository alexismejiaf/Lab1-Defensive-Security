#!/bin/sh

test_rate_limit() {
    attempts=${1:-10}
    expected_limit=${RateLimit__PermitLimit:-5}
    api_url=${2:-http://127.0.0.1:8081/}

    if ! [ "$attempts" -gt 0 ] 2>/dev/null; then
        printf 'El número de intentos debe ser un entero positivo.\n' >&2
        return 2
    fi

    if ! [ "$expected_limit" -gt 0 ] 2>/dev/null || [ "$expected_limit" -gt 2147483647 ]; then
        printf 'RateLimit__PermitLimit debe ser un entero entre 1 y 2147483647.\n' >&2
        return 2
    fi

    result=0
    request=0
    while [ "$request" -lt "$attempts" ]; do
        request=$((request + 1))
        expected_status=200
        if [ "$request" -gt "$expected_limit" ]; then
            expected_status=429
        fi

        if ! status=$(curl --silent --show-error --max-time 5 \
            --output /dev/null --write-out '%{http_code}' -- "$api_url"); then
            printf 'Solicitud %s → error al completar la solicitud.\n' "$request" >&2
            result=1
            continue
        fi

        printf 'Solicitud %s → HTTP %s\n' "$request" "$status"
        if [ "$status" != "$expected_status" ]; then
            printf 'Se esperaba HTTP %s en la solicitud %s.\n' "$expected_status" "$request" >&2
            result=1
        fi
    done

    return "$result"
}

test_rate_limit "$@"
