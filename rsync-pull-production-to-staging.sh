#!/bin/bash
# =========================================================================== #
# Description:        Rsync production to staging | Cloudpanel to Cloudpanel.
# Details:            Optimized Rsync pull for large sites with enhanced logging, executed from the staging server.
# Compatible with:    Linux (Debian/Ubuntu) running Cloudpanel.
# Requirements:       Cloudpanel, ssh-keygen, pv (Pipe Viewer)
# Author:             WP Speed Expert
# Author URI:         https://wpspeedexpert.com
# Version:            3.9.0
# GitHub:             https://github.com/WPSpeedExpert/rsync-pull-wp/
# To Make Executable: chmod +x rsync-pull-production-to-staging.sh
# Crontab Schedule:   0 0 * * * /home/epicdeals/rsync-pull-production-to-staging.sh 2>&1
# =========================================================================== #
#
# Variables: Source | Production
domainName=("domainName.com")
siteUser=("site-user")
# Variables: Destination | Staging #
staging_domainName=("staging.domainName.com")
staging_siteUser=("staging_siteUser")

# Remote server settings
use_remote_server=true
remote_server_ssh="root@0.0.0.0"

table_Prefix="wp_" # wp_

# Source | Production #
databaseName=${siteUser} # change if different from siteUser
databaseUserName=${siteUser} # change if different from siteUser
websitePath="/home/${siteUser}/htdocs/${domainName}"
scriptPath="/home/${siteUser}"

# Destination | Staging #
staging_databaseName=${staging_siteUser} # change if different from siteUser
staging_databaseUserName=${staging_siteUser} # change if different from siteUser
staging_websitePath="/home/${staging_siteUser}/htdocs/${staging_domainName}"
staging_scriptPath="/home/${staging_siteUser}"
staging_databaseUserPassword=$(sed -n 's/^password\s*=\s*"\(.*\)".*/\1/p' "${staging_scriptPath}/.my.cnf")

LogFile="${staging_scriptPath}/rsync-pull-production-to-staging.log"

# Import method control:
import_methods=("clpctl" "pv_gunzip" "default")

# Use PV (Pipe Viewer) for monitoring progress manually during import (set to true or false).
use_pv=true

# Install PV if not installed (set to true or false).
install_pv_if_missing=true

# Set to true to backup the staging database before deleting
backup_staging_database=true

# Set to true to delete and recreate the staging database, or false to drop all tables
recreate_database=true

# Set to true to enable automated retry on import failure (maximum retries: 3)
enable_automatic_retry=true
max_retries=3

# Set to false if you do not want to keep the wp-content/uploads folder during cleanup
keep_uploads_folder=false

# Set to true if you want to use an alternate domain name for the search and replace query
use_alternate_domain=false

# Alternate domain name (only used if use_alternate_domain is true)
alternate_domainName="staging.${staging_domainName}"

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
if [ ! -d ${staging_websitePath} ]; then
  echo "[+] ERROR: Directory ${staging_websitePath} does not exist"
  exit 1
fi 2>&1 | tee -a ${LogFile}

if [ ! -f ${staging_websitePath}/wp-config.php ]; then
  echo "[+] ERROR: No wp-config.php in ${staging_websitePath}"
  echo "[+] WARNING: Creating wp-config.php in ${staging_websitePath}"
  WPsalts=$(wget https://api.wordpress.org/secret-key/1.1/salt/ -q -O -)
  cat <<EOF > ${staging_websitePath}/wp-config.php
<?php
${WPsalts}
define( 'DB_NAME', "${staging_databaseName}" );
define( 'DB_USER', "${staging_databaseUserName}" );
define( 'DB_PASSWORD', "${staging_databaseUserPassword}" );
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
  echo "[+] SUCCESS: Created wp-config.php in ${staging_websitePath}"
  exit
fi 2>&1 | tee -a ${LogFile}

if [ -f ${staging_websitePath}/wp-config.php ]; then
  echo "[+] SUCCESS: Found wp-config.php in ${staging_websitePath}"
fi 2>&1 | tee -a ${LogFile}

# Export the remote MySQL database
if [ "$use_remote_server" = true ]; then
    echo "[+] NOTICE: Exporting the remote database: ${databaseName}" 2>&1 | tee -a ${LogFile}
    ssh ${remote_server_ssh} "clpctl db:export --databaseName=${databaseName} --file=${scriptPath}/tmp/${databaseName}.sql.gz" 2>&1 | tee -a ${LogFile}

    # Sync the database
    echo "[+] NOTICE: Syncing the database: ${databaseName}.sql.gz" 2>&1 | tee -a ${LogFile}
    rsync -azP ${remote_server_ssh}:${scriptPath}/tmp/${databaseName}.sql.gz ${staging_scriptPath}/tmp 2>&1 | tee -a ${LogFile}

    # Clean up the remote database export file
    echo "[+] NOTICE: Cleaning up the remote database export file: ${databaseName}" 2>&1 | tee -a ${LogFile}
    ssh ${remote_server_ssh} "rm ${scriptPath}/tmp/${databaseName}.sql.gz" 2>&1 | tee -a ${LogFile}
else
    echo "[+] NOTICE: Exporting the local database: ${databaseName}" 2>&1 | tee -a ${LogFile}
    clpctl db:export --databaseName=${databaseName} --file=${scriptPath}/tmp/${databaseName}.sql.gz 2>&1 | tee -a ${LogFile}
fi

# Check for and delete older database backups
backup_file="/tmp/${staging_databaseName}-backup-$(date +%F).sql.gz"
if ls /tmp/${staging_databaseName}-backup-*.sql.gz 1> /dev/null 2>&1; then
    echo "[+] NOTICE: Deleting older backup files in /tmp/" 2>&1 | tee -a ${LogFile}
    rm /tmp/${staging_databaseName}-backup-*.sql.gz
    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to delete the older backup files." 2>&1 | tee -a ${LogFile}
    fi
fi

# Optionally backup the staging database
if [ "$backup_staging_database" = true ]; then
    echo "[+] NOTICE: Creating a backup of the staging database: ${staging_databaseName}" 2>&1 | tee -a ${LogFile}
    clpctl db:export --databaseName=${staging_databaseName} --file=${backup_file} 2>&1 | tee -a ${LogFile}
    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to create a backup of the staging database. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi
fi

# Optionally delete and recreate the staging database, or drop all tables
if [ "$recreate_database" = true ]; then
    echo "[+] WARNING: Deleting the database: ${staging_databaseName}" 2>&1 | tee -a ${LogFile}
    clpctl db:delete --databaseName=${staging_databaseName} --force 2>&1 | tee -a ${LogFile}

    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to delete the staging database. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi

    echo "[+] NOTICE: Adding the database: ${staging_databaseName}" 2>&1 | tee -a ${LogFile}
    clpctl db:add --domainName=${staging_domainName} --databaseName=${staging_databaseName} --databaseUserName=${staging_databaseUserName} --databaseUserPassword=''${staging_databaseUserPassword}'' 2>&1 | tee -a ${LogFile}

    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to add the staging database. Aborting!" 2>&1 | tee -a ${LogFile}
        exit 1
    fi
else
    echo "[+] NOTICE: Dropping all database tables ..." 2>&1 | tee -a ${LogFile}
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

# Function to import the database using different methods
import_database() {
    method=$1
    echo "[+] NOTICE: Importing the MySQL database using method: $method" 2>&1 | tee -a ${LogFile}
    start_time=$(date +%s)

    if [ "$method" = "clpctl" ]; then
        clpctl db:import --databaseName=${staging_databaseName} --file=${staging_scriptPath}/tmp/${databaseName}.sql.gz 2>&1 | tee -a ${LogFile}
    elif [ "$method" = "pv_gunzip" ] && [ "$use_pv" = true ]; then
        pv ${staging_scriptPath}/tmp/${databaseName}.sql.gz | gunzip | mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} 2>&1 | tee -a ${LogFile}
    else
        echo "[+] NOTICE: Using default import method without pv." 2>&1 | tee -a ${LogFile}
        gunzip -c ${staging_scriptPath}/tmp/${databaseName}.sql.gz | mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf ${staging_databaseName} 2>&1 | tee -a ${LogFile}
    fi

    end_time=$(date +%s)
    elapsed_time=$((end_time - start_time))
    echo "[+] NOTICE: Database import took $elapsed_time seconds." 2>&1 | tee -a ${LogFile}

    if [ $? -ne 0 ]; then
        echo "[+] ERROR: Failed to import the MySQL database using method: $method" 2>&1 | tee -a ${LogFile}
        return 1
    fi

    expected_url="https://${domainName}"
    query=$(mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -se "SELECT option_value FROM ${table_Prefix}options WHERE option_name = 'siteurl';")

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
echo "[+] NOTICE: Cleaning up the database export file: ${staging_scriptPath}/tmp/${databaseName}.sql.gz" 2>&1 | tee -a ${LogFile}
rm ${staging_scriptPath}/tmp/${databaseName}.sql.gz

# Determine the domain to use for the search and replace query
if [ "$use_alternate_domain" = true ]; then
    final_staging_domainName="$alternate_domainName"
    echo "[+] NOTICE: Using alternate domain for search and replace: ${final_staging_domainName}" 2>&1 | tee -a ${LogFile}
else
    final_staging_domainName="$staging_domainName"
fi

# Search and replace URL in the database
echo "[+] NOTICE: Performing search and replace of URLs in the database: ${staging_databaseName}." 2>&1 | tee -a ${LogFile}
mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -e "
UPDATE ${table_Prefix}options SET option_value = REPLACE (option_value, 'https://${domainName}', 'https://${final_staging_domainName}') WHERE option_name = 'home' OR option_name = 'siteurl';
UPDATE ${table_Prefix}posts SET post_content = REPLACE (post_content, 'https://${domainName}', 'https://${final_staging_domainName}');
UPDATE ${table_Prefix}posts SET post_excerpt = REPLACE (post_excerpt, 'https://${domainName}', 'https://${final_staging_domainName}');
UPDATE ${table_Prefix}postmeta SET meta_value = REPLACE (meta_value, 'https://${domainName}', 'https://${final_staging_domainName}');
UPDATE ${table_Prefix}termmeta SET meta_value = REPLACE (meta_value, 'https://${domainName}', 'https://${final_staging_domainName}');
UPDATE ${table_Prefix}comments SET comment_content = REPLACE (comment_content, 'https://${domainName}', 'https://${final_staging_domainName}');
UPDATE ${table_Prefix}comments SET comment_author_url = REPLACE (comment_author_url, 'https://${domainName}','https://${final_staging_domainName}');
UPDATE ${table_Prefix}posts SET guid = REPLACE (guid, 'https://${domainName}', 'https://${final_staging_domainName}') WHERE post_type = 'attachment';
" 2>&1 | tee -a ${LogFile}

if [ $? -ne 0 ]; then
    echo "[+] ERROR: Failed to perform search and replace in the database. Aborting!" 2>&1 | tee -a ${LogFile}
    exit 1
fi

# Verify if the site URL is correctly set in the database after search and replace
expected_staging_url="https://${final_staging_domainName}"
query=$(mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -se "SELECT option_value FROM ${table_Prefix}options WHERE option_name = 'siteurl';")

if [ "$query" != "$expected_staging_url" ]; then
    echo "[+] ERROR: The site URL in the database ($query) does not match the expected staging URL ($expected_staging_url). The search and replace may have failed." 2>&1 | tee -a ${LogFile}
    exit 1
else
    echo "[+] SUCCESS: Site URL in the database matches the expected staging URL ($expected_staging_url)." 2>&1 | tee -a ${LogFile}
fi

# Enable: Discourage search engines from indexing this website
echo "[+] NOTICE: Enabling 'Discourage search engines from indexing this website'." 2>&1 | tee -a ${LogFile}
mysql --defaults-extra-file=${staging_scriptPath}/.my.cnf -D ${staging_databaseName} -e "
UPDATE ${table_Prefix}options SET option_value = '0' WHERE option_name = 'blog_public';
" 2>&1 | tee -a ${LogFile}

# Clean and remove specific directories before general cleanup
echo "[+] NOTICE: Deleting plugins, cache, and EWWW directories" 2>&1 | tee -a ${LogFile}
rm -rf ${staging_websitePath}/wp-content/plugins
rm -rf ${staging_websitePath}/wp-content/cache
rm -rf ${staging_websitePath}/wp-content/EWWW

# Clean and remove destination website files (except for the wp-config.php & .user.ini)
echo "[+] NOTICE: Cleaning up the destination website files: ${staging_websitePath}" 2>&1 | tee -a ${LogFile}

if [ "$keep_uploads_folder" = true ]; then
    echo "[+] NOTICE: Keeping the uploads folder during cleanup." 2>&1 | tee -a ${LogFile}
    find ${staging_websitePath}/ -mindepth 1 ! -regex '^'${staging_websitePath}'/wp-config.php' ! -regex '^'${staging_websitePath}'/.user.ini' ! -regex '^'${staging_websitePath}'/wp-content/uploads\(/.*\)?' -delete 2>&1 | tee -a ${LogFile}
else
    echo "[+] NOTICE: Deleting all files including the uploads folder." 2>&1 | tee -a ${LogFile}
    find ${staging_websitePath}/ -mindepth 1 ! -regex '^'${staging_websitePath}'/wp-config.php' ! -regex '^'${staging_websitePath}'/.user.ini' -delete 2>&1 | tee -a ${LogFile}
fi

# Rsync website files (pull)
echo "[+] NOTICE: Starting Rsync pull." 2>&1 | tee -a ${LogFile}
start_time=$(date +%s)

if [ "$use_remote_server" = true ]; then
    rsync -azP --update --delete --no-perms --no-owner --no-group --no-times --exclude 'wp-content/cache/*' --exclude 'wp-content/backups-dup-pro/*' --exclude 'wp-config.php' --exclude '.user.ini' ${remote_server_ssh}:${websitePath}/ ${staging_websitePath}
else
    rsync -azP --update --delete --no-perms --no-owner --no-group --no-times --exclude 'wp-content/cache/*' --exclude 'wp-content/backups-dup-pro/*' --exclude 'wp-config.php' --exclude '.user.ini' ${websitePath}/ ${staging_websitePath}
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
chown -Rf ${staging_siteUser}:${staging_siteUser} ${staging_websitePath}

# Set correct file permissions for folders
echo "[+] NOTICE: Setting correct file permissions for folders." 2>&1 | tee -a ${LogFile}
find ${staging_websitePath}/ -type d -exec chmod 755 {} + 2>&1 | tee -a ${LogFile}

# Set correct file permissions for files
echo "[+] NOTICE: Setting correct file permissions for files." 2>&1 | tee -a ${LogFile}
find ${staging_websitePath}/ -type f -exec chmod 644 {} + 2>&1 | tee -a ${LogFile}

# Flush & restart Redis
echo "[+] NOTICE: Flushing and restarting Redis." 2>&1 | tee -a ${LogFile}
redis-cli FLUSHALL
sudo systemctl restart redis-server

# Restart MySQL
echo "[+] NOTICE: Restarting the MySQL server." 2>&1 | tee -a ${LogFile}
systemctl restart mysql
sleep 5
systemctl status mysql

# Record the end time of the script and calculate total runtime
script_end_time=$(date +%s)
total_runtime=$((script_end_time - script_start_time))
echo "[+] NOTICE: Total script execution time: $total_runtime seconds." 2>&1 | tee -a ${LogFile}

# End of the script
echo "[+] NOTICE: End of script: $(TZ='Europe/Amsterdam' date)" 2>&1 | tee -a ${LogFile}
exit 0
