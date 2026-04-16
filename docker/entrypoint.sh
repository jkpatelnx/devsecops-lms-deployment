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

SERVER_NAMES="$WEBSITE_ADDRESS"
if [[ ! "$WEBSITE_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SERVER_NAMES="$SERVER_NAMES www.$WEBSITE_ADDRESS"
fi

set_cfg_string() {
    local key="$1"
    local value="$2"
    local file="$3"
    local escaped_value
    escaped_value=$(printf '%s' "$value" | sed 's/[&|]/\\&/g')

    if grep -Eq "^[[:space:]]*\\\$CFG->$key[[:space:]]*=" "$file"; then
        sed -i "s|^[[:space:]]*\\\$CFG->$key[[:space:]]*=.*|\\\$CFG->$key = '$escaped_value';|" "$file"
    else
        sed -i "/require_once(__DIR__ . '\/lib\/setup.php');/i \\\$CFG->$key = '$escaped_value';" "$file"
    fi
}

set_cfg_bool() {
    local key="$1"
    local value="$2"
    local file="$3"

    if grep -Eq "^[[:space:]]*\\\$CFG->$key[[:space:]]*=" "$file"; then
        sed -i "s|^[[:space:]]*\\\$CFG->$key[[:space:]]*=.*|\\\$CFG->$key = $value;|" "$file"
    else
        sed -i "/require_once(__DIR__ . '\/lib\/setup.php');/i \\\$CFG->$key = $value;" "$file"
    fi
}

echo "### Setting up runtime configurations ###"

# 1. Update moodle.conf with the runtime WEBSITE_ADDRESS
cat <<EOF > /etc/nginx/sites-available/moodle.conf
server {
    listen 80;
    server_name ${SERVER_NAMES};
    root ${MOODLE_CODE_FOLDER}/public;
    index index.php index.html index.htm;

    set \$fcgi_https off;
    if (\$http_x_forwarded_proto = "https") {
        set \$fcgi_https on;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args /r.php;
    }

    location ~ [^/]\.php(/|$) {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param HTTPS \$fcgi_https;
        fastcgi_param HTTP_X_FORWARDED_PROTO \$http_x_forwarded_proto;
        fastcgi_param HTTP_X_FORWARDED_HOST \$http_x_forwarded_host;
        fastcgi_param HTTP_X_FORWARDED_FOR \$http_x_forwarded_for;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/moodle.conf /etc/nginx/sites-enabled/moodle.conf
rm -f /etc/nginx/sites-enabled/default

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

if [ -f "$MOODLE_CODE_FOLDER/config.php" ]; then
    set_cfg_string "wwwroot" "${PROTOCOL}${WEBSITE_ADDRESS}" "$MOODLE_CODE_FOLDER/config.php"
    set_cfg_bool "slasharguments" "false" "$MOODLE_CODE_FOLDER/config.php"

    if [ "$PROTOCOL" = "https://" ]; then
        set_cfg_bool "sslproxy" "true" "$MOODLE_CODE_FOLDER/config.php"
    else
        set_cfg_bool "sslproxy" "false" "$MOODLE_CODE_FOLDER/config.php"
    fi

    # Standard TLS termination at the edge proxy only needs sslproxy.
    # Moodle's reverseproxy mode is for more specialised proxy/load-balancer setups.
    set_cfg_bool "reverseproxy" "false" "$MOODLE_CODE_FOLDER/config.php"
fi

# 5. Start Nginx in Foreground
echo "Starting Nginx Web Server..."

# Ensure Nginx uses www-data
chown -R www-data:www-data /var/lib/nginx || true
chown -R www-data:www-data /var/log/nginx || true

exec nginx -g "daemon off;"
