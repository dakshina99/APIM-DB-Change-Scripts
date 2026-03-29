# WSO2 API Manager – Database Setup Guide

This guide explains how to set up WSO2 API Manager (APIM) with different database types using the provided scripts and Docker Compose files.

---

## Quick Setup (Recommended)

### Using the Common Setup Script

1. **Download the setup script**
   ```bash
   curl -sL https://raw.githubusercontent.com/dakshina99/APIM-DB-Change-Scripts/main/setup-db.sh -o setup-db.sh
   chmod +x setup-db.sh
   ```

2. **Run from your APIM_HOME directory and enter the DB type**
   ```bash
   cd <APIM_HOME>
   ./setup-db.sh
   ```

   **Supported database types:** `mysql`, `postgresql`, `oracle`, `mssql`, `db2`

3. **Start APIM**
   ```bash
   ./bin/api-manager.sh
   ```

4. **Cleanup when done**
   ```bash
   ./cleanup.sh
   ```

---

## Database Dump Import (Optional)

You can import existing database dumps instead of using the default initialization scripts. This is useful for:
- Restoring from a backup
- Setting up a database with pre-existing data
- Testing with production-like data

### How to Use Database Dumps

When running `setup-db.sh`, you will be prompted to optionally provide dump file paths:

```bash
./setup-db.sh
# Select database type: mysql
# Path to APIM DB dump file (or press Enter to skip): /path/to/apim_db_dump.sql
# Path to Shared DB dump file (or press Enter to skip): /path/to/shared_db_dump.sql
```

### Supported Dump Formats

- `.sql` - Plain SQL dump files
- `.sql.gz` - Gzip compressed SQL dump files
- `.dump` - Database dump files

### Creating Database Dumps

To create a dump from an existing MySQL database:

```bash
# Plain SQL dump
mysqldump -u username -p database_name > dump.sql

# Compressed dump
mysqldump -u username -p database_name | gzip > dump.sql.gz
```

### Notes on Dump Import

- When dump files are provided, the default initialization scripts are skipped
- Dumps are imported after the database containers are fully ready
- You can provide just one dump file (e.g., only APIM DB) and skip the other
- The script validates dump file existence before proceeding

---

## Manual Setup (Alternative)

### Steps to Set Up Manually

1. **Select the Database Type**
   - Choose the database type you want to use (e.g., MySQL, PostgreSQL, Oracle, MSSQL).

2. **Copy Files**
   - Copy the files from the respective database directory into your `<APIM_HOME>`.

3. **Initialize Database**
   - Run the initialization script:
     ```bash
     ./init_<DB_TYPE>.sh
     ```
   - Example:
     ```bash
     ./init_mysql.sh
     ```

   - This will set up the respective databases and prepare them for use with APIM.

4. **Run APIM**
   - Once the initialization is complete, you can start the APIM pack using the selected database type.

5. **Cleanup**
   - When you are done with your testing, simply run:
     ```bash
     ./cleanup.sh
     ```
   - This will stop the Docker Compose setup and remove the containers.

---

## Notes

- **Dependencies**
  - Some database types will install additional dependencies on your PC during setup.

- **Changing Database Versions**
  - You can change the base DB image in the Docker Compose files to use different DB versions.
  - ⚠️ This may require additional changes in the provided scripts to ensure compatibility.

---

## Example

To set up APIM with PostgreSQL:

```bash
# Copy PostgreSQL setup files into APIM_HOME
cp -r <DB_CHANGE_SCRIPTS>/postgres/* <APIM_HOME>/

# Run initialization
./<APIM_HOME>/init_postgres.sh

# Start APIM with PostgreSQL
./<APIM_HOME>/bin/api-manager.sh
