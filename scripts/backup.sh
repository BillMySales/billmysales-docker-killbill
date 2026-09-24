#!/bin/bash
# Backups of the Kill Bill and Kaui databases and Kaui's encryption key.
#
#   backup.sh            # loop: back up now, then every BACKUP_INTERVAL_HOURS
#   backup.sh now        # one backup
#   backup.sh list       # list backups
#   backup.sh restore <timestamp>   # restore both databases and the key
#   backup.sh health     # healthcheck: last backup is recent enough
#
# Files: /backups/<timestamp>-killbill.sql.gz, <timestamp>-kaui.sql.gz and
# <timestamp>-kaui-config.tar.gz, deleted after BACKUP_KEEP_DAYS days.
set -euo pipefail
# Backups contain password hashes, API secrets and customer data.
umask 077

BACKUP_DIR=/backups
KAUI_CONFIG=/kaui-config

# Credentials in a temp file, not on the command line.
DB_CNF="$(mktemp)"
trap 'rm -f "${DB_CNF}"' EXIT
cat > "${DB_CNF}" <<CNF
[client]
host=${DB_HOST}
port=${DB_PORT}
user=${DB_USER}
password=${DB_PASSWORD}
CNF

backup() {
    local ts tmp db
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    echo "==> Backup ${ts}"
    tmp="${BACKUP_DIR}/.${ts}"
    for db in killbill kaui; do
        mariadb-dump --defaults-extra-file="${DB_CNF}" --single-transaction --quick \
            --routines --triggers --events "${db}" | gzip > "${tmp}-${db}.sql.gz"
    done
    tar -C "${KAUI_CONFIG}" -czf "${tmp}-kaui-config.tar.gz" .
    for f in killbill.sql.gz kaui.sql.gz kaui-config.tar.gz; do
        mv "${tmp}-${f}" "${BACKUP_DIR}/${ts}-${f}"
    done
    find "${BACKUP_DIR}" -maxdepth 1 \( -name '*-killbill.sql.gz' -o -name '*-kaui.sql.gz' \
        -o -name '*-kaui-config.tar.gz' \) -mtime +"${BACKUP_KEEP_DAYS}" -delete
    ls -lh "${BACKUP_DIR}/${ts}"-*
}

restore() {
    local ts="${1:?Usage: backup.sh restore <timestamp> (see: backup.sh list)}" db f
    for f in killbill.sql.gz kaui.sql.gz kaui-config.tar.gz; do
        [ -f "${BACKUP_DIR}/${ts}-${f}" ] || { echo "Backup ${ts} not found (${f})" >&2; exit 1; }
    done
    for db in killbill kaui; do
        echo "==> Restoring database ${db}"
        # Drop the tables first: nothing created after the backup remains.
        mariadb --defaults-extra-file="${DB_CNF}" --batch --skip-column-names -e \
            "SELECT CONCAT('DROP TABLE IF EXISTS \`', table_name, '\`;') FROM information_schema.tables WHERE table_schema = '${db}'" |
            { echo 'SET FOREIGN_KEY_CHECKS = 0;'; cat; } | mariadb --defaults-extra-file="${DB_CNF}" "${db}"
        gunzip -c "${BACKUP_DIR}/${ts}-${db}.sql.gz" | mariadb --defaults-extra-file="${DB_CNF}" "${db}"
    done
    echo "==> Restoring Kaui's encryption key"
    find "${KAUI_CONFIG}" -mindepth 1 -delete
    tar -C "${KAUI_CONFIG}" -xzpf "${BACKUP_DIR}/${ts}-kaui-config.tar.gz"
    echo "==> Restored ${ts}"
}

case "${1:-loop}" in
    now) backup ;;
    list) find "${BACKUP_DIR}" -maxdepth 1 -name '*-killbill.sql.gz' -printf '%f\n' | sed 's/-killbill\.sql\.gz$//' | sort ;;
    restore) restore "${2:-}" ;;
    health)
        [ -n "$(find "${BACKUP_DIR}" -maxdepth 1 -name '*-killbill.sql.gz' \
            -mmin -$(( BACKUP_INTERVAL_HOURS * 60 + 60 )) 2>/dev/null)" ]
        ;;
    loop)
        while :; do
            backup || echo "Backup failed" >&2
            sleep $(( BACKUP_INTERVAL_HOURS * 3600 ))
        done
        ;;
    *) echo "Unknown command: $1" >&2; exit 2 ;;
esac
