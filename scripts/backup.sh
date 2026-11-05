#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DB_CONTAINER="linkly-db"
ADMIN_NETWORK="linkly-admin"

SECRET_FILE="$PROJECT_DIR/secrets/db_password.txt"
BACKUP_DIR="$PROJECT_DIR/backups"

DB_NAME="linkly"
DB_USER="linkly"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="linkly_backup_${TIMESTAMP}.sql.gz"

echo "======================================"
echo " Linkly PostgreSQL Backup"
echo "======================================"

# Check database container
if ! docker inspect "$DB_CONTAINER" >/dev/null 2>&1; then
    echo "ERROR: PostgreSQL container is not running."
    exit 1
fi

# Check secret
if [[ ! -s "$SECRET_FILE" ]]; then
    echo "ERROR: Database password file missing or empty."
    exit 1
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILE"

# Ensure PostgreSQL is healthy
DB_STATUS=$(docker inspect \
    --format='{{.State.Health.Status}}' "$DB_CONTAINER")

if [[ "$DB_STATUS" != "healthy" ]]; then
    echo "ERROR: PostgreSQL is not healthy."
    exit 1
fi

echo "Creating PostgreSQL backup..."

# Run temporary backup container
docker run --rm \
    --name "linkly-backup-${TIMESTAMP}" \
    --network "$ADMIN_NETWORK" \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,noexec,nosuid,size=32m \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,source=$SECRET_FILE,target=/run/secrets/db_password,readonly" \
    --mount "type=bind,source=$BACKUP_DIR,target=/backups" \
    --entrypoint sh \
    postgres:16-alpine \
    -ec '
        export PGPASSWORD="$(cat /run/secrets/db_password)"

        pg_dump \
            -h linkly-db \
            -p 5432 \
            -U linkly \
            -d linkly \
            --no-owner \
            --no-acl |
        gzip > "/backups/'"$BACKUP_FILE"'"

        unset PGPASSWORD
    '

# Verify backup
if [[ ! -s "$BACKUP_PATH" ]]; then
    echo "ERROR: Backup file was not created."
    exit 1
fi

echo
echo "======================================"
echo " Backup Completed Successfully"
echo "======================================"

echo "File: $BACKUP_PATH"
echo "Size: $(du -h "$BACKUP_PATH" | cut -f1)"

echo
echo "Verifying gzip archive..."

gzip -t "$BACKUP_PATH"

echo "Backup archive is valid."
