#!/bin/bash
# Creates or upgrades the Kill Bill database schema. Runs in the Kill Bill
# image (so the schema always matches that version) before Kill Bill starts,
# on every `docker compose up`, and is safe to repeat:
# - Databases `killbill` and `kaui`, and the stack's user on both.
# - Empty `killbill` database: loads the DDL of every Kill Bill module (the
#   ddl.sql files inside the webapp's jars) and records all their migrations
#   as applied.
# - Otherwise: applies the migrations of the new version not applied yet (the
#   modules' Flyway-style `migration/V<version>__<name>.sql` files, in version
#   order) and records them in `docker_stack_migrations`.
# No internet needed (the official tooling downloads migrations from GitHub).
set -euo pipefail

LIB=/var/lib/tomcat/webapps/ROOT/WEB-INF/lib
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Credentials in a file, not on the command line.
cat > "${WORK}/root.cnf" <<CNF
[client]
host=${DB_HOST}
port=${DB_PORT}
user=root
password=${DB_ROOT_PASSWORD}
CNF
sql() { mysql --defaults-extra-file="${WORK}/root.cnf" --batch --skip-column-names "$@"; }
sql_quote() { printf "'%s'" "${1//\'/\'\'}"; }

for _ in $(seq 60); do
    sql -e 'SELECT 1' > /dev/null 2>&1 && break
    sleep 2
done
sql -e 'SELECT 1' > /dev/null

echo "==> Databases and user"
sql <<SQL
CREATE DATABASE IF NOT EXISTS killbill;
CREATE DATABASE IF NOT EXISTS kaui;
CREATE USER IF NOT EXISTS $(sql_quote "${DB_USER}")@'%' IDENTIFIED BY $(sql_quote "${DB_PASSWORD}");
GRANT ALL PRIVILEGES ON killbill.* TO $(sql_quote "${DB_USER}")@'%';
GRANT ALL PRIVILEGES ON kaui.* TO $(sql_quote "${DB_USER}")@'%';
CREATE TABLE IF NOT EXISTS killbill.docker_stack_migrations (
    version varchar(32) NOT NULL PRIMARY KEY,
    script varchar(255) NOT NULL,
    applied_at datetime NOT NULL
);
SQL

# Every migration of this version: "<version> <jar> <path>", sorted by version.
# Most are in org/killbill/billing/<module>/migration/, some at the jar's root
# (migration/, e.g. killbill-util's).
for jar in "${LIB}"/killbill-*-"${KILLBILL_VERSION}".jar; do
    unzip -Z1 "${jar}" | grep -E '^(org/killbill/billing/[a-z]+/)?migration/V[0-9]+__.+\.sql$' |
        sed -E "s#^(.*/V([0-9]+)__.*)\$#\\2 ${jar} \\1#" || true
done | sort -n > "${WORK}/migrations"

tables="$(sql -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'killbill' AND table_name <> 'docker_stack_migrations'")"
if [ "${tables}" = 0 ]; then
    echo "==> Creating the Kill Bill ${KILLBILL_VERSION} schema"
    for jar in "${LIB}"/killbill-*-"${KILLBILL_VERSION}".jar; do
        for ddl in $(unzip -Z1 "${jar}" | grep -E '^org/killbill/billing/[a-z]+/ddl\.sql$'); do
            unzip -p "${jar}" "${ddl}"
            # The files don't end with a newline.
            echo
        done
    done > "${WORK}/ddl.sql"
    sql killbill < "${WORK}/ddl.sql"
    # The DDL is the current schema: its migrations are already in it.
    while read -r version _ path; do
        echo "INSERT IGNORE INTO docker_stack_migrations VALUES ('${version}', '${path##*/}', NOW());"
    done < "${WORK}/migrations" | sql killbill
else
    applied="$(sql killbill -e 'SELECT version FROM docker_stack_migrations')"
    if [ -z "${applied}" ]; then
        # A database from elsewhere (e.g. imported): which migrations it has is
        # unknown. MIGRATE_BASELINE=1 marks this version's as applied.
        if [ "${MIGRATE_BASELINE:-}" != 1 ]; then
            echo "The killbill database has tables but no docker_stack_migrations records." >&2
            echo "If its schema is Kill Bill ${KILLBILL_VERSION}, run once with MIGRATE_BASELINE=1:" >&2
            echo "  MIGRATE_BASELINE=1 docker compose run --rm migrate" >&2
            exit 1
        fi
        echo "==> Baseline: marking the ${KILLBILL_VERSION} migrations as applied"
        while read -r version _ path; do
            echo "INSERT IGNORE INTO docker_stack_migrations VALUES ('${version}', '${path##*/}', NOW());"
        done < "${WORK}/migrations" | sql killbill
        applied="$(sql killbill -e 'SELECT version FROM docker_stack_migrations')"
    fi
    pending=0
    while read -r version jar path; do
        if ! grep -qx "${version}" <<< "${applied}"; then
            echo "==> Migration ${path##*/}"
            unzip -p "${jar}" "${path}" | sql killbill
            sql killbill -e "INSERT INTO docker_stack_migrations VALUES ('${version}', '${path##*/}', NOW())"
            pending=$((pending + 1))
        fi
    done < "${WORK}/migrations"
    echo "==> Schema up to date (${pending} migrations applied)"
fi
# Plugins baked into the image (image/Dockerfile) with a ddl.sql of their own:
# loaded once, when none of its tables exist (the files start with DROP TABLE).
BUNDLES="${KB_org_killbill_osgi_bundle_install_dir:-/var/lib/killbill/bundles}"
# SET_DEFAULT links to the plugin's active version. (No `grep -q` after unzip:
# it closes the pipe early and pipefail turns that into a failure.)
for jar in "${BUNDLES}"/plugins/java/*/SET_DEFAULT/*.jar; do
    [ -f "${jar}" ] || continue
    unzip -Z1 "${jar}" | grep -x 'ddl.sql' > /dev/null || continue
    plugin="$(basename "$(dirname "$(dirname "${jar}")")")"
    unzip -p "${jar}" ddl.sql > "${WORK}/plugin.sql"
    missing=0 present=0
    grep -oiE 'CREATE TABLE [a-z0-9_]+' "${WORK}/plugin.sql" | awk '{print tolower($3)}' | sort -u > "${WORK}/tables"
    while read -r table; do
        if [ "$(sql -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'killbill' AND table_name = '${table}'")" = 1 ]; then
            present=$((present + 1))
        else
            missing=$((missing + 1))
        fi
    done < "${WORK}/tables"
    if [ "${present}" = 0 ] && [ "${missing}" -gt 0 ]; then
        echo "==> Plugin schema: ${plugin}"
        sql killbill < "${WORK}/plugin.sql"
    elif [ "${missing}" -gt 0 ]; then
        echo "WARNING: ${plugin}: ${missing} of its tables are missing (not creating them over existing ones)." >&2
    fi
done
echo "==> Done: Kill Bill ${KILLBILL_VERSION} schema"
