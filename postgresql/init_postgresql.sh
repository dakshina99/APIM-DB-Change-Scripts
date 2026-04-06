#!/bin/bash

set -euo pipefail

VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=true ;;
  esac
done

# This script uses native tools to avoid installing additional dependencies:
# - docker compose plugin instead of standalone docker-compose when available

# Colors for better log visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_verbose() {
    [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}[INFO]${NC} $1" || true
}

##############################################
# Check for native tools instead of installing dependencies
##############################################
check_dependencies() {
  log_verbose "Checking for required native tools..."

  # Check for curl (native on both macOS and Linux)
  if ! command -v curl &> /dev/null; then
    log_error "curl is not available. Please install curl or ensure it's in your PATH."
    exit 1
  else
    log_verbose "curl is available"
  fi

  # Check for docker
  if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed. Please install Docker first."
    exit 1
  else
    log_verbose "Docker is available"
  fi

  # Check for docker compose (prefer native docker compose plugin over standalone docker-compose)
  if docker compose version &> /dev/null; then
    log_verbose "Docker Compose plugin is available (using native 'docker compose')"
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose &> /dev/null; then
    log_verbose "docker-compose standalone is available"
    COMPOSE_CMD="docker-compose"
  else
    log_error "Neither 'docker compose' plugin nor 'docker-compose' standalone is available."
    log_error "Please install Docker with the Compose plugin or install docker-compose."
    exit 1
  fi

  log_verbose "Using native system utilities (find, sed, cp, mv)"
}

##############################################
# Main Execution
##############################################
##############################################
# Dump file prompting
# Set APIM_DB_DUMP / SHARED_DB_DUMP env vars
# to skip interactive prompt.
##############################################
prompt_for_dumps() {
    APIM_DB_DUMP="${APIM_DB_DUMP:-}"
    SHARED_DB_DUMP="${SHARED_DB_DUMP:-}"

    if [[ -n "$APIM_DB_DUMP" && -n "$SHARED_DB_DUMP" ]]; then
        log_info "Using dump files from environment variables."
        return
    fi

    echo ""
    log_info "--------------------------------------------------"
    log_info "Database Dump Import (Optional)"
    log_info "--------------------------------------------------"
    log_info "You can optionally provide database dump files to import."
    log_info "Supported formats: .sql, .sql.gz, .dump (pg_restore custom format)"
    log_info "If not provided, default initialization scripts will be used."
    log_info "Press Enter to skip if you don't have dump files."
    echo ""

    if [[ -z "$APIM_DB_DUMP" ]]; then
        read -rp "Path to APIM DB dump file (or press Enter to skip): " APIM_DB_DUMP
    fi
    if [[ -n "$APIM_DB_DUMP" ]]; then
        APIM_DB_DUMP="${APIM_DB_DUMP/#\~/$HOME}"
        [[ "$APIM_DB_DUMP" != /* ]] && APIM_DB_DUMP="$(pwd)/$APIM_DB_DUMP"
        if [[ ! -f "$APIM_DB_DUMP" ]]; then
            log_error "APIM DB dump file not found: $APIM_DB_DUMP"; exit 1
        fi
        log_success "APIM DB dump: $APIM_DB_DUMP"
    fi

    if [[ -z "$SHARED_DB_DUMP" ]]; then
        read -rp "Path to Shared DB dump file (or press Enter to skip): " SHARED_DB_DUMP
    fi
    if [[ -n "$SHARED_DB_DUMP" ]]; then
        SHARED_DB_DUMP="${SHARED_DB_DUMP/#\~/$HOME}"
        [[ "$SHARED_DB_DUMP" != /* ]] && SHARED_DB_DUMP="$(pwd)/$SHARED_DB_DUMP"
        if [[ ! -f "$SHARED_DB_DUMP" ]]; then
            log_error "Shared DB dump file not found: $SHARED_DB_DUMP"; exit 1
        fi
        log_success "Shared DB dump: $SHARED_DB_DUMP"
    fi
    echo ""
}

main() {
  log_info "Starting PostgreSQL database initialization process..."
  [[ "$VERBOSE" == "false" ]] && log_info "(Run with -v for verbose output)"

  check_dependencies

  # Prompt for dump file paths (interactive or via env vars)
  prompt_for_dumps

  CONFIG_FILE="repository/conf/deployment.toml"
  DBSCRIPTS_DIR="dbscripts"
  APIMGT_DIR="${DBSCRIPTS_DIR}/apimgt"
  REPO_LIB_DIR="repository/components/lib"
  JDBC_URL="https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.8/postgresql-42.7.8.jar"
  JDBC_DRIVER="postgresql-42.7.8.jar"
  BACKUP_DIR="dbscripts_backup_$(date +%Y%m%d_%H%M%S)"

  log_verbose "Updating database configuration in $CONFIG_FILE..."

  # Check if config file exists
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Configuration file $CONFIG_FILE not found!"
    exit 1
  fi

  log_verbose "Removing existing database configuration blocks..."

  # Cross-platform sed handling (macOS vs Linux)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_OPT=(-i '')
  else
    SED_OPT=(-i)
  fi

  # Delete old DB blocks
  sed "${SED_OPT[@]}" '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed "${SED_OPT[@]}" '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"

  log_verbose "Adding PostgreSQL database configurations..."

  # Append PostgreSQL configs
  cat <<EOF >> "$CONFIG_FILE"

[database.apim_db]
type = "postgre"
url = "jdbc:postgresql://localhost:5432/apim_db"
username = "apim_user"
password = "apimpass"
driver = "org.postgresql.Driver"
validationQuery = "SELECT 1"

[database.shared_db]
type = "postgre"
url = "jdbc:postgresql://localhost:5433/shared_db"
username = "shared_user"
password = "sharedpass"
driver = "org.postgresql.Driver"
validationQuery = "SELECT 1"
EOF

  log_success "Database configuration updated successfully"

  log_verbose "Processing database scripts cleanup..."

  # Backup dbscripts directory before cleaning
  if [[ -d "$DBSCRIPTS_DIR" ]]; then
    log_verbose "Creating backup of dbscripts directory at $BACKUP_DIR..."
    cp -r "$DBSCRIPTS_DIR" "$BACKUP_DIR"
    log_verbose "Backup created successfully at $BACKUP_DIR"

    # Count files before cleanup
    TOTAL_SQL_FILES=$(find "$DBSCRIPTS_DIR" -type f -name "*.sql" | wc -l)
    POSTGRESQL_SQL_FILES=$(find "$DBSCRIPTS_DIR" -type f -name "postgresql.sql" | wc -l)
    FILES_TO_DELETE=$((TOTAL_SQL_FILES - POSTGRESQL_SQL_FILES))

    log_verbose "Found $TOTAL_SQL_FILES SQL files total, keeping $POSTGRESQL_SQL_FILES postgresql.sql files"
    log_verbose "Cleaning up $FILES_TO_DELETE unnecessary SQL files..."

    find "$DBSCRIPTS_DIR" -type f -name "*.sql" ! -name "postgresql.sql" -delete
    if [[ -d "$APIMGT_DIR" ]]; then
      find "$APIMGT_DIR" -type f -name "*.sql" ! -name "postgresql.sql" -delete
    fi
    log_verbose "Database scripts cleanup completed. Backup available at $BACKUP_DIR"
  else
    log_warning "dbscripts directory not found, skipping cleanup"
  fi

  log_verbose "Checking PostgreSQL JDBC driver availability..."

  # Check if lib directory exists
  if [[ ! -d "$REPO_LIB_DIR" ]]; then
    log_verbose "Creating lib directory: $REPO_LIB_DIR"
    mkdir -p "$REPO_LIB_DIR"
  fi

  # Check if JDBC driver already exists
  JDBC_PATH="$REPO_LIB_DIR/$JDBC_DRIVER"
  if [[ -f "$JDBC_PATH" ]]; then
    log_verbose "PostgreSQL JDBC driver already exists at $JDBC_PATH"
    log_verbose "Verifying driver file integrity..."

    # Check if file size is reasonable (should be > 500KB for PostgreSQL driver)
    FILE_SIZE=$(stat -c%s "$JDBC_PATH" 2>/dev/null || stat -f%z "$JDBC_PATH" 2>/dev/null || echo "0")
    if [[ "$FILE_SIZE" -gt 500000 ]]; then
      log_verbose "JDBC driver file appears to be valid (size: $FILE_SIZE bytes)"
    else
      log_warning "JDBC driver file seems corrupted or incomplete (size: $FILE_SIZE bytes)"
      log_verbose "Removing corrupted file and re-downloading..."
      rm -f "$JDBC_PATH"
    fi
  fi

  # Download JDBC driver if not present or corrupted
  if [[ ! -f "$JDBC_PATH" ]]; then
    log_info "Downloading PostgreSQL JDBC driver..."

    # Download to temporary location first
    TEMP_DRIVER="/tmp/$JDBC_DRIVER"
    if curl -fsSL -o "$TEMP_DRIVER" "$JDBC_URL"; then
      log_verbose "JDBC driver downloaded successfully"

      # Verify downloaded file
      TEMP_FILE_SIZE=$(stat -c%s "$TEMP_DRIVER" 2>/dev/null || stat -f%z "$TEMP_DRIVER" 2>/dev/null || echo "0")
      if [[ "$TEMP_FILE_SIZE" -gt 500000 ]]; then
        log_verbose "Moving JDBC driver to $REPO_LIB_DIR..."
        mv "$TEMP_DRIVER" "$JDBC_PATH"
        log_success "PostgreSQL JDBC driver installed successfully"
      else
        log_error "Downloaded JDBC driver appears to be corrupted (size: $TEMP_FILE_SIZE bytes)"
        rm -f "$TEMP_DRIVER"
        exit 1
      fi
    else
      log_error "Failed to download PostgreSQL JDBC driver"
      exit 1
    fi
  fi

  # Start containers
  log_info "Starting PostgreSQL Docker containers..."

  if $COMPOSE_CMD up -d; then
    log_success "PostgreSQL Docker containers started successfully"

    # Wait a moment and check container status
    sleep 3
    if [[ "$VERBOSE" == "true" ]]; then
      log_verbose "Checking container status..."
      $COMPOSE_CMD ps
    fi

    # Wait for databases to be fully ready
    log_info "Waiting for databases to be ready..."
    sleep 10

    log_success "PostgreSQL database initialization process completed!"

    # Inline dump restore if dump files were provided
    if [[ -n "$APIM_DB_DUMP" || -n "$SHARED_DB_DUMP" ]]; then
      log_info "======================================"
      log_info "PostgreSQL Dump Restore"
      log_info "======================================"

      local pg_apim_container="apim_db_container_postgres"
      local pg_shared_container="shared_db_container_postgres"
      local dump_failed=false

      # Helper: import a dump into a PostgreSQL database
      pg_import_dump() {
        local ctr="$1" db="$2" user="$3" dump="$4"
        [[ -z "$dump" ]] && return 0
        if [[ ! -f "$dump" ]]; then
          log_error "Dump file not found: $dump"; return 1
        fi
        log_info "Importing dump into '$db' from: $(basename "$dump")"
        if [[ "$dump" == *.dump ]]; then
          local tmp="/tmp/pg_restore_$$.dump"
          docker cp "$dump" "$ctr:$tmp"
          if docker exec "$ctr" pg_restore -U "$user" -d "$db" --no-owner --no-privileges "$tmp"; then
            docker exec "$ctr" rm -f "$tmp"
            log_success "Dump imported successfully into '$db'."; return 0
          else
            docker exec "$ctr" rm -f "$tmp" 2>/dev/null || true
            log_error "Failed to import dump into '$db'."; return 1
          fi
        elif [[ "$dump" == *.gz ]]; then
          if gunzip -c "$dump" | docker exec -i "$ctr" psql -U "$user" -d "$db"; then
            log_success "Dump imported successfully into '$db'."; return 0
          else
            log_error "Failed to import dump into '$db'."; return 1
          fi
        else
          if docker exec -i "$ctr" psql -U "$user" -d "$db" < "$dump"; then
            log_success "Dump imported successfully into '$db'."; return 0
          else
            log_error "Failed to import dump into '$db'."; return 1
          fi
        fi
      }

      [[ -n "$APIM_DB_DUMP" ]]   && { pg_import_dump "$pg_apim_container"   "apim_db"   "apim_user"   "$APIM_DB_DUMP"   || dump_failed=true; }
      [[ -n "$SHARED_DB_DUMP" ]] && { pg_import_dump "$pg_shared_container" "shared_db" "shared_user" "$SHARED_DB_DUMP" || dump_failed=true; }

      if [[ "$dump_failed" == "true" ]]; then
        log_error "One or more dump restores failed."
      else
        log_success "PostgreSQL dump restore completed successfully."
      fi
    fi

    # Display comprehensive database connection information
    echo
    log_info "==============================================="
    log_info "    DATABASE CONNECTION INFORMATION"
    log_info "==============================================="
    echo

    log_info "APIM Database Connection Details:"
    log_info "  Host: localhost"
    log_info "  Port: 5432"
    log_info "  Database Name: apim_db"
    log_info "  Username: apim_user"
    log_info "  Password: apimpass"
    log_info "  JDBC URL: jdbc:postgresql://localhost:5432/apim_db"
    echo

    log_info "Shared Database Connection Details:"
    log_info "  Host: localhost"
    log_info "  Port: 5433"
    log_info "  Database Name: shared_db"
    log_info "  Username: shared_user"
    log_info "  Password: sharedpass"
    log_info "  JDBC URL: jdbc:postgresql://localhost:5433/shared_db"
    echo

    log_info "Database Viewer Configuration (pgAdmin, DBeaver, etc.):"
    log_info "  Connection Type: PostgreSQL"
    log_info "  Server Host: localhost"
    log_info "  APIM DB Port: 5432 | Shared DB Port: 5433"
    log_info "  Authentication: Username/Password"
    log_info "  SSL Mode: Prefer (or disable for local development)"
    echo

    log_info "Container Management:"
    log_info "  View containers: $COMPOSE_CMD ps"
    log_info "  Stop containers: $COMPOSE_CMD down"
    log_info "  View logs: $COMPOSE_CMD logs -f"
    log_info "==============================================="
    echo

    # Restore dbscripts directory from backup and cleanup
    if [[ -n "$BACKUP_DIR" ]] && [[ -d "$BACKUP_DIR" ]]; then
      log_verbose "Restoring dbscripts directory from backup..."

      # Remove the modified dbscripts directory
      if [[ -d "$DBSCRIPTS_DIR" ]]; then
        rm -rf "$DBSCRIPTS_DIR"
        log_verbose "Removed modified dbscripts directory"
      fi

      # Restore from backup
      mv "$BACKUP_DIR" "$DBSCRIPTS_DIR"
      log_verbose "dbscripts directory restored from backup"

      log_verbose "dbscripts directory has been reset to its original state"
    else
      log_warning "No backup directory found to restore from"
    fi

  else
    log_error "Failed to start PostgreSQL Docker containers"

    # If container startup failed, still restore the backup if it exists
    if [[ -n "$BACKUP_DIR" ]] && [[ -d "$BACKUP_DIR" ]]; then
      log_verbose "Restoring dbscripts directory from backup due to failure..."
      if [[ -d "$DBSCRIPTS_DIR" ]]; then
        rm -rf "$DBSCRIPTS_DIR"
      fi
      mv "$BACKUP_DIR" "$DBSCRIPTS_DIR"
      log_verbose "dbscripts directory restored from backup"
    fi

    exit 1
  fi
}

main "$@"
