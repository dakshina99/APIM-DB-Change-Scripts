#!/bin/bash

set -euo pipefail

##############################################
# Utility: Install Dependencies
##############################################
install_dependencies() {
  echo "🔍 Checking for required commands..."

  # wget
  if ! command -v wget &>/dev/null; then
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
  fi

  # docker
  if ! command -v docker &>/dev/null; then
    echo "❌ Docker is not installed. Please install Docker first."
    exit 1
  fi

  # docker-compose
  if ! command -v docker-compose &>/dev/null; then
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

  # Db2 JDBC (pure Java type 4)
  JDBC_URL="https://repo1.maven.org/maven2/com/ibm/db2/jcc/11.5.9.0/jcc-11.5.9.0.jar"
  JDBC_DRIVER="jcc-11.5.9.0.jar"

  echo "⚙️  Updating deployment.toml..."

  # Cross-platform sed
  if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_OPT=(-i '')
  else
    SED_OPT=(-i)
  fi

  # Remove old DB blocks
  sed "${SED_OPT[@]}" '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed "${SED_OPT[@]}" '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"

  # Append Db2 configs
  cat <<EOF >>"$CONFIG_FILE"

[database.apim_db]
type = "db2"
url = "jdbc:db2://localhost:50000/apim_db"
username = "db2inst1"
password = "apimpass"
driver = "com.ibm.db2.jcc.DB2Driver"
validationQuery = "SELECT 1 FROM SYSIBM.SYSDUMMY1"

[database.shared_db]
type = "db2"
url = "jdbc:db2://localhost:50001/shareddb"
username = "db2inst1"
password = "sharedpass"
driver = "com.ibm.db2.jcc.DB2Driver"
validationQuery = "SELECT 1 FROM SYSIBM.SYSDUMMY1"
EOF

  echo "🧹 Cleaning up old SQL scripts (keeping only db2.sql)..."
  find "$DBSCRIPTS_DIR" -type f -name "*.sql" ! -name "db2.sql" -delete
  find "$APIMGT_DIR" -type f -name "*.sql" ! -name "db2.sql" -delete

  echo "⬇️  Downloading Db2 JDBC driver..."
  wget -q -O "$JDBC_DRIVER" "$JDBC_URL"

  echo "📦 Installing JDBC driver into $REPO_LIB_DIR..."
  mv "$JDBC_DRIVER" "$REPO_LIB_DIR"

  echo "🚀 Starting Docker containers..."
  docker-compose up -d

  # macOS: install Db2 CLP if needed
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "⚠️  Install Db2 CLP (command line processor) manually on macOS if not already installed."
  fi

  echo "⏳ Waiting for Db2 containers to initialize..."
  sleep 300
  until docker exec -i shared_db_container_db2 su - db2inst1 -c "db2 connect to shareddb"; do
    echo "Waiting for Shared Db2 container to be ready..."
    sleep 10
  done

  until docker exec -i apim_db_container_db2 su - db2inst1 -c "db2 connect to apim_db"; do
    echo "Waiting for APIM Db2 container to be ready..."
    sleep 10
  done

  docker exec -t apim_db_container_db2 su - db2inst1 -c "\
    db2 connect to apim_db user db2inst1 using apimpass; \
    db2 -td/ -f /dbscripts/apimgt/db2.sql"

  docker exec -t shared_db_container_db2 su - db2inst1 -c "\
    db2 connect to shareddb user db2inst1 using sharedpass; \
    db2 -td/ -f /dbscripts/db2.sql"

  echo "✅ Db2 Docker containers started and initialized successfully."
}

main "$@"
