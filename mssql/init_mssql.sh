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
  fi

  # Check for docker
  if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first."
    exit 1
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
  JDBC_URL="https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/12.10.0.jre11/mssql-jdbc-12.10.0.jre11.jar"
  JDBC_DRIVER="mssql-jdbc-12.10.0.jre11.jar"

  echo "⚙️  Updating deployment.toml..."

  # Cross-platform sed handling (macOS vs Linux)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_OPT=(-i '')
  else
    SED_OPT=(-i)
  fi

  # Delete old DB blocks
  sed "${SED_OPT[@]}" '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed "${SED_OPT[@]}" '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"

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

  echo "🧹 Cleaning up old SQL scripts (keeping only mssql.sql)..."
  find "$DBSCRIPTS_DIR" -type f -name "*.sql" ! -name "mssql.sql" -delete
  find "$APIMGT_DIR" -type f -name "*.sql" ! -name "mssql.sql" -delete

  echo "⬇️  Downloading MSSQL JDBC driver..."
  wget -q -O "$JDBC_DRIVER" "$JDBC_URL"

  echo "📦 Installing JDBC driver into $REPO_LIB_DIR..."
  mv "$JDBC_DRIVER" "$REPO_LIB_DIR"

  echo "🚀 Starting Docker containers..."
  docker-compose up -d

  # Install sqlcmd (macOS only – others should already have tools configured)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
    brew update
    brew install msodbcsql mssql-tools

    # Add sqlcmd tools to PATH for current session
    export PATH="/usr/local/opt/mssql-tools/bin:$PATH"
    echo "⚡ PATH updated with mssql-tools: /usr/local/opt/mssql-tools/bin"
  fi

  echo "⏳ Waiting for SQL Server containers to initialize..."
  sleep 60

  echo "📂 Running DB initialization scripts..."
  sqlcmd -S localhost,1433 -U SA -P 'RootPass123!' -C -i ./init/init-apim.sql
  sqlcmd -S localhost,1434 -U SA -P 'RootPass123!' -C -i ./init/init-shared.sql

  sqlcmd -S localhost,1433 -U SA -P 'RootPass123!' -d apim_db -C -i ./dbscripts/apimgt/mssql.sql
  sqlcmd -S localhost,1434 -U SA -P 'RootPass123!' -d shared_db -C -i ./dbscripts/mssql.sql

  echo "✅ MSSQL Docker containers started and initialized successfully."
}

main "$@"
