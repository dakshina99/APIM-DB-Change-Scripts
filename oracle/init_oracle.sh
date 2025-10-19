#!/bin/bash

set -euo pipefail

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

log_info "======================================"
log_info "Oracle Database Setup for WSO2 APIM"
log_info "======================================"
log_info "Starting Oracle database initialization process..."


# Detect OS
OS=$(uname -s)
log_info "Detected OS: $OS"

## Dependency install logic removed as requested
log_info "Checking environment..."
if [[ "$OS" == "Darwin" ]]; then
  log_info "macOS detected. Checking for other Docker engines (Rancher Desktop)..."
  # Stop Rancher Desktop if running
  if pgrep -x "Rancher Desktop" > /dev/null; then
    log_info "Rancher Desktop is running. Attempting to stop it..."
    osascript -e 'quit app "Rancher Desktop"'
    sleep 5
    log_success "Rancher Desktop stopped."
  else
    log_info "Rancher Desktop is not running."
  fi
  log_info "Checking Colima status..."
  if colima status | grep -q 'Running'; then
    log_success "Colima is already running."
  else
    log_info "Starting Colima with x86_64 architecture, 6GB RAM, and 6 CPUs..."
    colima start --arch x86_64 --memory 6 --cpu 6
    log_success "Colima started successfully."
  fi
else
  log_info "Non-macOS system detected. Skipping Colima setup."
fi
log_success "Environment check complete."

# Config file
CONFIG_FILE="repository/conf/deployment.toml"
log_info "Updating database configuration in $CONFIG_FILE..."

if [[ "$OS" == "Darwin" ]]; then
  sed -i '' '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed -i '' '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"
else
  sed -i '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed -i '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"
fi
log_success "Removed old database configurations."

log_info "Adding Oracle database configurations..."
cat <<EOF >> "$CONFIG_FILE"

[database.apim_db]
type = "oracle"
url = "jdbc:oracle:thin:@localhost:1521/XE"
username = "APIM_DB"
password = "apimpass"
driver = "oracle.jdbc.driver.OracleDriver"
validationQuery = "SELECT 1 FROM DUAL"

[database.shared_db]
type = "oracle"
url = "jdbc:oracle:thin:@localhost:1522/XE"
username = "SHARED_DB"
password = "sharedpass"
driver = "oracle.jdbc.driver.OracleDriver"
validationQuery = "SELECT 1 FROM DUAL"
EOF
log_success "Oracle database configurations added successfully."

# Clean SQL files
log_info "Managing database scripts..."
DBSCRIPTS_DIR="dbscripts"
APIMGT_DIR="${DBSCRIPTS_DIR}/apimgt"
USER_DIR="${DBSCRIPTS_DIR}/user"
APIM_USER_FILE="${USER_DIR}/apim_user.sql"
SHARED_USER_FILE="${USER_DIR}/shared_user.sql"

# Create backup of dbscripts directory if it exists
if [ -d "$DBSCRIPTS_DIR" ]; then
  BACKUP_DIR="${DBSCRIPTS_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
  log_info "Creating backup of $DBSCRIPTS_DIR as $BACKUP_DIR..."
  cp -r "$DBSCRIPTS_DIR" "$BACKUP_DIR"
  log_success "Backup created successfully at $BACKUP_DIR"
  log_info "Cleaning unnecessary SQL files from $DBSCRIPTS_DIR..."
  # Remove all SQL files except oracle.sql files
  find "$DBSCRIPTS_DIR" -type f -name "*.sql" ! -name "oracle.sql" -delete 2>/dev/null || true
  find "$APIMGT_DIR" -type f -name "*.sql" ! -name "oracle.sql" -delete 2>/dev/null || true
  log_success "Cleaned SQL files (kept oracle.sql files)."
else
  log_warning "No existing $DBSCRIPTS_DIR directory found."
fi

log_info "Creating Oracle user creation scripts..."
mkdir -p "$USER_DIR"
log_success "Created directory: $USER_DIR"

log_info "Writing APIM user creation script..."
cat <<EOF > "$APIM_USER_FILE"
-- APIM_USER
CREATE USER APIM_DB IDENTIFIED BY apimpass QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE TO APIM_DB;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE TRIGGER, CREATE PROCEDURE TO APIM_DB;
EOF

log_info "Writing SHARED user creation script..."
cat <<EOF > "$SHARED_USER_FILE"
-- SHARED_USER
CREATE USER SHARED_DB IDENTIFIED BY sharedpass QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE TO SHARED_DB;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE TRIGGER, CREATE PROCEDURE TO SHARED_DB;
EOF

log_success "Oracle user creation scripts written to $APIM_USER_FILE and $SHARED_USER_FILE"

log_info "Managing Oracle JDBC driver..."
REPO_LIB_DIR="repository/components/lib"
JDBC_URL="https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc11/23.7.0.25.01/ojdbc11-23.7.0.25.01.jar"
JDBC_DRIVER="ojdbc11-23.7.0.25.01.jar"
JDBC_DRIVER_PATH="$REPO_LIB_DIR/$JDBC_DRIVER"

# Create lib directory if it doesn't exist
mkdir -p "$REPO_LIB_DIR"
log_success "Ensured lib directory exists: $REPO_LIB_DIR"

# Check if JDBC driver already exists
if [ -f "$JDBC_DRIVER_PATH" ]; then
  log_success "Oracle JDBC driver already exists at $JDBC_DRIVER_PATH"
  log_info "Skipping download."
else
  log_info "Oracle JDBC driver not found. Downloading from Maven repository..."
  log_info "URL: $JDBC_URL"
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

log_info "Creating database setup scripts..."
log_info "Writing APIM database setup script..."
cat <<'EOF' > wait-and-run-apim.sh
#!/bin/bash
set -e

echo "Running APIM user script..."
docker exec -i apim_db_container_oracle bash -c "echo -e '@/scripts/user/apim_user.sql\nEXIT;' | sqlplus -s sys/apimpass@//apim_db_container_oracle:1521/XE as sysdba"
echo "Running APIM DB script..."
docker exec -it apim_db_container_oracle bash -c "echo -e '@/scripts/apimgt/oracle.sql\nEXIT;' | sqlplus -s APIM_DB/apimpass@//apim_db_container_oracle:1521/XE"

echo "APIM database setup completed."
EOF

chmod +x wait-and-run-apim.sh
log_success "Created executable script: wait-and-run-apim.sh"

log_info "Writing SHARED database setup script..."
cat <<'EOF' > wait-and-run-shared.sh
#!/bin/bash
set -e

echo "Running SHARED user script..."
docker exec -it shared_db_container_oracle bash -c "echo -e '@/scripts/user/shared_user.sql\nEXIT;' | sqlplus -s sys/sharedpass@//shared_db_container_oracle:1521/XE as sysdba"
echo "Running SHARED DB script..."
docker exec -it shared_db_container_oracle bash -c "echo -e '@/scripts/oracle.sql\nEXIT;' | sqlplus -s SHARED_DB/sharedpass@//shared_db_container_oracle:1521/XE"

echo "SHARED database setup completed."
EOF

chmod +x wait-and-run-shared.sh
log_success "Created executable script: wait-and-run-shared.sh"

log_info "Starting Docker containers..."
log_info "Running docker compose up -d..."
docker compose -f docker-compose.yaml up -d

log_info "Waiting for Oracle databases to become available..."
log_info "This may take up to 2 minutes for Oracle to fully initialize..."
sleep 120
log_success "Oracle databases should now be available."

log_info "Executing database setup scripts..."
log_info "Setting up APIM database..."
./wait-and-run-apim.sh

log_info "Setting up SHARED database..."
./wait-and-run-shared.sh

log_info "Restoring dbscripts directory from backup..."
if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
  log_info "Removing modified dbscripts directory..."
  rm -rf "$DBSCRIPTS_DIR"
  log_info "Restoring dbscripts from backup: $BACKUP_DIR..."
  mv "$BACKUP_DIR" "$DBSCRIPTS_DIR"
  log_success "dbscripts directory restored successfully."
  log_info "Backup cleanup completed."
else
  log_warning "No backup directory found to restore from."
fi

log_info "======================================"
log_success "Oracle Setup Complete!"
log_info "======================================"
log_success "Oracle containers and user creation completed successfully."
log_info "Summary:"
log_info "   - Oracle containers are running"
log_info "   - APIM database connection details:"
log_info "       Host: localhost"
log_info "       Port: 1521"
log_info "       SID: XE"
log_info "       Username: APIM_DB"
log_info "       Password: apimpass"
log_info "       JDBC URL: jdbc:oracle:thin:@localhost:1521/XE"
log_info "   - SHARED database connection details:"
log_info "       Host: localhost"
log_info "       Port: 1522"
log_info "       SID: XE"
log_info "       Username: SHARED_DB"
log_info "       Password: sharedpass"
log_info "       JDBC URL: jdbc:oracle:thin:@localhost:1522/XE"
log_info "   - JDBC driver installed in $REPO_LIB_DIR"
log_info "   - Database configurations updated in $CONFIG_FILE"
log_info "   - dbscripts directory restored to original state"
log_info "======================================"
