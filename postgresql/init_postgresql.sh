#!/bin/bash

set -euo pipefail

##############################################
# Utility: Install Dependencies
##############################################
install_dependencies() {
  echo "🔍 Checking for required commands..."

  # Check for wget
  if ! command -v wget &> /dev/null; then
    echo "⚠️  wget not found. Installing..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
      brew install wget
    elif [[ -f /etc/debian_version ]]; then
      sudo apt-get update && sudo apt-get install -y wget
    elif [[ -f /etc/redhat-release ]]; then
      sudo yum install -y wget
    else
      echo "❌ Unsupported OS. Please install wget manually."
      exit 1
    fi
  else
    echo "✅ wget is already installed."
  fi

  # Check for docker
  if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first."
    exit 1
  else
    echo "✅ Docker is available."
  fi

  # Check for docker-compose
  if ! command -v docker-compose &> /dev/null; then
    echo "⚠️  docker-compose not found. Installing..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
      brew install docker-compose
    elif [[ -f /etc/debian_version ]]; then
      sudo apt-get update && sudo apt-get install -y docker-compose
    elif [[ -f /etc/redhat-release ]]; then
      sudo yum install -y docker-compose
    else
      echo "❌ Unsupported OS. Please install docker-compose manually."
      exit 1
    fi
  else
    echo "✅ docker-compose is already installed."
  fi

  # Check for find
  if ! command -v find &> /dev/null; then
    echo "⚠️  find not found. Installing findutils..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
      brew install findutils
    elif [[ -f /etc/debian_version ]]; then
      sudo apt-get update && sudo apt-get install -y findutils
    elif [[ -f /etc/redhat-release ]]; then
      sudo yum install -y findutils
    else
      echo "❌ Unsupported OS. Please install findutils manually."
      exit 1
    fi
  else
    echo "✅ find is already installed."
  fi
}

##############################################
# Main Execution
##############################################
main() {
  install_dependencies

  CONFIG_FILE="repository/conf/deployment.toml"
  DBSCRIPTS_DIR="dbscripts"
  APIMGT_DIR="${DBSCRIPTS_DIR}/apimgt"
  REPO_LIB_DIR="repository/components/lib"
  JDBC_URL="https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar"
  JDBC_DRIVER="postgresql-42.7.4.jar"
  BACKUP_DIR="dbscripts_backup_$(date +%Y%m%d_%H%M%S)"

  echo "⚙️  Updating deployment.toml..."

  # Check if config file exists
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ Configuration file $CONFIG_FILE not found!"
    exit 1
  fi

  # Cross-platform sed handling (macOS vs Linux)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_OPT=(-i '')
  else
    SED_OPT=(-i)
  fi

  # Delete old DB blocks
  sed "${SED_OPT[@]}" '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed "${SED_OPT[@]}" '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"

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

  echo "✅ Database configuration updated successfully."

  # Backup dbscripts directory before cleaning
  echo "📂 Creating backup of dbscripts directory..."
  if [[ -d "$DBSCRIPTS_DIR" ]]; then
    cp -r "$DBSCRIPTS_DIR" "$BACKUP_DIR"
    echo "✅ Backup created at $BACKUP_DIR"
    
    echo "🧹 Cleaning up old SQL scripts (keeping only postgresql.sql)..."
    find "$DBSCRIPTS_DIR" -type f -name "*.sql" ! -name "postgresql.sql" -delete
    if [[ -d "$APIMGT_DIR" ]]; then
      find "$APIMGT_DIR" -type f -name "*.sql" ! -name "postgresql.sql" -delete
    fi
    echo "✅ SQL files cleaned successfully."
  else
    echo "⚠️  dbscripts directory not found. Skipping backup and cleanup."
  fi

  # Check if lib directory exists
  if [[ ! -d "$REPO_LIB_DIR" ]]; then
    echo "⚠️  Repository lib directory $REPO_LIB_DIR not found. Creating it..."
    mkdir -p "$REPO_LIB_DIR"
  fi

  # Check if JDBC driver already exists
  JDBC_PATH="$REPO_LIB_DIR/$JDBC_DRIVER"
  if [[ -f "$JDBC_PATH" ]]; then
    echo "✅ PostgreSQL JDBC driver already exists at $JDBC_PATH"
  else
    echo "⬇️  Downloading PostgreSQL JDBC driver..."
    if wget -q -O "$JDBC_DRIVER" "$JDBC_URL"; then
      echo "📦 Installing JDBC driver into $REPO_LIB_DIR..."
      mv "$JDBC_DRIVER" "$REPO_LIB_DIR"
      echo "✅ JDBC driver downloaded and placed in $REPO_LIB_DIR"
    else
      echo "❌ Failed to download JDBC driver!"
      exit 1
    fi
  fi

  echo "🚀 Starting Docker containers..."
  docker-compose up -d

  echo "✅ PostgreSQL containers started successfully."
  sleep 10  # Wait for DBs to initialize

  # Restore dbscripts directory from backup
  if [[ -d "$BACKUP_DIR" ]]; then
    echo "🔄 Restoring dbscripts directory from backup..."
    rm -rf "$DBSCRIPTS_DIR"
    mv "$BACKUP_DIR" "$DBSCRIPTS_DIR"
    echo "✅ dbscripts directory restored from backup."
  fi
}

main "$@"
