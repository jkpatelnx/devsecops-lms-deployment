#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <backup_dir>"
  echo "Example: $0 /opt/lms-backups/2026-04-18_09-52-15"
  exit 1
fi

BACKUP_DIR="$1"

if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "ERROR: Backup folder not found: $BACKUP_DIR"
  exit 1
fi

if [[ ! -f "$PROJECT_DIR/docker-compose.yml" ]]; then
  echo "ERROR: docker-compose.yml not found in project: $PROJECT_DIR"
  exit 1
fi

echo "Starting restore..."
echo "Backup folder: $BACKUP_DIR"

cd "$PROJECT_DIR"


# If backup contains env, restore it for DB credentials/domain settings.
if [[ -f "$BACKUP_DIR/.env.backup" ]]; then
  cp "$BACKUP_DIR/.env.backup" "$PROJECT_DIR/.env"
  echo "Restored .env from backup"
fi

####################################################################
# Ensure services/volumes are created.
####################################################################

docker compose up -d lms-db lms-web lms-proxy

# Stop app/proxy while restoring file volumes.
docker compose stop lms-web lms-proxy

####################################################################
# Restore named volumes archived by lms-backup.sh.
####################################################################

for vol in lms-moodle-data-volume lms-moodle-code-volume lms-proxy-certs-volume; do
  tar_file="$BACKUP_DIR/${vol}.tar.gz"
  if [[ -f "$tar_file" ]]; then
    docker run --rm -v "$vol":/to -v "$BACKUP_DIR":/from alpine:3.20 sh -c "cd /to && tar xzf /from/${vol}.tar.gz"
    echo "Restored volume: $vol"
  else
    echo "WARN: Missing volume backup: $tar_file"
  fi
done

# Restore DB from SQL dump.
if [[ -f "$BACKUP_DIR/mariadb.sql.gz" ]]; then
  gunzip -c "$BACKUP_DIR/mariadb.sql.gz" | docker compose exec -T lms-db sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'
  echo "Restored database from mariadb.sql.gz"
elif [[ -f "$BACKUP_DIR/mariadb.sql" ]]; then
  docker compose exec -T lms-db sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' < "$BACKUP_DIR/mariadb.sql"
  echo "Restored database from mariadb.sql"
else
  echo "ERROR: No database dump found (mariadb.sql.gz or mariadb.sql)"
  exit 1
fi

# Start all services.
docker compose up -d

echo "Restore completed successfully."
