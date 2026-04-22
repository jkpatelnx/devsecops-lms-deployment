#!/bin/bash

# Check if script is run as root (Effective User ID)
if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root or with sudo"
  exit
fi

set -e # Exit immediately if a command exits with a non-zero status

####################################################################
# Update and install base packages
####################################################################

# --- Variables & Input ---
PROTOCOL="http://"
read -r -p "Enter the web address (no http://, e.g., mymoodle123.com or 192.168.1.1): " WEBSITE_ADDRESS

MOODLE_PATH="/var/www/html/sites"
MOODLE_CODE_FOLDER="$MOODLE_PATH/moodle"
MOODLE_DATA_FOLDER="/var/www/data"

echo "### Starting Moodle Installation for $WEBSITE_ADDRESS ###"

# --- 1. Prepare Directories & Update System ---
sudo mkdir -p $MOODLE_PATH
sudo mkdir -p $MOODLE_DATA_FOLDER

sudo apt-get update && sudo apt upgrade -y

# --- 2. Install PHP 8.3 and Extensions ---
sudo apt-get install -y php8.3-fpm php8.3-cli php8.3-curl php8.3-zip php8.3-gd \
php8.3-xml php8.3-intl php8.3-mbstring php8.3-xmlrpc php8.3-soap php8.3-bcmath \
php8.3-exif php8.3-ldap php8.3-mysql php8.3-redis

# --- 3. Install Supporting Packages ---
sudo apt-get install -y unzip mariadb-server mariadb-client ufw nano graphviz \
aspell git clamav ghostscript composer redis-server

####################################################################
# Install a Webserver
####################################################################

# --- 4.  Install Nginx as your Webserver ---
sudo apt-get install -y nginx

sudo tee /etc/nginx/sites-available/moodle.conf > /dev/null <<EOF
server {
    listen 80;
    server_name $WEBSITE_ADDRESS www.$WEBSITE_ADDRESS;
    root $MOODLE_CODE_FOLDER/public;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args /r.php;
    }

    location ~ [^/]\.php(/|$) {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/moodle.conf /etc/nginx/sites-enabled/moodle.conf
sudo systemctl reload nginx

# --- 5. Configure PHP Settings ---
sudo systemctl enable --now php8.3-fpm

sudo sed -i 's/^;max_input_vars =.*/max_input_vars = 5000/' /etc/php/8.3/fpm/php.ini
sudo sed -i 's/^;max_input_vars =.*/max_input_vars = 5000/' /etc/php/8.3/cli/php.ini
sudo sed -i 's/^post_max_size =.*/post_max_size = 256M/' /etc/php/8.3/fpm/php.ini
sudo sed -i 's/^post_max_size =.*/post_max_size = 256M/' /etc/php/8.3/cli/php.ini
sudo sed -i 's/^upload_max_filesize =.*/upload_max_filesize = 256M/' /etc/php/8.3/fpm/php.ini
sudo sed -i 's/^upload_max_filesize =.*/upload_max_filesize = 256M/' /etc/php/8.3/cli/php.ini

sudo systemctl reload php8.3-fpm

####################################################################
# Obtain Moodle code using git
####################################################################

# --- 6. Obtain Moodle Code via Git ---
#sudo git clone --depth 1 -b v5.1.0 https://github.com/moodle/moodle.git $MOODLE_CODE_FOLDER
sudo git clone --depth 1 -b main https://github.com/jkpatelnx/devsecops-lms-app.git $MOODLE_CODE_FOLDER
sudo chown -R www-data:www-data $MOODLE_CODE_FOLDER

# Composer Install
CACHE_DIR="/var/www/.cache/composer"
sudo mkdir -p "$CACHE_DIR"
sudo chown -R www-data:www-data "$CACHE_DIR"
sudo chmod -R 750 "$CACHE_DIR"

cd $MOODLE_CODE_FOLDER
sudo -u www-data COMPOSER_CACHE_DIR="$CACHE_DIR" composer install --no-dev --classmap-authoritative
sudo chown -R www-data:www-data vendor
sudo chmod -R 755 $MOODLE_CODE_FOLDER

####################################################################
# Specific Moodle requirements
####################################################################

# --- 7. Setup MoodleData & Cron ---
sudo mkdir -p $MOODLE_DATA_FOLDER/moodledata
sudo chown -R www-data:www-data $MOODLE_DATA_FOLDER/moodledata
sudo find $MOODLE_DATA_FOLDER/moodledata -type d -exec chmod 700 {} \;
sudo find $MOODLE_DATA_FOLDER/moodledata -type f -exec chmod 600 {} \;

# Setup Cron task
echo "* * * * * /usr/bin/php $MOODLE_CODE_FOLDER/admin/cli/cron.php >/dev/null" | sudo crontab -u www-data -

####################################################################
# Create Database and User
####################################################################

# --- 8. Database and User Creation ---
MYSQL_MOODLEUSER_PASSWORD=$(openssl rand -base64 12) # Slightly longer for security

sudo mysql -e "CREATE DATABASE moodle DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -e "CREATE USER 'moodleuser'@'localhost' IDENTIFIED BY '$MYSQL_MOODLEUSER_PASSWORD';"
sudo mysql -e "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, CREATE TEMPORARY TABLES, DROP, INDEX, ALTER ON moodle.* TO 'moodleuser'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

####################################################################
# Configure Moodle from the command line
####################################################################

# --- 9. Moodle CLI Installation ---
MOODLE_ADMIN_PASSWORD=$(openssl rand -base64 12)

# Temporarily open permissions for install
sudo chmod -R 0777 $MOODLE_CODE_FOLDER

sudo -u www-data /usr/bin/php $MOODLE_CODE_FOLDER/admin/cli/install.php \
--non-interactive \
--lang=en \
--wwwroot="$PROTOCOL$WEBSITE_ADDRESS" \
--dataroot=$MOODLE_DATA_FOLDER/moodledata \
--dbtype=mariadb \
--dbhost=localhost \
--dbname=moodle \
--dbuser=moodleuser \
--dbpass="$MYSQL_MOODLEUSER_PASSWORD" \
--fullname="Generic Moodle" \
--shortname="GM" \
--adminuser=admin \
--summary="My Moodle Site" \
--adminpass="$MOODLE_ADMIN_PASSWORD" \
--adminemail="admin@example.com" \
--agree-license

# --- 10. Final Cleanup and Slash Arguments ---
# Re-set secure permissions
sudo find $MOODLE_CODE_FOLDER -type d -exec chmod 755 {} \;
sudo find $MOODLE_CODE_FOLDER -type f -exec chmod 644 {} \;

# Set slasharguments to false in config.php as requested
sudo sed -i "/require_once(__DIR__ . '\/lib\/setup.php');/i \$CFG->slasharguments = false;" $MOODLE_CODE_FOLDER/config.php

# Configure Redis for session caching
REDIS_PASSWORD=$(openssl rand -base64 12)
echo "requirepass $REDIS_PASSWORD" | sudo tee -a /etc/redis/redis.conf > /dev/null
echo "maxmemory 256mb" | sudo tee -a /etc/redis/redis.conf > /dev/null
echo "maxmemory-policy allkeys-lru" | sudo tee -a /etc/redis/redis.conf > /dev/null
sudo systemctl restart redis-server
sudo systemctl enable redis-server

sudo sed -i "/require_once(__DIR__ . '\/lib\/setup.php');/i \$CFG->session_provider = 'redis';" $MOODLE_CODE_FOLDER/config.php
sudo sed -i "/require_once(__DIR__ . '\/lib\/setup.php');/i \$CFG->session_redis_host = '127.0.0.1';" $MOODLE_CODE_FOLDER/config.php
sudo sed -i "/require_once(__DIR__ . '\/lib\/setup.php');/i \$CFG->session_redis_auth = '$REDIS_PASSWORD';" $MOODLE_CODE_FOLDER/config.php

echo "------------------------------------------------------------"
echo "Moodle installation completed successfully!"
echo "URL: $PROTOCOL$WEBSITE_ADDRESS"
echo "Admin Username: admin"
echo "Admin Password: $MOODLE_ADMIN_PASSWORD"
echo "Database Password: $MYSQL_MOODLEUSER_PASSWORD"
echo "Redis Password: $REDIS_PASSWORD"
echo "------------------------------------------------------------"
echo "Remember to change the admin email and site name via the web UI."
