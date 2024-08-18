<p align="center">
  <a href="https://wpspeedexpert.com/" target="_blank">
    <img src="https://wpspeedexpert.com/wp-content/uploads/2024/06/wpspeedexpert-dark-light-grey-400.webp">
  </a>
</p>

# Rsync Pull WordPress | CloudPanel to CloudPanel
The Rsync Pull script is a high-performance, robust solution designed to synchronize large-scale WordPress websites from a production environment to a staging environment and vice versa. It is specifically optimized for Linux systems running CloudPanel and WordPress, providing advanced logging, flexible database import techniques, and robust error handling. This script is ideal for web administrators looking to maintain an up-to-date staging environment for testing and development.

## Features
- High-Performance Syncing: Leverages rsync for efficient file synchronization between production and staging environments.
- Advanced Logging: Comprehensive logs for each operation, enabling easy monitoring and debugging.
- Flexible Database Handling: Multiple methods for importing databases, including clpctl, MySQL tools, and the MySQL command-line client, allowing tailored strategies based on your environment.
- Automated Backups: Optionally backs up the staging database before any deletion, ensuring data safety.
- Retry Mechanism: Automatically retries database imports up to three times if failures occur, increasing reliability.
- Maintenance Mode: Automatically creates and manages a maintenance page during the sync process to prevent user access.
- GitHub-Hosted Maintenance Page: Downloads a customizable maintenance page template from GitHub, allowing centralized management and updates.
- Customizable Team Name: Allows dynamic customization of the team name displayed on the maintenance page through a variable, enhancing personalization.
- Redis and MySQL Management: Includes options to flush and restart Redis and MySQL services, ensuring the staging environment is clean and optimized post-sync.
- Customizable: Flexible configuration for MySQL restart methods, file permissions, and more.
- Optional Database Maintenance Logging: Provides the option to log or suppress database maintenance output, giving you control over the verbosity of logs.

## Requirements

- Operating System: Linux (Debian/Ubuntu) running CloudPanel
- WordPress Installation: The script is designed for WordPress websites.

Dependencies:
- ssh-keygen
- pv (Pipe Viewer)
- rsync
- mysql
- clpctl (for managing CloudPanel databases)

## Installation

1. Clone the Repository:
```
git clone https://github.com/WPSpeedExpert/rsync-pull-wp.git
```

2. Make the Script Executable:
```
chmod +x rsync-pull-production-to-staging.sh
```

3. Set Up Crontab (Optional):
To schedule the script to run automatically, add it to your crontab:
```
0 0 * * * /home/youruser/rsync-pull-production-to-staging.sh 2>&1
```

## Configuration

Before running the script, you need to configure several variables:

### Source (Production) Configuration

- domainName: The domain name of the production site (e.g., example.com).
- siteUser: The system user for the production site (e.g., user).

### Destination (Staging) Configuration

- staging_domainName: The domain name of the staging site (e.g., staging.example.com).
- staging_siteUser: The system user for the staging site (e.g., staging_user).

### Remote Server Settings

- use_remote_server: Set to true if syncing from a remote production server.
- remote_server_ssh: The SSH connection string for the remote server (e.g., root@IP_ADDRESS).

### Admin Email

- admin_email: Email address for receiving alerts (e.g., admin@example.com).

### Database Configuration

-table_Prefix: The prefix of the WordPress database tables (default is wp_).
-databaseName: The name of the production database.
-staging_databaseName: The name of the staging database.
-staging_databaseUserPassword: The password for the staging database, fetched from .my.cnf.

### Additional Options

- import_methods: Choose the method(s) for importing the database.
- mysql_restart_method: Options are restart, stop_start, reboot, or none.
- backup_staging_database: Set to true to back up the staging database before deletion.
- recreate_database: Set to true to delete and recreate the staging database.
- keep_uploads_folder: Set to false if you want to delete the wp-content/uploads folder during cleanup.

## Usage

To run the script manually, simply execute:
```
./rsync-pull-production-to-staging.sh
```
### The script will perform the following steps:

1.	Initial Setup: Configures logging and checks for necessary files and directories.
2.	Pre-Execution Checks: Ensures all required files and services are available.
3.	Maintenance Mode: Activates maintenance mode by creating an index.html file.
4.	Database Export and Backup: Exports the production database and optionally backs up the staging database.
5.	Database Import: Imports the production database into the staging environment using the selected method.
6.	Search and Replace: Updates URLs in the staging database to match the staging environment.
7.	File Synchronization: Uses rsync to sync website files from production to staging.
8.	Post-Sync Cleanup: Restores files, flushes Redis, and adjusts permissions.

## Logging and Monitoring

The script logs all its actions to a log file (rsync-pull-production-to-staging.log) located in the staging script path. You can monitor the progress and troubleshoot issues by reviewing this log.

## Contributing

Contributions to this project are welcome. If you find a bug or have a feature request, please open an issue on GitHub. Pull requests are also encouraged.

## License

This script is open-source software licensed under the GNU General Public License v3.0. See the LICENSE file for more details.

This README file provides all the necessary information for understanding, configuring, and using the Rsync Production to Staging script. Feel free to adapt and expand upon it to suit your specific needs.
