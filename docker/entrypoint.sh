#!/bin/bash
set -e

MOODLE_CODE_FOLDER="/var/www/html/sites/moodle"
MOODLE_DATA_FOLDER="/var/www/data"

# Standardizing Database Connection Variables
DB_HOST=${DB_HOST:-"lms-db"}
DB_NAME=${DB_NAME:-"moodle"}
DB_USER=${DB_USER:-"moodleuser"}
DB_PASS=${DB_PASS:-"dbpassword!"}
WEBSITE_ADDRESS=${WEBSITE_ADDRESS:-"localhost"}
PROTOCOL=${PROTOCOL:-"http://"}

echo "### Setting up runtime configurations ###"

# 1. Update moodle.conf with the runtime WEBSITE_ADDRESS
cat <<EOF > /etc/apache2/sites-available/moodle.conf
<VirtualHost *:80>
    ServerName ${WEBSITE_ADDRESS}
    ServerAlias www.${WEBSITE_ADDRESS}
    DocumentRoot  ${MOODLE_CODE_FOLDER}/public
    <Directory /var/www/html/sites>
        Options FollowSymLinks
        AllowOverride None
        Require all granted
        DirectoryIndex index.php index.html
        FallbackResource /r.php
    </Directory>
    <FilesMatch "\.php$">
        SetHandler "proxy:unix:/run/php/php8.3-fpm.sock|fcgi://localhost/"
    </FilesMatch>
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

a2ensite moodle.conf > /dev/null

# 2. Start Process Services
echo "Starting PHP-FPM..."
mkdir -p /run/php
service php8.3-fpm start

echo "Starting Cron..."
service cron start

# 3. Wait for the remote database
echo "Waiting for External Database ($DB_HOST) to wake up..."
while ! mysqladmin ping -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" --silent; do
    sleep 2
done
echo "Database is awake and reachable!"

# 4. Handle Moodle Install
# We check if Moodle's tables exist already.
if ! mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "USE $DB_NAME; SHOW TABLES LIKE 'mdl_config';" | grep -q "mdl_config"; then
    echo "Moodle tables not found in database. Running Installer..."
    
    MOODLE_ADMIN_PASSWORD=$(openssl rand -base64 12)

    echo "Running Moodle CLI Installer against external database..."
    chmod -R 0777 $MOODLE_CODE_FOLDER
    
    sudo -u www-data /usr/bin/php $MOODLE_CODE_FOLDER/admin/cli/install.php \
        --non-interactive \
        --lang=en \
        --wwwroot="${PROTOCOL}${WEBSITE_ADDRESS}" \
        --dataroot=$MOODLE_DATA_FOLDER/moodledata \
        --dbtype=mariadb \
        --dbhost="$DB_HOST" \
        --dbname="$DB_NAME" \
        --dbuser="$DB_USER" \
        --dbpass="$DB_PASS" \
        --fullname="Generic Moodle" \
        --shortname="GM" \
        --adminuser=admin \
        --summary="My Moodle Site" \
        --adminpass="$MOODLE_ADMIN_PASSWORD" \
        --adminemail="admin@example.com" \
        --agree-license

    # Re-set secure permissions
    find $MOODLE_CODE_FOLDER -type d -exec chmod 755 {} \;
    find $MOODLE_CODE_FOLDER -type f -exec chmod 644 {} \;

    sed -i "/require_once(__DIR__ . '\/lib\/setup.php');/i \$CFG->slasharguments = false;" $MOODLE_CODE_FOLDER/config.php

    echo "------------------------------------------------------------"
    echo "Moodle Web Node installation completed successfully!"
    echo "URL: ${PROTOCOL}${WEBSITE_ADDRESS}"
    echo "Admin Username: admin"
    echo "Admin Password: $MOODLE_ADMIN_PASSWORD"
    echo "------------------------------------------------------------"

    mkdir -p $MOODLE_DATA_FOLDER
    echo "Admin Password: $MOODLE_ADMIN_PASSWORD" > $MOODLE_DATA_FOLDER/moodle_credentials.txt
else
    echo "Moodle is already installed in the remote database. Skipping initialization."
fi

# 5. Start Apache in Foreground
echo "Starting Apache Web Server..."

export APACHE_RUN_DIR="/var/run/apache2"
export APACHE_RUN_USER="www-data"
export APACHE_RUN_GROUP="www-data"
export APACHE_LOG_DIR="/var/log/apache2"
export APACHE_LOCK_DIR="/var/lock/apache2"
export APACHE_PID_FILE="/var/run/apache2/apache2.pid"

mkdir -p "$APACHE_RUN_DIR" "$APACHE_LOCK_DIR" "$APACHE_LOG_DIR"
chown -R "$APACHE_RUN_USER:$APACHE_RUN_GROUP" "$APACHE_RUN_DIR" "$APACHE_LOCK_DIR" "$APACHE_LOG_DIR"

exec /usr/sbin/apache2 -D FOREGROUND

