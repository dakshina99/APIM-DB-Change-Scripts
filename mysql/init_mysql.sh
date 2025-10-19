#!/bin/bash

set -e

# This script use    log_error "curl    log_success "docker-compose standalone is available"is not available. Please install curl or ensure it's in your PATH." native tools to avoid installing additional dependencies:
# - curl instead of wget (pre-installed on macOS and most Linux distributions)
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

# Check for native tools instead of installing dependencies
check_dependencies() {
  log_info "Checking for required native tools..."

  # Check for curl (native on macOS and most Linux distributions)
  if ! command -v curl &> /dev/null; then
    log_error "� curl is not available. Please install curl or ensure it's in your PATH."
    exit 1
  else
    log_success "curl is available (using native tool instead of wget)"
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

# Cleanup unnecessary SQL files with backup
DBSCRIPTS_DIR="dbscripts"
APIMGT_DIR="${DBSCRIPTS_DIR}/apimgt"
BACKUP_DIR=""  # Initialize backup directory variable

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

# Download JDBC driver only if not present
REPO_LIB_DIR="repository/components/lib"
JDBC_URL="https://repo1.maven.org/maven2/mysql/mysql-connector-java/8.0.30/mysql-connector-java-8.0.30.jar"
JDBC_DRIVER="mysql-connector-java-8.0.30.jar"
JDBC_PATH="$REPO_LIB_DIR/$JDBC_DRIVER"

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
    sleep 10
    
    log_success "MySQL database initialization process completed!"
    
    # Display comprehensive database connection information
    echo
    log_info "==============================================="
    log_info "    DATABASE CONNECTION INFORMATION"
    log_info "==============================================="
    echo
    
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
