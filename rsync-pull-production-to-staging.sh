#!/bin/bash
# ==============================================================================
# Script Name:        Rsync Production to Staging | CloudPanel to CloudPanel
# Description:        High-performance, robust Rsync pull for large-scale websites with advanced logging,
#                     optimized for execution from staging or production servers.
# Compatibility:      Linux (Debian/Ubuntu) running CloudPanel
# Requirements:       CloudPanel, ssh-keygen, pv (Pipe Viewer)
# Author:             WP Speed Expert
# Author URI:         https://wpspeedexpert.com
# Version:            4.1.3
# GitHub:             https://github.com/WPSpeedExpert/rsync-pull-wp/
# To Make Executable: chmod +x rsync-pull-production-to-staging.sh
# Crontab Schedule:   0 0 * * * /home/epicdeals/rsync-pull-production-to-staging.sh 2>&1
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
use_remote_server=true
remote_server_ssh="root@0.0.0.0"

# Database password for the staging (destination) database from .my.cnf
databaseUserPassword=$(sed -n 's/^password\s*=\s*"\(.*\)".*/\1/p' "${staging_scriptPath}/.my.cnf")

# Source | Production
databaseName=${siteUser} # change if different from siteUser
databaseUserName=${siteUser} # change if different from siteUser
websitePath="/home/${siteUser}/htdocs/${domainName}"
scriptPath="/home/${siteUser}"

# Destination | Staging
staging_databaseName=${staging_siteUser} # change if different from siteUser
staging_databaseUserName=${staging_siteUser} # change if different from siteUser
staging_websitePath="/home/${staging_siteUser}/htdocs/${staging_domainName}"
staging_scriptPath="/home/${staging_siteUser}"

LogFile="${staging_scriptPath}/rsync-pull-production-to-staging.log"

# ==============================================================================
# Part 2: Database Import Techniques, MySQL Restart Methods, and Backup Options
# ==============================================================================

# Database import method control:
# - "clpctl": Uses the clpctl tool directly to import the compressed SQL file.
# - "unzip_clpctl": Unzips the SQL file and then uses clpctl to import the unzipped file.
# - "default": Uses the standard method of uncompressing the SQL file and importing it using MySQL commands.
# - "gunzip": Uncompresses the SQL file using gunzip and imports it using MySQL commands.
# - "pv_gunzip": Uses Pipe Viewer (pv) to show progress while uncompressing the SQL file with gunzip and importing it via MySQL commands.
# - "mysql_unzip": Directly imports an uncompressed SQL file using the MySQL command-line client.
# - "mysql_gunzip": Uncompresses the SQL file using gunzip and pipes it directly to the MySQL command-line client.
import_methods=("clpctl" "unzip_clpctl" "default" "gunzip" "pv_gunzip" "mysql_unzip" "mysql_gunzip")

# MySQL and Server Restart Options:
# This variable determines how MySQL is managed and whether the server should be rebooted during the script's execution.
# - "restart": Restarts the MySQL service to ensure changes take effect.
# - "stop_start": Stops the MySQL service and then starts it again, useful for more thorough service resets.
# - "reboot": Performs a graceful shutdown and reboots the entire server, ensuring all services restart.
# - "none": No action is taken regarding MySQL or the server, preserving the current state.
mysql_restart_method="stop_start"

# Use PV (Pipe Viewer) for monitoring progress manually during import (set to true or false).
use_pv=true

# Install PV if not installed (set to true or false).
install_pv_if_missing=true

# Backup Options for Destination Database (Staging Environment):
# Controls whether the destination website's database (in Cloudpanel and MySQL) should be backed up before any deletion occurs.
# Set to true to create a backup of the staging (destination) database before proceeding with deletion.
backup_staging_database=true

# Database Recreation Options for Destination Website:
# Determines how the destination website's database (in Cloudpanel and MySQL) is handled during the sync process.
# Set to true to delete the entire staging (destination) database and recreate it from scratch.
# Set to false if you prefer to drop all tables in the staging database instead of deleting the entire database.
recreate_database=true

# Set to true to enable automated retry on import failure (maximum retries: 3)
enable_automatic_retry=true
max_retries=3

# Set to false if you do not want to keep the wp-content/uploads folder during cleanup
# Typically set to true for very large websites with a large media library.
keep_uploads_folder=false

# Set to true if you want to use an alternate domain name for the search and replace query
use_alternate_domain=false

# Alternate domain name (only used if use_alternate_domain is true)
alternate_domainName="staging.${staging_domainName}"

# ==============================================================================
# Part 3: Function to rename .user.ini file if it exists
# ==============================================================================

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

# Function to restore the original .user.ini file after the sync
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
    echo "[+] ERROR: .my.cnf not found at ${staging_scriptPath}/.my.cnf" 2>&1 | tee -a ${LogFile}
    exit 1
else
    echo "[+] .my.cnf found at ${staging_scriptPath}/.my.cnf" 2>&1 | tee -a ${LogFile}
fi

# 1. Check SSH Connection to Remote Server (Only if using a remote server)
if [ "$use_remote_server" = true ]; then
    echo "[+] Checking SSH connection to remote server: ${remote_server_ssh}" 2>&1 | tee -a ${LogFile}
    if ssh -o BatchMode=yes -o ConnectTimeout=5 ${remote_server_ssh} 'true' 2>&1 | tee -a ${LogFile}; then
        echo "[+] SSH connection to remote server established." 2>&1 | tee -a ${LogFile}
    else
        echo "[+] ERROR: SSH connection to remote server failed. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi
fi

# 2. Check if the Website Directory Exists on Remote or Local Server
if [ "$use_remote_server" = true ]; then
    # Remote server check
    echo "[+] Checking if remote website directory exists: ${websitePath}" 2>&1 | tee -a ${LogFile}
    if ssh ${remote_server_ssh} "[ -d ${websitePath} ]"; then
        echo "[+] Remote website directory exists." 2>&1 | tee -a ${LogFile}
    else
        echo "[+] ERROR: Remote website directory does not exist. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi
else
    # Local server check
    echo "[+] Checking if local website directory exists: ${websitePath}" 2>&1 | tee -a ${LogFile}
    if [ -d ${websitePath} ]; then
        echo "[+] Local website directory exists." 2>&1 | tee -a ${LogFile}
    else
        echo "[+] ERROR: Local website directory does not exist. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi
fi

# 3. Check if wp-config.php Exists to Confirm WordPress Installation (Remote or Local Server)
is_wordpress_installation=false

if [ "$use_remote_server" = true ]; then
    # Remote server check
    echo "[+] Checking if wp-config.php exists in remote directory." 2>&1 | tee -a ${LogFile}
    remote_wp_config="${websitePath}/wp-config.php"
    if ssh ${remote_server_ssh} "[ -f ${remote_wp_config} ]"; then
        echo "[+] wp-config.php found in remote directory." 2>&1 | tee -a ${LogFile}
        is_wordpress_installation=true
    else
        echo "[+] wp-config.php not found in remote directory, skipping WP checks." 2>&1 | tee -a ${LogFile}
    fi
else
    # Local server check
    echo "[+] Checking if wp-config.php exists in local directory." 2>&1 | tee -a ${LogFile}
    local_wp_config="${websitePath}/wp-config.php"
    if [ -f ${local_wp_config} ]; then
        echo "[+] wp-config.php found in local directory." 2>&1 | tee -a ${LogFile}
        is_wordpress_installation=true
    else
        echo "[+] wp-config.php not found in local directory, skipping WP checks." 2>&1 | tee -a ${LogFile}
    fi
fi

# ==============================================================================
# Part 6: Pre-execution Checks (Local) and Creating the wp-config.php File
# ==============================================================================

# Check for command dependencies
for cmd in mysql rsync; do
    if ! command -v $cmd &> /dev/null; then
        echo "[+] ERROR: $cmd could not be found. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi
done

# Check for PV if needed
if [ "$use_pv" = true ]; then
    if ! command -v pv &> /dev/null; then
        if [ "$install_pv_if_missing" = true ]; then
            echo "[+] NOTICE: pv not found, installing..." 2>&1 | tee -a ${LogFile}
            sudo apt-get update && sudo apt-get install -y pv
            if [ $? -ne 0 ]; then
                echo "[+] ERROR: Failed to install pv. Aborting!" 2>&1 | tee -a ${LogFile}
                exit 1
            fi
        else
            echo "[+] WARNING: pv not found, proceeding without it." 2>&1 | tee -a ${LogFile}
            use_pv=false
        fi
    fi
fi

# Check for WP directory & wp-config.php
if [ ! -d ${staging_websitePath} ]; then
  echo "[+] ERROR: Directory ${staging_websitePath} does not exist. Aborting!" 2>&1 | tee -a ${LogFile}
  exit 1
fi

if [ ! -f ${staging_websitePath}/wp-config.php ]; then
  echo "[+] ERROR: No wp-config.php in ${staging_websitePath}" 2>&1 | tee -a ${LogFile}
  echo "[+] WARNING: Creating wp-config.php in ${staging_websitePath}" 2>&1 | tee -a ${LogFile}
  # Copy the content of WP Salts page
  WPsalts=$(wget https://api.wordpress.org/secret-key/1.1/salt/ -q -O -)
  cat <<EOF > ${staging_websitePath}/wp-config.php
<?php
/**
 * The base configuration for WordPress
 *
 * The wp-config.php creation script uses this file during the installation.
 * You don't have to use the web site, you can copy this file to "wp-config.php"
 * and fill in the values.
 *
 * This file contains the following configurations:
 *
 * * Database settings
 * * Secret keys
 * * Database table prefix
 * * Localized language
 * * ABSPATH
 *
 * @link https://wordpress.org/support/article/editing-wp-config-php/
 *
 * @package WordPress
 */
// define( 'WP_AUTO_UPDATE_CORE', false );

// ** Database settings - You can get this info from your web host ** //
/** The name of the database for WordPress */
define( 'DB_NAME', "${staging_databaseName}" );

/** Database username */
define( 'DB_USER', "${staging_databaseUserName}" );

/** Database password */
define( 'DB_PASSWORD', "${staging_databaseUserPassword}" );

/** Database hostname */
define( 'DB_HOST', "localhost" );

/** Database charset to use in creating database tables. */
define( 'DB_CHARSET', 'utf8' );

/** The database collate type. Don't change this if in doubt. */
define( 'DB_COLLATE', '' );

/**
 * Authentication unique keys and salts.
 *
 * Change these to different unique phrases! You can generate these using
 * the {@link https://api.wordpress.org/secret-key/1.1/salt/ WordPress.org secret-key service}.
 *
 * You can change these at any point in time to invalidate all existing cookies.
 * This will force all users to have to log in again.
 *
 * @since 2.6.0
 */
${WPsalts}
define('WP_CACHE_KEY_SALT','${staging_domainName}');

/**
 * WordPress database table prefix.
 *
 * You can have multiple installations in one database if you give each
 * a unique prefix. Only numbers, letters, and underscores please!
 */
\$table_prefix  = '${table_Prefix}';

/**
 * For developers: WordPress debugging mode.
 *
 * Change this to true to enable the display of notices during development.
 * It is strongly recommended that plugin and theme developers use WP_DEBUG
 * in their development environments.
 *
 * For information on other constants that can be used for debugging,
 * visit the documentation.
 *
 * @link https://wordpress.org/support/article/debugging-in-wordpress/
 */
define( 'WP_DEBUG', false );

/* Add any custom values between this line and the "stop editing" line. */
define( 'FS_METHOD', 'direct' );
define( 'WP_DEBUG_DISPLAY', false );
define( 'WP_DEBUG_LOG', true );
define( 'CONCATENATE_SCRIPTS', false );
define( 'AUTOSAVE_INTERVAL', 600 );
define( 'WP_POST_REVISIONS', 5 );
define( 'EMPTY_TRASH_DAYS', 21 );
/* That's all, stop editing! Happy publishing. */

/** Absolute path to the WordPress directory. */
if ( ! defined( 'ABSPATH' ) ) {
	define( 'ABSPATH', dirname(__FILE__) . '/' );
}

/** Sets up WordPress vars and included files. */
require_once ABSPATH . 'wp-settings.php';
EOF
  echo "[+] SUCCESS: Created wp-config.php in ${staging_websitePath}"
  exit
fi 2>&1 | tee -a ${LogFile}

if [ -f ${staging_websitePath}/wp-config.php ]; then
  echo "[+] SUCCESS: Found wp-config.php in ${staging_websitePath}"
fi 2>&1 | tee -a ${LogFile}

echo "[+] All pre-execution checks passed. Proceeding with script execution." 2>&1 | tee -a ${LogFile}

# ==============================================================================
# Part 7: Maintenance Page Creation and Initial Cleanup
# ==============================================================================

# Rename .user.ini before any cleanup to ensure it is preserved
rename_user_ini

# Create a maintenance page
echo "[+] NOTICE: Creating maintenance page as index.html" 2>&1 | tee -a ${LogFile}
cat <<EOF > ${staging_websitePath}/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Maintenance</title>
    <style>
        body{font-family:Arial,sans-serif;text-align:center;padding:20px;color:#444;background-color:#f1f1f1;margin:0;}h1{font-size:36px;margin:20px 0;}article{display:block;text-align:left;max-width:1024px;margin:5% auto;padding:20px;background:#fff;border-radius:8px;box-shadow:0 0 10px rgba(0,0,0,0.1);}p{font-size:18px;line-height:1.6;}a{color:#0073aa;text-decoration:none;}a:hover{color:#005177;text-decoration:none;}@media (max-width:768px){h1{font-size:28px;}article{padding:15px;margin:10% auto;}}@media (max-width:480px){h1{font-size:24px;}p{font-size:16px;}article{padding:10px;}}
    </style>
</head>
<body>
    <article>
        <h1>We'll be back soon!</h1>
        <div>
            <p>Sorry for the inconvenience but we're performing some maintenance at the moment. If you need to you can always <a href="mailto:${admin_email}">contact us</a>, otherwise we'll be back online shortly!</p>
            <p>&mdash; The Team</p>
        </div>
    </article>
</body>
</html>
EOF

# Set correct ownership and permissions for the maintenance page
echo "[+] NOTICE: Setting correct ownership and permissions for index.html" 2>&1 | tee -a ${LogFile}
chown -Rf ${staging_siteUser}:${staging_siteUser} ${staging_websitePath}/index.html
chmod 00755 -R ${staging_websitePath}/index.html

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
    method=$1
    echo "[+] NOTICE: Importing the MySQL database using method: $method" 2>&1 | tee -a ${LogFile}

    # Record the start time of the database import process
    start_time=$(date +%s)

    # Database import logic
    if [ "$method" = "clpctl" ]; then
        clpctl db:import --databaseName=${staging_databaseName} --file=${staging_scriptPath}/tmp/${databaseName}.sql.gz 2>&1 | tee -a ${LogFile}
    elif [ "$method" = "unzip_clpctl" ]; then
        gunzip -c ${staging_scriptPath}/tmp/${databaseName}.sql.gz > ${staging_scriptPath}/tmp/${databaseName}.sql
        clpctl db:import --databaseName=${staging_databaseName} --file=${staging_scriptPath}/tmp/${databaseName}.sql 2>&1 | tee -a ${LogFile}
    elif [ "$method" = "gunzip" ]; then
        gunzip -c ${staging_scriptPath}/tmp/${databaseName}.sql.gz | mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} 2>&1 | tee -a ${LogFile}
    elif [ "$method" = "pv_gunzip" ] && [ "$use_pv" = true ]; then
        pv ${staging_scriptPath}/tmp/${databaseName}.sql.gz | gunzip | mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} 2>&1 | tee -a ${LogFile}
    elif [ "$method" = "mysql_unzip" ]; then
        # Unzip the file first before using the mysql command-line client
        gunzip -c ${staging_scriptPath}/tmp/${databaseName}.sql.gz > ${staging_scriptPath}/tmp/${databaseName}.sql
        mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} < ${staging_scriptPath}/tmp/${databaseName}.sql 2>&1 | tee -a ${LogFile}
    elif [ "$method" = "mysql_gunzip" ]; then
        gunzip -c ${staging_scriptPath}/tmp/${databaseName}.sql.gz | mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} 2>&1 | tee -a ${LogFile}
    else
        echo "[+] NOTICE: Using default import method without pv." 2>&1 | tee -a ${LogFile}
        gunzip -c ${staging_scriptPath}/tmp/${databaseName}.sql.gz | mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} 2>&1 | tee -a ${LogFile}
    fi

    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to import the MySQL database using method: $method" 2>&1 | tee -a ${LogFile}
        return 1
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

    # Define the expected site URL based on the provided domain name
    expected_url="https://${domainName}"

    # Query the database to check the current site URL stored in the options table
    query=$(mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -se "SELECT option_value FROM ${table_Prefix}options WHERE option_name = 'siteurl';")

    # Compare the queried site URL with the expected URL
    if [ "$query" != "$expected_url" ]; then
        # If the URLs do not match, log an error and return an error code
        echo "[+] ERROR: The site URL in the database ($query) does not match the expected URL ($expected_url). The database import may have failed." 2>&1 | tee -a ${LogFile}

        # Add a delay before checking the URL again to allow the database to stabilize
        sleep 2

        # Re-check the site URL after the delay
        query=$(mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -se "SELECT option_value FROM ${table_Prefix}options WHERE option_name = 'siteurl';")

        if [ "$query" != "$expected_url" ]; then
            echo "[+] ERROR: The site URL in the database ($query) still does not match the expected URL ($expected_url). The database import may have failed." 2>&1 | tee -a ${LogFile}
            return 1  # Return 1 to indicate failure (assuming this is within a function)
        else
            echo "[+] SUCCESS: Site URL in the database matches the expected URL ($expected_url) after delay." 2>&1 | tee -a ${LogFile}
            return 0  # Return 0 to indicate success (assuming this is within a function)
        fi
    else
        # If the URLs match, log a success message and return success
        echo "[+] SUCCESS: Site URL in the database matches the expected URL ($expected_url)." 2>&1 | tee -a ${LogFile}
        return 0  # Return 0 to indicate success (assuming this is within a function)
    fi
}

# ==============================================================================
# Part 11: Retry Mechanism for Database Import
# ==============================================================================

# This section will attempt to import the database using various methods. If one method fails,
# it retries up to a specified maximum number of times before moving on to the next method.

# Initialize a flag to track if the import was successful
import_success=false

# Loop through each import method specified in the import_methods array
for method in "${import_methods[@]}"; do
    # Initialize the retry count for the current method
    retry_count=0

    # Attempt the import, retrying up to max_retries times if it fails
    while [ $retry_count -lt $max_retries ]; do
        import_database $method  # Call the function to perform the database import

        # Check if the import was successful
        if [ $? -eq 0 ]; then
            # If successful, set the import_success flag to true and break the loop
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

# If none of the import methods were successful after all retries, log an error and abort the script
if [ "$import_success" = false ]; then
    echo "[+] ERROR: All import methods failed after trying each method $max_retries times. Aborting!" 2>&1 | tee -a ${LogFile}
    exit 1  # Exit the script with a failure status
fi

# Remove the MySQL database export file from the staging environment
# The file is named after the production database but resides in the staging environment's temporary directory
echo "[+] NOTICE: Deleting the database export file: ${staging_scriptPath}/tmp/${databaseName}.sql.gz" 2>&1 | tee -a ${LogFile}
rm ${staging_scriptPath}/tmp/${databaseName}.sql.gz

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

# Verify if the site URL is correctly set in the staging database after search and replace
expected_url="https://${final_domainName}"
query=$(mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -se "SELECT option_value FROM ${table_Prefix}options WHERE option_name = 'siteurl';")

if [ "$query" != "$expected_url" ]; then
    echo "[+] ERROR: The site URL in the database ($query) does not match the expected URL ($expected_url). The search and replace may have failed." 2>&1 | tee -a ${LogFile}
    exit 1
else
    echo "[+] SUCCESS: Site URL in the database matches the expected URL ($expected_url)." 2>&1 | tee -a ${LogFile}
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
          --exclude '/index.php' --exclude 'wp-content/cache/*' --exclude 'wp-content/backups-dup-pro/*' \
          --exclude 'wp-config.php' --exclude '.user.ini.bak' --exclude '.user.ini' \
          ${remote_server_ssh}:${websitePath}/ ${staging_websitePath}/
else
    rsync -azP --update --delete --no-perms --no-owner --no-group --no-times \
          --exclude '/index.php' --exclude 'wp-content/cache/*' --exclude 'wp-content/backups-dup-pro/*' \
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
