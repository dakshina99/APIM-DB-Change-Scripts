#!/bin/bash

set -e

# Detect OS
OS=$(uname -s)

# Function to install missing commands
install_if_missing() {
  local cmd=$1
  local pkg=$2

  if ! command -v "$cmd" &> /dev/null; then
    echo "$cmd not found. Installing $pkg..."

    if [[ "$OS" == "Darwin" ]]; then
      if ! command -v brew &> /dev/null; then
        echo "Homebrew not found. Please install it from https://brew.sh/"
        exit 1
      fi
      brew install "$pkg"
    elif command -v apt-get &> /dev/null; then
      sudo apt-get update && sudo apt-get install -y "$pkg"
    elif command -v yum &> /dev/null; then
      sudo yum install -y "$pkg"
    else
      echo "Unsupported package manager. Please install $pkg manually."
      exit 1
    fi
  else
    echo "$cmd is already installed."
  fi
}

# Required tools
install_if_missing qemu qemu
install_if_missing colima colima
install_if_missing wget wget
install_if_missing docker-compose docker-compose
install_if_missing find findutils

# Config file
CONFIG_FILE="repository/conf/deployment.toml"

# Clean old DB config
if [[ "$OS" == "Darwin" ]]; then
  sed -i '' '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed -i '' '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"
else
  sed -i '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed -i '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"
fi

# Append Oracle DB configs
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

# Clean SQL files
DBSCRIPTS_DIR="dbscripts"
APIMGT_DIR="${DBSCRIPTS_DIR}/apimgt"
USER_DIR="${DBSCRIPTS_DIR}/user"
APIM_USER_FILE="${USER_DIR}/apim_user.sql"
SHARED_USER_FILE="${USER_DIR}/shared_user.sql"

find "$DBSCRIPTS_DIR" -type f -name "*.sql" ! -name "oracle.sql" -delete
find "$APIMGT_DIR" -type f -name "*.sql" ! -name "oracle.sql" -delete

echo "Updated deployment.toml and cleaned SQL files."

# Start colima
colima status | grep -q 'Running' || colima start --arch x86_64 --memory 6 --cpu 6

# Create user SQL scripts
mkdir -p "$USER_DIR"
cat <<EOF > "$APIM_USER_FILE"
-- APIM_USER
CREATE USER APIM_DB IDENTIFIED BY apimpass QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE TO APIM_DB;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE TRIGGER, CREATE PROCEDURE TO APIM_DB;
EOF

cat <<EOF > "$SHARED_USER_FILE"
-- SHARED_USER
CREATE USER SHARED_DB IDENTIFIED BY sharedpass QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE TO SHARED_DB;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE TRIGGER, CREATE PROCEDURE TO SHARED_DB;
EOF

echo "Oracle user creation scripts written to /dbscripts/apimgt and /dbscripts."

# JDBC driver download
REPO_LIB_DIR="repository/components/lib"
JDBC_URL="https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc11/23.7.0.25.01/ojdbc11-23.7.0.25.01.jar"
JDBC_DRIVER="ojdbc11-23.7.0.25.01.jar"

echo "Downloading Oracle JDBC driver..."
wget --no-cookies --no-check-certificate --header "Cookie: oraclelicense=accept-securebackup-cookie" -O "$JDBC_DRIVER" "$JDBC_URL"
mkdir -p "$REPO_LIB_DIR"
mv "$JDBC_DRIVER" "$REPO_LIB_DIR"

echo "JDBC driver placed in $REPO_LIB_DIR."

# Write wait-and-run script
cat <<'EOF' > wait-and-run-apim.sh
#!/bin/bash
set -e

echo "Running APIM user script..."
docker exec -i apim_db_container bash -c "echo -e '@/scripts/user/apim_user.sql\nEXIT;' | sqlplus -s sys/apimpass@//apim_db_container:1521/XE as sysdba"
echo "Running APIM DB script..."
docker exec -it apim_db_container bash -c "echo -e '@/scripts/apimgt/oracle.sql\nEXIT;' | sqlplus -s APIM_DB/apimpass@//apim_db_container:1521/XE"

echo "Database setup completed."
EOF

chmod +x wait-and-run-apim.sh

# Write wait-and-run script
cat <<'EOF' > wait-and-run-shared.sh
#!/bin/bash
set -e

echo "Running SHARED user script..."
docker exec -it shared_db_container bash -c "echo -e '@/scripts/user/shared_user.sql\nEXIT;' | sqlplus -s sys/sharedpass@//shared_db_container:1521/XE as sysdba"
echo "Running SHARED DB script..."
docker exec -it shared_db_container bash -c "echo -e '@/scripts/oracle.sql\nEXIT;' | sqlplus -s SHARED_DB/sharedpass@//shared_db_container:1521/XE"

echo "Database setup completed."
EOF

chmod +x wait-and-run-shared.sh

# Start Docker
docker-compose -f docker-compose.yaml up -d

# Wait for 60s to ensure Oracle is up
echo "Waiting for Oracle to become available..."
sleep 120
echo "Oracle is now available."

# Run the scripts
./wait-and-run-apim.sh
./wait-and-run-shared.sh

echo "Oracle containers and user creation started successfully."
