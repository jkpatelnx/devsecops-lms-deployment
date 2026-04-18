#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_ROOT="/opt/lms-backups"
TIMESTAMP="$(date +%F_%H-%M-%S)"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"

mkdir -p "$BACKUP_DIR"

echo "Starting backup..."
echo "Backup folder: $BACKUP_DIR"

cd "$PROJECT_DIR"

# 1) Database dump from lms-db container
docker compose exec -T lms-db sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' > "$BACKUP_DIR/mariadb.sql"
gzip "$BACKUP_DIR/mariadb.sql"

# 2) Backup important named volumes
for vol in lms-db-volume lms-moodle-data-volume lms-moodle-code-volume lms-proxy-certs-volume; do
  docker run --rm -v "$vol":/from:ro -v "$BACKUP_DIR":/to alpine:3.20 sh -c "cd /from && tar czf /to/${vol}.tar.gz ."
done

# 3) Backup compose and env files
cp "$PROJECT_DIR/docker-compose.yml" "$BACKUP_DIR/"
if [[ -f "$PROJECT_DIR/.env" ]]; then
  cp "$PROJECT_DIR/.env" "$BACKUP_DIR/.env.backup"
fi

echo "Backup completed successfully."
echo "Saved at: $BACKUP_DIR"
