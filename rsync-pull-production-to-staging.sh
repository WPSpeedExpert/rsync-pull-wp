#!/bin/bash
# ==============================================================================
# Script Name:        Rsync Production to Staging | CloudPanel to CloudPanel
# Description:        High-performance, robust Rsync pull for large-scale websites with advanced logging,
#                     optimized for execution from staging or production servers.
# Compatibility:      Linux (Debian/Ubuntu) running CloudPanel & WordPress
# Requirements:       CloudPanel, ssh-keygen, pv (Pipe Viewer)
# Author:             WP Speed Expert
# Author URI:         https://wpspeedexpert.com
# Version:            5.6.7
# GitHub:             https://github.com/WPSpeedExpert/rsync-pull-wp/
# To Make Executable: chmod +x rsync-pull-production-to-staging.sh
# Crontab Schedule:   0 0 * * * /home/${staging_domainName}/rsync-pull-production-to-staging.sh 2>&1
# ==============================================================================
#
# ==============================================================================
# Part 1: Header and Initial Setup
# ==============================================================================
#
# Variables: Source | Production
domainName=("domainName.com")
siteUser=("site-user")

# Variables: Destination | Staging
staging_domainName=("staging.domainName.com")
staging_siteUser=("staging_siteUser")

# Remote server settings
use_remote_server="true"
remote_server_ssh="root@0.0.0.0"

# Add variables for maintenance page
admin_email="someone@example.com" # Admin email for contact and alerts
team_name="The Team"  # Customize this as needed

# Define the timezone variable (Default: Europe/Amsterdam)
# To find your correct time zone, you can use the 'timedatectl' command on a Linux system or visit the IANA time zone database at https://www.iana.org/time-zones.
timezone="Europe/Amsterdam"

# Log the date and time with the correct timezone
start_time=$(TZ="$timezone" date)

# Set the table prefix for WordPress database tables.
# Default is 'wp_' but may vary if customized.
table_Prefix=("wp_")

# Source | Production
databaseName="${siteUser}" # change if different from siteUser
databaseUserName="${siteUser}" # change if different from siteUser
websitePath="/home/${siteUser}/htdocs/${domainName}"
scriptPath="/home/${siteUser}"

# Destination | Staging
staging_databaseName="${staging_siteUser}" # change if different from siteUser
staging_databaseUserName="${staging_siteUser}" # change if different from siteUser
staging_websitePath="/home/${staging_siteUser}/htdocs/${staging_domainName}"
staging_scriptPath="/home/${staging_siteUser}"

LogFile="${staging_scriptPath}/rsync-pull-production-to-staging.log"

# Database password for the staging (destination) database from .my.cnf
staging_databaseUserPassword=$(sed -n 's/^password\s*=\s*"\(.*\)".*/\1/p' "${staging_scriptPath}/.my.cnf")

# ==============================================================================
# Part 2: Database Export, Import, MySQL Management, and Key Settings
# ==============================================================================

# Database import method control:
# Choose the method for importing the database. The available options are:
# - "clpctl": Use CloudPanel's clpctl tool to directly import the compressed SQL file.
# - "unzip_clpctl": Unzip the SQL file first, then use clpctl to import the unzipped file.
# - "mysql_gunzip": Uncompress the SQL file using gunzip and pipe it directly into MySQL.
# - "mysql_unzip": Import an already uncompressed SQL file using the MySQL command-line client.
# - "gunzip": Uncompress the SQL file using gunzip and import it directly using MySQL commands.
# - "default": Standard method that unzips the SQL file and imports it using MySQL commands.
import_methods=("clpctl" "unzip_clpctl" "mysql_gunzip" "mysql_unzip" "gunzip" "default")

# Set this variable to true if you want to use pv (Pipe Viewer) for showing progress during database import.
# Note: pv is only compatible with the following methods: "mysql_gunzip", "mysql_unzip", "gunzip", "default".
# Set it to false if you are running the script via cron or do not require progress display.
use_pv="false"

# Install PV if not installed (set to true or false).
install_pv_if_missing="true"

# MySQL and Server Restart Options:
# This variable determines how MySQL is managed and whether the server should be rebooted during the script's execution.
# - "restart": Restarts the MySQL service to ensure changes take effect.
# - "stop_start": Stops the MySQL service and then starts it again, useful for more thorough service resets.
# - "reboot": Performs a graceful shutdown and reboots the entire server, ensuring all services restart.
# - "none": No action is taken regarding MySQL or the server, preserving the current state.
mysql_restart_method="stop_start"

# Backup Options for Destination Database (Staging Environment):
# Controls whether the destination website's database (in Cloudpanel and MySQL) should be backed up before any deletion occurs.
# Set to true to create a backup of the staging (destination) database before proceeding with deletion.
backup_staging_database="true"

# Database Recreation Options for Destination Website:
# Determines how the destination website's database (in Cloudpanel and MySQL) is handled during the sync process.
# Set to true to delete the entire staging (destination) database and recreate it from scratch.
# Set to false if you prefer to drop all tables in the staging database instead of deleting the entire database.
recreate_database="true"

# Set to true to enable automated retry on import failure (maximum retries: 2)
enable_automatic_retry="true"
max_retries="1"

# Set to false if you do not want to keep the wp-content/uploads folder during cleanup
# Typically set to true for very large websites with a large media library.
keep_uploads_folder="false"

# Set to true if you want to use an alternate domain name for the search and replace query
use_alternate_domain="false"

# Alternate domain name (only used if use_alternate_domain is true)
alternate_domainName="staging.${staging_domainName}"

# Option to enable or disable database maintenance after import
perform_database_maintenance="true"  # Set to false if you don't want to perform maintenance

# Option to log or suppress database maintenance output
log_database_maintenance="false"  # Set to false to suppress logs

# URL of the raw maintenance page template hosted on GitHub.
maintenance_template_url="https://raw.githubusercontent.com/WPSpeedExpert/rsync-pull-wp/main/maintenance-template.html"

# Option to pause the script after creating the maintenance page for testing purposes.
pause_after_maintenance_creation="false"  # Set to true to enable the pause

# URL of the raw wp-config.php template hosted on GitHub.
template_url="https://raw.githubusercontent.com/WPSpeedExpert/rsync-pull-wp/main/wp-config-template.php"

# Define the path where the wp-config.php will be generated
output_path="${staging_websitePath}/wp-config.php"

# ==============================================================================
# Part 3: Functions
# ==============================================================================

# ------------------------------------------------------------------------------
# Function: rename_user_ini
# Description: Renames the .user.ini file to .user.ini.bak if it exists, ensuring
#              that the file is preserved during the sync process.
# ------------------------------------------------------------------------------
rename_user_ini() {
    if [ -f "${staging_websitePath}/.user.ini" ]; then
        echo "[+] NOTICE: Renaming .user.ini to .user.ini.bak" 2>&1 | tee -a ${LogFile}
        mv "${staging_websitePath}/.user.ini" "${staging_websitePath}/.user.ini.bak"
        if [ $? -ne 0 ]; then
            echo "[+] ERROR: Failed to rename .user.ini. Aborting!" 2>&1 | tee -a ${LogFile}
            exit 1
        fi
    else
        echo "[+] NOTICE: No .user.ini file found to rename." 2>&1 | tee -a ${LogFile}
    fi
}

# ------------------------------------------------------------------------------
# Function: restore_user_ini
# Description: Restores the original .user.ini file from the backup
#              (.user.ini.bak) after the sync process is complete.
# ------------------------------------------------------------------------------
restore_user_ini() {
    if [ -f "${staging_websitePath}/.user.ini.bak" ]; then
        echo "[+] NOTICE: Restoring .user.ini from .user.ini.bak" 2>&1 | tee -a ${LogFile}
        mv "${staging_websitePath}/.user.ini.bak" "${staging_websitePath}/.user.ini"
        if [ $? -ne 0 ]; then
            echo "[+] ERROR: Failed to restore .user.ini. Aborting!" 2>&1 | tee -a ${LogFile}
            exit 1
        fi
    else
        echo "[+] NOTICE: No .user.ini.bak file found to restore." 2>&1 | tee -a ${LogFile}
    fi
}

# ==============================================================================
# Function: generate_wp_config
# Description: Downloads the wp-config.php template from GitHub, replaces
#              placeholders with actual values, writes the final output
#              to the specified file, and sets appropriate permissions.
# Parameters:
#              1. GitHub raw template URL
#              2. Output file path
# ==============================================================================
generate_wp_config() {
    local template_url="$1"
    local output_file="$2"

    # Temporary files to store the downloaded template and WP salts in /tmp
    local temp_template="/tmp/wp-config-template.php"
    local wp_salts_file="/tmp/wp_keys.txt"

    # Download the template from GitHub to /tmp
    echo "[+] NOTICE: Downloading wp-config.php template from GitHub."
    curl -sL "$template_url" -o "$temp_template"

    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to download the wp-config.php template."
        exit 1
    fi

    # Generate WP salts and save to /tmp/wp_keys.txt
    echo "[+] NOTICE: Generating WP salts."
    curl -s http://api.wordpress.org/secret-key/1.1/salt/ > "$wp_salts_file"

    if [ ! -s "$wp_salts_file" ]; then
        echo "[+] ERROR: Failed to generate WP salts."
        exit 1
    fi

    # Replace placeholders in the template with actual values and output to the desired file
    echo "[+] NOTICE: Replacing placeholders in the wp-config.php template."
    sed -e "s|{{DB_NAME}}|${staging_databaseName}|g" \
        -e "s|{{DB_USER}}|${staging_databaseUserName}|g" \
        -e "s|{{DB_PASSWORD}}|${staging_databaseUserPassword}|g" \
        -e "s|{{DB_HOST}}|${db_host}|g" \
        -e "s|{{TABLE_PREFIX}}|${table_Prefix}|g" \
        -e "s|{{DOMAIN_NAME}}|${staging_domainName}|g" \
        -e "/{{WP_SALTS}}/r $wp_salts_file" \
        -e "s|{{WP_SALTS}}||g" \
        "$temp_template" > "$output_file"

    # Check if the file was created successfully
    if [ -f "$output_file" ]; then
        echo "[+] SUCCESS: wp-config.php generated successfully."
    else
        echo "[+] ERROR: Failed to generate wp-config.php."
        exit 1
    fi

    # Set file ownership and permissions
    echo "[+] NOTICE: Setting ownership and permissions for wp-config.php."
    chown ${staging_siteUser}:${staging_siteUser} "$output_file"
    chmod 00644 "$output_file"

    if [ $? -eq 0 ]; then
        echo "[+] SUCCESS: File permissions set for wp-config.php."
    else
        echo "[+] ERROR: Failed to set file permissions for wp-config.php."
        exit 1
    fi

    # Clean up temporary files
    rm -f "$temp_template"
    rm -f "$wp_salts_file"
}

# ==============================================================================
# Function: choose_import_method
# Description: Determines the appropriate import method based on the use_pv setting.
#              If use_pv is true, methods utilizing pv will be selected where compatible.
#              If an unsupported method is chosen, it will default to the standard method.
# ==============================================================================

choose_import_method() {
    local method=$1
    if [ "$use_pv" = true ]; then
        case "$method" in
            "mysql_gunzip")
                echo "pv_gunzip"  # Use pv to show progress during gunzip and import
                ;;
            "mysql_unzip")
                echo "pv_mysql_unzip"  # Use pv during unzipping and then import
                ;;
            "gunzip")
                echo "pv_gunzip"  # Use pv to show progress during gunzip and import
                ;;
            "default")
                echo "pv_default"  # Use pv during the default import method
                ;;
            *)
                echo "$method"  # Unsupported method for pv, fallback to the standard method
                ;;
        esac
    else
        # Use standard methods without pv
        echo "$method"
    fi
}

# ==============================================================================
# Function: check_database_integrity
# Description: Ensures key WordPress tables exist and contain data in the
#              staging database. Logs an error and returns 1 if any table is
#              missing or empty; returns 0 if all checks pass.
# ==============================================================================
check_database_integrity() {
    echo "[+] NOTICE: Checking database integrity for selected tables." 2>&1 | tee -a ${LogFile}

    # List of relevant tables for WordPress
    required_tables=(
        "options"
        "posts"
        "postmeta"
        "terms"
        "term_taxonomy"
        "term_relationships"
        "usermeta"
        "users"
    )

    # Loop through each table and check if it exists and has data
    for table in "${required_tables[@]}"; do
        full_table_name="${table_Prefix}${table}"

        # Check if the table exists
        table_exists=$(mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -e "SHOW TABLES LIKE '$full_table_name';" | grep "$full_table_name")

        if [ -z "$table_exists" ]; then
            echo "[+] ERROR: Table $full_table_name does not exist. Import may have failed." 2>&1 | tee -a ${LogFile}
            return 1
        else
            # If the table exists, check if it has data
            row_count=$(mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -e "SELECT COUNT(*) FROM $full_table_name;" | tail -n 1)
            if [ "$row_count" -le 0 ]; then
                echo "[+] ERROR: Table $full_table_name has no data. Import may have failed." 2>&1 | tee -a ${LogFile}
                return 1
            else
                echo "[+] SUCCESS: Table $full_table_name has $row_count rows." 2>&1 | tee -a ${LogFile}
            fi
        fi
    done

    echo "[+] NOTICE: Database integrity check completed successfully." 2>&1 | tee -a ${LogFile}
    return 0
}

# ==============================================================================
# Function: perform_database_maintenance
# Description: Executes database maintenance tasks such as optimizing tables
#              within the staging environment's MySQL database. This operation
#              is controlled by the 'perform_database_maintenance' flag.
#              If the flag is set to true, the function will run; otherwise,
#              the script will skip this step.
# ==============================================================================
perform_database_maintenance() {
    if [ "$perform_database_maintenance" = true ]; then
        echo "[+] NOTICE: Starting database optimization and maintenance tasks." 2>&1 | tee -a ${LogFile}

        if [ "$log_database_maintenance" = true ]; then
            # Log the output
            mysqlcheck --defaults-extra-file=${staging_scriptPath}/.my.cnf --optimize --all-databases 2>&1 | tee -a ${LogFile}
        else
            # Suppress the output
            mysqlcheck --defaults-extra-file=${staging_scriptPath}/.my.cnf --optimize --all-databases > /dev/null 2>&1
        fi

        if [ $? -eq 0 ]; then
            echo "[+] SUCCESS: Database optimization and maintenance completed successfully." 2>&1 | tee -a ${LogFile}
        else
            echo "[+] ERROR: Database optimization and maintenance failed." 2>&1 | tee -a ${LogFile}
        fi
    else
        echo "[+] NOTICE: Database maintenance is disabled. Skipping optimization tasks." 2>&1 | tee -a ${LogFile}
    fi
}

# ==============================================================================
# Part 4: Start of the script
# ==============================================================================

# Empty the log file if it exists
if [ -f ${LogFile} ]; then
    truncate -s 0 ${LogFile}
fi

# Record the start time of the script
script_start_time=$(date +%s)

# Log the date and time
echo "[+] NOTICE: Start script: ${start_time}" 2>&1 | tee -a ${LogFile}

# ==============================================================================
# Part 5: Pre-execution Checks (Local and Remote)
# ==============================================================================

# 0. Check if .my.cnf Exists on the Local Server
if [ ! -f "${staging_scriptPath}/.my.cnf" ]; then
    echo "[+] PRE-CHECK ERROR: .my.cnf not found at ${staging_scriptPath}/.my.cnf" 2>&1 | tee -a ${LogFile}
    exit 1
else
    echo "[+] PRE-CHECK: .my.cnf found at ${staging_scriptPath}/.my.cnf" 2>&1 | tee -a ${LogFile}
fi

# 1. Check SSH Connection to Remote Server (Only if using a remote server)
if [ "$use_remote_server" = true ]; then
    echo "[+] PRE-CHECK: Checking SSH connection to remote server: ${remote_server_ssh}" 2>&1 | tee -a ${LogFile}
    if ssh -o BatchMode=yes -o ConnectTimeout=5 ${remote_server_ssh} 'true' 2>&1 | tee -a ${LogFile}; then
        echo "[+] PRE-CHECK: SSH connection to remote server established." 2>&1 | tee -a ${LogFile}
    else
        echo "[+] PRE-CHECK ERROR: SSH connection to remote server failed. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi
fi

# 2. Check if the Website Directory Exists on Remote or Local Server
if [ "$use_remote_server" = true ]; then
    # Remote server check
    echo "[+] PRE-CHECK: Checking if remote website directory exists: ${websitePath}" 2>&1 | tee -a ${LogFile}
    if ssh ${remote_server_ssh} "[ -d ${websitePath} ]"; then
        echo "[+] PRE-CHECK: Remote website directory exists." 2>&1 | tee -a ${LogFile}
    else
        echo "[+]  PRE-CHECK ERROR: Remote website directory does not exist. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi
else
    # Local server check
    echo "[+] PRE-CHECK: Checking if local website directory exists: ${websitePath}" 2>&1 | tee -a ${LogFile}
    if [ -d ${websitePath} ]; then
        echo "[+] PRE-CHECK: Local website directory exists." 2>&1 | tee -a ${LogFile}
    else
        echo "[+] PRE-CHECK ERROR: Local website directory does not exist. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi
fi

# 3. Check if wp-config.php Exists to Confirm WordPress Installation (Remote or Local Server)
is_wordpress_installation=false

if [ "$use_remote_server" = true ]; then
    # Remote server check
    echo "[+] PRE-CHECK: Checking if wp-config.php exists in remote directory." 2>&1 | tee -a ${LogFile}
    remote_wp_config="${websitePath}/wp-config.php"
    if ssh ${remote_server_ssh} "[ -f ${remote_wp_config} ]"; then
        echo "[+] PRE-CHECK: wp-config.php found in remote directory." 2>&1 | tee -a ${LogFile}
        is_wordpress_installation=true
    else
        echo "[+] PRE-CHECK: wp-config.php not found in remote directory, skipping WP checks." 2>&1 | tee -a ${LogFile}
    fi
else
    # Local server check
    echo "[+] PRE-CHECK: Checking if wp-config.php exists in local directory." 2>&1 | tee -a ${LogFile}
    local_wp_config="${websitePath}/wp-config.php"
    if [ -f ${local_wp_config} ]; then
        echo "[+] PRE-CHECK: wp-config.php found in local directory." 2>&1 | tee -a ${LogFile}
        is_wordpress_installation=true
    else
        echo "[+] PRE-CHECK: wp-config.php not found in local directory, skipping WP checks." 2>&1 | tee -a ${LogFile}
    fi
fi

# ==============================================================================
# Part 6: Pre-execution Checks (Local) and Creating the wp-config.php File
# ==============================================================================

# Check for command dependencies
for cmd in mysql rsync; do
    if ! command -v $cmd &> /dev/null; then
        echo "[+] PRE-CHECK ERROR: $cmd could not be found. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi
done

# Check for PV if needed
if [ "$use_pv" = true ]; then
    if ! command -v pv &> /dev/null; then
        if [ "$install_pv_if_missing" = true ]; then
            echo "[+] PRE-CHECK NOTICE: pv not found, installing..." 2>&1 | tee -a ${LogFile}
            sudo apt-get update && sudo apt-get install -y pv
            if [ $? -ne 0 ]; then
                echo "[+] PRE-CHECK ERROR: Failed to install pv. Aborting!" 2>&1 | tee -a ${LogFile}
                exit 1
            fi
        else
            echo "[+] PRE-CHECK WARNING: pv not found, proceeding without it." 2>&1 | tee -a ${LogFile}
            use_pv=false
        fi
    fi
fi

# Check for WP directory & wp-config.php
if [ ! -d "${staging_websitePath}" ]; then
  echo "[+] PRE-CHECK ERROR: Directory ${staging_websitePath} does not exist. Aborting!" 2>&1 | tee -a ${LogFile}
  exit 1
fi

if [ ! -f "${staging_websitePath}/wp-config.php" ]; then
  echo "[+] PRE-CHECK ERROR: No wp-config.php in ${staging_websitePath}" 2>&1 | tee -a ${LogFile}
  echo "[+] PRE-CHECK WARNING: Creating wp-config.php in ${staging_websitePath}" 2>&1 | tee -a ${LogFile}

  # Call the function to generate the wp-config.php using the pre-defined variables from Part 2
  generate_wp_config "$template_url" "$output_path"

  echo "[+] PRE-CHECK SUCCESS: Created wp-config.php in ${staging_websitePath}"
  exit
fi 2>&1 | tee -a ${LogFile}

if [ -f ${staging_websitePath}/wp-config.php ]; then
  echo "[+] PRE-CHECK: Found wp-config.php in ${staging_websitePath}"
fi 2>&1 | tee -a ${LogFile}

echo "[+] All pre-execution checks passed. Proceeding with script execution." 2>&1 | tee -a ${LogFile}

# ==============================================================================
# Part 7: Maintenance Page Creation and Initial Cleanup
# ==============================================================================

# Rename .user.ini before any cleanup to ensure it is preserved
rename_user_ini

# Create a maintenance page
echo "[+] NOTICE: Creating maintenance page as index.html" 2>&1 | tee -a "${LogFile}"

# Define the path for the maintenance page
maintenance_page="${staging_websitePath}/index.html"

# Download the maintenance page template from GitHub
curl -sL "$maintenance_template_url" -o "$maintenance_page"

# Verify the download was successful
if [ ! -s "$maintenance_page" ]; then
    echo "[+] ERROR: Failed to download the maintenance page template or the file is empty. Please check the URL." 2>&1 | tee -a "${LogFile}"
    exit 1
else
    echo "[+] SUCCESS: Maintenance page template downloaded successfully." 2>&1 | tee -a "${LogFile}"
fi

# Replace the placeholder with the actual team name
sed -i "s/{{TEAM_NAME}}/${team_name}/g" "$maintenance_page"

# Replace the placeholder with the actual admin email
sed -i "s/{{ADMIN_EMAIL}}/${admin_email}/g" "$maintenance_page"

# Verify that the placeholders were replaced correctly
if grep -q "{{TEAM_NAME}}" "$maintenance_page" || grep -q "{{ADMIN_EMAIL}}" "$maintenance_page"; then
    echo "[+] ERROR: Placeholder replacement failed. Please check the template file and the script." 2>&1 | tee -a "${LogFile}"
    exit 1
else
    echo "[+] SUCCESS: Placeholder replacement completed." 2>&1 | tee -a "${LogFile}"
fi

# Set correct ownership and permissions for the maintenance page
echo "[+] NOTICE: Setting correct ownership and permissions for index.html" 2>&1 | tee -a "${LogFile}"
chown -Rf "${staging_siteUser}:${staging_siteUser}" "$maintenance_page"
chmod 00755 "$maintenance_page"

# Immediately delete the original index.php file after setting permissions for index.html
echo "[+] NOTICE: Deleting original index.php file." 2>&1 | tee -a "${LogFile}"
rm -f "${staging_websitePath}/index.php"

# Pause the script if the pause_after_maintenance_creation variable is set to true
if [ "$pause_after_maintenance_creation" = true ]; then
    echo "[+] PAUSE: The script will now pause for 60 seconds to allow testing of the maintenance page." 2>&1 | tee -a "${LogFile}"
    sleep 60
    echo "[+] NOTICE: Resuming script execution after the pause." 2>&1 | tee -a "${LogFile}"
fi

# Clean and remove specific directories if they exist before general cleanup
echo "[+] NOTICE: Deleting plugins, cache, and EWWW directories" 2>&1 | tee -a ${LogFile}
rm -rf ${staging_websitePath}/wp-content/plugins
rm -rf ${staging_websitePath}/wp-content/cache
rm -rf ${staging_websitePath}/wp-content/EWWW

# Clean and remove destination website files (except for the wp-config.php, .user.ini, .user.ini.bak, and index.html)
echo "[+] NOTICE: Cleaning up the destination website files: ${staging_websitePath}" 2>&1 | tee -a ${LogFile}

if [ "$keep_uploads_folder" = true ]; then
    echo "[+] NOTICE: Keeping the uploads folder during cleanup." 2>&1 | tee -a ${LogFile}
    find ${staging_websitePath}/ -mindepth 1 ! -regex '^'${staging_websitePath}'/wp-config.php' ! -regex '^'${staging_websitePath}'/.user.ini' ! -regex '^'${staging_websitePath}'/.user.ini.bak' ! -regex '^'${staging_websitePath}'/index.html' ! -regex '^'${staging_websitePath}'/wp-content/uploads\(/.*\)?' -delete 2>&1 | tee -a ${LogFile}
else
    echo "[+] NOTICE: Deleting all files including the uploads folder." 2>&1 | tee -a ${LogFile}
    find ${staging_websitePath}/ -mindepth 1 ! -regex '^'${staging_websitePath}'/wp-config.php' ! -regex '^'${staging_websitePath}'/.user.ini' ! -regex '^'${staging_websitePath}'/.user.ini.bak' ! -regex '^'${staging_websitePath}'/index.html' -delete 2>&1 | tee -a ${LogFile}
fi

# ==============================================================================
# Part 8: Database Export from Production and Backup
# ==============================================================================

# Export the production (source) MySQL database
if [ "$use_remote_server" = true ]; then
    echo "[+] NOTICE: Exporting the production (source) database: ${databaseName}" 2>&1 | tee -a ${LogFile}
    ssh ${remote_server_ssh} "clpctl db:export --databaseName=${databaseName} --file=${scriptPath}/tmp/${databaseName}.sql.gz" 2>&1 | tee -a ${LogFile}

    # Sync the database
    echo "[+] NOTICE: Syncing the database: ${databaseName}.sql.gz" 2>&1 | tee -a ${LogFile}
    rsync -azP ${remote_server_ssh}:${scriptPath}/tmp/${databaseName}.sql.gz ${staging_scriptPath}/tmp 2>&1 | tee -a ${LogFile}

    # Clean up the remote database export file
    echo "[+] NOTICE: Cleaning up the remote database export file: ${databaseName}" 2>&1 | tee -a ${LogFile}
    ssh ${remote_server_ssh} "rm ${scriptPath}/tmp/${databaseName}.sql.gz" 2>&1 | tee -a ${LogFile}
else
    # If both websites are on the same server we can export directly to the destination scriptPath
    echo "[+] NOTICE: Exporting the production (source) database: ${databaseName}" 2>&1 | tee -a ${LogFile}
    clpctl db:export --databaseName=${databaseName} --file=${staging_scriptPath}/tmp/${databaseName}.sql.gz 2>&1 | tee -a ${LogFile}
fi

# Check for and delete older database backups
backup_file="${staging_scriptPath}/tmp/${staging_databaseName}-backup-$(date +%F).sql.gz"
if ls ${staging_scriptPath}/tmp/${staging_databaseName}-backup-*.sql.gz 1> /dev/null 2>&1; then
    echo "[+] NOTICE: Deleting older backup files in ${staging_scriptPath}/tmp/" 2>&1 | tee -a ${LogFile}
    rm ${staging_scriptPath}/tmp/${staging_databaseName}-backup-*.sql.gz
    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to delete the older backup files." 2>&1 | tee -a ${LogFile}
    else
        echo "[+] SUCCESS: Older backup files deleted." 2>&1 | tee -a ${LogFile}
    fi
fi

# Optionally backup the staging database
if [ "$backup_staging_database" = true ]; then
    echo "[+] NOTICE: Creating a backup of the staging database: ${staging_databaseName}" 2>&1 | tee -a ${LogFile}
    clpctl db:export --databaseName=${staging_databaseName} --file=${backup_file} 2>&1 | tee -a ${LogFile}
    export_status=$?

    if [ $export_status -ne 0 ]; then
        echo "[+] ERROR: Failed to create a backup of the staging database. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    else
        echo "[+] SUCCESS: Backup created successfully: ${backup_file}" 2>&1 | tee -a ${LogFile}
    fi
fi

# ==============================================================================
# Part 9: Database Recreation and Import
# ==============================================================================

# Optionally delete and recreate the staging database, or drop all tables
if [ "$recreate_database" = true ]; then
    echo "[+] WARNING: Deleting the database: ${staging_databaseName}" 2>&1 | tee -a ${LogFile}
    clpctl db:delete --databaseName=${staging_databaseName} --force 2>&1 | tee -a ${LogFile}

    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to delete the staging database. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi

    echo "[+] NOTICE: Adding the database: ${staging_databaseName}" 2>&1 | tee -a ${LogFile}
    clpctl db:add --domainName=${staging_domainName} --databaseName=${staging_databaseName} --databaseUserName=${staging_databaseUserName} --databaseUserPassword="${staging_databaseUserPassword}" 2>&1 | tee -a ${LogFile}
    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to add the staging database. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi
else
    echo "[+] NOTICE: Dropping all database tables from ${staging_databaseName} ..." 2>&1 | tee -a ${LogFile}
    tables=$(mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -Nse 'SHOW TABLES' ${staging_databaseName})
    for table in $tables; do
        echo "[+] NOTICE: Dropping $table from ${staging_databaseName}." 2>&1 | tee -a ${LogFile}
        mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf  -e "DROP TABLE $table" ${staging_databaseName}
        if [ $? -ne 0 ]; then
            echo "[+] ERROR: Failed to drop table $table. Aborting!" 2>&1 | tee -a ${LogFile}
            exit 1
        fi
    done
    echo "[+] SUCCESS: All tables dropped from ${staging_databaseName}." 2>&1 | tee -a ${LogFile}
fi

# ==============================================================================
# Part 10: Database Import Function and URL Update
# ==============================================================================

# Function to import the database using different methods
import_database() {
    # Choose the appropriate method based on the current settings and use_pv variable
    method=$(choose_import_method "$1")
    echo "[+] NOTICE: Importing the MySQL database using method: $method" 2>&1 | tee -a ${LogFile}

    # Record the start time of the database import process
    start_time=$(date +%s)

    # Database import logic
    case "$method" in
        "clpctl")
            clpctl db:import --databaseName=${staging_databaseName} --file=${staging_scriptPath}/tmp/${databaseName}.sql.gz 2>&1 | tee -a ${LogFile}
            ;;
        "unzip_clpctl")
            gunzip -c ${staging_scriptPath}/tmp/${databaseName}.sql.gz > ${staging_scriptPath}/tmp/${databaseName}.sql
            clpctl db:import --databaseName=${staging_databaseName} --file=${staging_scriptPath}/tmp/${databaseName}.sql 2>&1 | tee -a ${LogFile}
            ;;
        "pv_gunzip")
            pv ${staging_scriptPath}/tmp/${databaseName}.sql.gz | gunzip | mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} 2>&1 | tee -a ${LogFile}
            ;;
        "pv_unzip")
            pv ${staging_scriptPath}/tmp/${databaseName}.sql.gz | gunzip > ${staging_scriptPath}/tmp/${databaseName}.sql
            mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} < ${staging_scriptPath}/tmp/${databaseName}.sql 2>&1 | tee -a ${LogFile}
            ;;
        "pv_default")
            pv ${staging_scriptPath}/tmp/${databaseName}.sql.gz | gunzip | mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} 2>&1 | tee -a ${LogFile}
            ;;
        "mysql_gunzip")
            gunzip -c ${staging_scriptPath}/tmp/${databaseName}.sql.gz | mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} 2>&1 | tee -a ${LogFile}
            ;;
        "mysql_unzip")
            gunzip -c ${staging_scriptPath}/tmp/${databaseName}.sql.gz > ${staging_scriptPath}/tmp/${databaseName}.sql
            mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} < ${staging_scriptPath}/tmp/${databaseName}.sql 2>&1 | tee -a ${LogFile}
            ;;
        "gunzip")
            gunzip -c ${staging_scriptPath}/tmp/${databaseName}.sql.gz | mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} 2>&1 | tee -a ${LogFile}
            ;;
        "default")
            gunzip -c ${staging_scriptPath}/tmp/${databaseName}.sql.gz | mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} 2>&1 | tee -a ${LogFile}
            ;;
        *)
            echo "[+] ERROR: Unknown import method: $method" 2>&1 | tee -a ${LogFile}
            return 1
            ;;
    esac

    # Check if the import was successful
    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to import the MySQL database using method: $method" 2>&1 | tee -a ${LogFile}
        return 1
    fi

    # Verify the site URL in the database matches the expected URL
    expected_url="https://${domainName}"
    query=$(mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -se "SELECT option_value FROM ${table_Prefix}options WHERE option_name = 'siteurl';")

    # Strip trailing slashes and whitespace for comparison
    expected_url=$(echo "$expected_url" | sed 's:/*$::' | xargs)
    query=$(echo "$query" | sed 's:/*$::' | xargs)

    # Check if the retrieved URL matches the expected URL
    if [ "$query" != "$expected_url" ]; then
        echo "[+] ERROR: Site URL mismatch. Expected: $expected_url, Found: $query" 2>&1 | tee -a ${LogFile}
        return 1
    else
        echo "[+] SUCCESS: Site URL matches the expected URL ($expected_url)." 2>&1 | tee -a ${LogFile}
    fi

    # Record the end time and calculate the elapsed time
    end_time=$(date +%s)
    elapsed_time=$((end_time - start_time))

    # Convert elapsed time to hours, minutes, and seconds
    hours=$((elapsed_time / 3600))
    minutes=$(( (elapsed_time % 3600) / 60 ))
    seconds=$((elapsed_time % 60))

    # Display the elapsed time in a human-readable format
    echo "[+] NOTICE: Database import took ${hours} hours, ${minutes} minutes, and ${seconds} seconds." 2>&1 | tee -a ${LogFile}
    return 0
}

# ==============================================================================
# Part 11: Retry Mechanism for Database Import
# ==============================================================================

# This section will attempt to import the database using various methods. If one method fails,
# it retries up to a specified maximum number of times before moving on to the next method.

# Initialize a flag to track if the import was successful
import_success=false

# Loop through each import method specified in the import_methods array
for original_method in "${import_methods[@]}"; do
    method=$(choose_import_method "$original_method")

    # Initialize the retry count for the current method
    retry_count=0

    # Attempt the import, retrying up to max_retries times if it fails
    while [ $retry_count -lt $max_retries ]; do
        import_database $method  # Call the function to perform the database import

        # Check if the import was successful
        if [ $? -eq 0 ]; then
            import_success=true
            break  # Exit the retry loop for this method
        else
            # If the import failed, increment the retry count and log a warning
            echo "[+] WARNING: Import method $method failed. Retrying ($((retry_count + 1))/$max_retries)..." 2>&1 | tee -a ${LogFile}
            retry_count=$((retry_count + 1))
        fi
    done

    # If the import was successful, break out of the loop over methods
    if [ "$import_success" = true ]; then
        break  # Exit the loop over methods
    fi
done

# If the import was not successful after all retries, log an error and abort the script
if [ "$import_success" = false ]; then
    echo "[+] ERROR: All import methods failed after trying each method $max_retries times. Aborting!" 2>&1 | tee -a ${LogFile}
    exit 1  # Exit the script with a failure status
fi

# Run an integrity check on key database tables only once after successful import
check_database_integrity
if [ $? -ne 0 ]; then
    echo "[+] ERROR: Database integrity check failed after successful import." 2>&1 | tee -a ${LogFile}
    exit 1
fi

# Cleanup unzipped SQL files after successful import
if [ -f "${staging_scriptPath}/tmp/${databaseName}.sql" ]; then
    echo "[+] NOTICE: Deleting unzipped SQL file: ${staging_scriptPath}/tmp/${databaseName}.sql" 2>&1 | tee -a ${LogFile}
    rm -f ${staging_scriptPath}/tmp/${databaseName}.sql
fi

# Cleanup split SQL files if any
split_files_patterns=(
    "${staging_scriptPath}/tmp/*_part_*"
    "${staging_scriptPath}/tmp/*-part-*"
    "${staging_scriptPath}/tmp/*-part-*"
)

for pattern in "${split_files_patterns[@]}"; do
    if ls $pattern 1> /dev/null 2>&1; then
        echo "[+] NOTICE: Found split SQL files matching pattern '$pattern'. Deleting them from ${staging_scriptPath}/tmp/" 2>&1 | tee -a ${LogFile}
        rm -f $pattern
        if [ $? -eq 0 ]; then
            echo "[+] SUCCESS: Split SQL files deleted successfully." 2>&1 | tee -a ${LogFile}
        else
            echo "[+] WARNING: Failed to delete some split SQL files. Please check permissions or file locks." 2>&1 | tee -a ${LogFile}
        fi
    else
        echo "[+] NOTICE: No split SQL files found matching pattern '$pattern' in ${staging_scriptPath}/tmp/." 2>&1 | tee -a ${LogFile}
    fi
done

# Remove the MySQL database export file from the staging environment
echo "[+] NOTICE: Deleting the database export file: ${staging_scriptPath}/tmp/${databaseName}.sql.gz" 2>&1 | tee -a ${LogFile}
rm ${staging_scriptPath}/tmp/${databaseName}.sql.gz

# Perform database maintenance after import
perform_database_maintenance

# ==============================================================================
# Part 12: Search and Replace URLs and Rsync Website Files
# ==============================================================================

# Determine the domain to use for the search and replace operation
# If an alternate domain is specified, use it; otherwise, use the staging domain
if [ "$use_alternate_domain" = true ]; then
    final_domainName="$alternate_domainName"
    echo "[+] NOTICE: Using alternate domain for search and replace: ${final_domainName}" 2>&1 | tee -a ${LogFile}
else
    final_domainName="$staging_domainName"
    echo "[+] NOTICE: Using staging domain for search and replace: ${final_domainName}" 2>&1 | tee -a ${LogFile}
fi

# Perform search and replace in the staging database
# This replaces all instances of the production domain with the staging domain (or alternate domain)
echo "[+] NOTICE: Performing search and replace of URLs in the staging database: ${staging_databaseName}." 2>&1 | tee -a ${LogFile}

# Strip trailing slashes and whitespace for comparison
domainName=$(echo "${domainName}" | sed 's:/*$::' | xargs)
final_domainName=$(echo "${final_domainName}" | sed 's:/*$::' | xargs)

mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -e "
UPDATE ${table_Prefix}options SET option_value = REPLACE(option_value, 'https://${domainName}', 'https://${final_domainName}') WHERE option_name = 'home' OR option_name = 'siteurl';
UPDATE ${table_Prefix}posts SET post_content = REPLACE(post_content, 'https://${domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}posts SET post_excerpt = REPLACE(post_excerpt, 'https://${domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}postmeta SET meta_value = REPLACE(meta_value, 'https://${domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}termmeta SET meta_value = REPLACE(meta_value, 'https://${domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}comments SET comment_content = REPLACE(comment_content, 'https://${domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}comments SET comment_author_url = REPLACE(comment_author_url, 'https://${domainName}','https://${final_domainName}');
UPDATE ${table_Prefix}posts SET guid = REPLACE(guid, 'https://${domainName}', 'https://${final_domainName}') WHERE post_type = 'attachment';
" 2>&1 | tee -a ${LogFile}

# Check if the search and replace operation was successful
if [ $? -ne 0 ]; then
    echo "[+] ERROR: Failed to perform search and replace in the database. Aborting!" 2>&1 | tee -a ${LogFile}
    exit 1
fi

# Verify the site URL in the database matches the expected URL
expected_url="https://${final_domainName}"
query=$(mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -se "SELECT option_value FROM ${table_Prefix}options WHERE option_name = 'siteurl';")

# Strip trailing slashes and whitespace for comparison
expected_url=$(echo "$expected_url" | sed 's:/*$::' | xargs)
query=$(echo "$query" | sed 's:/*$::' | xargs)

# Check if the retrieved URL matches the expected URL
if [ "$query" != "$expected_url" ]; then
    echo "[+] ERROR: Site URL mismatch. Expected: $expected_url, Found: $query" 2>&1 | tee -a ${LogFile}
    return 1
else
    echo "[+] SUCCESS: Site URL matches the expected URL ($expected_url)." 2>&1 | tee -a ${LogFile}
fi

# Disable: Discourage search engines from indexing this website in the staging environment
# Set 'blog_public' to '0' to enable this setting in WordPress
echo "[+] NOTICE: Enabling 'Discourage search engines from indexing this website'." 2>&1 | tee -a ${LogFile}
mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -e "
UPDATE ${table_Prefix}options SET option_value = '0' WHERE option_name = 'blog_public';
" 2>&1 | tee -a ${LogFile}

# ==============================================================================
# Part 13: Rsync Website Files from Production to Staging
# ==============================================================================

# Start the process of synchronizing website files from production to staging
echo "[+] NOTICE: Starting Rsync pull." 2>&1 | tee -a ${LogFile}
start_time=$(date +%s)

# Rsync files from the production environment to the staging environment
if [ "$use_remote_server" = true ]; then
    rsync -azP --update --delete --no-perms --no-owner --no-group --no-times \
          --exclude '/index.php' --exclude '/index.html' --exclude 'wp-content/cache/*' --exclude 'wp-content/backups-dup-pro/*' \
          --exclude 'wp-config.php' --exclude '.user.ini.bak' --exclude '.user.ini' \
          ${remote_server_ssh}:${websitePath}/ ${staging_websitePath}/
else
    rsync -azP --update --delete --no-perms --no-owner --no-group --no-times \
          --exclude '/index.php' --exclude '/index.html' --exclude 'wp-content/cache/*' --exclude 'wp-content/backups-dup-pro/*' \
          --exclude 'wp-config.php' --exclude '.user.ini.bak' --exclude '.user.ini' \
          ${websitePath}/ ${staging_websitePath}/
fi

# Calculate and log the total time taken for the Rsync operation
end_time=$(date +%s)
elapsed_time=$((end_time - start_time))

# Convert elapsed time to hours, minutes, and seconds
hours=$((elapsed_time / 3600))
minutes=$(( (elapsed_time % 3600) / 60 ))
seconds=$((elapsed_time % 60))

# Display the elapsed time in a human-readable format
echo "[+] NOTICE: Rsync pull took ${hours} hours, ${minutes} minutes, and ${seconds} seconds." 2>&1 | tee -a ${LogFile}

# Check if the Rsync operation was successful and handle any errors
if [ $? -ne 0 ]; then
    echo "[+] ERROR: Failed to rsync website files. Aborting!" 2>&1 | tee -a ${LogFile}
    exit 1
fi

# ==============================================================================
# Part 14: Post-Rsync File Permission and Ownership Fixes
# ==============================================================================

# Set correct ownership
echo "[+] NOTICE: Set correct ownership (${staging_siteUser})." 2>&1 | tee -a ${LogFile}
chown -Rf ${staging_siteUser}:${staging_siteUser} ${staging_websitePath}

# Set correct file permissions for folders
echo "[+] NOTICE: Setting correct file permissions (755) for folders." 2>&1 | tee -a ${LogFile}
chmod 00755 -R ${staging_websitePath}

# Set correct file permissions for files
echo "[+] NOTICE: Set correct permissions (644) for files." 2>&1 | tee -a ${LogFile}
find ${staging_websitePath}/ -type f -print0 | xargs -0 chmod 00644

# ==============================================================================
# Part 15: Final Rsync and Remove Maintenance Page After Setting File Permissions
# ==============================================================================

# Ensure the root 'index.php' file is synced last to avoid potential issues during the process
if [ "$use_remote_server" = true ]; then
    rsync -azP --update --delete --no-perms --no-owner --no-group --no-times \
          ${remote_server_ssh}:${websitePath}/index.php ${staging_websitePath}/index.php
else
    rsync -azP --update --delete --no-perms --no-owner --no-group --no-times \
          ${websitePath}/index.php ${staging_websitePath}/index.php
fi

# Set correct ownership and permissions for the index.php page
echo "[+] NOTICE: Setting correct ownership and permissions for index.php" 2>&1 | tee -a ${LogFile}
chown -Rf ${staging_siteUser}:${staging_siteUser} ${staging_websitePath}/index.php
chmod 00755 -R ${staging_websitePath}/index.php

# Clean up by deleting the temporary maintenance page ('index.html') from the staging environment
echo "[+] NOTICE: Deleting the maintenance page (index.html)" 2>&1 | tee -a ${LogFile}
rm -f ${staging_websitePath}/index.html

# Restore .user.ini by renaming from backup if it exists
restore_user_ini

# ==============================================================================
# Part 16: Redis Flush and Restart
# ==============================================================================

# Flush & restart Redis
echo "[+] NOTICE: Flushing and restarting Redis." 2>&1 | tee -a ${LogFile}
# Flush all Redis keys
redis-cli FLUSHALL
# Stop and start Redis service
systemctl stop redis-server
systemctl start redis-server
# Capture and log the status of Redis service
echo "[+] Redis server status after restart:" 2>&1 | tee -a ${LogFile}
systemctl status redis-server 2>&1 | tee -a ${LogFile}

# ==============================================================================
# Part 17: MySQL Restart and Script Completion
# ==============================================================================

# Handle MySQL restart based on chosen method
case "$mysql_restart_method" in
    "restart")
        echo "[+] NOTICE: Restarting MySQL server." 2>&1 | tee -a ${LogFile}
        start_time=$(date +%s)
        systemctl restart mysql
        end_time=$(date +%s)
        echo "[+] MySQL server status after restart:" 2>&1 | tee -a ${LogFile}
        systemctl status mysql 2>&1 | tee -a ${LogFile}
        ;;
    "stop_start")
        echo "[+] NOTICE: Stopping and starting MySQL server." 2>&1 | tee -a ${LogFile}
        start_time=$(date +%s)
        systemctl stop mysql
        systemctl start mysql
        end_time=$(date +%s)
        echo "[+] MySQL server status after stop/start:" 2>&1 | tee -a ${LogFile}
        systemctl status mysql 2>&1 | tee -a ${LogFile}
        ;;
    "reboot")
        echo "[+] NOTICE: Performing a graceful shutdown and reboot." 2>&1 | tee -a ${LogFile}
        start_time=$(date +%s)

        # Calculate elapsed time before rebooting
        end_time=$(date +%s)
        elapsed_time=$((end_time - start_time))
        echo "[+] NOTICE: MySQL reboot preparation took $elapsed_time seconds." 2>&1 | tee -a ${LogFile}

        # Record the end time of the script before rebooting
        script_end_time=$(date +%s)
        total_runtime=$((script_end_time - script_start_time))
        echo "[+] NOTICE: Total script execution time before reboot: $total_runtime seconds." 2>&1 | tee -a ${LogFile}

        # Reboot the system
        shutdown -r now
        ;;
    "none")
        echo "[+] NOTICE: No action taken for MySQL or server restart." 2>&1 | tee -a ${LogFile}
        start_time=$script_end_time  # Assuming script_end_time is set earlier in the script
        end_time=$script_end_time
        ;;
    *)
        echo "[+] WARNING: Invalid mysql_restart_method. No action taken." 2>&1 | tee -a ${LogFile}
        start_time=$script_end_time
        end_time=$script_end_time
        ;;
esac

# Calculate elapsed time for the chosen action
elapsed_time=$((end_time - start_time))

# Convert elapsed time to hours, minutes, and seconds
hours=$((elapsed_time / 3600))
minutes=$(( (elapsed_time % 3600) / 60 ))
seconds=$((elapsed_time % 60))

# Display the elapsed time in a human-readable format
echo "[+] NOTICE: MySQL $mysql_restart_method took ${hours} hours, ${minutes} minutes, and ${seconds} seconds." 2>&1 | tee -a ${LogFile}

# Record the end time of the script and calculate total runtime (excluding reboot scenario)
if [ "$mysql_restart_method" != "reboot" ]; then
    script_end_time=$(date +%s)
    total_runtime=$((script_end_time - script_start_time))

    # Convert total runtime to hours, minutes, and seconds
    hours=$((total_runtime / 3600))
    minutes=$(( (total_runtime % 3600) / 60 ))
    seconds=$((total_runtime % 60))

    # Display the total runtime in a human-readable format
    echo "[+] NOTICE: Total script execution time: ${hours} hours, ${minutes} minutes, and ${seconds} seconds." 2>&1 | tee -a ${LogFile}
fi

# Log the end time with the correct timezone
end_time=$(TZ=$timezone date)
echo "[+] NOTICE: End of script: ${end_time}" 2>&1 | tee -a ${LogFile}
exit 0
