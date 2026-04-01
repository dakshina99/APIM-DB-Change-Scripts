#!/bin/bash

set -e

# This script use    log_error "curl    log_success "docker-compose standalone is available"is not available. Please install curl or ensure it's in your PATH." native tools to avoid installing additional dependencies:
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

# Database dump file paths (from environment variables)
APIM_DB_DUMP="${APIM_DB_DUMP:-}"
SHARED_DB_DUMP="${SHARED_DB_DUMP:-}"

# Flag to track if we're using dumps
USING_DUMPS=false
if [[ -n "$APIM_DB_DUMP" ]] || [[ -n "$SHARED_DB_DUMP" ]]; then
    USING_DUMPS=true
fi

# Check for native tools instead of installing dependencies
check_dependencies() {
  log_info "Checking for required native tools..."

  # Check for curl (native on macOS and most Linux distributions)
  if ! command -v curl &> /dev/null; then
    log_error "� curl is not available. Please install curl or ensure it's in your PATH."
    exit 1
  else
    log_success "curl is available"
  fi

  # Check for docker
  if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed. Please install Docker first."
    exit 1
  else
    log_success "Docker is available"
  fi

  # Check for docker compose (prefer native docker compose plugin over standalone docker-compose)
  if docker compose version &> /dev/null; then
    log_success "Docker Compose plugin is available (using native 'docker compose')"
    DOCKER_COMPOSE_CMD="docker compose"
  elif command -v docker-compose &> /dev/null; then
    log_success "� docker-compose standalone is available"
    DOCKER_COMPOSE_CMD="docker-compose"
  else
    log_error "Neither 'docker compose' plugin nor 'docker-compose' standalone is available."
    log_error "Please install Docker with the Compose plugin or install docker-compose."
    exit 1
  fi
}

# Function to wait for MySQL to be ready
wait_for_mysql() {
    local container_name="$1"
    local max_attempts=30
    local attempt=1

    log_info "Waiting for MySQL container '$container_name' to be ready..."

    while [ $attempt -le $max_attempts ]; do
        if docker exec "$container_name" mysqladmin ping -h localhost -u root -prootpass --silent &>/dev/null; then
            log_success "MySQL container '$container_name' is ready!"
            return 0
        fi

        log_info "  Attempt $attempt/$max_attempts - MySQL not ready yet, waiting..."
        sleep 2
        attempt=$((attempt + 1))
    done

    log_error "MySQL container '$container_name' failed to become ready after $max_attempts attempts"
    return 1
}

# Function to import a database dump
# Uses root credentials for proper privileges (CREATE, DROP, ALTER, etc.)
import_dump() {
    local container_name="$1"
    local database_name="$2"
    local dump_file="$3"

    # Use root credentials for dump import (application users may lack required privileges)
    local root_user="root"
    local root_pass="rootpass"

    if [[ -z "$dump_file" ]]; then
        log_info "No dump file provided for $database_name, skipping import"
        return 0
    fi

    if [[ ! -f "$dump_file" ]]; then
        log_error "Dump file not found: $dump_file"
        return 1
    fi

    log_info "Importing dump into $database_name from $dump_file..."
    log_info "  Using root credentials for proper privileges"

    # Determine if the file is compressed
    if [[ "$dump_file" == *.gz ]]; then
        log_info "  Detected gzipped dump file, decompressing during import..."
        if gunzip -c "$dump_file" | docker exec -i "$container_name" mysql -u "$root_user" -p"$root_pass" "$database_name" 2>&1; then
            log_success "Dump imported successfully into $database_name"
            return 0
        else
            log_error "Failed to import dump into $database_name"
            return 1
        fi
    else
        # Regular SQL file
        if docker exec -i "$container_name" mysql -u "$root_user" -p"$root_pass" "$database_name" < "$dump_file" 2>&1; then
            log_success "Dump imported successfully into $database_name"
            return 0
        else
            log_error "Failed to import dump into $database_name"
            return 1
        fi
    fi
}

log_info "Starting MySQL database initialization process..."

check_dependencies

# Configuration file path
CONFIG_FILE="repository/conf/deployment.toml"

log_info "Updating database configuration in $CONFIG_FILE..."

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file $CONFIG_FILE not found!"
    exit 1
fi

log_info "Removing existing database configuration blocks..."
# Delete existing DB config blocks
sed -i '' '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
sed -i '' '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"

log_info "Adding MySQL database configurations..."
# Add MySQL DB configurations
cat <<EOF >> "$CONFIG_FILE"

[database.apim_db]
type = "mysql"
url = "jdbc:mysql://localhost:3306/apim_db?allowPublicKeyRetrieval=true&amp;useSSL=false"
username = "apim_user"
password = "apimpass"
driver = "com.mysql.cj.jdbc.Driver"
validationQuery = "SELECT 1"

[database.shared_db]
type = "mysql"
url = "jdbc:mysql://localhost:3307/shared_db?allowPublicKeyRetrieval=true&amp;useSSL=false"
username = "shared_user"
password = "sharedpass"
driver = "com.mysql.cj.jdbc.Driver"
validationQuery = "SELECT 1"
EOF

log_success "Database configuration updated successfully"

# Cleanup unnecessary SQL files with backup (only if not using dumps)
DBSCRIPTS_DIR="dbscripts"
APIMGT_DIR="${DBSCRIPTS_DIR}/apimgt"
BACKUP_DIR=""  # Initialize backup directory variable

# Only process dbscripts if we're not using dump files
if [ "$USING_DUMPS" = false ]; then
    log_info "Processing database scripts cleanup..."

    if [ -d "$DBSCRIPTS_DIR" ]; then
        # Create backup directory with timestamp
        BACKUP_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
        BACKUP_DIR="${DBSCRIPTS_DIR}_backup_${BACKUP_TIMESTAMP}"

        log_info "Creating backup of dbscripts directory at $BACKUP_DIR..."
        cp -r "$DBSCRIPTS_DIR" "$BACKUP_DIR"
        log_success "Backup created successfully at $BACKUP_DIR"

        # Count files before cleanup
        TOTAL_SQL_FILES=$(find "$DBSCRIPTS_DIR" -type f -name "*.sql" | wc -l)
        MYSQL_SQL_FILES=$(find "$DBSCRIPTS_DIR" -type f -name "mysql.sql" | wc -l)
        FILES_TO_DELETE=$((TOTAL_SQL_FILES - MYSQL_SQL_FILES))

        log_info "Found $TOTAL_SQL_FILES SQL files total, keeping $MYSQL_SQL_FILES mysql.sql files"
        log_info "Cleaning up $FILES_TO_DELETE unnecessary SQL files..."

        # Remove unnecessary SQL files (keep only mysql.sql files)
        find "$DBSCRIPTS_DIR" -type f -name "*.sql" ! -name "mysql.sql" -delete

        if [ -d "$APIMGT_DIR" ]; then
            find "$APIMGT_DIR" -type f -name "*.sql" ! -name "mysql.sql" -delete
        fi

        log_success "Database scripts cleanup completed. Backup available at $BACKUP_DIR"
    else
        log_warning "dbscripts directory not found, skipping cleanup"
    fi
else
    log_info "Using database dumps - skipping dbscripts cleanup"
fi

# Download JDBC driver only if not present
REPO_LIB_DIR="repository/components/lib"
JDBC_URL="https://repo1.maven.org/maven2/mysql/mysql-connector-java/8.0.30/mysql-connector-java-8.0.30.jar"
JDBC_DRIVER="mysql-connector-java-8.0.30.jar"
JDBC_PATH="$REPO_LIB_DIR/$JDBC_DRIVER"

# Modify docker-compose if using dumps (to skip auto-initialization from scripts)
if [ "$USING_DUMPS" = true ]; then
    log_info "Configuring Docker Compose for dump import mode..."

    # Create a modified docker-compose without volume mounts for init scripts
    cat > docker-compose.yaml <<'DUMPEOF'
version: '3.8'
services:
  apim_db:
    image: mysql:8.0
    container_name: apim_db_container_mysql
    environment:
      MYSQL_DATABASE: apim_db
      MYSQL_USER: apim_user
      MYSQL_PASSWORD: apimpass
      MYSQL_ROOT_PASSWORD: rootpass
    command: --character-set-server=latin1 --collation-server=latin1_swedish_ci --default-authentication-plugin=mysql_native_password
    ports:
      - "3306:3306"

  shared_db:
    image: mysql:8.0
    container_name: shared_db_container_mysql
    environment:
      MYSQL_DATABASE: shared_db
      MYSQL_USER: shared_user
      MYSQL_PASSWORD: sharedpass
      MYSQL_ROOT_PASSWORD: rootpass
    command: --character-set-server=latin1 --collation-server=latin1_swedish_ci --default-authentication-plugin=mysql_native_password
    ports:
      - "3307:3306"
DUMPEOF
    log_success "Docker Compose configured for dump import (no auto-init scripts)"
fi

log_info "Checking MySQL JDBC driver availability..."

# Create lib directory if it doesn't exist
if [ ! -d "$REPO_LIB_DIR" ]; then
    log_info "Creating lib directory: $REPO_LIB_DIR"
    mkdir -p "$REPO_LIB_DIR"
fi

# Check if JDBC driver already exists
if [ -f "$JDBC_PATH" ]; then
    log_success "MySQL JDBC driver already exists at $JDBC_PATH"
    log_info "Verifying driver file integrity..."

    # Check if file size is reasonable (should be > 1MB for MySQL connector)
    FILE_SIZE=$(stat -f%z "$JDBC_PATH" 2>/dev/null || echo "0")
    if [ "$FILE_SIZE" -gt 1000000 ]; then
        log_success "JDBC driver file appears to be valid (size: $FILE_SIZE bytes)"
    else
        log_warning "JDBC driver file seems corrupted or incomplete (size: $FILE_SIZE bytes)"
        log_info "Removing corrupted file and re-downloading..."
        rm -f "$JDBC_PATH"
    fi
fi

# Download JDBC driver if not present or corrupted
if [ ! -f "$JDBC_PATH" ]; then
    log_info "Downloading MySQL JDBC driver from $JDBC_URL..."

    # Download to temporary location first
    TEMP_DRIVER="/tmp/$JDBC_DRIVER"
    if curl -L -o "$TEMP_DRIVER" "$JDBC_URL"; then
        log_success "JDBC driver downloaded successfully"

        # Verify downloaded file
        TEMP_FILE_SIZE=$(stat -f%z "$TEMP_DRIVER" 2>/dev/null || echo "0")
        if [ "$TEMP_FILE_SIZE" -gt 1000000 ]; then
            log_info "Moving JDBC driver to $REPO_LIB_DIR..."
            mv "$TEMP_DRIVER" "$JDBC_PATH"
            log_success "MySQL JDBC driver installed successfully at $JDBC_PATH"
        else
            log_error "Downloaded JDBC driver appears to be corrupted (size: $TEMP_FILE_SIZE bytes)"
            rm -f "$TEMP_DRIVER"
            exit 1
        fi
    else
        log_error "Failed to download MySQL JDBC driver"
        exit 1
    fi
fi

# Start containers
log_info "Starting MySQL Docker containers..."

if $DOCKER_COMPOSE_CMD up -d; then
    log_success "MySQL Docker containers started successfully"

    # Wait a moment and check container status
    sleep 3
    log_info "Checking container status..."
    $DOCKER_COMPOSE_CMD ps

    # Wait for databases to be fully ready
    log_info "Waiting for databases to be fully initialized..."

    # Wait for MySQL containers to be ready (proper health check)
    wait_for_mysql "apim_db_container_mysql"
    wait_for_mysql "shared_db_container_mysql"

    # Import database dumps if provided
    if [ "$USING_DUMPS" = true ]; then
        log_info "==============================================="
        log_info "    IMPORTING DATABASE DUMPS"
        log_info "==============================================="
        echo

        IMPORT_FAILED=false

        if [[ -n "$APIM_DB_DUMP" ]]; then
            if ! import_dump "apim_db_container_mysql" "apim_db" "$APIM_DB_DUMP"; then
                IMPORT_FAILED=true
            fi
        fi

        if [[ -n "$SHARED_DB_DUMP" ]]; then
            if ! import_dump "shared_db_container_mysql" "shared_db" "$SHARED_DB_DUMP"; then
                IMPORT_FAILED=true
            fi
        fi

        if [ "$IMPORT_FAILED" = true ]; then
            log_warning "Some dump imports failed. Please check the logs above."
        else
            log_success "All database dumps imported successfully!"
        fi
        echo
    fi

    log_success "MySQL database initialization process completed!"

    # Display comprehensive database connection information
    echo
    log_info "==============================================="
    log_info "    DATABASE CONNECTION INFORMATION"
    log_info "==============================================="
    echo

    if [ "$USING_DUMPS" = true ]; then
        log_info "Mode: Database Dump Import"
        if [[ -n "$APIM_DB_DUMP" ]]; then
            log_info "  APIM DB Dump: $APIM_DB_DUMP"
        fi
        if [[ -n "$SHARED_DB_DUMP" ]]; then
            log_info "  Shared DB Dump: $SHARED_DB_DUMP"
        fi
        echo
    else
        log_info "Mode: Default Initialization Scripts"
        echo
    fi

    log_info "APIM Database Connection Details:"
    log_info "  Host: localhost"
    log_info "  Port: 3306"
    log_info "  Database Name: apim_db"
    log_info "  Username: apim_user"
    log_info "  Password: apimpass"
    log_info "  JDBC URL: jdbc:mysql://localhost:3306/apim_db?allowPublicKeyRetrieval=true&useSSL=false"
    echo

    log_info "Shared Database Connection Details:"
    log_info "  Host: localhost"
    log_info "  Port: 3307"
    log_info "  Database Name: shared_db"
    log_info "  Username: shared_user"
    log_info "  Password: sharedpass"
    log_info "  JDBC URL: jdbc:mysql://localhost:3307/shared_db?allowPublicKeyRetrieval=true&useSSL=false"
    echo

    log_info "Database Viewer Configuration (MySQL Workbench, DBeaver, etc.):"
    log_info "  Connection Type: MySQL"
    log_info "  Server Host: localhost"
    log_info "  APIM DB Port: 3306 | Shared DB Port: 3307"
    log_info "  Authentication: Standard (Username/Password)"
    log_info "  SSL: Disabled"
    echo

    log_info "Container Management:"
    log_info "  View containers: $DOCKER_COMPOSE_CMD ps"
    log_info "  Stop containers: $DOCKER_COMPOSE_CMD down"
    log_info "  View logs: $DOCKER_COMPOSE_CMD logs -f"
    log_info "==============================================="
    echo

    # Restore dbscripts directory from backup and cleanup
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        log_info "Restoring dbscripts directory from backup..."

        # Remove the modified dbscripts directory
        if [ -d "$DBSCRIPTS_DIR" ]; then
            rm -rf "$DBSCRIPTS_DIR"
            log_info "Removed modified dbscripts directory"
        fi

        # Restore from backup
        cp -r "$BACKUP_DIR" "$DBSCRIPTS_DIR"
        log_success "dbscripts directory restored from backup"

        # Clean up backup directory
        log_info "Cleaning up backup directory: $BACKUP_DIR"
        rm -rf "$BACKUP_DIR"
        log_success "Backup directory cleaned up"

        log_info "dbscripts directory has been reset to its original state"
    else
        log_warning "No backup directory found to restore from"
    fi

else
    log_error "Failed to start MySQL Docker containers"

    # If container startup failed, still restore the backup if it exists
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        log_info "Restoring dbscripts directory from backup due to failure..."
        if [ -d "$DBSCRIPTS_DIR" ]; then
            rm -rf "$DBSCRIPTS_DIR"
        fi
        cp -r "$BACKUP_DIR" "$DBSCRIPTS_DIR"
        rm -rf "$BACKUP_DIR"
        log_success "dbscripts directory restored from backup"
    fi

    exit 1
fi
