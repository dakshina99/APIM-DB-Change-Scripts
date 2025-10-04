#!/bin/bash

set -e

echo "======================================"
echo "Oracle Database Setup for WSO2 APIM"
echo "======================================"
echo "Starting Oracle database initialization process..."

# Detect OS
OS=$(uname -s)
echo "Detected OS: $OS"

# Function to install missing commands
install_if_missing() {
  local cmd=$1
  local pkg=$2

  echo "Checking if $cmd is installed..."
  if ! command -v "$cmd" &> /dev/null; then
    echo "⚠️  $cmd not found. Installing $pkg..."

    if [[ "$OS" == "Darwin" ]]; then
      if ! command -v brew &> /dev/null; then
        echo "❌ Homebrew not found. Please install it from https://brew.sh/"
        exit 1
      fi
      echo "📦 Installing $pkg using Homebrew..."
      brew install "$pkg"
    elif command -v apt-get &> /dev/null; then
      echo "📦 Installing $pkg using apt-get..."
      sudo apt-get update && sudo apt-get install -y "$pkg"
    elif command -v yum &> /dev/null; then
      echo "📦 Installing $pkg using yum..."
      sudo yum install -y "$pkg"
    else
      echo "❌ Unsupported package manager. Please install $pkg manually."
      exit 1
    fi
    echo "✅ $pkg installed successfully."
  else
    echo "✅ $cmd is already installed."
  fi
}

# Required tools
echo ""
echo "🔧 Checking and installing required tools..."
install_if_missing qemu qemu
install_if_missing colima colima
install_if_missing wget wget
install_if_missing docker-compose docker-compose
install_if_missing find findutils
echo "✅ All required tools are available."

# Config file
CONFIG_FILE="repository/conf/deployment.toml"
echo ""
echo "📝 Updating database configuration in $CONFIG_FILE..."

# Clean old DB config
if [[ "$OS" == "Darwin" ]]; then
  sed -i '' '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed -i '' '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"
else
  sed -i '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed -i '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"
fi
echo "🗑️  Removed old database configurations."

# Append Oracle DB configs
echo "➕ Adding Oracle database configurations..."
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
echo "✅ Oracle database configurations added successfully."

# Clean SQL files
echo ""
echo "🗂️  Managing database scripts..."
DBSCRIPTS_DIR="dbscripts"
APIMGT_DIR="${DBSCRIPTS_DIR}/apimgt"
USER_DIR="${DBSCRIPTS_DIR}/user"
APIM_USER_FILE="${USER_DIR}/apim_user.sql"
SHARED_USER_FILE="${USER_DIR}/shared_user.sql"

# Create backup of dbscripts directory if it exists
if [ -d "$DBSCRIPTS_DIR" ]; then
    BACKUP_DIR="${DBSCRIPTS_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
    echo "📦 Creating backup of $DBSCRIPTS_DIR as $BACKUP_DIR..."
    cp -r "$DBSCRIPTS_DIR" "$BACKUP_DIR"
    echo "✅ Backup created successfully at $BACKUP_DIR"
    
    echo "🗑️  Cleaning unnecessary SQL files from $DBSCRIPTS_DIR..."
    # Remove all SQL files except oracle.sql files
    find "$DBSCRIPTS_DIR" -type f -name "*.sql" ! -name "oracle.sql" -delete 2>/dev/null || true
    find "$APIMGT_DIR" -type f -name "*.sql" ! -name "oracle.sql" -delete 2>/dev/null || true
    echo "✅ Cleaned SQL files (kept oracle.sql files)."
else
    echo "ℹ️  No existing $DBSCRIPTS_DIR directory found."
fi

# Start colima
echo ""
echo "🐳 Starting Colima (Docker runtime)..."
if colima status | grep -q 'Running'; then
    echo "✅ Colima is already running."
else
    echo "🚀 Starting Colima with x86_64 architecture, 6GB RAM, and 6 CPUs..."
    colima start --arch x86_64 --memory 6 --cpu 6
    echo "✅ Colima started successfully."
fi

# Create user SQL scripts
echo ""
echo "📝 Creating Oracle user creation scripts..."
mkdir -p "$USER_DIR"
echo "📁 Created directory: $USER_DIR"

echo "✏️  Writing APIM user creation script..."
cat <<EOF > "$APIM_USER_FILE"
-- APIM_USER
CREATE USER APIM_DB IDENTIFIED BY apimpass QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE TO APIM_DB;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE TRIGGER, CREATE PROCEDURE TO APIM_DB;
EOF

echo "✏️  Writing SHARED user creation script..."
cat <<EOF > "$SHARED_USER_FILE"
-- SHARED_USER
CREATE USER SHARED_DB IDENTIFIED BY sharedpass QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE TO SHARED_DB;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE TRIGGER, CREATE PROCEDURE TO SHARED_DB;
EOF

echo "✅ Oracle user creation scripts written to $APIM_USER_FILE and $SHARED_USER_FILE"

# JDBC driver download
echo ""
echo "📥 Managing Oracle JDBC driver..."
REPO_LIB_DIR="repository/components/lib"
JDBC_URL="https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc11/23.7.0.25.01/ojdbc11-23.7.0.25.01.jar"
JDBC_DRIVER="ojdbc11-23.7.0.25.01.jar"
JDBC_DRIVER_PATH="$REPO_LIB_DIR/$JDBC_DRIVER"

# Create lib directory if it doesn't exist
mkdir -p "$REPO_LIB_DIR"
echo "📁 Ensured lib directory exists: $REPO_LIB_DIR"

# Check if JDBC driver already exists
if [ -f "$JDBC_DRIVER_PATH" ]; then
    echo "✅ Oracle JDBC driver already exists at $JDBC_DRIVER_PATH"
    echo "ℹ️  Skipping download."
else
    echo "📥 Oracle JDBC driver not found. Downloading from Maven repository..."
    echo "🌐 URL: $JDBC_URL"
    
    # Download to temporary location first
    TEMP_DRIVER="/tmp/$JDBC_DRIVER"
    if wget --no-cookies --no-check-certificate --header "Cookie: oraclelicense=accept-securebackup-cookie" -O "$TEMP_DRIVER" "$JDBC_URL"; then
        # Move to final location
        mv "$TEMP_DRIVER" "$JDBC_DRIVER_PATH"
        echo "✅ JDBC driver downloaded and placed in $REPO_LIB_DIR"
    else
        echo "❌ Failed to download JDBC driver. Please check your internet connection."
        exit 1
    fi
fi

# Write wait-and-run script
echo ""
echo "📝 Creating database setup scripts..."
echo "✏️  Writing APIM database setup script..."
cat <<'EOF' > wait-and-run-apim.sh
#!/bin/bash
set -e

echo "🏃 Running APIM user script..."
docker exec -i apim_db_container_oracle bash -c "echo -e '@/scripts/user/apim_user.sql\nEXIT;' | sqlplus -s sys/apimpass@//apim_db_container_oracle:1521/XE as sysdba"
echo "🏃 Running APIM DB script..."
docker exec -it apim_db_container_oracle bash -c "echo -e '@/scripts/apimgt/oracle.sql\nEXIT;' | sqlplus -s APIM_DB/apimpass@//apim_db_container_oracle:1521/XE"

echo "✅ APIM database setup completed."
EOF

chmod +x wait-and-run-apim.sh
echo "✅ Created executable script: wait-and-run-apim.sh"

# Write wait-and-run script
echo "✏️  Writing SHARED database setup script..."
cat <<'EOF' > wait-and-run-shared.sh
#!/bin/bash
set -e

echo "🏃 Running SHARED user script..."
docker exec -it shared_db_container_oracle bash -c "echo -e '@/scripts/user/shared_user.sql\nEXIT;' | sqlplus -s sys/sharedpass@//shared_db_container_oracle:1521/XE as sysdba"
echo "🏃 Running SHARED DB script..."
docker exec -it shared_db_container_oracle bash -c "echo -e '@/scripts/oracle.sql\nEXIT;' | sqlplus -s SHARED_DB/sharedpass@//shared_db_container_oracle:1521/XE"

echo "✅ SHARED database setup completed."
EOF

chmod +x wait-and-run-shared.sh
echo "✅ Created executable script: wait-and-run-shared.sh"

# Start Docker
echo ""
echo "🐳 Starting Docker containers..."
echo "🚀 Running docker-compose up -d..."
docker-compose -f docker-compose.yaml up -d

# Wait for 60s to ensure Oracle is up
echo ""
echo "⏳ Waiting for Oracle databases to become available..."
echo "🕐 This may take up to 2 minutes for Oracle to fully initialize..."
sleep 120
echo "✅ Oracle databases should now be available."

# Run the scripts
echo ""
echo "🚀 Executing database setup scripts..."
echo "📊 Setting up APIM database..."
./wait-and-run-apim.sh

echo "📊 Setting up SHARED database..."
./wait-and-run-shared.sh

# Restore dbscripts directory from backup and cleanup
echo ""
echo "🔄 Restoring dbscripts directory from backup..."
if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
    echo "🗑️  Removing modified dbscripts directory..."
    rm -rf "$DBSCRIPTS_DIR"
    
    echo "📦 Restoring dbscripts from backup: $BACKUP_DIR..."
    mv "$BACKUP_DIR" "$DBSCRIPTS_DIR"
    
    echo "✅ dbscripts directory restored successfully."
    echo "🗑️  Backup cleanup completed."
else
    echo "ℹ️  No backup directory found to restore from."
fi

echo ""
echo "======================================"
echo "✅ Oracle Setup Complete!"
echo "======================================"
echo "🎉 Oracle containers and user creation completed successfully."
echo "📋 Summary:"
echo "   - Oracle containers are running"
echo "   - APIM database configured on port 1521"
echo "   - SHARED database configured on port 1522"
echo "   - JDBC driver installed in $REPO_LIB_DIR"
echo "   - Database configurations updated in $CONFIG_FILE"
echo "   - dbscripts directory restored to original state"
echo "======================================"
