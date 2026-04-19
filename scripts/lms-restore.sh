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

echo "============================================================"
echo "  LMS RESTORE"
echo "  Backup folder : $BACKUP_DIR"
echo "  Project dir   : $PROJECT_DIR"
echo "============================================================"
echo ""
echo "What will be restored:"
echo "  [1] .env file (credentials & domain)"
echo "  [2] lms-moodle-data-volume  (moodle uploads, logos, cache)"
echo "  [3] lms-moodle-code-volume  (moodle PHP code + config.php)"
echo "  [4] lms-proxy-certs-volume  (nginx TLS certificates)"
echo "  [5] Database                (from mariadb.sql.gz SQL dump)"
echo ""
echo "  NOTE: lms-db-volume raw tar is intentionally SKIPPED."
echo "  MariaDB raw data files are NOT safe to restore across"
echo "  hosts/versions. The SQL dump (mariadb.sql.gz) is the"
echo "  correct and reliable way to restore the database."
echo "============================================================"
echo ""

cd "$PROJECT_DIR"

####################################################################
# Detect docker compose project name.
#
# CRITICAL: Docker Compose prefixes every named volume with the
# project name.  For example, if your project directory is
# "devsecops-lms-deployment", the actual Docker volume name is:
#   devsecops-lms-deployment_lms-moodle-data-volume
#
# Using a bare name like "lms-moodle-data-volume" in docker run
# creates/mounts a COMPLETELY DIFFERENT empty volume — NOT the one
# that docker compose uses.  This was the root cause of logos and
# uploaded files not appearing after restore.
####################################################################
COMPOSE_PROJECT=$(docker compose config 2>/dev/null | awk '/^name:/{print $2; exit}')
if [[ -z "$COMPOSE_PROJECT" ]]; then
  echo "ERROR: Could not detect docker compose project name."
  echo "       Make sure docker compose is installed and you are"
  echo "       running this script from the correct project directory."
  exit 1
fi
echo "Compose project name: $COMPOSE_PROJECT"
echo ""

####################################################################
# 1. Restore .env
####################################################################
if [[ -f "$BACKUP_DIR/.env.backup" ]]; then
  cp "$BACKUP_DIR/.env.backup" "$PROJECT_DIR/.env"
  echo "[1/5] Restored .env from backup"
else
  echo "[1/5] No .env.backup found — using existing .env"
fi

####################################################################
# 2. Ensure all services and volumes are created, then stop
#    app+proxy so we can safely restore their volumes.
#    Keep lms-db running so we can restore the SQL dump later.
####################################################################
echo ""
echo "[2/5] Starting containers to create volumes..."
docker compose up -d lms-db lms-web lms-proxy
docker compose stop lms-web lms-proxy
echo "  lms-web and lms-proxy stopped. lms-db still running."

####################################################################
# 3. Restore file volumes (data, code, certs)
#
#    Uses FULL prefixed volume names so data goes into the correct
#    volumes that docker compose actually uses.
#
#    lms-db-volume is intentionally NOT restored via tar.
#    The database is restored via SQL dump in step 5.
####################################################################
echo ""
echo "[3/5] Restoring file volumes..."

for vol in lms-moodle-data-volume lms-moodle-code-volume lms-proxy-certs-volume; do
  full_vol="${COMPOSE_PROJECT}_${vol}"
  tar_file="$BACKUP_DIR/${vol}.tar.gz"

  if [[ ! -f "$tar_file" ]]; then
    echo "  WARN: Missing backup archive: $tar_file — skipping $vol"
    continue
  fi

  if ! docker volume inspect "$full_vol" > /dev/null 2>&1; then
    echo "  WARN: Volume not found: $full_vol — skipping"
    continue
  fi

  docker run --rm \
    -v "${full_vol}":/to \
    -v "$BACKUP_DIR":/from \
    alpine:3.20 \
    sh -c "cd /to && tar xzf /from/${vol}.tar.gz"

  echo "  [OK] Extracted: ${vol}.tar.gz -> $full_vol"
done

####################################################################
# 4. Fix ownership & permissions on the real compose volumes.
#
#    Why needed:
#      tar inside alpine runs as root (UID 0). Files may land with
#      UID 0 ownership. nginx and php-fpm run as www-data (UID 33).
#      If www-data can't read the files, Moodle reports:
#        "Cannot read file... permission problem"
#      for logos, favicons, and any uploaded content.
#
#    Code volume  : dirs=755, files=644  (www-data reads, never writes)
#    Data volume  : dirs=700, files=600  (private to www-data only)
####################################################################
echo ""
echo "[4/5] Fixing ownership and permissions..."

echo "  moodle-code-volume -> www-data:www-data | dirs=755 files=644"
docker run --rm \
  -v "${COMPOSE_PROJECT}_lms-moodle-code-volume":/target \
  alpine:3.20 \
  sh -c "chown -R 33:33 /target \
      && find /target -type d -exec chmod 755 {} \; \
      && find /target -type f -exec chmod 644 {} \;"

echo "  moodle-data-volume -> www-data:www-data | dirs=700 files=600"
docker run --rm \
  -v "${COMPOSE_PROJECT}_lms-moodle-data-volume":/target \
  alpine:3.20 \
  sh -c "chown -R 33:33 /target \
      && find /target -type d -exec chmod 700 {} \; \
      && find /target -type f -exec chmod 600 {} \;"

echo "  [OK] Permissions repaired."

####################################################################
# 5. Restore database from SQL dump.
####################################################################
echo ""
echo "[5/5] Restoring database..."
if [[ -f "$BACKUP_DIR/mariadb.sql.gz" ]]; then
  gunzip -c "$BACKUP_DIR/mariadb.sql.gz" \
    | docker compose exec -T lms-db \
        sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'
  echo "  [OK] Database restored from mariadb.sql.gz"
elif [[ -f "$BACKUP_DIR/mariadb.sql" ]]; then
  docker compose exec -T lms-db \
    sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' \
    < "$BACKUP_DIR/mariadb.sql"
  echo "  [OK] Database restored from mariadb.sql"
else
  echo "  ERROR: No database dump found (mariadb.sql.gz or mariadb.sql)"
  exit 1
fi

####################################################################
# 6. Start all services.
####################################################################
echo ""
echo "Starting all services..."
docker compose up -d

echo ""
echo "============================================================"
echo "  Restore completed successfully!"
echo ""
echo "  Volumes restored :"
echo "    devsecops-lms-deployment_lms-moodle-data-volume"
echo "    devsecops-lms-deployment_lms-moodle-code-volume"
echo "    devsecops-lms-deployment_lms-proxy-certs-volume"
echo "  Database restored  : YES (via SQL dump)"
echo "  lms-db-volume      : Managed by MariaDB (raw tar skipped)"
echo "  Permissions fixed  : YES (chown www-data, correct chmod)"
echo "============================================================"
