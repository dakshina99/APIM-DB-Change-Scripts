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

# Configuration
APIM_CONTAINER="apim_db_container_db2"
SHARED_CONTAINER="shared_db_container_db2"
APIM_DB="apim_db"
SHARED_DB="shareddb"
DB_USER="db2inst1"
APIM_PASSWORD="apimpass"
SHARED_PASSWORD="sharedpass"
BACKUP_DIR="/backup"
LOCAL_BACKUP_DIR="./db2_backups"

##############################################
# Utility Functions
##############################################

# Check if container is running
check_container() {
    local container_name="$1"
    if docker ps --format "table {{.Names}}" | grep -q "^${container_name}$"; then
        return 0
    else
        return 1
    fi
}

# Create local backup directory
create_local_backup_dir() {
    if [ ! -d "$LOCAL_BACKUP_DIR" ]; then
        log_info "📁 Creating local backup directory: $LOCAL_BACKUP_DIR"
        mkdir -p "$LOCAL_BACKUP_DIR"
    fi
}

# Get timestamp for backup identification
get_timestamp() {
    date +"%Y%m%d%H%M%S"
}

##############################################
# Backup Functions
##############################################

backup_apim_db() {
    local timestamp="$1"
    
    log_info "🗄️  Starting APIM database backup..." >&2
    
    # Ensure backup directory exists in container
    docker exec "$APIM_CONTAINER" mkdir -p "$BACKUP_DIR" >&2
    
    # Prepare database for backup (force disconnect and complete rollforward if needed)
    log_info "🔧 Preparing APIM database for backup..." >&2
    docker exec -i "$APIM_CONTAINER" su - "$DB_USER" -c "
        db2 'FORCE APPLICATION ALL' && 
        db2 'ROLLFORWARD DATABASE $APIM_DB TO END OF LOGS AND STOP'
    " >&2 2>/dev/null || true
    
    # Connect and backup APIM database
    local backup_output
    backup_output=$(docker exec -i "$APIM_CONTAINER" su - "$DB_USER" -c "
        db2 connect to $APIM_DB user $DB_USER using $APIM_PASSWORD && 
        db2 'BACKUP DATABASE $APIM_DB TO $BACKUP_DIR'
    " 2>&1)
    
    if [ $? -eq 0 ]; then
        log_success "🗄️  APIM database backup completed" >&2
        
        # Extract the backup timestamp from the output
        local backup_timestamp=$(echo "$backup_output" | grep "timestamp for this backup image is" | sed 's/.*timestamp for this backup image is : //')
        
        # Find the backup file and copy to local system
        local backup_file=$(docker exec "$APIM_CONTAINER" sh -c "ls -1t $BACKUP_DIR/APIM_DB*.001 2>/dev/null | head -1")
        
        if [ -n "$backup_file" ]; then
            local local_filename="${APIM_DB}_${timestamp}.backup"
            log_info "📦 Copying APIM backup to local system: $local_filename" >&2
            
            if docker cp "$APIM_CONTAINER:$backup_file" "$LOCAL_BACKUP_DIR/$local_filename" >&2; then
                log_success "📦 APIM backup copied to: $LOCAL_BACKUP_DIR/$local_filename" >&2
                echo "$LOCAL_BACKUP_DIR/$local_filename|$backup_timestamp"
            else
                log_error "💥 Failed to copy APIM backup to local system" >&2
                return 1
            fi
        else
            log_error "💥 Could not find APIM backup file in container" >&2
            return 1
        fi
    else
        log_error "💥 Failed to backup APIM database" >&2
        return 1
    fi
}

backup_shared_db() {
    local timestamp="$1"
    
    log_info "🗄️  Starting Shared database backup..." >&2
    
    # Ensure backup directory exists in container
    docker exec "$SHARED_CONTAINER" mkdir -p "$BACKUP_DIR" >&2
    
    # Prepare database for backup (force disconnect and complete rollforward if needed)
    log_info "🔧 Preparing Shared database for backup..." >&2
    docker exec -i "$SHARED_CONTAINER" su - "$DB_USER" -c "
        db2 'FORCE APPLICATION ALL' && 
        db2 'ROLLFORWARD DATABASE $SHARED_DB TO END OF LOGS AND STOP'
    " >&2 2>/dev/null || true
    
    # Connect and backup Shared database
    local backup_output
    backup_output=$(docker exec -i "$SHARED_CONTAINER" su - "$DB_USER" -c "
        db2 connect to $SHARED_DB user $DB_USER using $SHARED_PASSWORD && 
        db2 'BACKUP DATABASE $SHARED_DB TO $BACKUP_DIR'
    " 2>&1)
    
    if [ $? -eq 0 ]; then
        log_success "🗄️  Shared database backup completed" >&2
        
        # Extract the backup timestamp from the output
        local backup_timestamp=$(echo "$backup_output" | grep "timestamp for this backup image is" | sed 's/.*timestamp for this backup image is : //')
        
        # Find the backup file and copy to local system
        local backup_file=$(docker exec "$SHARED_CONTAINER" sh -c "ls -1t $BACKUP_DIR/SHAREDDB*.001 2>/dev/null | head -1")
        
        if [ -n "$backup_file" ]; then
            local local_filename="${SHARED_DB}_${timestamp}.backup"
            log_info "📦 Copying Shared backup to local system: $local_filename" >&2
            
            if docker cp "$SHARED_CONTAINER:$backup_file" "$LOCAL_BACKUP_DIR/$local_filename" >&2; then
                log_success "📦 Shared backup copied to: $LOCAL_BACKUP_DIR/$local_filename" >&2
                echo "$LOCAL_BACKUP_DIR/$local_filename|$backup_timestamp"
            else
                log_error "💥 Failed to copy Shared backup to local system" >&2
                return 1
            fi
        else
            log_error "💥 Could not find Shared backup file in container" >&2
            return 1
        fi
    else
        log_error "💥 Failed to backup Shared database" >&2
        return 1
    fi
}

##############################################
# Restore Functions
##############################################

restore_apim_db() {
    local backup_file="$1"
    local backup_timestamp="$2"
    
    log_info "🔄 Starting APIM database restore from: $backup_file"
    
    # Copy backup file to container
    local container_backup_file="$BACKUP_DIR/$(basename "$backup_file")"
    log_info "📋 Copying backup file to container..."
    
    if docker cp "$backup_file" "$APIM_CONTAINER:$container_backup_file"; then
        log_success "📋 Backup file copied to container"
    else
        log_error "💥 Failed to copy backup file to container"
        return 1
    fi
    
    # Restore database
    if docker exec -i "$APIM_CONTAINER" su - "$DB_USER" -c "
        db2 'FORCE APPLICATION ALL' && 
        db2 'RESTORE DATABASE $APIM_DB FROM $BACKUP_DIR TAKEN AT $backup_timestamp INTO $APIM_DB REPLACE EXISTING'
    "; then
        log_success "🔄 APIM database restored successfully"
        
        # Automatically complete roll-forward if needed
        log_info "🔄 Completing roll-forward for APIM database..."
        if docker exec -i "$APIM_CONTAINER" su - "$DB_USER" -c "
            db2 'ROLLFORWARD DATABASE $APIM_DB TO END OF LOGS AND STOP'
        " >&2 2>/dev/null || true; then
            log_success "✅ APIM database roll-forward completed"
        fi
        
        # Clean up backup file from container
        docker exec "$APIM_CONTAINER" rm -f "$container_backup_file"
        log_info "🧹 Cleaned up temporary backup file from container"
    else
        log_error "💥 Failed to restore APIM database"
        # Clean up backup file from container even on failure
        docker exec "$APIM_CONTAINER" rm -f "$container_backup_file"
        return 1
    fi
}

restore_shared_db() {
    local backup_file="$1"
    local backup_timestamp="$2"
    
    log_info "🔄 Starting Shared database restore from: $backup_file"
    
    # Copy backup file to container
    local container_backup_file="$BACKUP_DIR/$(basename "$backup_file")"
    log_info "📋 Copying backup file to container..."
    
    if docker cp "$backup_file" "$SHARED_CONTAINER:$container_backup_file"; then
        log_success "📋 Backup file copied to container"
    else
        log_error "💥 Failed to copy backup file to container"
        return 1
    fi
    
    # Restore database
    if docker exec -i "$SHARED_CONTAINER" su - "$DB_USER" -c "
        db2 'FORCE APPLICATION ALL' && 
        db2 'RESTORE DATABASE $SHARED_DB FROM $BACKUP_DIR TAKEN AT $backup_timestamp INTO $SHARED_DB REPLACE EXISTING'
    "; then
        log_success "🔄 Shared database restored successfully"
        
        # Automatically complete roll-forward if needed
        log_info "🔄 Completing roll-forward for Shared database..."
        if docker exec -i "$SHARED_CONTAINER" su - "$DB_USER" -c "
            db2 'ROLLFORWARD DATABASE $SHARED_DB TO END OF LOGS AND STOP'
        " >&2 2>/dev/null || true; then
            log_success "✅ Shared database roll-forward completed"
        fi
        
        # Clean up backup file from container
        docker exec "$SHARED_CONTAINER" rm -f "$container_backup_file"
        log_info "🧹 Cleaned up temporary backup file from container"
    else
        log_error "💥 Failed to restore Shared database"
        # Clean up backup file from container even on failure
        docker exec "$SHARED_CONTAINER" rm -f "$container_backup_file"
        return 1
    fi
}

##############################################
# Main Functions
##############################################

backup_databases() {
    log_info "🚀 Starting DB2 databases backup process..."
    
    # Check if containers are running
    if ! check_container "$APIM_CONTAINER"; then
        log_error "💥 APIM container '$APIM_CONTAINER' is not running"
        exit 1
    fi
    
    if ! check_container "$SHARED_CONTAINER"; then
        log_error "💥 Shared container '$SHARED_CONTAINER' is not running"
        exit 1
    fi
    
    # Create local backup directory
    create_local_backup_dir
    
    # Get timestamp for this backup session
    local timestamp=$(get_timestamp)
    local backup_session_dir="$LOCAL_BACKUP_DIR/backup_$timestamp"
    mkdir -p "$backup_session_dir"
    
    log_info "📁 Backup session directory: $backup_session_dir"
    
    # Backup APIM database
    local apim_backup_result
    if apim_backup_result=$(backup_apim_db "$timestamp"); then
        local apim_file=$(echo "$apim_backup_result" | cut -d'|' -f1)
        local apim_timestamp=$(echo "$apim_backup_result" | cut -d'|' -f2)
        mv "$apim_file" "$backup_session_dir/"
        log_success "✅ APIM backup moved to session directory"
    else
        log_error "💥 APIM database backup failed"
        return 1
    fi
    
    # Backup Shared database
    local shared_backup_result
    if shared_backup_result=$(backup_shared_db "$timestamp"); then
        local shared_file=$(echo "$shared_backup_result" | cut -d'|' -f1)
        local shared_timestamp=$(echo "$shared_backup_result" | cut -d'|' -f2)
        mv "$shared_file" "$backup_session_dir/"
        log_success "✅ Shared backup moved to session directory"
    else
        log_error "💥 Shared database backup failed"
        return 1
    fi
    
    # Create backup info file
    cat > "$backup_session_dir/backup_info.txt" << EOF
Backup Information
==================
Session Timestamp: $timestamp
Date: $(date)
APIM Database: $APIM_DB
Shared Database: $SHARED_DB
APIM Container: $APIM_CONTAINER
Shared Container: $SHARED_CONTAINER

Backup Timestamps:
- APIM Database: $apim_timestamp
- Shared Database: $shared_timestamp

Files:
- ${APIM_DB}_${timestamp}.backup
- ${SHARED_DB}_${timestamp}.backup

To restore, use:
./backup_restore_db2.sh restore $backup_session_dir $apim_timestamp $shared_timestamp
EOF
    
    log_success "🎉 Database backup process completed successfully!"
    log_info "📁 Backup location: $backup_session_dir"
    log_info "📋 Backup info saved to: $backup_session_dir/backup_info.txt"
}

restore_databases() {
    local backup_session_dir="$1"
    local apim_timestamp="$2"
    local shared_timestamp="$3"
    
    if [ -z "$backup_session_dir" ]; then
        log_error "💥 Usage: $0 restore <backup_session_dir> [apim_timestamp] [shared_timestamp]"
        log_info "📋 Example: $0 restore ./db2_backups/backup_20241014123045 20241014082435 20241014082445"
        log_info "📋 If timestamps are omitted, they will be read from backup_info.txt"
        exit 1
    fi
    
    if [ ! -d "$backup_session_dir" ]; then
        log_error "💥 Backup session directory not found: $backup_session_dir"
        exit 1
    fi
    
    # Try to read timestamps from backup_info.txt if not provided
    local info_file="$backup_session_dir/backup_info.txt"
    if [ -z "$apim_timestamp" ] && [ -f "$info_file" ]; then
        apim_timestamp=$(grep "APIM Database:" "$info_file" | grep -E "[0-9]{14}" -o)
        shared_timestamp=$(grep "Shared Database:" "$info_file" | grep -E "[0-9]{14}" -o)
        log_info "📋 Read timestamps from backup info: APIM=$apim_timestamp, Shared=$shared_timestamp"
    fi
    
    if [ -z "$apim_timestamp" ] || [ -z "$shared_timestamp" ]; then
        log_error "💥 Backup timestamps are required. Check backup_info.txt or provide them as arguments."
        exit 1
    fi
    
    log_info "🚀 Starting DB2 databases restore process..."
    log_info "📁 Restore from: $backup_session_dir"
    log_info "⏰ APIM backup timestamp: $apim_timestamp"
    log_info "⏰ Shared backup timestamp: $shared_timestamp"
    
    # Check if containers are running
    if ! check_container "$APIM_CONTAINER"; then
        log_error "💥 APIM container '$APIM_CONTAINER' is not running"
        exit 1
    fi
    
    if ! check_container "$SHARED_CONTAINER"; then
        log_error "💥 Shared container '$SHARED_CONTAINER' is not running"
        exit 1
    fi
    
    # Find backup files
    local apim_backup_file=$(find "$backup_session_dir" -name "${APIM_DB}_*.backup" | head -1)
    local shared_backup_file=$(find "$backup_session_dir" -name "${SHARED_DB}_*.backup" | head -1)
    
    if [ -z "$apim_backup_file" ]; then
        log_error "💥 APIM backup file not found in $backup_session_dir"
        exit 1
    fi
    
    if [ -z "$shared_backup_file" ]; then
        log_error "💥 Shared backup file not found in $backup_session_dir"
        exit 1
    fi
    
    log_info "📋 APIM backup file: $apim_backup_file"
    log_info "📋 Shared backup file: $shared_backup_file"
    
    # Ask for confirmation
    log_warning "⚠️  This will overwrite existing databases!"
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "🚫 Restore operation cancelled by user"
        exit 0
    fi
    
    # Restore APIM database
    if restore_apim_db "$apim_backup_file" "$apim_timestamp"; then
        log_success "✅ APIM database restored successfully"
    else
        log_error "💥 APIM database restore failed"
        return 1
    fi
    
    # Restore Shared database
    if restore_shared_db "$shared_backup_file" "$shared_timestamp"; then
        log_success "✅ Shared database restored successfully"
    else
        log_error "💥 Shared database restore failed"
        return 1
    fi
    
    # Verify databases are accessible
    log_info "🔍 Verifying database accessibility..."
    
    # Test APIM database connection
    if docker exec -i "$APIM_CONTAINER" su - "$DB_USER" -c "db2 connect to $APIM_DB" >&2 2>/dev/null; then
        log_success "✅ APIM database is accessible"
    else
        log_warning "⚠️  APIM database connection test failed"
    fi
    
    # Test Shared database connection  
    if docker exec -i "$SHARED_CONTAINER" su - "$DB_USER" -c "db2 connect to $SHARED_DB" >&2 2>/dev/null; then
        log_success "✅ Shared database is accessible"
    else
        log_warning "⚠️  Shared database connection test failed"
    fi
    
    log_success "🎉 Database restore process completed successfully!"
}

list_backups() {
    log_info "📋 Available backup sessions:"
    
    if [ ! -d "$LOCAL_BACKUP_DIR" ]; then
        log_warning "⚠️  No backup directory found: $LOCAL_BACKUP_DIR"
        return 0
    fi
    
    local backup_dirs=$(find "$LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "backup_*" | sort -r)
    
    if [ -z "$backup_dirs" ]; then
        log_warning "⚠️  No backup sessions found"
        return 0
    fi
    
    echo
    while IFS= read -r backup_dir; do
        local session_name=$(basename "$backup_dir")
        local info_file="$backup_dir/backup_info.txt"
        
        echo "📁 $session_name"
        if [ -f "$info_file" ]; then
            local backup_date=$(grep "Date:" "$info_file" | cut -d' ' -f2-)
            echo "   📅 Date: $backup_date"
            echo "   📂 Path: $backup_dir"
            
            # List backup files
            local files=$(find "$backup_dir" -name "*.backup" -exec basename {} \;)
            if [ -n "$files" ]; then
                echo "   📋 Files:"
                echo "$files" | sed 's/^/      - /'
            fi
        else
            echo "   📂 Path: $backup_dir"
        fi
        echo
    done <<< "$backup_dirs"
}

show_help() {
    echo "DB2 Database Backup and Restore Script"
    echo "====================================="
    echo
    echo "Usage:"
    echo "  $0 backup                                    - Backup both APIM and Shared databases"
    echo "  $0 restore <session_dir> [apim_ts] [shared_ts] - Restore databases from backup"
    echo "  $0 list                                     - List available backup sessions"
    echo "  $0 help                                     - Show this help message"
    echo
    echo "Examples:"
    echo "  $0 backup"
    echo "  $0 restore ./db2_backups/backup_20241014123045"
    echo "  $0 restore ./db2_backups/backup_20241014123045 20241014082435 20241014082445"
    echo "  $0 list"
    echo
    echo "Features:"
    echo "  ✅ Fully automated backup and restore process"
    echo "  ✅ Automatic database state management (rollforward, force disconnect)"
    echo "  ✅ Individual timestamp handling for each database"
    echo "  ✅ Automatic post-restore verification"
    echo "  ✅ No manual intervention required"
    echo
    echo "Notes:"
    echo "  - Containers must be running before backup/restore operations"
    echo "  - If timestamps are omitted during restore, they will be read from backup_info.txt"
    echo "  - Each database has its own backup timestamp"
    echo "  - Restore will overwrite existing databases (confirmation required)"
    echo "  - All database state management is handled automatically"
}

##############################################
# Main Script Logic
##############################################

case "${1:-help}" in
    "backup")
        backup_databases
        ;;
    "restore")
        restore_databases "$2" "$3" "$4"
        ;;
    "list")
        list_backups
        ;;
    "help"|*)
        show_help
        ;;
esac