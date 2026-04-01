#!/bin/bash

set -euo pipefail

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

log_info "======================================"
log_info "Oracle Database Setup for WSO2 APIM"
log_info "======================================"
log_info "Starting Oracle database initialization process..."
[[ "$VERBOSE" == "false" ]] && log_info "(Run with -v for verbose output)"

# Detect OS
OS=$(uname -s)
log_verbose "Detected OS: $OS"

if ! docker info > /dev/null 2>&1; then
  log_error "Docker is not running. Please start Docker (Rancher Desktop, Docker Desktop, etc.) and re-run the script."
  exit 1
fi
log_success "Docker is available."

# Config file
CONFIG_FILE="repository/conf/deployment.toml"
log_verbose "Updating database configuration in $CONFIG_FILE..."

if [[ "$OS" == "Darwin" ]]; then
  sed -i '' '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed -i '' '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"
else
  sed -i '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed -i '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"
fi
log_verbose "Removed old database configurations."

log_verbose "Adding Oracle database configurations..."
cat <<EOF >> "$CONFIG_FILE"

[database.apim_db]
type = "oracle"
url = "jdbc:oracle:thin:@localhost:1521/apim_db"
username = "APIM_DB"
password = "apimpass"
driver = "oracle.jdbc.driver.OracleDriver"
validationQuery = "SELECT 1 FROM DUAL"

[database.shared_db]
type = "oracle"
url = "jdbc:oracle:thin:@localhost:1521/shared_db"
username = "SHARED_DB"
password = "sharedpass"
driver = "oracle.jdbc.driver.OracleDriver"
validationQuery = "SELECT 1 FROM DUAL"
EOF
log_success "Database configurations updated in $CONFIG_FILE."

# Clean SQL files
log_verbose "Managing database scripts..."
DBSCRIPTS_DIR="dbscripts"
APIMGT_DIR="${DBSCRIPTS_DIR}/apimgt"
USER_DIR="${DBSCRIPTS_DIR}/user"
APIM_USER_FILE="${USER_DIR}/apim_user.sql"
SHARED_USER_FILE="${USER_DIR}/shared_user.sql"

# Create backup of dbscripts directory if it exists
if [ -d "$DBSCRIPTS_DIR" ]; then
  BACKUP_DIR="${DBSCRIPTS_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
  log_verbose "Creating backup of $DBSCRIPTS_DIR as $BACKUP_DIR..."
  cp -r "$DBSCRIPTS_DIR" "$BACKUP_DIR"
  log_success "Backup created at $BACKUP_DIR"
  log_verbose "Cleaning unnecessary SQL files..."
  # Remove all SQL files except oracle.sql files
  find "$DBSCRIPTS_DIR" -type f -name "*.sql" ! -name "oracle.sql" -delete 2>/dev/null || true
  find "$APIMGT_DIR" -type f -name "*.sql" ! -name "oracle.sql" -delete 2>/dev/null || true
else
  log_warning "No existing $DBSCRIPTS_DIR directory found."
fi

log_verbose "Creating Oracle user creation scripts..."
mkdir -p "$USER_DIR"
log_verbose "Writing APIM user creation script..."
cat <<EOF > "$APIM_USER_FILE"
-- APIM_USER
CREATE USER APIM_DB IDENTIFIED BY apimpass QUOTA UNLIMITED ON USERS QUOTA UNLIMITED ON SYSTEM;
GRANT CONNECT, RESOURCE TO APIM_DB;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE TRIGGER, CREATE PROCEDURE TO APIM_DB;
GRANT UNLIMITED TABLESPACE TO APIM_DB;
EOF

log_verbose "Writing SHARED user creation script..."
cat <<EOF > "$SHARED_USER_FILE"
-- SHARED_USER
CREATE USER SHARED_DB IDENTIFIED BY sharedpass QUOTA UNLIMITED ON USERS QUOTA UNLIMITED ON SYSTEM;
GRANT CONNECT, RESOURCE TO SHARED_DB;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE TRIGGER, CREATE PROCEDURE TO SHARED_DB;
GRANT UNLIMITED TABLESPACE TO SHARED_DB;
EOF

log_verbose "Oracle user creation scripts written to $APIM_USER_FILE and $SHARED_USER_FILE"

CREATE_SHARED_PDB_FILE="${USER_DIR}/create_shared_pdb.sql"
log_verbose "Writing shared_db PDB creation script..."
cat <<EOF > "$CREATE_SHARED_PDB_FILE"
CREATE PLUGGABLE DATABASE shared_db
  ADMIN USER pdb_admin IDENTIFIED BY apimpass
  FILE_NAME_CONVERT = ('/opt/oracle/oradata/FREE/pdbseed/', '/opt/oracle/oradata/FREE/shared_db/');
ALTER PLUGGABLE DATABASE shared_db OPEN;
ALTER PLUGGABLE DATABASE shared_db SAVE STATE;
ALTER SESSION SET CONTAINER = shared_db;
CREATE TABLESPACE users DATAFILE '/opt/oracle/oradata/FREE/shared_db/users01.dbf' SIZE 50M AUTOEXTEND ON NEXT 10M MAXSIZE UNLIMITED;
EXIT;
EOF
log_verbose "PDB creation script written to $CREATE_SHARED_PDB_FILE"

log_verbose "Managing Oracle JDBC driver..."
REPO_LIB_DIR="repository/components/lib"
JDBC_URL="https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc11/23.7.0.25.01/ojdbc11-23.7.0.25.01.jar"
JDBC_DRIVER="ojdbc11-23.7.0.25.01.jar"
JDBC_DRIVER_PATH="$REPO_LIB_DIR/$JDBC_DRIVER"

# Create lib directory if it doesn't exist
mkdir -p "$REPO_LIB_DIR"

# Check if JDBC driver already exists
if [ -f "$JDBC_DRIVER_PATH" ]; then
  log_success "Oracle JDBC driver present at $JDBC_DRIVER_PATH"
else
  log_info "Downloading Oracle JDBC driver..."
  log_verbose "URL: $JDBC_URL"
  # Download to temporary location first
  TEMP_DRIVER="/tmp/$JDBC_DRIVER"
  if curl -L -o "$TEMP_DRIVER" "$JDBC_URL"; then
    # Move to final location
    mv "$TEMP_DRIVER" "$JDBC_DRIVER_PATH"
    log_success "JDBC driver downloaded and placed in $REPO_LIB_DIR"
  else
    log_error "Failed to download JDBC driver. Please check your internet connection."
    exit 1
  fi
fi

log_verbose "Creating database setup scripts..."
log_verbose "Writing APIM database setup script..."
cat <<'EOF' > wait-and-run-apim.sh
#!/bin/bash
set -e

echo "Creating shared_db PDB..."
docker exec -i oracle_db_container sqlplus -s "sys/apimpass@//localhost:1521/FREE AS SYSDBA" <<SQLEOF
@/scripts/user/create_shared_pdb.sql
EXIT;
SQLEOF

echo "Running APIM user script..."
docker exec -i oracle_db_container sqlplus -s "sys/apimpass@//localhost:1521/apim_db AS SYSDBA" <<SQLEOF
@/scripts/user/apim_user.sql
EXIT;
SQLEOF

echo "Running APIM DB script..."
docker exec -i oracle_db_container sqlplus -s "APIM_DB/apimpass@//localhost:1521/apim_db" <<SQLEOF
@/scripts/apimgt/oracle.sql
EXIT;
SQLEOF

echo "APIM database setup completed."
EOF

chmod +x wait-and-run-apim.sh
log_verbose "Created wait-and-run-apim.sh"

log_verbose "Writing SHARED database setup script..."
cat <<'EOF' > wait-and-run-shared.sh
#!/bin/bash
set -e

echo "Running SHARED user script..."
docker exec -i oracle_db_container sqlplus -s "sys/apimpass@//localhost:1521/shared_db AS SYSDBA" <<SQLEOF
@/scripts/user/shared_user.sql
EXIT;
SQLEOF

echo "Running SHARED DB script..."
docker exec -i oracle_db_container sqlplus -s "SHARED_DB/sharedpass@//localhost:1521/shared_db" <<SQLEOF
@/scripts/oracle.sql
EXIT;
SQLEOF

echo "SHARED database setup completed."
EOF

chmod +x wait-and-run-shared.sh
log_verbose "Created wait-and-run-shared.sh"

log_info "Starting Docker containers..."
log_verbose "Cleaning up any existing Oracle containers..."
for container in apim_db_container_oracle shared_db_container_oracle oracle_db_container; do
  if docker ps -a --format '{{.Names}}' | grep -q "^${container}$" 2>/dev/null; then
    log_verbose "Removing existing container: $container"
    docker rm -f "$container" 2>/dev/null || true
  fi
done
log_verbose "Running docker compose up -d..."
docker compose -f docker-compose.yaml up -d

log_info "Waiting for Oracle to become available (this may take a few minutes)..."
wait_for_oracle() {
  local container=$1
  local max_attempts=60
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    if docker exec "$container" healthcheck.sh > /dev/null 2>&1; then
      log_success "$container is ready."
      return 0
    fi
    log_verbose "Waiting for $container... (attempt $attempt/$max_attempts)"
    if (( attempt % 10 == 0 )); then
      log_info "Still waiting for $container... ($((attempt * 5))s elapsed)"
    fi
    sleep 5
    attempt=$((attempt + 1))
  done
  log_error "$container did not become ready in time."
  exit 1
}
wait_for_oracle oracle_db_container

log_verbose "Executing database setup scripts..."
log_info "Setting up APIM database..."
./wait-and-run-apim.sh
log_success "APIM database setup complete."

log_info "Setting up SHARED database..."
./wait-and-run-shared.sh
log_success "SHARED database setup complete."

log_verbose "Restoring dbscripts directory from backup..."
if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
  log_verbose "Removing modified dbscripts directory..."
  rm -rf "$DBSCRIPTS_DIR"
  log_verbose "Restoring dbscripts from backup: $BACKUP_DIR..."
  mv "$BACKUP_DIR" "$DBSCRIPTS_DIR"
  log_success "Restored dbscripts to original state."
else
  log_warning "No backup directory found to restore from."
fi

log_info "======================================"
log_success "Oracle Setup Complete!"
log_info "======================================"
log_success "Oracle container and user creation completed successfully."
log_info "Summary:"
log_info "   - Single Oracle container running (2 PDBs: apim_db and shared_db)"
log_info "   - APIM database connection details:"
log_info "       Host: localhost"
log_info "       Port: 1521"
log_info "       Service: apim_db"
log_info "       Username: APIM_DB"
log_info "       Password: apimpass"
log_info "       JDBC URL: jdbc:oracle:thin:@localhost:1521/apim_db"
log_info "   - SHARED database connection details:"
log_info "       Host: localhost"
log_info "       Port: 1521"
log_info "       Service: shared_db"
log_info "       Username: SHARED_DB"
log_info "       Password: sharedpass"
log_info "       JDBC URL: jdbc:oracle:thin:@localhost:1521/shared_db"
log_verbose "   - JDBC driver: $JDBC_DRIVER_PATH"
log_verbose "   - Config: $CONFIG_FILE"
log_info "======================================"
