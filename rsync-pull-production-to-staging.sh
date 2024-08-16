#!/bin/bash
# ==============================================================================
# Script Name:        Rsync Production to Staging | CloudPanel to CloudPanel
# Description:        High-performance, robust Rsync pull for large-scale websites with advanced logging,
#                     optimized for execution from staging or production servers.
# Compatibility:      Linux (Debian/Ubuntu) running CloudPanel
# Requirements:       CloudPanel, ssh-keygen, pv (Pipe Viewer)
# Author:             WP Speed Expert
# Author URI:         https://wpspeedexpert.com
# Version:            4.1.0
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
import_methods=("default" "clpctl" "unzip_clpctl" "gunzip" "pv_gunzip")

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
keep_uploads_folder=true

# Set to true if you want to use an alternate domain name for the search and replace query
use_alternate_domain=true

# Alternate domain name (only used if use_alternate_domain is true)
alternate_domainName="staging.${staging_domainName}"

### Part 3: Initial Checks and Creating the wp-config.php File

# Empty the log file if it exists
if [ -f ${LogFile} ]; then
    truncate -s 0 ${LogFile}
fi

# Record the start time of the script
script_start_time=$(date +%s)

# Log the date and time (Amsterdam Time)
echo "[+] NOTICE: Start script: $(TZ='Europe/Amsterdam' date)" 2>&1 | tee -a ${LogFile}

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

# ==============================================================================
# Part 4: Maintenance Page Creation and Initial Cleanup
# ==============================================================================

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
        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
        h1 { font-size: 50px; }
        body { font: 20px Helvetica, sans-serif; color: #333; }
        article { display: block; text-align: left; width: 650px; margin: 0 auto; }
        a { color: #dc8100; text-decoration: none; }
        a:hover { color: #333; text-decoration: none; }
    </style>
</head>
<body>
    <article>
        <h1>We'll be back soon!</h1>
        <div>
            <p>Sorry for the inconvenience but we're performing some maintenance at the moment. If you need to you can always <a href="mailto:someone@example.com">contact us</a>, otherwise we'll be back online shortly!</p>
            <p>&mdash; The Team</p>
        </div>
    </article>
</body>
</html>
EOF

# Set correct ownership and permissions for the maintenance page
echo "[+] NOTICE: Setting correct ownership and permissions for index.html" 2>&1 | tee -a ${LogFile}
chown ${staging_siteUser}:${staging_siteUser} ${staging_websitePath}/index.html
chmod 644 ${staging_websitePath}/index.html

# Clean and remove specific directories if they exist before general cleanup
echo "[+] NOTICE: Deleting plugins, cache, and EWWW directories" 2>&1 | tee -a ${LogFile}
rm -rf ${staging_websitePath}/wp-content/plugins
rm -rf ${staging_websitePath}/wp-content/cache
rm -rf ${staging_websitePath}/wp-content/EWWW

# Clean and remove destination website files (except for the wp-config.php, .user.ini, and index.html)
echo "[+] NOTICE: Cleaning up the destination website files: ${staging_websitePath}" 2>&1 | tee -a ${LogFile}

if [ "$keep_uploads_folder" = true ]; then
    echo "[+] NOTICE: Keeping the uploads folder during cleanup." 2>&1 | tee -a ${LogFile}
    find ${staging_websitePath}/ -mindepth 1 ! -regex '^'${staging_websitePath}'/wp-config.php' ! -regex '^'${staging_websitePath}'/.user.ini' ! -regex '^'${staging_websitePath}'/index.html' ! -regex '^'${staging_websitePath}'/wp-content/uploads$begin:math:text$/.*$end:math:text$?' -delete 2>&1 | tee -a ${LogFile}
else
    echo "[+] NOTICE: Deleting all files including the uploads folder." 2>&1 | tee -a ${LogFile}
    find ${staging_websitePath}/ -mindepth 1 ! -regex '^'${staging_websitePath}'/wp-config.php' ! -regex '^'${staging_websitePath}'/.user.ini' ! -regex '^'${staging_websitePath}'/index.html' -delete 2>&1 | tee -a ${LogFile}
fi

# Pause for 120 seconds to test maintenance page
echo "[+] NOTICE: Pausing for 120 seconds to test maintenance page." 2>&1 | tee -a ${LogFile}
sleep 120

# ==============================================================================
# Part 5: Database Export from Production and Backup
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
# Part 6: Database Recreation and Import
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
    clpctl db:add --domainName=${staging_domainName} --databaseName=${staging_databaseName} --databaseUserName=${staging_databaseUserName} --databaseUserPassword=''${databaseUserPassword}'' 2>&1 | tee -a ${LogFile}

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
# Part 7: Database Import Function and URL Update
# ==============================================================================

# Function to import the database using different methods
import_database() {
    method=$1
    echo "[+] NOTICE: Importing the MySQL database using method: $method" 2>&1 | tee -a ${LogFile}
    start_time=$(date +%s)

    if [ "$method" = "clpctl" ]; then
        clpctl db:import --databaseName=${staging_databaseName} --file=${staging_scriptPath}/tmp/${databaseName}.sql.gz 2>&1 | tee -a ${LogFile}
    elif [ "$method" = "unzip_clpctl" ]; then
        gunzip -c ${staging_scriptPath}/tmp/${databaseName}.sql.gz > ${staging_scriptPath}/tmp/${databaseName}.sql
        clpctl db:import --databaseName=${staging_databaseName} --file=${staging_scriptPath}/tmp/${databaseName}.sql 2>&1 | tee -a ${LogFile}
    elif [ "$method" = "gunzip" ]; then
        gunzip -c ${staging_scriptPath}/tmp/${databaseName}.sql.gz | mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} 2>&1 | tee -a ${LogFile}
    elif [ "$method" = "pv_gunzip" ] && [ "$use_pv" = true ]; then
        pv ${staging_scriptPath}/tmp/${databaseName}.sql.gz | gunzip | mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} 2>&1 | tee -a ${LogFile}
    else
        echo "[+] NOTICE: Using default import method without pv." 2>&1 | tee -a ${LogFile}
        gunzip -c ${staging_scriptPath}/tmp/${databaseName}.sql.gz | mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} 2>&1 | tee -a ${LogFile}
    fi

    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to import the MySQL database using method: $method" 2>&1 | tee -a ${LogFile}
        return 1
    fi
}

# Record the end time of the database import process
end_time=$(date +%s)

# Calculate the elapsed time for the database import process
elapsed_time=$((end_time - start_time))

# Log the time taken for the database import to complete
echo "[+] NOTICE: Database import took $elapsed_time seconds." 2>&1 | tee -a ${LogFile}

# Check if the previous command (database import) was successful
if [ $? -ne 0 ]; then
    # If the import failed, log an error message and return an error code
    echo "[+] ERROR: Failed to import the MySQL database using method: $method" 2>&1 | tee -a ${LogFile}
    return 1
fi

# Define the expected site URL based on the provided domain name
expected_url="https://${staging_domainName}"

# Query the database to check the current site URL stored in the options table
query=$(mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -se "SELECT option_value FROM ${table_Prefix}options WHERE option_name = 'siteurl';")

# Compare the queried site URL with the expected URL
if [ "$query" != "$expected_url" ]; then
    # If the URLs do not match, log an error and return an error code
    echo "[+] ERROR: The site URL in the database ($query) does not match the expected URL ($expected_url). The database import may have failed." 2>&1 | tee -a ${LogFile}
    return 1
else
    # If the URLs match, log a success message and return success
    echo "[+] SUCCESS: Site URL in the database matches the expected URL ($expected_url)." 2>&1 | tee -a ${LogFile}
    return 0
fi

# ==============================================================================
# Part 8: Retry Mechanism for Database Import
# ==============================================================================

# Sequentially try different methods if import fails
import_success=false

for method in "${import_methods[@]}"; do
    retry_count=0
    while [ $retry_count -lt $max_retries ]; do
        import_database $method
        if [ $? -eq 0 ]; then
            import_success=true
            break
        else
            echo "[+] WARNING: Import method $method failed. Retrying ($((retry_count + 1))/$max_retries)..." 2>&1 | tee -a ${LogFile}
            retry_count=$((retry_count + 1))
        fi
    done

    if [ "$import_success" = true ]; then
        break
    fi
done

if [ "$import_success" = false ]; then
    echo "[+] ERROR: All import methods failed after trying each method $max_retries times. Aborting!" 2>&1 | tee -a ${LogFile}
    exit 1
fi

# Remove the MySQL database export file from the staging environment
# The file is named after the production database but resides in the staging environment's temporary directory
echo "[+] NOTICE: Deleting the database export file: ${staging_scriptPath}/tmp/${databaseName}.sql.gz" 2>&1 | tee -a ${LogFile}
rm ${staging_scriptPath}/tmp/${databaseName}.sql.gz

### Part 9: Search and Replace URLs and Rsync Website Files

# Determine the domain to use for the search and replace operation
# If an alternate domain is specified, use it; otherwise, use the production domain
if [ "$use_alternate_domain" = true ]; then
    final_domainName="$alternate_domainName"
    echo "[+] NOTICE: Using alternate domain for search and replace: ${final_domainName}" 2>&1 | tee -a ${LogFile}
else
    final_domainName="$domainName"
fi

# Perform search and replace in the staging database
# This replaces all instances of the production domain with the staging domain (or alternate domain)
echo "[+] NOTICE: Performing search and replace of URLs in the staging database: ${staging_databaseName}." 2>&1 | tee -a ${LogFile}
mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -e "
UPDATE ${table_Prefix}options SET option_value = REPLACE (option_value, 'https://${domainName}', 'https://${final_domainName}') WHERE option_name = 'home' OR option_name = 'siteurl';
UPDATE ${table_Prefix}posts SET post_content = REPLACE (post_content, 'https://${domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}posts SET post_excerpt = REPLACE (post_excerpt, 'https://${domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}postmeta SET meta_value = REPLACE (meta_value, 'https://${domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}termmeta SET meta_value = REPLACE (meta_value, 'https://${domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}comments SET comment_content = REPLACE (comment_content, 'https://${domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}comments SET comment_author_url = REPLACE (comment_author_url, 'https://${domainName}','https://${final_domainName}');
UPDATE ${table_Prefix}posts SET guid = REPLACE (guid, 'https://${domainName}', 'https://${final_domainName}') WHERE post_type = 'attachment';
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
# Part 10: Rsync Website Files from Production to Staging
# ==============================================================================

# Start the process of synchronizing website files from production to staging
echo "[+] NOTICE: Starting Rsync pull." 2>&1 | tee -a ${LogFile}
start_time=$(date +%s)

# Rsync files from the production environment to the staging environment
if [ "$use_remote_server" = true ]; then
    # If the production site is on a remote server, sync files from the remote server to the local staging path
    rsync -azP --update --delete --no-perms --no-owner --no-group --no-times \
          --exclude 'wp-content/cache/*' --exclude 'wp-content/backups-dup-pro/*' \
          --exclude 'wp-config.php' --exclude '.user.ini' --exclude 'index.php' \
          ${remote_server_ssh}:${websitePath}/ ${staging_websitePath}/
else
    # If both production and staging are on the same local server, sync directly from production to staging
    rsync -azP --update --delete --no-perms --no-owner --no-group --no-times \
          --exclude 'wp-content/cache/*' --exclude 'wp-content/backups-dup-pro/*' \
          --exclude 'wp-config.php' --exclude '.user.ini' --exclude 'index.php' \
          ${websitePath}/ ${staging_websitePath}/
fi

# Ensure the 'index.php' file is synced last to avoid potential issues during the process
if [ "$use_remote_server" = true ]; then
    rsync -azP --update --delete --no-perms --no-owner --no-group --no-times \
          ${remote_server_ssh}:${websitePath}/index.php ${staging_websitePath}/index.php
else
    rsync -azP --update --delete --no-perms --no-owner --no-group --no-times \
          ${websitePath}/index.php ${staging_websitePath}/index.php
fi

# Clean up by deleting the temporary maintenance page ('index.html') from the staging environment
echo "[+] NOTICE: Deleting the maintenance page (index.html)" 2>&1 | tee -a ${LogFile}
rm -f ${staging_websitePath}/index.html

# Calculate and log the total time taken for the Rsync operation
end_time=$(date +%s)
elapsed_time=$((end_time - start_time))
echo "[+] NOTICE: Rsync pull took $elapsed_time seconds." 2>&1 | tee -a ${LogFile}

# Check if the Rsync operation was successful and handle any errors
if [ $? -ne 0 ]; then
    echo "[+] ERROR: Failed to rsync website files. Aborting!" 2>&1 | tee -a ${LogFile}
    exit 1
fi

# ==============================================================================
# Part 11: Post-Rsync File Permission and Ownership Fixes
# ==============================================================================

# Set correct ownership
echo "[+] NOTICE: Setting correct ownership." 2>&1 | tee -a ${LogFile}
chown -Rf ${staging_siteUser}:${staging_siteUser} ${staging_websitePath}

# Set correct file permissions for folders
echo "[+] NOTICE: Setting correct file permissions for folders." 2>&1 | tee -a ${LogFile}
find ${staging_websitePath}/ -type d -exec chmod 755 {} + 2>&1 | tee -a ${LogFile}

# Set correct file permissions for files
echo "[+] NOTICE: Setting correct file permissions for files." 2>&1 | tee -a ${LogFile}
find ${staging_websitePath}/ -type f -exec chmod 644 {} + 2>&1 | tee -a ${LogFile}

# ==============================================================================
# Part 12: Redis Flush and Restart
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
# Part 13: MySQL Restart and Script Completion
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
echo "[+] NOTICE: MySQL $mysql_restart_method took $elapsed_time seconds." 2>&1 | tee -a ${LogFile}

# Record the end time of the script and calculate total runtime (excluding reboot scenario)
if [ "$mysql_restart_method" != "reboot" ]; then
    script_end_time=$(date +%s)
    total_runtime=$((script_end_time - script_start_time))
    echo "[+] NOTICE: Total script execution time: $total_runtime seconds." 2>&1 | tee -a ${LogFile}
fi

# End of the script
echo "[+] NOTICE: End of script: $(TZ='Europe/Amsterdam' date)" 2>&1 | tee -a ${LogFile}
exit 0
