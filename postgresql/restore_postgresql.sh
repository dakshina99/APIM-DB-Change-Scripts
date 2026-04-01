#!/bin/bash

set -euo pipefail

##############################################
# PostgreSQL Dump Restore Script
#
# Imports APIM_DB and Shared DB dump files
# into running PostgreSQL containers.
#
# Supported formats: .sql, .sql.gz, .dump
#   .sql / .sql.gz  -> restored via psql
#   .dump           -> restored via pg_restore (custom format)
#
# Environment variables:
#   APIM_DB_DUMP   - path to apim_db dump file
#   SHARED_DB_DUMP - path to shared_db dump file
#
# Usage:
#   APIM_DB_DUMP=/path/to/apim.sql \
#   SHARED_DB_DUMP=/path/to/shared.sql \
#   ./restore_postgresql.sh [-v]
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
APIM_CONTAINER="apim_db_container_postgres"
SHARED_CONTAINER="shared_db_container_postgres"

##############################################
# Wait for a PostgreSQL container to accept connections
##############################################
wait_for_postgresql() {
    local container_name="$1"
    local db_user="$2"
    local max_attempts=30
    local attempt=1

    log_info "Waiting for PostgreSQL container '$container_name' to be ready..."

    while [ $attempt -le $max_attempts ]; do
        if docker exec "$container_name" pg_isready -U "$db_user" &>/dev/null; then
            log_success "PostgreSQL container '$container_name' is ready."
            return 0
        fi
        log_verbose "  Attempt $attempt/$max_attempts - not ready yet, waiting 2s..."
        sleep 2
        attempt=$((attempt + 1))
    done

    log_error "PostgreSQL container '$container_name' did not become ready after $max_attempts attempts."
    return 1
}

##############################################
# Import a dump file into a PostgreSQL database
##############################################
import_dump() {
    local container_name="$1"
    local database_name="$2"
    local db_user="$3"
    local dump_file="$4"

    if [[ -z "$dump_file" ]]; then
        log_verbose "No dump file specified for $database_name, skipping."
        return 0
    fi

    if [[ ! -f "$dump_file" ]]; then
        log_error "Dump file not found: $dump_file"
        return 1
    fi

    log_info "Importing dump into '$database_name' from: $(basename "$dump_file")"
    log_verbose "  Container: $container_name | User: $db_user"

    if [[ "$dump_file" == *.dump ]]; then
        # pg_dump custom-format file — use pg_restore
        log_verbose "  Detected pg_dump custom format — using pg_restore..."
        local temp_dest="/tmp/pg_restore_$$.dump"
        docker cp "$dump_file" "$container_name:$temp_dest"
        if docker exec "$container_name" pg_restore -U "$db_user" -d "$database_name" --no-owner --no-privileges "$temp_dest"; then
            docker exec "$container_name" rm -f "$temp_dest"
            log_success "Dump imported successfully into '$database_name'."
            return 0
        else
            docker exec "$container_name" rm -f "$temp_dest" 2>/dev/null || true
            log_error "Failed to import dump into '$database_name'."
            return 1
        fi
    elif [[ "$dump_file" == *.gz ]]; then
        log_verbose "  Detected gzip archive — decompressing on the fly..."
        if gunzip -c "$dump_file" | docker exec -i "$container_name" psql -U "$db_user" -d "$database_name"; then
            log_success "Dump imported successfully into '$database_name'."
            return 0
        else
            log_error "Failed to import dump into '$database_name'."
            return 1
        fi
    else
        # Plain SQL file
        if docker exec -i "$container_name" psql -U "$db_user" -d "$database_name" < "$dump_file"; then
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
    log_info "PostgreSQL Dump Restore"
    log_info "======================================"

    if [[ -z "$APIM_DB_DUMP" && -z "$SHARED_DB_DUMP" ]]; then
        log_warning "No dump files provided (APIM_DB_DUMP / SHARED_DB_DUMP). Nothing to restore."
        exit 0
    fi

    [[ -n "$APIM_DB_DUMP" ]]   && log_info "  APIM DB dump:   $APIM_DB_DUMP"
    [[ -n "$SHARED_DB_DUMP" ]] && log_info "  Shared DB dump: $SHARED_DB_DUMP"
    echo

    # Wait for both containers (each uses its own db user as POSTGRES_USER)
    wait_for_postgresql "$APIM_CONTAINER"   "apim_user"
    wait_for_postgresql "$SHARED_CONTAINER" "shared_user"

    local failed=false

    if [[ -n "$APIM_DB_DUMP" ]]; then
        import_dump "$APIM_CONTAINER" "apim_db" "apim_user" "$APIM_DB_DUMP" || failed=true
    fi

    if [[ -n "$SHARED_DB_DUMP" ]]; then
        import_dump "$SHARED_CONTAINER" "shared_db" "shared_user" "$SHARED_DB_DUMP" || failed=true
    fi

    if [[ "$failed" == "true" ]]; then
        log_error "One or more dump restores failed."
        exit 1
    fi

    log_success "PostgreSQL dump restore completed successfully."
}

main "$@"
