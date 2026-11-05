#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# Configuration
API_IMAGE="linkly-api:latest"
WORKER_IMAGE="linkly-worker:latest"

DB_CONTAINER="linkly-db"
CACHE_CONTAINER="linkly-cache"
API_CONTAINER="linkly-api"
WORKER_CONTAINER="linkly-worker"
PROXY_CONTAINER="linkly-proxy"

DMZ_NETWORK="linkly-dmz"
INTERNAL_NETWORK="linkly-internal"
ADMIN_NETWORK="linkly-admin"

DB_VOLUME="pgdata"
REDIS_VOLUME="redisdata"
REPORTS_VOLUME="reports"

SECRET_FILE="$PROJECT_DIR/secrets/db_password.txt"

echo "======================================"
echo " Starting Linkly Docker Stack"
echo "======================================"

# Check Docker access
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Cannot access Docker daemon."
    echo "Try running with sudo."
    exit 1
fi

# Check required files
for file in \
    api/Dockerfile \
    api/requirements.txt \
    api/app.py \
    api/healthcheck.py \
    worker/Dockerfile \
    worker/requirements.txt \
    worker/worker.py \
    worker/healthcheck.py \
    proxy/default.conf
do
    if [[ ! -f "$file" ]]; then
        echo "ERROR: Required file missing: $file"
        exit 1
    fi
done

# Create database secret if missing
if [[ ! -f "$SECRET_FILE" ]]; then
    mkdir -p secrets
    chmod 700 secrets

    echo "Generating database password..."
    openssl rand -hex 32 > "$SECRET_FILE"
    chmod 444 "$SECRET_FILE"
fi

# Validate secret
if [[ ! -s "$SECRET_FILE" ]]; then
    echo "ERROR: Database password file is empty."
    exit 1
fi

# Build images
echo "Building API image..."
docker build -t "$API_IMAGE" ./api

echo "Building Worker image..."
docker build -t "$WORKER_IMAGE" ./worker

# Create networks
echo "Creating Docker networks..."

docker network inspect "$DMZ_NETWORK" >/dev/null 2>&1 ||
docker network create \
    --driver bridge \
    --subnet 172.30.1.0/24 \
    "$DMZ_NETWORK"

docker network inspect "$INTERNAL_NETWORK" >/dev/null 2>&1 ||
docker network create \
    --driver bridge \
    --internal \
    --subnet 172.30.2.0/24 \
    "$INTERNAL_NETWORK"

docker network inspect "$ADMIN_NETWORK" >/dev/null 2>&1 ||
docker network create \
    --driver bridge \
    --internal \
    --subnet 172.30.3.0/24 \
    "$ADMIN_NETWORK"

# Create persistent volumes
echo "Creating Docker volumes..."

docker volume create "$DB_VOLUME" >/dev/null
docker volume create "$REDIS_VOLUME" >/dev/null
docker volume create "$REPORTS_VOLUME" >/dev/null

# Remove old containers if present
for container in \
    "$PROXY_CONTAINER" \
    "$WORKER_CONTAINER" \
    "$API_CONTAINER" \
    "$CACHE_CONTAINER" \
    "$DB_CONTAINER"
do
    docker rm -f "$container" >/dev/null 2>&1 || true
done

COMMON_SECURITY=(
    --cap-drop ALL
    --security-opt no-new-privileges:true
    --read-only
)

# Start PostgreSQL
echo "Starting PostgreSQL..."

docker run -d \
    --name "$DB_CONTAINER" \
    --network "$INTERNAL_NETWORK" \
    --restart unless-stopped \
    "${COMMON_SECURITY[@]}" \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    --tmpfs /var/run/postgresql:rw,noexec,nosuid,size=16m \
    --mount "type=volume,source=$DB_VOLUME,target=/var/lib/postgresql/data" \
    --mount "type=bind,source=$SECRET_FILE,target=/run/secrets/db_password,readonly" \
    -e POSTGRES_DB=linkly \
    -e POSTGRES_USER=linkly \
    -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password \
    --health-cmd="pg_isready -U linkly -d linkly" \
    --health-interval=10s \
    --health-timeout=5s \
    --health-retries=5 \
    postgres:16-alpine

# Attach PostgreSQL to admin network
docker network connect "$ADMIN_NETWORK" "$DB_CONTAINER"

# Wait for PostgreSQL
echo "Waiting for PostgreSQL..."

for i in {1..30}; do
    STATUS=$(docker inspect \
        --format='{{.State.Health.Status}}' "$DB_CONTAINER")

    if [[ "$STATUS" == "healthy" ]]; then
        echo "PostgreSQL is healthy."
        break
    fi

    if [[ "$i" -eq 30 ]]; then
        echo "ERROR: PostgreSQL did not become healthy."
        docker logs "$DB_CONTAINER"
        exit 1
    fi

    sleep 2
done

# Start Redis
echo "Starting Redis..."

docker run -d \
    --name "$CACHE_CONTAINER" \
    --network "$INTERNAL_NETWORK" \
    --restart unless-stopped \
    "${COMMON_SECURITY[@]}" \
    --tmpfs /tmp:rw,noexec,nosuid,size=32m \
    --mount "type=volume,source=$REDIS_VOLUME,target=/data" \
    redis:7.4-alpine \
    redis-server --appendonly yes --appendfsync everysec

# Wait for Redis
echo "Waiting for Redis..."

for i in {1..20}; do
    if docker exec "$CACHE_CONTAINER" redis-cli ping 2>/dev/null |
        grep -q PONG; then
        echo "Redis is ready."
        break
    fi

    if [[ "$i" -eq 20 ]]; then
        echo "ERROR: Redis did not become ready."
        docker logs "$CACHE_CONTAINER"
        exit 1
    fi

    sleep 2
done

# Start API
echo "Starting API..."

docker run -d \
    --name "$API_CONTAINER" \
    --network "$DMZ_NETWORK" \
    --restart unless-stopped \
    "${COMMON_SECURITY[@]}" \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    -e DB_HOST="$DB_CONTAINER" \
    -e DB_PORT=5432 \
    -e DB_NAME=linkly \
    -e DB_USER=linkly \
    -e DB_PASSWORD_FILE=/run/secrets/db_password \
    -e REDIS_HOST="$CACHE_CONTAINER" \
    -e REDIS_PORT=6379 \
    --mount "type=bind,source=$SECRET_FILE,target=/run/secrets/db_password,readonly" \
    "$API_IMAGE"

# Connect API to internal network
docker network connect "$INTERNAL_NETWORK" "$API_CONTAINER"

# Wait for API
echo "Waiting for API..."

for i in {1..30}; do
    STATUS=$(docker inspect \
        --format='{{.State.Health.Status}}' "$API_CONTAINER")

    if [[ "$STATUS" == "healthy" ]]; then
        echo "API is healthy."
        break
    fi

    if [[ "$i" -eq 30 ]]; then
        echo "ERROR: API did not become healthy."
        docker logs "$API_CONTAINER"
        exit 1
    fi

    sleep 2
done

# Start Worker
echo "Starting Worker..."

docker run -d \
    --name "$WORKER_CONTAINER" \
    --network "$INTERNAL_NETWORK" \
    --restart unless-stopped \
    "${COMMON_SECURITY[@]}" \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    --mount "type=volume,source=$REPORTS_VOLUME,target=/reports" \
    --mount "type=bind,source=$SECRET_FILE,target=/run/secrets/db_password,readonly" \
    -e DB_HOST="$DB_CONTAINER" \
    -e DB_PORT=5432 \
    -e DB_NAME=linkly \
    -e DB_USER=linkly \
    -e DB_PASSWORD_FILE=/run/secrets/db_password \
    -e REDIS_HOST="$CACHE_CONTAINER" \
    -e REDIS_PORT=6379 \
    -e REPORT_DIR=/reports \
    "$WORKER_IMAGE"

# Start Nginx reverse proxy
echo "Starting Nginx proxy..."

docker run -d \
    --name "$PROXY_CONTAINER" \
    --network "$DMZ_NETWORK" \
    --restart unless-stopped \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    --tmpfs /var/cache/nginx:rw,noexec,nosuid,size=64m \
    --tmpfs /var/run:rw,noexec,nosuid,size=16m \
    -p 80:8080 \
    -p 443:8443 \
    --mount "type=bind,source=$PROJECT_DIR/proxy/default.conf,target=/etc/nginx/conf.d/default.conf,readonly" \
    nginxinc/nginx-unprivileged:1.27-alpine

echo
echo "======================================"
echo " Linkly Stack Started"
echo "======================================"

docker ps

echo
echo "API:     http://localhost"
echo "HTTPS:   https://localhost"
echo
echo "Run ./scripts/netcheck.sh to test network segmentation."
