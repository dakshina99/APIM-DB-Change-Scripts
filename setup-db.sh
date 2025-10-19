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

# Logging functions
log_info() {
    echo -e "[INFO] $1"
}

log_success() {
    echo -e "[SUCCESS] $1"
}

log_warning() {
    echo -e "[WARNING] $1"
}

log_error() {
    echo -e "[ERROR] $1"
}

print_banner() {
    log_info "=================================================="
    log_info "  WSO2 API Manager Database Setup Script v${SCRIPT_VERSION}"
    log_info "=================================================="
    echo ""
}

print_usage() {
    log_info "Usage: $0 <database_type>"
    echo ""
    log_info "Supported database types:"
    for db in "${SUPPORTED_DBS[@]}"; do
        log_info "  - $db"
    done
    echo ""
    log_info "Examples:"
    log_info "  $0 mysql"
    log_info "  $0 postgresql"
    log_info "  $0 oracle"
    echo ""
    log_info "This script should be run from your APIM_HOME directory."
}

check_dependencies() {
    log_info "Checking for required dependencies..."
    # Check for curl or wget
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        log_error "Neither curl nor wget is available. Please install one of them."
        exit 1
    fi
    # Check for unzip
    if ! command -v unzip &>/dev/null; then
        log_error "unzip is not available. Please install unzip."
        exit 1
    fi
    # Check for docker
    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    log_success "All dependencies are available."
}

validate_apim_home() {
    log_info "Validating APIM_HOME directory..."
    # Check if we're in a valid APIM directory
    if [[ ! -d "repository" ]] || [[ ! -d "bin" ]]; then
        log_error "This doesn't appear to be a valid APIM_HOME directory."
        log_error "   Expected to find 'repository' and 'bin' directories."
        log_error "   Please run this script from your APIM_HOME directory."
        exit 1
    fi
    # Check for deployment.toml
    if [[ ! -f "repository/conf/deployment.toml" ]]; then
        log_error "deployment.toml not found at repository/conf/deployment.toml"
        exit 1
    fi
    # Create necessary directories if they don't exist
    mkdir -p "repository/components/lib"
    mkdir -p "dbscripts"
    mkdir -p "dbscripts/apimgt"
    log_success "APIM_HOME directory validated."
}

validate_database_type() {
    local db_type="$1"
    for supported_db in "${SUPPORTED_DBS[@]}"; do
        if [[ "$db_type" == "$supported_db" ]]; then
            return 0
        fi
    done
    log_error "Unsupported database type '$db_type'"
    log_error "Supported types: ${SUPPORTED_DBS[*]}"
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
        log_error "No download tool available"
        exit 1
    fi
}

download_database_files() {
    local db_type="$1"
    local temp_dir="/tmp/apim-db-setup-$$"
    log_info "Downloading database files for $db_type..."
    # Create temporary directory
    mkdir -p "$temp_dir"
    # Download the repository archive
    local archive_url="${REPO_URL}/archive/refs/heads/${BRANCH}.zip"
    local archive_file="$temp_dir/repo.zip"
    log_info "   Downloading from: $archive_url"
    download_file "$archive_url" "$archive_file"
    # Extract the archive
    log_info "   Extracting files..."
    unzip -q "$archive_file" -d "$temp_dir"
    # Copy database-specific files
    local source_dir="$temp_dir/${REPO_NAME}-${BRANCH}/${db_type}"
    if [[ ! -d "$source_dir" ]]; then
        log_error "Database directory '$db_type' not found in repository"
        rm -rf "$temp_dir"
        exit 1
    fi
    log_info "   Copying files to current directory..."
    cp -r "$source_dir"/* .
    # Make scripts executable
    chmod +x *.sh 2>/dev/null || true
    # Cleanup
    rm -rf "$temp_dir"
    log_success "Database files downloaded successfully."
}

setup_database() {
    local db_type="$1"
    local init_script="init_${db_type}.sh"
    log_info "Setting up $db_type database..."
    if [[ ! -f "$init_script" ]]; then
        log_error "Initialization script '$init_script' not found"
        exit 1
    fi
    log_info "   Running initialization script: $init_script"
    ./$init_script
    log_success "Database setup completed successfully."
}

print_next_steps() {
    local db_type="$1"
    echo ""
    log_success "Setup completed successfully!"
    echo ""
    log_info "Next steps:"
    log_info "1. Wait for the database containers to fully initialize"
    log_info "2. Start WSO2 API Manager:"
    log_info "   ./bin/api-manager.sh"
    echo ""
    log_info "To cleanup when done:"
    log_info "   ./cleanup.sh"
    echo ""
    log_info "Database type: $db_type"
    case "$db_type" in
        "mysql")
            log_info "MySQL ports: 3306 (apim_db), 3307 (shared_db)"
            ;;
        "postgresql")
            log_info "PostgreSQL ports: 5432 (apim_db), 5433 (shared_db)"
            ;;
        "oracle")
            log_info "Oracle ports: 1521 (apim_db), 1522 (shared_db)"
            log_info "Note: Oracle requires Colima and may take longer to initialize"
            ;;
        "mssql")
            log_info "MSSQL ports: 1433 (apim_db), 1434 (shared_db)"
            ;;
        "db2")
            log_info "DB2 ports: 50000 (apim_db), 50001 (shared_db)"
            log_info "Note: DB2 containers may take several minutes to initialize"
            ;;
    esac
}

##############################################
# Main Execution
##############################################

main() {
    print_banner
    # Prompt for database type interactively
    echo "--------------------------------------------------"
    log_info "Database Setup Selection"
    echo "--------------------------------------------------"
    log_info "Supported database types:"
    for db in "${SUPPORTED_DBS[@]}"; do
        log_info "  - $db"
    done
    echo "--------------------------------------------------"
    log_info "Please type the database you want to set up and press Enter."
    read -rp "Database type: " db_type
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
trap 'echo ""; log_error "Script interrupted. Cleaning up..."; exit 1' INT TERM

# Run main function
main "$@"
