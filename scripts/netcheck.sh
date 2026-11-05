#!/usr/bin/env bash

set -uo pipefail

DMZ_NETWORK="linkly-dmz"
INTERNAL_NETWORK="linkly-internal"
ADMIN_NETWORK="linkly-admin"

API="linkly-api"
DB="linkly-db"
CACHE="linkly-cache"

PASS=0
FAIL=0

echo "======================================"
echo " Linkly Network Segmentation Test"
echo "======================================"

# Check required networks
for network in "$DMZ_NETWORK" "$INTERNAL_NETWORK" "$ADMIN_NETWORK"; do
    if ! docker network inspect "$network" >/dev/null 2>&1; then
        echo "ERROR: Network $network does not exist."
        exit 1
    fi
done

# Check required containers
for container in "$API" "$DB" "$CACHE"; do
    if ! docker inspect "$container" >/dev/null 2>&1; then
        echo "ERROR: Container $container does not exist."
        exit 1
    fi
done

# Check connectivity
check_connection() {

    local label="$1"
    local network="$2"
    local target="$3"
    local port="$4"
    local expected="$5"

    printf "%-40s" "$label"

    if docker run --rm \
        --network "$network" \
        alpine:3.20 \
        sh -c "nc -z -w 3 '$target' '$port'" \
        >/dev/null 2>&1; then

        actual="allowed"
    else
        actual="blocked"
    fi

    if [[ "$actual" == "$expected" ]]; then
        echo "PASS ($actual)"
        ((PASS+=1))
    else
        echo "FAIL (expected $expected, got $actual)"
        ((FAIL+=1))
    fi
}

echo
echo "========== DMZ NETWORK =========="

# Proxy and API share DMZ
check_connection \
    "DMZ -> API" \
    "$DMZ_NETWORK" \
    "$API" 5000 allowed

# DB and cache must not be accessible from DMZ
check_connection \
    "DMZ -> PostgreSQL" \
    "$DMZ_NETWORK" \
    "$DB" 5432 blocked

check_connection \
    "DMZ -> Redis" \
    "$DMZ_NETWORK" \
    "$CACHE" 6379 blocked

echo
echo "========== INTERNAL NETWORK =========="

# API, worker, DB and Redis share internal
check_connection \
    "Internal -> API" \
    "$INTERNAL_NETWORK" \
    "$API" 5000 allowed

check_connection \
    "Internal -> PostgreSQL" \
    "$INTERNAL_NETWORK" \
    "$DB" 5432 allowed

check_connection \
    "Internal -> Redis" \
    "$INTERNAL_NETWORK" \
    "$CACHE" 6379 allowed

echo
echo "========== ADMIN NETWORK =========="

# Only DB should be accessible from admin
check_connection \
    "Admin -> PostgreSQL" \
    "$ADMIN_NETWORK" \
    "$DB" 5432 allowed

check_connection \
    "Admin -> API" \
    "$ADMIN_NETWORK" \
    "$API" 5000 blocked

check_connection \
    "Admin -> Redis" \
    "$ADMIN_NETWORK" \
    "$CACHE" 6379 blocked

echo
echo "========== INTERNET ACCESS =========="

# Internal and admin networks should not have external access
check_connection \
    "Internal -> Internet" \
    "$INTERNAL_NETWORK" \
    "1.1.1.1" 443 blocked

check_connection \
    "Admin -> Internet" \
    "$ADMIN_NETWORK" \
    "1.1.1.1" 443 blocked

# DMZ should have external access
check_connection \
    "DMZ -> Internet" \
    "$DMZ_NETWORK" \
    "1.1.1.1" 443 allowed

echo
echo "======================================"
echo " Network Test Summary"
echo "======================================"

echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ "$FAIL" -eq 0 ]]; then
    echo
    echo "SUCCESS: All network tests passed."
    exit 0
else
    echo
    echo "FAILURE: Network segmentation needs attention."
    exit 1
fi
