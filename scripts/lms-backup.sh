#!/usr/bin/env bash

set -euo pipefail

if [ -f /home/ubuntu/.env ]; then
  set -a
  source /home/ubuntu/.env
  set +a
else
  echo "Warning: .env file not found, using defaults"
fi


#CRON_JOB='*/5 * * * * /home/ubuntu/devsecops-lms-deployment/scripts/lms-backup.sh >> /home/ubuntu/backup.log 2>&1'
CRON_JOB='*/5 * * * * /home/ubuntu/devsecops-lms-deployment/scripts/lms-backup.sh'
if sudo crontab -l 2>/dev/null | grep -Fq "/home/ubuntu/devsecops-lms-deployment/scripts/lms-backup.sh"; then
  echo "Cron job already exists, skipping..."
else
  echo "Adding cron job..."
  (sudo crontab -l 2>/dev/null; echo "$CRON_JOB") | sudo crontab -
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_ROOT="/opt/lms-backups"
TIMESTAMP="$(date +%F_%H-%M-%S)"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"

# Optional S3 settings
# Set S3_BUCKET to enable upload
# Example:
#   export S3_BUCKET=lms-backup-jitendra-prod-2026
#   export S3_PREFIX=lms
#   export S3_KEEP_LAST=3
#   export LOCAL_KEEP_LAST=3
#   sudo -E ./scripts/lms-backup.sh
S3_BUCKET="${S3_BUCKET:-lms-backup-jitendra-prod-2026}"
S3_PREFIX="${S3_PREFIX:-lms}"
S3_KEEP_LAST="${S3_KEEP_LAST:-3}"
LOCAL_KEEP_LAST="${LOCAL_KEEP_LAST:-3}"

mkdir -p "$BACKUP_DIR"

echo "Starting backup..."
echo "Backup folder: $BACKUP_DIR"

cd "$PROJECT_DIR"

# Detect the docker compose project name.
# Docker Compose prefixes every volume with this name, e.g.:
#   project = devsecops-lms-deployment
#   actual volume = devsecops-lms-deployment_lms-moodle-data-volume
# Without the prefix, docker run mounts a DIFFERENT (empty) volume!
COMPOSE_PROJECT=$(docker compose config 2>/dev/null | awk '/^name:/{print $2; exit}')
if [[ -z "$COMPOSE_PROJECT" ]]; then
  echo "ERROR: Could not detect docker compose project name."
  echo "       Make sure you are running this script from the project directory."
  exit 1
fi
echo "Compose project name: $COMPOSE_PROJECT"

# 1) Database dump from lms-db container
docker compose exec -T lms-db sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' > "$BACKUP_DIR/mariadb.sql"
gzip "$BACKUP_DIR/mariadb.sql"
echo "  [OK] Database dump: mariadb.sql.gz"

# 2) Backup important named volumes using FULL prefixed volume names.
#    lms-db-volume raw tar is kept as an emergency reference ONLY.
#    Database should always be restored via the SQL dump (mariadb.sql.gz).
for vol in lms-db-volume lms-moodle-data-volume lms-moodle-code-volume lms-proxy-certs-volume; do
  full_vol="${COMPOSE_PROJECT}_${vol}"
  if docker volume inspect "$full_vol" > /dev/null 2>&1; then
    docker run --rm -v "$full_vol":/from:ro -v "$BACKUP_DIR":/to alpine:3.20 \
      sh -c "cd /from && tar czf /to/${vol}.tar.gz ."
    echo "  [OK] Volume backed up: $full_vol -> ${vol}.tar.gz"
  else
    echo "  WARN: Volume not found, skipped: $full_vol"
  fi
done

# 3) Backup compose and env files
cp "$PROJECT_DIR/docker-compose.yml" "$BACKUP_DIR/"
if [[ -f "$PROJECT_DIR/.env" ]]; then
  cp "$PROJECT_DIR/.env" "$BACKUP_DIR/.env.backup"
fi

# 4) Create one archive file for easy upload/restore transfer
ARCHIVE_PATH="$BACKUP_ROOT/lms-backup-${TIMESTAMP}.tar.gz"
tar czf "$ARCHIVE_PATH" -C "$BACKUP_ROOT" "$TIMESTAMP"

# 4b) Keep only the newest N local backups on EC2.
if [[ "$LOCAL_KEEP_LAST" =~ ^[0-9]+$ ]] && [[ "$LOCAL_KEEP_LAST" -gt 0 ]]; then
  CUT_FROM=$((LOCAL_KEEP_LAST + 1))

  # Delete old backup directories and matching archive files.
  while IFS= read -r old_ts; do
    [[ -z "$old_ts" ]] && continue
    rm -rf "${BACKUP_ROOT:?}/${old_ts:?}"
    
    old_archive="$BACKUP_ROOT/lms-backup-${old_ts}.tar.gz"
    if [[ -f "$old_archive" ]]; then
      rm -f "$old_archive"
    fi
    echo "Deleted old local backup: $BACKUP_ROOT/$old_ts"
  done < <(
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*-*-*_*' -printf '%f\n' \
      | sort -r \
      | tail -n +"$CUT_FROM"
  )

  # Delete any extra archives left after directory cleanup.
  while IFS= read -r old_archive_file; do
    [[ -z "$old_archive_file" ]] && continue
    rm -f "$BACKUP_ROOT/$old_archive_file"
    echo "Deleted extra local archive: $BACKUP_ROOT/$old_archive_file"
  done < <(
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type f -name 'lms-backup-*.tar.gz' -printf '%f\n' \
      | sort -r \
      | tail -n +"$CUT_FROM"
  )
else
  echo "WARN: LOCAL_KEEP_LAST must be a positive integer. Skipped local retention cleanup."
fi

# 5) Optional upload to AWS S3
if [[ -n "$S3_BUCKET" ]]; then
  if command -v aws >/dev/null 2>&1; then
    aws s3 cp "$ARCHIVE_PATH" "s3://$S3_BUCKET/$S3_PREFIX/"
    echo "Uploaded to s3://$S3_BUCKET/$S3_PREFIX/$(basename "$ARCHIVE_PATH")"

    # Keep only the newest N backup archives in S3 for this prefix.
    if [[ "$S3_KEEP_LAST" =~ ^[0-9]+$ ]] && [[ "$S3_KEEP_LAST" -gt 0 ]]; then
      mapfile -t S3_OBJECT_KEYS < <(
        aws s3api list-objects-v2 \
          --bucket "$S3_BUCKET" \
          --prefix "$S3_PREFIX/lms-backup-" \
          --query 'reverse(sort_by(Contents,&LastModified))[].Key' \
          --output text | tr '\t' '\n' | sed '/^$/d' | sed '/^None$/d'
      )

      if [[ "${#S3_OBJECT_KEYS[@]}" -gt "$S3_KEEP_LAST" ]]; then
        for ((i=S3_KEEP_LAST; i<${#S3_OBJECT_KEYS[@]}; i++)); do
          aws s3api delete-object --bucket "$S3_BUCKET" --key "${S3_OBJECT_KEYS[$i]}" >/dev/null
          echo "Deleted old S3 backup: s3://$S3_BUCKET/${S3_OBJECT_KEYS[$i]}"
        done
      fi
    else
      echo "WARN: S3_KEEP_LAST must be a positive integer. Skipped S3 retention cleanup."
    fi
  else
    echo "WARN: aws CLI not found. Skipped S3 upload."
  fi
else
  echo "S3_BUCKET not set. Skipped S3 upload."
fi

echo "Backup completed successfully."
echo "Saved at: $BACKUP_DIR"
echo "Archive: $ARCHIVE_PATH"
