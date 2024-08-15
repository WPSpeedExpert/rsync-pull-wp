#!/bin/bash
# =========================================================================== #
# Description:        Rsync staging to production | Cloudpanel to Cloudpanel.
# Details:            Optimized Rsync pull for large sites with enhanced logging, executed from the production server.
# Compatible with:    Linux (Debian/Ubuntu) running Cloudpanel.
# Requirements:       Cloudpanel, ssh-keygen, pv (Pipe Viewer)
# Author:             WP Speed Expert
# Author URI:         https://wpspeedexpert.com
# Version:            3.9.1
# GitHub:             https://github.com/WPSpeedExpert/rsync-pull-wp/
# To Make Executable: chmod +x rsync-pull-staging-to-production.sh
# Crontab Schedule:   0 0 * * * /home/epicdeals/rsync-pull-staging-to-production.sh 2>&1
# =========================================================================== #
#
# Variables: Source | Staging
domainName=("domainName.com")
siteUser=("site-user")
# Variables: Destination | Production #
staging_domainName=("staging.domainName.com")
staging_siteUser=("staging_siteUser")

# Remote server settings
use_remote_server=true
remote_server_ssh="root@0.0.0.0"

table_Prefix="wp_" # wp_

# Source | Staging #
staging_databaseName=${staging_siteUser} # change if different from siteUser
staging_databaseUserName=${staging_siteUser} # change if different from siteUser
staging_websitePath="/home/${staging_siteUser}/htdocs/${staging_domainName}"
staging_scriptPath="/home/${staging_siteUser}"

# Destination | Production #
databaseName=${siteUser} # change if different from siteUser
databaseUserName=${siteUser} # change if different from siteUser
websitePath="/home/${siteUser}/htdocs/${domainName}"
scriptPath="/home/${siteUser}"
databaseUserPassword=$(sed -n 's/^password\s*=\s*"\(.*\)".*/\1/p' "${scriptPath}/.my.cnf")

LogFile="${scriptPath}/rsync-pull-staging-to-production.log"

# Import method control:
import_methods=("clpctl" "pv_gunzip" "default")

# Use PV (Pipe Viewer) for monitoring progress manually during import (set to true or false).
use_pv=true

# Install PV if not installed (set to true or false).
install_pv_if_missing=true

# Set to true to backup the production database before deleting
backup_production_database=true

# Set to true to delete and recreate the production database, or false to drop all tables
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
alternate_domainName="www1.${domainName}"

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
        echo "[+] ERROR: $cmd could not be found. Please install it." 2>&1 | tee -a ${LogFile}
        exit 1
    fi
done

# Check for PV if needed
if [ "$use_pv" = true ]; then
    if ! command -v pv &> /dev/null; then
        if [ "$install_pv_if_missing" = true ]; then
            echo "[+] NOTICE: pv not found, installing..."
            sudo apt-get update && sudo apt-get install -y pv
            if [ $? -ne 0 ]; then
                echo "[+] ERROR: Failed to install pv. Aborting!" 2>&1 | tee -a ${LogFile}
                exit 1
            fi
        else
            echo "[+] WARNING: pv not found, proceeding without it."
            use_pv=false
        fi
    fi
fi

# Check for WP directory & wp-config.php
if [ ! -d ${websitePath} ]; then
  echo "[+] ERROR: Directory ${websitePath} does not exist"
  exit 1
fi 2>&1 | tee -a ${LogFile}

if [ ! -f ${websitePath}/wp-config.php ]; then
  echo "[+] ERROR: No wp-config.php in ${websitePath}"
  echo "[+] WARNING: Creating wp-config.php in ${websitePath}"
  WPsalts=$(wget https://api.wordpress.org/secret-key/1.1/salt/ -q -O -)
  cat <<EOF > ${websitePath}/wp-config.php
<?php
${WPsalts}
define( 'DB_NAME', "${databaseName}" );
define( 'DB_USER', "${databaseUserName}" );
define( 'DB_PASSWORD', "${databaseUserPassword}" );
define( 'DB_HOST', "localhost" );
define( 'DB_CHARSET', 'utf8' );
define( 'DB_COLLATE', '' );
\$table_prefix  = '${table_Prefix}';
define( 'WP_DEBUG', false );
if ( ! defined( 'ABSPATH' ) ) {
	define( 'ABSPATH', dirname(__FILE__) . '/' );
}
require_once ABSPATH . 'wp-settings.php';
EOF
  echo "[+] SUCCESS: Created wp-config.php in ${websitePath}"
  exit
fi 2>&1 | tee -a ${LogFile}

if [ -f ${websitePath}/wp-config.php ]; then
  echo "[+] SUCCESS: Found wp-config.php in ${websitePath}"
fi 2>&1 | tee -a ${LogFile}

# Export the staging MySQL database
if [ "$use_remote_server" = true ]; then
    echo "[+] NOTICE: Exporting the staging database: ${staging_databaseName}" 2>&1 | tee -a ${LogFile}
    ssh ${remote_server_ssh} "clpctl db:export --databaseName=${staging_databaseName} --file=${staging_scriptPath}/tmp/${staging_databaseName}.sql.gz" 2>&1 | tee -a ${LogFile}

    # Sync the database
    echo "[+] NOTICE: Syncing the database: ${staging_databaseName}.sql.gz" 2>&1 | tee -a ${LogFile}
    rsync -azP ${remote_server_ssh}:${staging_scriptPath}/tmp/${staging_databaseName}.sql.gz ${scriptPath}/tmp 2>&1 | tee -a ${LogFile}

    # Clean up the remote database export file
    echo "[+] NOTICE: Cleaning up the remote database export file: ${staging_databaseName}" 2>&1 | tee -a ${LogFile}
    ssh ${remote_server_ssh} "rm ${staging_scriptPath}/tmp/${staging_databaseName}.sql.gz" 2>&1 | tee -a ${LogFile}
else
    echo "[+] NOTICE: Exporting the local staging database: ${staging_databaseName}" 2>&1 | tee -a ${LogFile}
    clpctl db:export --databaseName=${staging_databaseName} --file=${staging_scriptPath}/tmp/${staging_databaseName}.sql.gz 2>&1 | tee -a ${LogFile}
fi

# Check for and delete older database backups
backup_file="/tmp/${databaseName}-backup-$(date +%F).sql.gz"
if ls /tmp/${databaseName}-backup-*.sql.gz 1> /dev/null 2>&1; then
    echo "[+] NOTICE: Deleting older backup files in /tmp/" 2>&1 | tee -a ${LogFile}
    rm /tmp/${databaseName}-backup-*.sql.gz
    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to delete the older backup files." 2>&1 | tee -a ${LogFile}
    fi
fi

# Optionally backup the production database
if [ "$backup_production_database" = true ]; then
    echo "[+] NOTICE: Creating a backup of the production database: ${databaseName}" 2>&1 | tee -a ${LogFile}
    clpctl db:export --databaseName=${databaseName} --file=${backup_file} 2>&1 | tee -a ${LogFile}
    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to create a backup of the production database. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi
fi

# Optionally delete and recreate the production database, or drop all tables
if [ "$recreate_database" = true ]; then
    echo "[+] WARNING: Deleting the database: ${databaseName}" 2>&1 | tee -a ${LogFile}
    clpctl db:delete --databaseName=${databaseName} --force 2>&1 | tee -a ${LogFile}

    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to delete the production database. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi

    echo "[+] NOTICE: Adding the database: ${databaseName}" 2>&1 | tee -a ${LogFile}
    clpctl db:add --domainName=${domainName} --databaseName=${databaseName} --databaseUserName=${databaseUserName} --databaseUserPassword=''${databaseUserPassword}'' 2>&1 | tee -a ${LogFile}

    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to add the production database. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi
else
    echo "[+] NOTICE: Dropping all database tables ..." 2>&1 | tee -a ${LogFile}
    tables=$(mysql --defaults-extra-file=${scriptPath}/.my.cnf -Nse 'SHOW TABLES' ${databaseName})
    for table in $tables; do
        echo "[+] NOTICE: Dropping $table from ${databaseName}." 2>&1 | tee -a ${LogFile}
        mysql --defaults-extra-file=${scriptPath}/.my.cnf  -e "DROP TABLE $table" ${databaseName}
        if [ $? -ne 0 ]; then
            echo "[+] ERROR: Failed to drop table $table. Aborting!" 2>&1 | tee -a ${LogFile}
            exit 1
        fi
    done
    echo "[+] SUCCESS: All tables dropped from ${databaseName}." 2>&1 | tee -a ${LogFile}
fi

# Function to import the database using different methods
import_database() {
    method=$1
    echo "[+] NOTICE: Importing the MySQL database using method: $method" 2>&1 | tee -a ${LogFile}
    start_time=$(date +%s)

    if [ "$method" = "clpctl" ]; then
        clpctl db:import --databaseName=${databaseName} --file=${scriptPath}/tmp/${staging_databaseName}.sql.gz 2>&1 | tee -a ${LogFile}
    elif [ "$method" = "pv_gunzip" ] && [ "$use_pv" = true ]; then
        pv ${scriptPath}/tmp/${staging_databaseName}.sql.gz | gunzip | mysql --defaults-extra-file=${scriptPath}/.my.cnf ${databaseName} 2>&1 | tee -a ${LogFile}
    else
        echo "[+] NOTICE: Using default import method without pv." 2>&1 | tee -a ${LogFile}
        gunzip -c ${scriptPath}/tmp/${staging_databaseName}.sql.gz | mysql --defaults-extra-file=${scriptPath}/.my.cnf ${databaseName} 2>&1 | tee -a ${LogFile}
    fi

    end_time=$(date +%s)
    elapsed_time=$((end_time - start_time))
    echo "[+] NOTICE: Database import took $elapsed_time seconds." 2>&1 | tee -a ${LogFile}

    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to import the MySQL database using method: $method" 2>&1 | tee -a ${LogFile}
        return 1
    fi

    expected_url="https://${domainName}"
    query=$(mysql --defaults-extra-file=${scriptPath}/.my.cnf -D ${databaseName} -se "SELECT option_value FROM ${table_Prefix}options WHERE option_name = 'siteurl';")

    if [ "$query" != "$expected_url" ]; then
        echo "[+] ERROR: The site URL in the database ($query) does not match the expected URL ($expected_url). The database import may have failed." 2>&1 | tee -a ${LogFile}
        return 1
    else
        echo "[+] SUCCESS: Site URL in the database matches the expected URL ($expected_url)." 2>&1 | tee -a ${LogFile}
        return 0
    fi
}

import_success=false
retry_count=0
for method in "${import_methods[@]}"; do
    while [ $retry_count -lt $max_retries ]; do
        import_database $method
        if [ $? -eq 0 ]; then
            import_success=true
            break 2
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
    echo "[+] ERROR: All import methods failed after $max_retries attempts. Aborting!" 2>&1 | tee -a ${LogFile}
    exit 1
fi

# Cleanup the MySQL database export file
echo "[+] NOTICE: Cleaning up the database export file: ${scriptPath}/tmp/${staging_databaseName}.sql.gz" 2>&1 | tee -a ${LogFile}
rm ${scriptPath}/tmp/${staging_databaseName}.sql.gz

# Determine the domain to use for the search and replace query
if [ "$use_alternate_domain" = true ]; then
    final_domainName="$alternate_domainName"
    echo "[+] NOTICE: Using alternate domain for search and replace: ${final_domainName}" 2>&1 | tee -a ${LogFile}
else
    final_domainName="$domainName"
fi

# Search and replace URL in the database
echo "[+] NOTICE: Performing search and replace of URLs in the database: ${databaseName}." 2>&1 | tee -a ${LogFile}
mysql --defaults-extra-file=${scriptPath}/.my.cnf -D ${databaseName} -e "
UPDATE ${table_Prefix}options SET option_value = REPLACE (option_value, 'https://${staging_domainName}', 'https://${final_domainName}') WHERE option_name = 'home' OR option_name = 'siteurl';
UPDATE ${table_Prefix}posts SET post_content = REPLACE (post_content, 'https://${staging_domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}posts SET post_excerpt = REPLACE (post_excerpt, 'https://${staging_domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}postmeta SET meta_value = REPLACE (meta_value, 'https://${staging_domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}termmeta SET meta_value = REPLACE (meta_value, 'https://${staging_domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}comments SET comment_content = REPLACE (comment_content, 'https://${staging_domainName}', 'https://${final_domainName}');
UPDATE ${table_Prefix}comments SET comment_author_url = REPLACE (comment_author_url, 'https://${staging_domainName}','https://${final_domainName}');
UPDATE ${table_Prefix}posts SET guid = REPLACE (guid, 'https://${staging_domainName}', 'https://${final_domainName}') WHERE post_type = 'attachment';
" 2>&1 | tee -a ${LogFile}

if [ $? -ne 0 ]; then
    echo "[+] ERROR: Failed to perform search and replace in the database. Aborting!" 2>&1 | tee -a ${LogFile}
    exit 1
fi

# Verify if the site URL is correctly set in the database after search and replace
expected_url="https://${final_domainName}"
query=$(mysql --defaults-extra-file=${scriptPath}/.my.cnf -D ${databaseName} -se "SELECT option_value FROM ${table_Prefix}options WHERE option_name = 'siteurl';")

if [ "$query" != "$expected_url" ]; then
    echo "[+] ERROR: The site URL in the database ($query) does not match the expected URL ($expected_url). The search and replace may have failed." 2>&1 | tee -a ${LogFile}
    exit 1
else
    echo "[+] SUCCESS: Site URL in the database matches the expected URL ($expected_url)." 2>&1 | tee -a ${LogFile}
fi

# Disable: Discourage search engines from indexing this website
echo "[+] NOTICE: Enabling 'Discourage search engines from indexing this website'." 2>&1 | tee -a ${LogFile}
mysql --defaults-extra-file=${scriptPath}/.my.cnf -D ${databaseName} -e "
UPDATE ${table_Prefix}options SET option_value = '1' WHERE option_name = 'blog_public';
" 2>&1 | tee -a ${LogFile}

# Clean and remove specific directories before general cleanup
echo "[+] NOTICE: Deleting plugins, cache, and EWWW directories" 2>&1 | tee -a ${LogFile}
rm -rf ${websitePath}/wp-content/plugins
rm -rf ${websitePath}/wp-content/cache
rm -rf ${websitePath}/wp-content/EWWW

# Clean and remove destination website files (except for the wp-config.php & .user.ini)
echo "[+] NOTICE: Cleaning up the destination website files: ${websitePath}" 2>&1 | tee -a ${LogFile}

if [ "$keep_uploads_folder" = true ]; then
    echo "[+] NOTICE: Keeping the uploads folder during cleanup." 2>&1 | tee -a ${LogFile}
    find ${websitePath}/ -mindepth 1 ! -regex '^'${websitePath}'/wp-config.php' ! -regex '^'${websitePath}'/.user.ini' ! -regex '^'${websitePath}'/wp-content/uploads\(/.*\)?' -delete 2>&1 | tee -a ${LogFile}
else
    echo "[+] NOTICE: Deleting all files including the uploads folder." 2>&1 | tee -a ${LogFile}
    find ${websitePath}/ -mindepth 1 ! -regex '^'${websitePath}'/wp-config.php' ! -regex '^'${websitePath}'/.user.ini' -delete 2>&1 | tee -a ${LogFile}
fi

# Rsync website files (pull)
echo "[+] NOTICE: Starting Rsync pull." 2>&1 | tee -a ${LogFile}
start_time=$(date +%s)

if [ "$use_remote_server" = true ]; then
    rsync -azP --update --delete --no-perms --no-owner --no-group --no-times --exclude 'wp-content/cache/*' --exclude 'wp-content/backups-dup-pro/*' --exclude 'wp-config.php' --exclude '.user.ini' ${remote_server_ssh}:${staging_websitePath}/ ${websitePath}
else
    rsync -azP --update --delete --no-perms --no-owner --no-group --no-times --exclude 'wp-content/cache/*' --exclude 'wp-content/backups-dup-pro/*' --exclude 'wp-config.php' --exclude '.user.ini' ${staging_websitePath}/ ${websitePath}
fi

end_time=$(date +%s)
elapsed_time=$((end_time - start_time))
echo "[+] NOTICE: Rsync pull took $elapsed_time seconds." 2>&1 | tee -a ${LogFile}

if [ $? -ne 0 ]; then
    echo "[+] ERROR: Failed to rsync website files. Aborting!" 2>&1 | tee -a ${LogFile}
    exit 1
fi

# Set correct ownership
echo "[+] NOTICE: Setting correct ownership." 2>&1 | tee -a ${LogFile}
chown -Rf ${siteUser}:${siteUser} ${websitePath}

# Set correct file permissions for folders
echo "[+] NOTICE: Setting correct file permissions for folders." 2>&1 | tee -a ${LogFile}
find ${websitePath}/ -type d -exec chmod 755 {} + 2>&1 | tee -a ${LogFile}

# Set correct file permissions for files
echo "[+] NOTICE: Setting correct file permissions for files." 2>&1 | tee -a ${LogFile}
find ${websitePath}/ -type f -exec chmod 644 {} + 2>&1 | tee -a ${LogFile}

# Flush & restart Redis
echo "[+] NOTICE: Flushing and restarting Redis." 2>&1 | tee -a ${LogFile}
redis-cli FLUSHALL
sudo systemctl restart redis-server

# Restart MySQL (using stop and start to avoid potential restart issues)
echo "[+] NOTICE: Restarting the MySQL server." 2>&1 | tee -a ${LogFile}
systemctl stop mysql
systemctl start mysql
systemctl status mysql | tee -a ${LogFile}

# Record the end time of the script and calculate total runtime
script_end_time=$(date +%s)
total_runtime=$((script_end_time - script_start_time))
echo "[+] NOTICE: Total script execution time: $total_runtime seconds." 2>&1 | tee -a ${LogFile}

# End of the script
echo "[+] NOTICE: End of script: $(TZ='Europe/Amsterdam' date)" 2>&1 | tee -a ${LogFile}
exit 0
