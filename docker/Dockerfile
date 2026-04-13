FROM ubuntu:24.04

# Environment Variables
ENV DEBIAN_FRONTEND=noninteractive
ENV WEBSITE_ADDRESS=localhost
ENV PROTOCOL=http://

# 1. Install strictly necessary system & PHP dependencies, then instantly purge caches
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    ca-certificates curl unzip zip graphviz aspell git ghostscript \
    mariadb-client apache2 libapache2-mod-fcgid sudo cron \
    php8.3-fpm php8.3-cli php8.3-curl php8.3-zip php8.3-gd \
    php8.3-xml php8.3-intl php8.3-mbstring php8.3-xmlrpc \
    php8.3-soap php8.3-bcmath php8.3-exif php8.3-ldap php8.3-mysql && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Install Composer, shallow-clone Moodle, run Composer, and instantly delete caches
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer && \
    mkdir -p /var/www/html/sites/moodle && \
    mkdir -p /var/www/data/moodledata && \
    mkdir -p /var/www/.cache/composer && \
    chown -R www-data:www-data /var/www/.cache/composer && \
    chmod -R 750 /var/www/.cache/composer && \
    git clone --depth 1 -b v5.1.0 https://github.com/moodle/moodle.git /var/www/html/sites/moodle && \
    rm -rf /var/www/html/sites/moodle/.git && \
    chown -R www-data:www-data /var/www/html/sites/moodle && \
    cd /var/www/html/sites/moodle && \
    sudo -u www-data COMPOSER_CACHE_DIR="/var/www/.cache/composer" composer install --no-dev --classmap-authoritative && \
    rm -rf /var/www/.cache/composer && \
    chmod -R 755 /var/www/html/sites/moodle && \
    chown -R www-data:www-data /var/www/data/moodledata && \
    find /var/www/data/moodledata -type d -exec chmod 700 {} \; && \
    find /var/www/data/moodledata -type f -exec chmod 600 {} \;

# 3. Configure Apache and PHP variables
RUN a2enmod proxy_fcgi setenvif rewrite && \
    a2dissite 000-default.conf && \
    php_ini_apache="/etc/php/8.3/fpm/php.ini" && \
    php_ini_cli="/etc/php/8.3/cli/php.ini" && \
    sed -i 's/^[[:space:]]*;*[[:space:]]*max_input_vars[[:space:]]*=.*/max_input_vars = 5000/' "$php_ini_apache" "$php_ini_cli" && \
    sed -i 's/^\s*post_max_size\s*=.*/post_max_size = 256M/' "$php_ini_apache" "$php_ini_cli" && \
    sed -i 's/^\s*upload_max_filesize\s*=.*/upload_max_filesize = 256M/' "$php_ini_apache" "$php_ini_cli"

# Setup Cron Task
RUN echo "* * * * * /usr/bin/php /var/www/html/sites/moodle/admin/cli/cron.php >/dev/null" | crontab -u www-data -

# Copy and setup Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose Web port
EXPOSE 80

# Run entrypoint
ENTRYPOINT ["/entrypoint.sh"]

