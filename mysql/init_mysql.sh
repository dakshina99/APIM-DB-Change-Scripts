#!/bin/bash

set -e

# Detect OS for package installation
install_dependencies() {
  echo "Checking for required commands..."

  # Check for wget
  if ! command -v wget &> /dev/null; then
    echo "wget not found. Installing..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
      brew install wget
    elif [[ -f /etc/debian_version ]]; then
      sudo apt-get update && sudo apt-get install -y wget
    elif [[ -f /etc/redhat-release ]]; then
      sudo yum install -y wget
    else
      echo "Unsupported OS. Please install wget manually."
      exit 1
    fi
  fi

  # Check for docker
  if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Please install Docker first."
    exit 1
  fi

  # Check for docker-compose
  if ! command -v docker-compose &> /dev/null; then
    echo "docker-compose not found. Installing..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
      brew install docker-compose
    elif [[ -f /etc/debian_version ]]; then
      sudo apt-get update && sudo apt-get install -y docker-compose
    elif [[ -f /etc/redhat-release ]]; then
      sudo yum install -y docker-compose
    else
      echo "Unsupported OS. Please install docker-compose manually."
      exit 1
    fi
  fi
}

install_dependencies

# Configuration file path
CONFIG_FILE="repository/conf/deployment.toml"

# Delete existing DB config blocks
sed -i '' '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
sed -i '' '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"

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

# Cleanup unnecessary SQL files
DBSCRIPTS_DIR="dbscripts"
APIMGT_DIR="${DBSCRIPTS_DIR}/apimgt"

find "$DBSCRIPTS_DIR" -type f -name "*.sql" ! -name "mysql.sql" -delete
find "$APIMGT_DIR" -type f -name "*.sql" ! -name "mysql.sql" -delete

echo "Updated deployment.toml and cleaned up old SQL files."

# Download JDBC driver
REPO_LIB_DIR="repository/components/lib"
JDBC_URL="https://repo1.maven.org/maven2/mysql/mysql-connector-java/8.0.30/mysql-connector-java-8.0.30.jar"
JDBC_DRIVER="mysql-connector-java-8.0.30.jar"

echo "Downloading MySQL JDBC driver..."
wget -O "$JDBC_DRIVER" "$JDBC_URL"

echo "Moving JDBC driver to $REPO_LIB_DIR..."
mv "$JDBC_DRIVER" "$REPO_LIB_DIR"

echo "MySQL JDBC driver installed."

# Start containers
docker-compose up -d

echo "MySQL Docker containers started successfully."
