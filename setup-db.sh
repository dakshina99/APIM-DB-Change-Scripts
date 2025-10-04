#!/bin/bash

set -euo pipefail

##############################################
# WSO2 API Manager Database Setup Script
# 
# This script downloads and sets up database
# configurations for WSO2 APIM with various
# database types.
##############################################

# Script version
SCRIPT_VERSION="1.0.0"

# Repository information
REPO_OWNER="dakshina99"
REPO_NAME="APIM-DB-Change-Scripts"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
BRANCH="main"

# Supported database types
SUPPORTED_DBS=("mysql" "postgresql" "oracle" "mssql" "db2")

##############################################
# Utility Functions
##############################################

print_banner() {
    echo "=================================================="
    echo "  WSO2 API Manager Database Setup Script v${SCRIPT_VERSION}"
    echo "=================================================="
    echo ""
}

print_usage() {
    echo "Usage: $0 <database_type>"
    echo ""
    echo "Supported database types:"
    for db in "${SUPPORTED_DBS[@]}"; do
        echo "  - $db"
    done
    echo ""
    echo "Examples:"
    echo "  $0 mysql"
    echo "  $0 postgresql"
    echo "  $0 oracle"
    echo ""
    echo "This script should be run from your APIM_HOME directory."
}

check_dependencies() {
    echo "🔍 Checking for required dependencies..."
    
    # Check for curl or wget
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        echo "❌ Error: Neither curl nor wget is available. Please install one of them."
        exit 1
    fi
    
    # Check for unzip
    if ! command -v unzip &>/dev/null; then
        echo "❌ Error: unzip is not available. Please install unzip."
        exit 1
    fi
    
    # Check for docker
    if ! command -v docker &>/dev/null; then
        echo "❌ Error: Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    # Check for docker-compose
    if ! command -v docker-compose &>/dev/null; then
        echo "❌ Error: docker-compose is not available. Please install docker-compose."
        exit 1
    fi
    
    echo "✅ All dependencies are available."
}

validate_apim_home() {
    echo "🏠 Validating APIM_HOME directory..."
    
    # Check if we're in a valid APIM directory
    if [[ ! -d "repository" ]] || [[ ! -d "bin" ]]; then
        echo "❌ Error: This doesn't appear to be a valid APIM_HOME directory."
        echo "   Expected to find 'repository' and 'bin' directories."
        echo "   Please run this script from your APIM_HOME directory."
        exit 1
    fi
    
    # Check for deployment.toml
    if [[ ! -f "repository/conf/deployment.toml" ]]; then
        echo "❌ Error: deployment.toml not found at repository/conf/deployment.toml"
        exit 1
    fi
    
    # Create necessary directories if they don't exist
    mkdir -p "repository/components/lib"
    mkdir -p "dbscripts"
    mkdir -p "dbscripts/apimgt"
    
    echo "✅ APIM_HOME directory validated."
}

validate_database_type() {
    local db_type="$1"
    
    for supported_db in "${SUPPORTED_DBS[@]}"; do
        if [[ "$db_type" == "$supported_db" ]]; then
            return 0
        fi
    done
    
    echo "❌ Error: Unsupported database type '$db_type'"
    echo "Supported types: ${SUPPORTED_DBS[*]}"
    exit 1
}

download_file() {
    local url="$1"
    local output="$2"
    
    if command -v curl &>/dev/null; then
        curl -sL "$url" -o "$output"
    elif command -v wget &>/dev/null; then
        wget -q "$url" -O "$output"
    else
        echo "❌ Error: No download tool available"
        exit 1
    fi
}

download_database_files() {
    local db_type="$1"
    local temp_dir="/tmp/apim-db-setup-$$"
    
    echo "📥 Downloading database files for $db_type..."
    
    # Create temporary directory
    mkdir -p "$temp_dir"
    
    # Download the repository archive
    local archive_url="${REPO_URL}/archive/refs/heads/${BRANCH}.zip"
    local archive_file="$temp_dir/repo.zip"
    
    echo "   Downloading from: $archive_url"
    download_file "$archive_url" "$archive_file"
    
    # Extract the archive
    echo "   Extracting files..."
    unzip -q "$archive_file" -d "$temp_dir"
    
    # Copy database-specific files
    local source_dir="$temp_dir/${REPO_NAME}-${BRANCH}/${db_type}"
    
    if [[ ! -d "$source_dir" ]]; then
        echo "❌ Error: Database directory '$db_type' not found in repository"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    echo "   Copying files to current directory..."
    cp -r "$source_dir"/* .
    
    # Make scripts executable
    chmod +x *.sh 2>/dev/null || true
    
    # Cleanup
    rm -rf "$temp_dir"
    
    echo "✅ Database files downloaded successfully."
}

setup_database() {
    local db_type="$1"
    local init_script="init_${db_type}.sh"
    
    echo "🚀 Setting up $db_type database..."
    
    if [[ ! -f "$init_script" ]]; then
        echo "❌ Error: Initialization script '$init_script' not found"
        exit 1
    fi
    
    echo "   Running initialization script: $init_script"
    ./"$init_script"
    
    echo "✅ Database setup completed successfully."
}

print_next_steps() {
    local db_type="$1"
    
    echo ""
    echo "🎉 Setup completed successfully!"
    echo ""
    echo "Next steps:"
    echo "1. Wait for the database containers to fully initialize"
    echo "2. Start WSO2 API Manager:"
    echo "   ./bin/api-manager.sh"
    echo ""
    echo "To cleanup when done:"
    echo "   ./cleanup.sh"
    echo ""
    echo "Database type: $db_type"
    
    case "$db_type" in
        "mysql")
            echo "MySQL ports: 3306 (apim_db), 3307 (shared_db)"
            ;;
        "postgresql")
            echo "PostgreSQL ports: 5432 (apim_db), 5433 (shared_db)"
            ;;
        "oracle")
            echo "Oracle ports: 1521 (apim_db), 1522 (shared_db)"
            echo "Note: Oracle requires Colima and may take longer to initialize"
            ;;
        "mssql")
            echo "MSSQL ports: 1433 (apim_db), 1434 (shared_db)"
            ;;
        "db2")
            echo "DB2 ports: 50000 (apim_db), 50001 (shared_db)"
            echo "Note: DB2 containers may take several minutes to initialize"
            ;;
    esac
}

##############################################
# Main Execution
##############################################

main() {
    print_banner
    
    # Check arguments
    if [[ $# -ne 1 ]]; then
        print_usage
        exit 1
    fi
    
    local db_type="$1"
    
    # Validate inputs
    validate_database_type "$db_type"
    validate_apim_home
    check_dependencies
    
    # Download and setup
    download_database_files "$db_type"
    setup_database "$db_type"
    
    # Print completion message
    print_next_steps "$db_type"
}

# Handle script interruption
trap 'echo ""; echo "❌ Script interrupted. Cleaning up..."; exit 1' INT TERM

# Run main function
main "$@"
