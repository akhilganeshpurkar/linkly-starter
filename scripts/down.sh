#!/usr/bin/env bash

set -Eeuo pipefail

echo "======================================"
echo " Stopping Linkly Docker Stack"
echo "======================================"

CONTAINERS=(
    linkly-proxy
    linkly-worker
    linkly-api
    linkly-cache
    linkly-db
)

NETWORKS=(
    linkly-dmz
    linkly-internal
    linkly-admin
)

# Stop and remove containers
for container in "${CONTAINERS[@]}"; do

    if docker container inspect "$container" >/dev/null 2>&1; then
        echo "Removing container: $container"

        docker rm -f "$container"
    else
        echo "Container not found: $container"
    fi

done

# Remove networks
for network in "${NETWORKS[@]}"; do

    if docker network inspect "$network" >/dev/null 2>&1; then
        echo "Removing network: $network"

        docker network rm "$network" || {
            echo "WARNING: Could not remove $network."
        }
    fi

done

echo
echo "======================================"
echo " Linkly Stack Stopped"
echo "======================================"

echo "Persistent volumes have been preserved:"
docker volume ls --format '{{.Name}}' |
    grep -E '^(pgdata|redisdata|reports)$' || true

echo
echo "To start again, run:"
echo "./scripts/up.sh"
