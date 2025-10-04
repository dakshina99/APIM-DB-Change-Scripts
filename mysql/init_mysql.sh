#!/bin/bash

set -e

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

# Detect OS for package installation
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

log_info "🚀 Starting MySQL database initialization process..."

install_dependencies

# Configuration file path
CONFIG_FILE="repository/conf/deployment.toml"

log_info "⚙️  Updating database configuration in $CONFIG_FILE..."

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "📄 Configuration file $CONFIG_FILE not found!"
    exit 1
fi

log_info "🧹 Removing existing database configuration blocks..."
# Delete existing DB config blocks
sed -i '' '/\[database.apim_db\]/,/^$/d' "$CONFIG_FILE"
sed -i '' '/\[database.shared_db\]/,/^$/d' "$CONFIG_FILE"

log_info "✏️  Adding MySQL database configurations..."
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

log_success "⚙️  Database configuration updated successfully"

# Cleanup unnecessary SQL files with backup
DBSCRIPTS_DIR="dbscripts"
APIMGT_DIR="${DBSCRIPTS_DIR}/apimgt"
BACKUP_DIR=""  # Initialize backup directory variable

log_info "📁 Processing database scripts cleanup..."

if [ -d "$DBSCRIPTS_DIR" ]; then
    # Create backup directory with timestamp
    BACKUP_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_DIR="${DBSCRIPTS_DIR}_backup_${BACKUP_TIMESTAMP}"
    
    log_info "💾 Creating backup of dbscripts directory at $BACKUP_DIR..."
    cp -r "$DBSCRIPTS_DIR" "$BACKUP_DIR"
    log_success "💾 Backup created successfully at $BACKUP_DIR"
    
    # Count files before cleanup
    TOTAL_SQL_FILES=$(find "$DBSCRIPTS_DIR" -type f -name "*.sql" | wc -l)
    MYSQL_SQL_FILES=$(find "$DBSCRIPTS_DIR" -type f -name "mysql.sql" | wc -l)
    FILES_TO_DELETE=$((TOTAL_SQL_FILES - MYSQL_SQL_FILES))
    
    log_info "📊 Found $TOTAL_SQL_FILES SQL files total, keeping $MYSQL_SQL_FILES mysql.sql files"
    log_info "🧹 Cleaning up $FILES_TO_DELETE unnecessary SQL files..."
    
    # Remove unnecessary SQL files (keep only mysql.sql files)
    find "$DBSCRIPTS_DIR" -type f -name "*.sql" ! -name "mysql.sql" -delete
    
    if [ -d "$APIMGT_DIR" ]; then
        find "$APIMGT_DIR" -type f -name "*.sql" ! -name "mysql.sql" -delete
    fi
    
    log_success "🧹 Database scripts cleanup completed. Backup available at $BACKUP_DIR"
else
    log_warning "📁 dbscripts directory not found, skipping cleanup"
fi

# Download JDBC driver only if not present
REPO_LIB_DIR="repository/components/lib"
JDBC_URL="https://repo1.maven.org/maven2/mysql/mysql-connector-java/8.0.30/mysql-connector-java-8.0.30.jar"
JDBC_DRIVER="mysql-connector-java-8.0.30.jar"
JDBC_PATH="$REPO_LIB_DIR/$JDBC_DRIVER"

log_info "🔌 Checking MySQL JDBC driver availability..."

# Create lib directory if it doesn't exist
if [ ! -d "$REPO_LIB_DIR" ]; then
    log_info "📂 Creating lib directory: $REPO_LIB_DIR"
    mkdir -p "$REPO_LIB_DIR"
fi

# Check if JDBC driver already exists
if [ -f "$JDBC_PATH" ]; then
    log_success "🔌 MySQL JDBC driver already exists at $JDBC_PATH"
    log_info "🔍 Verifying driver file integrity..."
    
    # Check if file size is reasonable (should be > 1MB for MySQL connector)
    FILE_SIZE=$(stat -f%z "$JDBC_PATH" 2>/dev/null || echo "0")
    if [ "$FILE_SIZE" -gt 1000000 ]; then
        log_success "🔍 JDBC driver file appears to be valid (size: $FILE_SIZE bytes)"
    else
        log_warning "⚠️  JDBC driver file seems corrupted or incomplete (size: $FILE_SIZE bytes)"
        log_info "🗑️  Removing corrupted file and re-downloading..."
        rm -f "$JDBC_PATH"
    fi
fi

# Download JDBC driver if not present or corrupted
if [ ! -f "$JDBC_PATH" ]; then
    log_info "📥 Downloading MySQL JDBC driver from $JDBC_URL..."
    
    # Download to temporary location first
    TEMP_DRIVER="/tmp/$JDBC_DRIVER"
    if wget -O "$TEMP_DRIVER" "$JDBC_URL"; then
        log_success "📥 JDBC driver downloaded successfully"
        
        # Verify downloaded file
        TEMP_FILE_SIZE=$(stat -f%z "$TEMP_DRIVER" 2>/dev/null || echo "0")
        if [ "$TEMP_FILE_SIZE" -gt 1000000 ]; then
            log_info "📦 Moving JDBC driver to $REPO_LIB_DIR..."
            mv "$TEMP_DRIVER" "$JDBC_PATH"
            log_success "🔌 MySQL JDBC driver installed successfully at $JDBC_PATH"
        else
            log_error "💥 Downloaded JDBC driver appears to be corrupted (size: $TEMP_FILE_SIZE bytes)"
            rm -f "$TEMP_DRIVER"
            exit 1
        fi
    else
        log_error "💥 Failed to download MySQL JDBC driver"
        exit 1
    fi
fi

# Start containers
log_info "🐳 Starting MySQL Docker containers..."

if docker-compose up -d; then
    log_success "🐳 MySQL Docker containers started successfully"
    
    # Wait a moment and check container status
    sleep 3
    log_info "🔍 Checking container status..."
    docker-compose ps
    
    # Wait for databases to be fully ready
    log_info "⏳ Waiting for databases to be fully initialized..."
    sleep 10
    
    log_success "🎉 MySQL database initialization process completed!"
    log_info "🌐 Database containers are running. You can now connect to:"
    log_info "  🗄️  APIM DB: mysql://localhost:3306/apim_db"
    log_info "  🗄️  Shared DB: mysql://localhost:3307/shared_db"
    
    # Restore dbscripts directory from backup and cleanup
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        log_info "🔄 Restoring dbscripts directory from backup..."
        
        # Remove the modified dbscripts directory
        if [ -d "$DBSCRIPTS_DIR" ]; then
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
    
else
    log_error "💥 Failed to start MySQL Docker containers"
    
    # If container startup failed, still restore the backup if it exists
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        log_info "🔄 Restoring dbscripts directory from backup due to failure..."
        if [ -d "$DBSCRIPTS_DIR" ]; then
            rm -rf "$DBSCRIPTS_DIR"
        fi
        cp -r "$BACKUP_DIR" "$DBSCRIPTS_DIR"
        rm -rf "$BACKUP_DIR"
        log_success "🔄 dbscripts directory restored from backup"
    fi
    
    exit 1
fi
