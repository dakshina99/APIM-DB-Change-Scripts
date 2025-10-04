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
    echo -e "${BLUE}[INFO]${NC} ℹ️  $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} ✅ $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} ⚠️  $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} ❌ $1"
}

##############################################
# Utility: Install Dependencies
##############################################
install_dependencies() {
  log_info "🔍 Checking for required commands and dependencies..."

  # Check for wget
  if ! command -v wget &> /dev/null; then
    log_warning "📥 wget not found. Installing wget..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
      log_info "🍎 Detected macOS. Installing wget using Homebrew..."
      brew install wget
    elif [[ -f /etc/debian_version ]]; then
      log_info "🐧 Detected Debian/Ubuntu. Installing wget using apt..."
      sudo apt-get update && sudo apt-get install -y wget
    elif [[ -f /etc/redhat-release ]]; then
      log_info "🎩 Detected Red Hat/CentOS. Installing wget using yum..."
      sudo yum install -y wget
    else
      log_error "💻 Unsupported OS. Please install wget manually."
      exit 1
    fi
    log_success "📥 wget installed successfully"
  else
    log_success "📥 wget is already installed"
  fi

  # Check for docker
  if ! command -v docker &> /dev/null; then
    log_error "🐳 Docker is not installed. Please install Docker first."
    exit 1
  else
    log_success "🐳 Docker is available"
  fi

  # Check for docker-compose
  if ! command -v docker-compose &> /dev/null; then
    log_warning "🐙 docker-compose not found. Installing docker-compose..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
      log_info "🍎 Detected macOS. Installing docker-compose using Homebrew..."
      brew install docker-compose
    elif [[ -f /etc/debian_version ]]; then
      log_info "🐧 Detected Debian/Ubuntu. Installing docker-compose using apt..."
      sudo apt-get update && sudo apt-get install -y docker-compose
    elif [[ -f /etc/redhat-release ]]; then
      log_info "🎩 Detected Red Hat/CentOS. Installing docker-compose using yum..."
      sudo yum install -y docker-compose
    else
      log_error "💻 Unsupported OS. Please install docker-compose manually."
      exit 1
    fi
    log_success "🐙 docker-compose installed successfully"
  else
    log_success "🐙 docker-compose is already installed"
  fi
}

##############################################
# Main Execution
##############################################
main() {
  log_info "🚀 Starting MSSQL database initialization process..."
  
  install_dependencies

  CONFIG_FILE="repository/conf/deployment.toml"
  DBSCRIPTS_DIR="dbscripts"
  APIMGT_DIR="${DBSCRIPTS_DIR}/apimgt"
  REPO_LIB_DIR="repository/components/lib"
  JDBC_URL="https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/12.10.0.jre11/mssql-jdbc-12.10.0.jre11.jar"
  JDBC_DRIVER="mssql-jdbc-12.10.0.jre11.jar"
  BACKUP_DIR=""  # Initialize backup directory variable

  log_info "⚙️  Updating database configuration in $CONFIG_FILE..."

  # Check if config file exists
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "📄 Configuration file $CONFIG_FILE not found!"
    exit 1
  fi

  # Cross-platform sed handling (macOS vs Linux)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_OPT=(-i '')
  else
    SED_OPT=(-i)
  fi

  log_info "🧹 Removing existing database configuration blocks..."
  # Delete old DB blocks
  sed "${SED_OPT[@]}" '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
  sed "${SED_OPT[@]}" '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"

  log_info "✏️  Adding MSSQL database configurations..."
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

  log_success "⚙️  Database configuration updated successfully"

  # Backup and cleanup database scripts
  log_info "📁 Processing database scripts cleanup..."

  if [[ -d "$DBSCRIPTS_DIR" ]]; then
    # Create backup directory with timestamp
    BACKUP_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_DIR="${DBSCRIPTS_DIR}_backup_${BACKUP_TIMESTAMP}"
    
    log_info "💾 Creating backup of dbscripts directory at $BACKUP_DIR..."
    cp -r "$DBSCRIPTS_DIR" "$BACKUP_DIR"
    log_success "💾 Backup created successfully at $BACKUP_DIR"
    
    # Count files before cleanup
    TOTAL_SQL_FILES=$(find "$DBSCRIPTS_DIR" -type f -name "*.sql" | wc -l | tr -d ' ')
    MSSQL_SQL_FILES=$(find "$DBSCRIPTS_DIR" -type f -name "mssql.sql" | wc -l | tr -d ' ')
    FILES_TO_DELETE=$((TOTAL_SQL_FILES - MSSQL_SQL_FILES))
    
    log_info "📊 Found $TOTAL_SQL_FILES SQL files total, keeping $MSSQL_SQL_FILES mssql.sql files"
    log_info "🧹 Cleaning up $FILES_TO_DELETE unnecessary SQL files..."
    
    # Remove unnecessary SQL files (keep only mssql.sql files)
    find "$DBSCRIPTS_DIR" -type f -name "*.sql" ! -name "mssql.sql" -delete
    if [[ -d "$APIMGT_DIR" ]]; then
      find "$APIMGT_DIR" -type f -name "*.sql" ! -name "mssql.sql" -delete
    fi
    
    log_success "🧹 Database scripts cleanup completed. Backup available at $BACKUP_DIR"
  else
    log_warning "📁 dbscripts directory not found, skipping cleanup"
  fi

  # Download JDBC driver only if not present
  JDBC_PATH="$REPO_LIB_DIR/$JDBC_DRIVER"

  log_info "🔌 Checking MSSQL JDBC driver availability..."

  # Create lib directory if it doesn't exist
  if [[ ! -d "$REPO_LIB_DIR" ]]; then
    log_info "📂 Creating lib directory: $REPO_LIB_DIR"
    mkdir -p "$REPO_LIB_DIR"
  fi

  # Check if JDBC driver already exists
  if [[ -f "$JDBC_PATH" ]]; then
    log_success "🔌 MSSQL JDBC driver already exists at $JDBC_PATH"
    log_info "🔍 Verifying driver file integrity..."
    
    # Check if file size is reasonable (should be > 1MB for MSSQL connector)
    if [[ "$OSTYPE" == "darwin"* ]]; then
      FILE_SIZE=$(stat -f%z "$JDBC_PATH" 2>/dev/null || echo "0")
    else
      FILE_SIZE=$(stat -c%s "$JDBC_PATH" 2>/dev/null || echo "0")
    fi
    
    if [[ "$FILE_SIZE" -gt 1000000 ]]; then
      log_success "🔍 JDBC driver file appears to be valid (size: $FILE_SIZE bytes)"
    else
      log_warning "⚠️  JDBC driver file seems corrupted or incomplete (size: $FILE_SIZE bytes)"
      log_info "🗑️  Removing corrupted file and re-downloading..."
      rm -f "$JDBC_PATH"
    fi
  fi

  # Download JDBC driver if not present or corrupted
  if [[ ! -f "$JDBC_PATH" ]]; then
    log_info "📥 Downloading MSSQL JDBC driver from $JDBC_URL..."
    
    # Download to temporary location first
    TEMP_DRIVER="/tmp/$JDBC_DRIVER"
    if wget -q -O "$TEMP_DRIVER" "$JDBC_URL"; then
      log_success "📥 JDBC driver downloaded successfully"
      
      # Verify downloaded file
      if [[ "$OSTYPE" == "darwin"* ]]; then
        TEMP_FILE_SIZE=$(stat -f%z "$TEMP_DRIVER" 2>/dev/null || echo "0")
      else
        TEMP_FILE_SIZE=$(stat -c%s "$TEMP_DRIVER" 2>/dev/null || echo "0")
      fi
      
      if [[ "$TEMP_FILE_SIZE" -gt 1000000 ]]; then
        log_info "📦 Moving JDBC driver to $REPO_LIB_DIR..."
        mv "$TEMP_DRIVER" "$JDBC_PATH"
        log_success "🔌 MSSQL JDBC driver installed successfully at $JDBC_PATH"
      else
        log_error "💥 Downloaded JDBC driver appears to be corrupted (size: $TEMP_FILE_SIZE bytes)"
        rm -f "$TEMP_DRIVER"
        exit 1
      fi
    else
      log_error "💥 Failed to download MSSQL JDBC driver"
      exit 1
    fi
  fi

  log_info "🚀 Starting Docker containers..."
  if docker-compose up -d; then
    log_success "🐳 MSSQL Docker containers started successfully"
    
    # Wait a moment and check container status
    sleep 3
    log_info "🔍 Checking container status..."
    docker-compose ps
  else
    log_error "💥 Failed to start MSSQL Docker containers"
    
    # If container startup failed, still restore the backup if it exists
    if [[ -n "$BACKUP_DIR" ]] && [[ -d "$BACKUP_DIR" ]]; then
      log_info "🔄 Restoring dbscripts directory from backup due to failure..."
      if [[ -d "$DBSCRIPTS_DIR" ]]; then
        rm -rf "$DBSCRIPTS_DIR"
      fi
      cp -r "$BACKUP_DIR" "$DBSCRIPTS_DIR"
      rm -rf "$BACKUP_DIR"
      log_success "🔄 dbscripts directory restored from backup"
    fi
    
    exit 1
  fi

  # Install sqlcmd (macOS only – others should already have tools configured)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    log_info "🍎 Installing MSSQL tools for macOS..."
    if ! command -v sqlcmd &> /dev/null; then
      log_info "📥 Installing Microsoft SQL Server command-line tools..."
      brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
      brew update
      brew install msodbcsql mssql-tools

      # Add sqlcmd tools to PATH for current session
      export PATH="/usr/local/opt/mssql-tools/bin:$PATH"
      log_success "⚡ PATH updated with mssql-tools: /usr/local/opt/mssql-tools/bin"
    else
      log_success "🔧 sqlcmd is already available"
    fi
  fi

  log_info "⏳ Waiting for SQL Server containers to initialize..."
  sleep 60

  log_info "📂 Running database initialization scripts..."
  
  # Run initialization scripts with better error handling
  if sqlcmd -S localhost,1433 -U SA -P 'RootPass123!' -C -i ./init/init-apim.sql; then
    log_success "📂 APIM database initialization completed"
  else
    log_error "💥 Failed to initialize APIM database"
  fi
  
  if sqlcmd -S localhost,1434 -U SA -P 'RootPass123!' -C -i ./init/init-shared.sql; then
    log_success "📂 Shared database initialization completed"
  else
    log_error "💥 Failed to initialize shared database"
  fi

  if sqlcmd -S localhost,1433 -U SA -P 'RootPass123!' -d apim_db -C -i ./dbscripts/apimgt/mssql.sql; then
    log_success "📂 APIM database schema creation completed"
  else
    log_error "💥 Failed to create APIM database schema"
  fi
  
  if sqlcmd -S localhost,1434 -U SA -P 'RootPass123!' -d shared_db -C -i ./dbscripts/mssql.sql; then
    log_success "📂 Shared database schema creation completed"
  else
    log_error "💥 Failed to create shared database schema"
  fi

  log_success "🎉 MSSQL database initialization process completed!"
  log_info "🌐 Database containers are running. You can now connect to:"
  log_info "  🗄️  APIM DB: sqlserver://localhost:1433/apim_db"
  log_info "  🗄️  Shared DB: sqlserver://localhost:1434/shared_db"

  # Restore dbscripts directory from backup and cleanup
  if [[ -n "$BACKUP_DIR" ]] && [[ -d "$BACKUP_DIR" ]]; then
    log_info "🔄 Restoring dbscripts directory from backup..."
    
    # Remove the modified dbscripts directory
    if [[ -d "$DBSCRIPTS_DIR" ]]; then
      rm -rf "$DBSCRIPTS_DIR"
      log_info "🗑️  Removed modified dbscripts directory"
    fi
    
    # Restore from backup
    cp -r "$BACKUP_DIR" "$DBSCRIPTS_DIR"
    log_success "🔄 dbscripts directory restored from backup"
    
    # Clean up backup directory
    log_info "🧹 Cleaning up backup directory: $BACKUP_DIR"
    rm -rf "$BACKUP_DIR"
    log_success "🧹 Backup directory cleaned up"
    
    log_info "♻️  dbscripts directory has been reset to its original state"
  else
    log_warning "💾 No backup directory found to restore from"
  fi
}

main "$@"
