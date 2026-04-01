#!/bin/bash

set -euo pipefail

##############################################
# MSSQL Dump Restore Script
#
# Imports APIM_DB and Shared DB SQL files
# into running MSSQL containers.
#
# Supported formats: .sql, .sql.gz, .bak
#   .sql     -> executed via sqlcmd -i
#   .sql.gz  -> decompressed to a temp file, then executed via sqlcmd -i
#   .bak     -> SQL Server native backup; copied into container and restored
#               via RESTORE DATABASE ... WITH REPLACE, MOVE ...
#
# Platform behaviour:
#   macOS : uses the sqlcmd binary available on the host
#           (installed by init_mssql.sh via Homebrew)
#   Linux : copies the SQL file into the container and runs sqlcmd
#           from /opt/mssql-tools/bin/sqlcmd inside the container
#
# Environment variables:
#   APIM_DB_DUMP   - path to apim_db .sql / .sql.gz file
#   SHARED_DB_DUMP - path to shared_db .sql / .sql.gz file
#
# Usage:
#   APIM_DB_DUMP=/path/to/apim.sql \
#   SHARED_DB_DUMP=/path/to/shared.sql \
#   ./restore_mssql.sh [-v]
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

# Container names and ports (must match docker-compose files)
APIM_CONTAINER="apim_db_container_mssql"
APIM_PORT="1433"
SHARED_CONTAINER="shared_db_container_mssql"
SHARED_PORT="1434"

# SA credentials
SA_USER="SA"
SA_PASS="RootPass123!"

##############################################
# Run a sqlcmd command in a platform-aware way
#   $1 - container name
#   $2 - host port (used on macOS)
#   $3 - database name
#   $4 - sql file path (host path)
##############################################
run_sqlcmd_file() {
    local container_name="$1"
    local port="$2"
    local database_name="$3"
    local sql_file="$4"

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: use the externally installed sqlcmd binary
        log_verbose "  Running sqlcmd on host (macOS) against localhost:$port..."
        sqlcmd -S "localhost,$port" -U "$SA_USER" -P "$SA_PASS" -d "$database_name" -i "$sql_file"
    else
        # Linux: copy file into container, run container's sqlcmd
        local remote_path="/tmp/mssql_restore_$$.sql"
        log_verbose "  Copying SQL file into container '$container_name'..."
        docker cp "$sql_file" "$container_name:$remote_path"
        log_verbose "  Running sqlcmd inside container '$container_name'..."
        docker exec "$container_name" /opt/mssql-tools/bin/sqlcmd \
            -S localhost -U "$SA_USER" -P "$SA_PASS" -d "$database_name" -i "$remote_path"
        docker exec "$container_name" rm -f "$remote_path"
    fi
}

##############################################
# Restore a SQL Server native .bak file
# The backup is always copied into the container first so that the SQL Server
# process (which runs inside the container) can read it via its local path.
##############################################
restore_bak() {
    local container_name="$1"
    local database_name="$2"
    local port="$3"
    local bak_file="$4"

    local remote_bak="/tmp/mssql_restore_$$.bak"

    log_verbose "  Copying .bak file into container '$container_name'..."
    docker cp "$bak_file" "$container_name:$remote_bak"

    # Read the list of logical files stored in the backup
    log_verbose "  Reading backup file list (RESTORE FILELISTONLY)..."
    local filelist
    if [[ "$OSTYPE" == "darwin"* ]]; then
        filelist=$(sqlcmd -S "localhost,$port" -U "$SA_USER" -P "$SA_PASS" \
            -h -1 -s "|" -W \
            -Q "RESTORE FILELISTONLY FROM DISK = '$remote_bak'" 2>/dev/null)
    else
        filelist=$(docker exec "$container_name" /opt/mssql-tools/bin/sqlcmd \
            -S localhost -U "$SA_USER" -P "$SA_PASS" \
            -h -1 -s "|" -W \
            -Q "RESTORE FILELISTONLY FROM DISK = '$remote_bak'" 2>/dev/null)
    fi

    # Parse logical names: column 1 = LogicalName, column 3 = Type (D=data, L=log)
    local data_logical log_logical
    data_logical=$(echo "$filelist" | awk -F'|' 'NF>2 && $3~/^ *D *$/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1; exit}')
    log_logical=$(echo "$filelist"  | awk -F'|' 'NF>2 && $3~/^ *L *$/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1; exit}')

    if [[ -z "$data_logical" || -z "$log_logical" ]]; then
        docker exec "$container_name" rm -f "$remote_bak" 2>/dev/null || true
        log_error "Could not parse logical file names from backup. Ensure the .bak is a valid SQL Server backup."
        return 1
    fi

    log_verbose "  Data logical name: $data_logical"
    log_verbose "  Log  logical name: $log_logical"

    local restore_sql="RESTORE DATABASE [$database_name] FROM DISK = '$remote_bak' WITH REPLACE, MOVE '$data_logical' TO '/var/opt/mssql/data/${database_name}.mdf', MOVE '$log_logical' TO '/var/opt/mssql/data/${database_name}_log.ldf'"

    log_verbose "  Running RESTORE DATABASE..."
    local ok=false
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sqlcmd -S "localhost,$port" -U "$SA_USER" -P "$SA_PASS" -Q "$restore_sql" && ok=true || true
    else
        docker exec "$container_name" /opt/mssql-tools/bin/sqlcmd \
            -S localhost -U "$SA_USER" -P "$SA_PASS" -Q "$restore_sql" && ok=true || true
    fi

    docker exec "$container_name" rm -f "$remote_bak" 2>/dev/null || true

    [[ "$ok" == "true" ]]
}

##############################################
# Wait for an MSSQL container to accept connections
##############################################
wait_for_mssql() {
    local container_name="$1"
    local port="$2"
    local max_attempts=30
    local attempt=1

    log_info "Waiting for MSSQL container '$container_name' to be ready..."

    while [ $attempt -le $max_attempts ]; do
        local ok=false
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sqlcmd -S "localhost,$port" -U "$SA_USER" -P "$SA_PASS" -Q "SELECT 1" &>/dev/null && ok=true || true
        else
            docker exec "$container_name" /opt/mssql-tools/bin/sqlcmd \
                -S localhost -U "$SA_USER" -P "$SA_PASS" -Q "SELECT 1" &>/dev/null && ok=true || true
        fi

        if [[ "$ok" == "true" ]]; then
            log_success "MSSQL container '$container_name' is ready."
            return 0
        fi

        log_verbose "  Attempt $attempt/$max_attempts - not ready yet, waiting 2s..."
        sleep 2
        attempt=$((attempt + 1))
    done

    log_error "MSSQL container '$container_name' did not become ready after $max_attempts attempts."
    return 1
}

##############################################
# Import a SQL dump file into an MSSQL database
##############################################
import_dump() {
    local container_name="$1"
    local database_name="$2"
    local port="$3"
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
    log_verbose "  Container: $container_name | Port: $port"

    if [[ "$dump_file" == *.bak ]]; then
        log_verbose "  Detected SQL Server native backup (.bak) — using RESTORE DATABASE..."
        if restore_bak "$container_name" "$database_name" "$port" "$dump_file"; then
            log_success "Dump imported successfully into '$database_name'."
            return 0
        else
            log_error "Failed to restore '$database_name' from .bak file."
            return 1
        fi
    fi

    local sql_file="$dump_file"
    local temp_file=""

    if [[ "$dump_file" == *.gz ]]; then
        log_verbose "  Detected gzip archive — decompressing to temp file..."
        temp_file="/tmp/mssql_restore_$$.sql"
        gunzip -c "$dump_file" > "$temp_file"
        sql_file="$temp_file"
    fi

    if run_sqlcmd_file "$container_name" "$port" "$database_name" "$sql_file"; then
        [[ -n "$temp_file" ]] && rm -f "$temp_file"
        log_success "Dump imported successfully into '$database_name'."
        return 0
    else
        [[ -n "$temp_file" ]] && rm -f "$temp_file" 2>/dev/null || true
        log_error "Failed to import dump into '$database_name'."
        return 1
    fi
}

##############################################
# Main
##############################################
main() {
    log_info "======================================"
    log_info "MSSQL Dump Restore"
    log_info "======================================"

    if [[ -z "$APIM_DB_DUMP" && -z "$SHARED_DB_DUMP" ]]; then
        log_warning "No dump files provided (APIM_DB_DUMP / SHARED_DB_DUMP). Nothing to restore."
        exit 0
    fi

    [[ -n "$APIM_DB_DUMP" ]]   && log_info "  APIM DB dump:   $APIM_DB_DUMP"
    [[ -n "$SHARED_DB_DUMP" ]] && log_info "  Shared DB dump: $SHARED_DB_DUMP"
    echo

    # Ensure both containers are accepting connections before importing
    wait_for_mssql "$APIM_CONTAINER"   "$APIM_PORT"
    wait_for_mssql "$SHARED_CONTAINER" "$SHARED_PORT"

    local failed=false

    if [[ -n "$APIM_DB_DUMP" ]]; then
        import_dump "$APIM_CONTAINER" "apim_db" "$APIM_PORT" "$APIM_DB_DUMP" || failed=true
    fi

    if [[ -n "$SHARED_DB_DUMP" ]]; then
        import_dump "$SHARED_CONTAINER" "shared_db" "$SHARED_PORT" "$SHARED_DB_DUMP" || failed=true
    fi

    if [[ "$failed" == "true" ]]; then
        log_error "One or more dump restores failed."
        exit 1
    fi

    log_success "MSSQL dump restore completed successfully."
}

main "$@"
