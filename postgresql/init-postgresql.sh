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
install_if_missing wget wget
install_if_missing docker-compose docker-compose
install_if_missing find findutils

# Check for docker
if ! command -v docker &> /dev/null; then
  echo "Docker is not installed. Please install Docker first."
  exit 1
fi

# Config file
CONFIG_FILE="repository/conf/deployment.toml"

# sed compatibility: use BSD/macOS version
if [[ "$OS" == "Darwin" ]]; then
  sed -i '' '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed -i '' '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"
else
  sed -i '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed -i '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"
fi

# Append DB configs
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

# Clean SQL files
DBSCRIPTS_DIR="dbscripts"
APIMGT_DIR="${DBSCRIPTS_DIR}/apimgt"

find "$DBSCRIPTS_DIR" -type f -name "*.sql" ! -name "postgresql.sql" -delete
find "$APIMGT_DIR" -type f -name "*.sql" ! -name "postgresql.sql" -delete

echo "Updated deployment.toml and cleaned SQL files."

# JDBC download
REPO_LIB_DIR="repository/components/lib"
JDBC_URL="https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar"
JDBC_DRIVER="postgresql-42.7.4.jar"

echo "Downloading JDBC driver..."
wget -O "$JDBC_DRIVER" "$JDBC_URL"
mv "$JDBC_DRIVER" "$REPO_LIB_DIR"

echo "JDBC driver placed in $REPO_LIB_DIR."

# Start Docker containers
docker-compose up -d

echo "PostgreSQL containers started successfully."
