#!/bin/bash

# MSSQL Database Initialization Script
# 
# This script provides cross-platform SQL Server setup:
# - macOS: Uses Azure SQL Edge + external sqlcmd (auto-installed via Homebrew)
# - Linux: Uses full SQL Server + container sqlcmd tools
# - Auto-detects platform and installs required dependencies
# - Uses platform-specific Docker Compose files
# - Cross-platform compatible (macOS and Linux)

set -euo pipefail

# Colors for log visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

log_config() {
    echo -e "${CYAN}[CONFIG]${NC} $1"
}

##############################################
# Utility: Install platform-specific dependencies
##############################################
install_platform_dependencies() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    log_info "Detected macOS - checking Microsoft SQL Server tools..."
    
    # Check if sqlcmd is already available
    if command -v sqlcmd &> /dev/null; then
      log_success "sqlcmd is already installed"
      return 0
    fi
    
    # Check if Homebrew is installed
    if ! command -v brew &> /dev/null; then
      log_error "Homebrew is required on macOS but not installed."
      log_error "Please install Homebrew first: https://brew.sh/"
      exit 1
    fi
    
    log_info "Installing Microsoft SQL Server tools via Homebrew..."
    log_info "This may take a few minutes..."
    
    # Add Microsoft tap and install tools
    if ! brew tap | grep -q "microsoft/mssql-release"; then
      log_info "Adding Microsoft Homebrew tap..."
      if brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release > /dev/null 2>&1; then
        log_success "Added Microsoft Homebrew tap"
      else
        log_warning "Failed to add Microsoft tap, continuing..."
      fi
    fi
    
    log_info "Updating Homebrew..."
    brew update > /dev/null 2>&1 || log_warning "Homebrew update had issues, continuing..."
    
    log_info "Installing Microsoft SQL Server tools..."
    if brew install msodbcsql mssql-tools > /dev/null 2>&1; then
      log_success "Installed Microsoft SQL Server tools"
      
      # Add sqlcmd to PATH for current session
      export PATH="/usr/local/opt/mssql-tools/bin:$PATH"
      export PATH="/opt/homebrew/opt/mssql-tools/bin:$PATH"  # For Apple Silicon
      log_success "Added sqlcmd to PATH"
    else
      log_error "Failed to install Microsoft SQL Server tools"
      log_error "You may need to run this manually:"
      log_error "  brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release"
      log_error "  brew install msodbcsql mssql-tools"
      exit 1
    fi
    
  else
    log_info "Detected Linux - will use SQL Server container with built-in sqlcmd tools"
  fi
}

##############################################
# Utility: Check Dependencies
##############################################
check_dependencies() {
  log_info "Checking for required commands and dependencies..."

  # Check for docker
  if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed. Please install Docker first."
    exit 1
  else
    log_success "Docker is available"
  fi

  # Determine Docker Compose file based on OS
  if [[ "$OSTYPE" == "darwin"* ]]; then
    COMPOSE_FILE="docker-compose.macos.yaml"
    log_info "Using macOS-specific Docker Compose file: $COMPOSE_FILE"
  else
    COMPOSE_FILE="docker-compose.linux.yaml"
    log_info "Using Linux-specific Docker Compose file: $COMPOSE_FILE"
  fi

  # Check for docker-compose or docker compose and set global variable
  if command -v docker-compose &> /dev/null; then
    log_success "docker-compose is available"
    export DOCKER_COMPOSE_CMD="docker-compose -f $COMPOSE_FILE"
  elif docker compose version &> /dev/null; then
    log_success "docker compose is available"
    export DOCKER_COMPOSE_CMD="docker compose -f $COMPOSE_FILE"
  else
    log_error "Neither docker-compose nor docker compose is available. Please install Docker Compose."
    exit 1
  fi

  # Check for curl (native on most systems)
  if ! command -v curl &> /dev/null; then
    log_error "curl is not available. Please install curl."
    exit 1
  else
    log_success "curl is available"
  fi

  # Install platform-specific dependencies
  install_platform_dependencies
}

##############################################
# Utility: Wait for container to be ready
##############################################
wait_for_container_ready() {
  local container_name="$1"
  local port="$2"
  local max_attempts=30
  local attempt=1
  
  log_info "Waiting for container $container_name to be ready on port $port..."
  
  while [[ $attempt -le $max_attempts ]]; do
    # Try a simple SQL query to ensure SQL Server is ready
    if [[ "$OSTYPE" == "darwin"* ]]; then
      # macOS - use external sqlcmd
      log_info "Testing SQL Server connection on port $port (attempt $attempt/$max_attempts)..."
      
      # Test SQL Server connection
      if sqlcmd -S localhost,$port -U SA -P 'RootPass123!' -Q "SELECT 1" > /dev/null 2>&1; then
        log_success "Container $container_name is ready and responding to SQL queries (attempt $attempt/$max_attempts)"
        return 0
      else
        if [[ $attempt -eq 1 ]]; then
          log_info "SQL Server initializing (this is normal for the first few attempts)..."
        else
          log_info "SQL Server not ready yet on port $port, retrying..."
        fi
      fi
    else
      # Linux - use container's internal sqlcmd
      log_info "Testing SQL Server connection on port $port (attempt $attempt/$max_attempts)..."
      if docker exec -i "$container_name" /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P 'RootPass123!' -Q "SELECT 1" > /dev/null 2>&1; then
        log_success "Container $container_name is ready and responding to SQL queries (attempt $attempt/$max_attempts)"
        return 0
      else
        if [[ $attempt -eq 1 ]]; then
          log_info "SQL Server initializing (this is normal for the first few attempts)..."
        else
          log_info "SQL Server not ready yet on port $port, retrying..."
        fi
      fi
    fi
    
    # Use shorter wait time for first few attempts since SQL Server often comes up quickly
    local wait_time
    if [[ $attempt -le 3 ]]; then
      wait_time=5
    else
      wait_time=10
    fi
    
    log_info "Container $container_name not ready yet (attempt $attempt/$max_attempts), waiting $wait_time seconds..."
    sleep $wait_time
    ((attempt++))
  done
  
  log_error "Container $container_name failed to become ready after $max_attempts attempts"
  log_error "Please check container logs: docker logs $container_name"
  return 1
}

##############################################
# Utility: Run SQL commands on container
##############################################
run_sql_on_container() {
  local container_name="$1"
  local sql_command="$2"
  local database="${3:-master}"
  
  # Extract port from container name
  local port
  if [[ "$container_name" == "apim_db_container_mssql" ]]; then
    port="1433"
  else
    port="1434"
  fi
  
  log_info "Executing SQL command on container $container_name (database: $database)"
  
  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS - use external sqlcmd (installed via Homebrew)
    if sqlcmd -S localhost,$port -U SA -P 'RootPass123!' -d "$database" -Q "$sql_command" > /dev/null 2>&1; then
      return 0
    else
      log_error "Failed to execute SQL command on container $container_name using external sqlcmd"
      return 1
    fi
  else
    # Linux - use container's internal sqlcmd
    if docker exec -i "$container_name" /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P 'RootPass123!' -d "$database" -Q "$sql_command" > /dev/null 2>&1; then
      return 0
    else
      log_error "Failed to execute SQL command on container $container_name using container sqlcmd"
      return 1
    fi
  fi
}

##############################################
# Utility: Initialize databases
##############################################
initialize_databases() {
  local apim_container="apim_db_container_mssql"
  local shared_container="shared_db_container_mssql"
  
  log_info "Waiting for SQL Server containers to initialize..."
  
  # Wait for both containers to be ready
  if ! wait_for_container_ready "$apim_container" "1433"; then
    log_error "APIM container failed to initialize"
    return 1
  fi
  
  if ! wait_for_container_ready "$shared_container" "1434"; then
    log_error "Shared container failed to initialize"
    return 1
  fi
  
  # Initialize APIM database
  log_info "Creating APIM database and user..."
  if run_sql_on_container "$apim_container" "CREATE DATABASE apim_db;" &&
     run_sql_on_container "$apim_container" "CREATE LOGIN apim_user WITH PASSWORD = 'RootPass123!';" &&
     run_sql_on_container "$apim_container" "USE apim_db; CREATE USER apim_user FOR LOGIN apim_user;" &&
     run_sql_on_container "$apim_container" "USE apim_db; ALTER DATABASE apim_db SET READ_COMMITTED_SNAPSHOT ON;" &&
     run_sql_on_container "$apim_container" "USE apim_db; ALTER ROLE db_owner ADD MEMBER apim_user;"; then
    log_success "APIM database initialization completed"
  else
    log_error "APIM database initialization failed"
    return 1
  fi
  
  # Initialize Shared database
  log_info "Creating Shared database and user..."
  if run_sql_on_container "$shared_container" "CREATE DATABASE shared_db;" &&
     run_sql_on_container "$shared_container" "CREATE LOGIN shared_user WITH PASSWORD = 'RootPass123!';" &&
     run_sql_on_container "$shared_container" "USE shared_db; CREATE USER shared_user FOR LOGIN shared_user;" &&
     run_sql_on_container "$shared_container" "USE shared_db; ALTER DATABASE shared_db SET READ_COMMITTED_SNAPSHOT ON;" &&
     run_sql_on_container "$shared_container" "USE shared_db; ALTER ROLE db_owner ADD MEMBER shared_user;"; then
    log_success "Shared database initialization completed"
  else
    log_error "Shared database initialization failed"
    return 1
  fi
  
  # Run schema creation scripts if they exist
  if [[ -f "./dbscripts/apimgt/mssql.sql" ]]; then
    log_info "Creating APIM database schema from script..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
      # macOS - use external sqlcmd with input file
      if sqlcmd -S localhost,1433 -U SA -P 'RootPass123!' -d apim_db -i "./dbscripts/apimgt/mssql.sql" > /dev/null 2>&1; then
        log_success "APIM database schema creation completed"
      else
        log_warning "APIM database schema creation failed or had warnings"
      fi
    else
      # Linux - copy file to container and execute
      docker cp "./dbscripts/apimgt/mssql.sql" "$apim_container:/tmp/apimgt-schema.sql"
      if docker exec -i "$apim_container" /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P 'RootPass123!' -d apim_db -i /tmp/apimgt-schema.sql > /dev/null 2>&1; then
        log_success "APIM database schema creation completed"
      else
        log_warning "APIM database schema creation failed or had warnings"
      fi
    fi
  fi
  
  if [[ -f "./dbscripts/mssql.sql" ]]; then
    log_info "Creating Shared database schema from script..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
      # macOS - use external sqlcmd with input file
      if sqlcmd -S localhost,1434 -U SA -P 'RootPass123!' -d shared_db -i "./dbscripts/mssql.sql" > /dev/null 2>&1; then
        log_success "Shared database schema creation completed"
      else
        log_warning "Shared database schema creation failed or had warnings"
      fi
    else
      # Linux - copy file to container and execute
      docker cp "./dbscripts/mssql.sql" "$shared_container:/tmp/shared-schema.sql"
      if docker exec -i "$shared_container" /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P 'RootPass123!' -d shared_db -i /tmp/shared-schema.sql > /dev/null 2>&1; then
        log_success "Shared database schema creation completed"
      else
        log_warning "Shared database schema creation failed or had warnings"
      fi
    fi
  fi
}

##############################################
# Utility: Display connection information
##############################################
display_connection_info() {
  echo ""
  echo "========================================="
  echo -e "${CYAN}[DATABASE CONNECTION INFORMATION]${NC}"
  echo "========================================="
  echo ""
  
  log_config "APIM Database Connection Details:"
  echo "  Server: localhost"
  echo "  Port: 1433"
  echo "  Database: apim_db"
  echo "  Username: apim_user"
  echo "  Password: RootPass123!"
  echo "  Connection String: sqlserver://localhost:1433/apim_db"
  echo ""
  
  log_config "Shared Database Connection Details:"
  echo "  Server: localhost"
  echo "  Port: 1434"
  echo "  Database: shared_db"
  echo "  Username: shared_user"
  echo "  Password: RootPass123!"
  echo "  Connection String: sqlserver://localhost:1434/shared_db"
  echo ""
  
  log_config "Administrator Access (Both Databases):"
  echo "  Username: SA"
  echo "  Password: RootPass123!"
  echo "  APIM DB Port: 1433"
  echo "  Shared DB Port: 1434"
  echo ""
  
  log_config "JDBC Connection URLs:"
  echo "  APIM DB: jdbc:sqlserver://localhost:1433;databaseName=apim_db;encrypt=false"
  echo "  Shared DB: jdbc:sqlserver://localhost:1434;databaseName=shared_db;encrypt=false"
  echo ""
  echo "========================================="
}

##############################################
# Main Execution
##############################################
main() {
  log_info "Starting MSSQL database initialization process..."
  
  check_dependencies

  CONFIG_FILE="repository/conf/deployment.toml"
  DBSCRIPTS_DIR="dbscripts"
  APIMGT_DIR="${DBSCRIPTS_DIR}/apimgt"
  REPO_LIB_DIR="repository/components/lib"
  JDBC_URL="https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/12.10.0.jre11/mssql-jdbc-12.10.0.jre11.jar"
  JDBC_DRIVER="mssql-jdbc-12.10.0.jre11.jar"
  BACKUP_DIR=""  # Initialize backup directory variable

  log_info "Updating database configuration in $CONFIG_FILE..."

  # Check if config file exists
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Configuration file $CONFIG_FILE not found!"
    exit 1
  fi

  # Cross-platform sed handling (macOS vs Linux)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_OPT=(-i '')
  else
    SED_OPT=(-i)
  fi

  log_info "Removing existing database configuration blocks..."
  # Delete old DB blocks
  sed "${SED_OPT[@]}" '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed "${SED_OPT[@]}" '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"

  log_info "Adding MSSQL database configurations..."
  # Append MSSQL configs
  cat <<EOF >> "$CONFIG_FILE"

[database.apim_db]
type = "mssql"
url = "jdbc:sqlserver://localhost:1433;databaseName=apim_db;SendStringParametersAsUnicode=false;integratedSecurity=false;encrypt=false"
username = "sa"
password = "RootPass123!"
driver = "com.microsoft.sqlserver.jdbc.SQLServerDriver"
validationQuery = "SELECT 1"
'pool_options.maxActive' = 50
'pool_options.maxWait' = 30000

[database.shared_db]
type = "mssql"
url = "jdbc:sqlserver://localhost:1434;databaseName=shared_db;SendStringParametersAsUnicode=false;integratedSecurity=false;encrypt=false"
username = "sa"
password = "RootPass123!"
driver = "com.microsoft.sqlserver.jdbc.SQLServerDriver"
validationQuery = "SELECT 1"
'pool_options.maxActive' = 100
'pool_options.maxWait' = 10000
'pool_options.validationInterval' = 10000
EOF

  log_success "Database configuration updated successfully"

  # Backup and cleanup database scripts
  log_info "Processing database scripts cleanup..."

  if [[ -d "$DBSCRIPTS_DIR" ]]; then
    # Create backup directory with timestamp
    BACKUP_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_DIR="${DBSCRIPTS_DIR}_backup_${BACKUP_TIMESTAMP}"
    
    log_info "Creating backup of dbscripts directory at $BACKUP_DIR..."
    cp -r "$DBSCRIPTS_DIR" "$BACKUP_DIR"
    log_success "Backup created successfully at $BACKUP_DIR"
    
    # Count files before cleanup
    TOTAL_SQL_FILES=$(find "$DBSCRIPTS_DIR" -type f -name "*.sql" | wc -l | tr -d ' ')
    MSSQL_SQL_FILES=$(find "$DBSCRIPTS_DIR" -type f -name "mssql.sql" | wc -l | tr -d ' ')
    FILES_TO_DELETE=$((TOTAL_SQL_FILES - MSSQL_SQL_FILES))
    
    log_info "Found $TOTAL_SQL_FILES SQL files total, keeping $MSSQL_SQL_FILES mssql.sql files"
    log_info "Cleaning up $FILES_TO_DELETE unnecessary SQL files..."
    
    # Remove unnecessary SQL files (keep only mssql.sql files)
    find "$DBSCRIPTS_DIR" -type f -name "*.sql" ! -name "mssql.sql" -delete
    if [[ -d "$APIMGT_DIR" ]]; then
      find "$APIMGT_DIR" -type f -name "*.sql" ! -name "mssql.sql" -delete
    fi
    
    log_success "Database scripts cleanup completed. Backup available at $BACKUP_DIR"
  else
    log_warning "dbscripts directory not found, skipping cleanup"
  fi

  # Download JDBC driver only if not present
  JDBC_PATH="$REPO_LIB_DIR/$JDBC_DRIVER"

  log_info "Checking MSSQL JDBC driver availability..."

  # Create lib directory if it doesn't exist
  if [[ ! -d "$REPO_LIB_DIR" ]]; then
    log_info "Creating lib directory: $REPO_LIB_DIR"
    mkdir -p "$REPO_LIB_DIR"
  fi

  # Check if JDBC driver already exists
  if [[ -f "$JDBC_PATH" ]]; then
    log_success "MSSQL JDBC driver already exists at $JDBC_PATH"
    log_info "Verifying driver file integrity..."
    
    # Cross-platform file size check
    if [[ "$OSTYPE" == "darwin"* ]]; then
      FILE_SIZE=$(stat -f%z "$JDBC_PATH" 2>/dev/null || echo "0")
    else
      FILE_SIZE=$(stat -c%s "$JDBC_PATH" 2>/dev/null || echo "0")
    fi
    
    if [[ "$FILE_SIZE" -gt 1000000 ]]; then
      log_success "JDBC driver file appears to be valid (size: $FILE_SIZE bytes)"
    else
      log_warning "JDBC driver file seems corrupted or incomplete (size: $FILE_SIZE bytes)"
      log_info "Removing corrupted file and re-downloading..."
      rm -f "$JDBC_PATH"
    fi
  fi

  # Download JDBC driver if not present or corrupted
  if [[ ! -f "$JDBC_PATH" ]]; then
    log_info "Downloading MSSQL JDBC driver from $JDBC_URL..."
    
    # Download to temporary location first using curl
    TEMP_DRIVER="/tmp/$JDBC_DRIVER"
    if curl -s -L -o "$TEMP_DRIVER" "$JDBC_URL"; then
      log_success "JDBC driver downloaded successfully"
      
      # Verify downloaded file
      if [[ "$OSTYPE" == "darwin"* ]]; then
        TEMP_FILE_SIZE=$(stat -f%z "$TEMP_DRIVER" 2>/dev/null || echo "0")
      else
        TEMP_FILE_SIZE=$(stat -c%s "$TEMP_DRIVER" 2>/dev/null || echo "0")
      fi
      
      if [[ "$TEMP_FILE_SIZE" -gt 1000000 ]]; then
        log_info "Moving JDBC driver to $REPO_LIB_DIR..."
        mv "$TEMP_DRIVER" "$JDBC_PATH"
        log_success "MSSQL JDBC driver installed successfully at $JDBC_PATH"
      else
        log_error "Downloaded JDBC driver appears to be corrupted (size: $TEMP_FILE_SIZE bytes)"
        rm -f "$TEMP_DRIVER"
        exit 1
      fi
    else
      log_error "Failed to download MSSQL JDBC driver"
      exit 1
    fi
  fi

  log_info "Starting Docker containers..."
  if $DOCKER_COMPOSE_CMD up -d; then
    log_success "MSSQL Docker containers started successfully"
    
    # Wait a moment and check container status
    sleep 3
    log_info "Checking container status..."
    $DOCKER_COMPOSE_CMD ps
    
    # Initialize databases using direct container execution
    if ! initialize_databases; then
      log_error "Database initialization failed"
      exit 1
    fi
  else
    log_error "Failed to start MSSQL Docker containers"
    
    # If container startup failed, still restore the backup if it exists
    if [[ -n "$BACKUP_DIR" ]] && [[ -d "$BACKUP_DIR" ]]; then
      log_info "Restoring dbscripts directory from backup due to failure..."
      if [[ -d "$DBSCRIPTS_DIR" ]]; then
        rm -rf "$DBSCRIPTS_DIR"
      fi
      cp -r "$BACKUP_DIR" "$DBSCRIPTS_DIR"
      rm -rf "$BACKUP_DIR"
      log_success "dbscripts directory restored from backup"
    fi
    
    exit 1
  fi

  log_success "MSSQL database initialization process completed!"
  
  # Display connection information
  display_connection_info

  # Restore dbscripts directory from backup and cleanup
  if [[ -n "$BACKUP_DIR" ]] && [[ -d "$BACKUP_DIR" ]]; then
    log_info "Restoring dbscripts directory from backup..."
    
    # Remove the modified dbscripts directory
    if [[ -d "$DBSCRIPTS_DIR" ]]; then
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

  echo ""
  log_success "Setup completed successfully. You can now use the connection details above to connect to your databases."
}

main "$@"
