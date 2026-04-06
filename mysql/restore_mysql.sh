#!/bin/bash

set -euo pipefail

##############################################
# MySQL Dump Restore Script
#
# Imports APIM_DB and Shared DB dump files
# into running MySQL containers.
#
# Environment variables:
#   APIM_DB_DUMP   - path to apim_db dump file
#   SHARED_DB_DUMP - path to shared_db dump file
#
# Usage:
#   APIM_DB_DUMP=/path/to/apim.sql \
#   SHARED_DB_DUMP=/path/to/shared.sql \
#   ./restore_mysql.sh [-v]
##############################################

VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=true ;;
  esac
done

# Colors for better log visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_verbose() { [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}[INFO]${NC} $1" || true; }

# Dump file paths from environment variables
APIM_DB_DUMP="${APIM_DB_DUMP:-}"
SHARED_DB_DUMP="${SHARED_DB_DUMP:-}"

# Container names (must match docker-compose.yaml)
APIM_CONTAINER="apim_db_container_mysql"
SHARED_CONTAINER="shared_db_container_mysql"

##############################################
# Wait for a MySQL container to accept connections
##############################################
wait_for_mysql() {
    local container_name="$1"
    local max_attempts=30
    local attempt=1

    log_info "Waiting for MySQL container '$container_name' to be ready..."

    while [ $attempt -le $max_attempts ]; do
        if docker exec "$container_name" mysqladmin ping -h localhost -u root -prootpass --silent &>/dev/null; then
            log_success "MySQL container '$container_name' is ready."
            return 0
        fi
        log_verbose "  Attempt $attempt/$max_attempts - not ready yet, waiting 2s..."
        sleep 2
        attempt=$((attempt + 1))
    done

    log_error "MySQL container '$container_name' did not become ready after $max_attempts attempts."
    return 1
}

##############################################
# Import a dump file into a MySQL database
# Uses root for full privileges (DROP/CREATE/ALTER)
##############################################
import_dump() {
    local container_name="$1"
    local database_name="$2"
    local dump_file="$3"
    local root_user="root"
    local root_pass="rootpass"

    if [[ -z "$dump_file" ]]; then
        log_verbose "No dump file specified for $database_name, skipping."
        return 0
    fi

    if [[ ! -f "$dump_file" ]]; then
        log_error "Dump file not found: $dump_file"
        return 1
    fi

    log_info "Dropping and recreating '$database_name' before restore..."
    docker exec "$container_name" mysql -h 127.0.0.1 -u "$root_user" -p"$root_pass" \
        -e "DROP DATABASE IF EXISTS \`${database_name}\`; CREATE DATABASE \`${database_name}\`;"
    log_verbose "  Database '$database_name' recreated."

    log_info "Importing dump into '$database_name' from: $(basename "$dump_file")"
    log_verbose "  Container: $container_name | Credentials: $root_user"

    if [[ "$dump_file" == *.gz ]]; then
        log_verbose "  Detected gzip archive — decompressing on the fly..."
        if gunzip -c "$dump_file" | docker exec -i "$container_name" mysql -h 127.0.0.1 -u "$root_user" -p"$root_pass" "$database_name"; then
            log_success "Dump imported successfully into '$database_name'."
            return 0
        else
            log_error "Failed to import dump into '$database_name'."
            return 1
        fi
    else
        if docker exec -i "$container_name" mysql -h 127.0.0.1 -u "$root_user" -p"$root_pass" "$database_name" < "$dump_file"; then
            log_success "Dump imported successfully into '$database_name'."
            return 0
        else
            log_error "Failed to import dump into '$database_name'."
            return 1
        fi
    fi
}

##############################################
# Main
##############################################
main() {
    log_info "======================================"
    log_info "MySQL Dump Restore"
    log_info "======================================"

    # If dumps were loaded via Docker entrypoint (mounted into
    # /docker-entrypoint-initdb.d/), skip external restore.
    ENTRYPOINT_MARKER=".mysql-dump-via-entrypoint"
    if [[ -f "$ENTRYPOINT_MARKER" ]]; then
        log_info "Database dumps were loaded via Docker entrypoint initialization."
        log_info "Skipping external restore — databases are already populated."
        rm -f "$ENTRYPOINT_MARKER"
        exit 0
    fi

    if [[ -z "$APIM_DB_DUMP" && -z "$SHARED_DB_DUMP" ]]; then
        log_warning "No dump files provided (APIM_DB_DUMP / SHARED_DB_DUMP). Nothing to restore."
        exit 0
    fi

    [[ -n "$APIM_DB_DUMP" ]]   && log_info "  APIM DB dump:   $APIM_DB_DUMP"
    [[ -n "$SHARED_DB_DUMP" ]] && log_info "  Shared DB dump: $SHARED_DB_DUMP"
    echo

    # Wait for both containers to be accepting connections
    wait_for_mysql "$APIM_CONTAINER"
    wait_for_mysql "$SHARED_CONTAINER"

    local failed=false

    if [[ -n "$APIM_DB_DUMP" ]]; then
        import_dump "$APIM_CONTAINER" "apim_db" "$APIM_DB_DUMP" || failed=true
    fi

    if [[ -n "$SHARED_DB_DUMP" ]]; then
        import_dump "$SHARED_CONTAINER" "shared_db" "$SHARED_DB_DUMP" || failed=true
    fi

    if [[ "$failed" == "true" ]]; then
        log_error "One or more dump restores failed."
        exit 1
    fi

    log_success "MySQL dump restore completed successfully."
}

main "$@"
