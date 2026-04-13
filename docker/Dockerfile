####################################################################
# STAGE 1: THE BUILDER
####################################################################

FROM ubuntu:24.04 as builder

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install dependencies, download tools, and strictly compile Moodle
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    ca-certificates curl unzip git \
    php8.3-cli php8.3-curl php8.3-zip php8.3-mbstring php8.3-xml && \
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer && \
    mkdir -p /app/moodle && \
    mkdir -p /app/.cache/composer && \
    git clone --depth 1 -b v5.1.0 https://github.com/moodle/moodle.git /app/moodle && \
    rm -rf /app/moodle/.git && \
    cd /app/moodle && \
    COMPOSER_CACHE_DIR="/app/.cache/composer" composer install --no-dev --classmap-authoritative --ignore-platform-reqs && \
    rm -rf /app/.cache/composer && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

####################################################################
# STAGE 2: THE PRODUCTION RUNTIME
####################################################################

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV WEBSITE_ADDRESS=localhost
ENV PROTOCOL=http://

# 1. Install pristine runtime components (No git, curl, or heavy building packages left!)
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    ca-certificates zip unzip graphviz aspell ghostscript \
    mariadb-client apache2 libapache2-mod-fcgid sudo cron \
    php8.3-fpm php8.3-cli php8.3-curl php8.3-zip php8.3-gd \
    php8.3-xml php8.3-intl php8.3-mbstring php8.3-xmlrpc \
    php8.3-soap php8.3-bcmath php8.3-exif php8.3-ldap php8.3-mysql && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Securely copy the fully compiled Moodle repository from the Builder stage
COPY --from=builder --chown=www-data:www-data /app/moodle /var/www/html/sites/moodle

# 3. Configure directories, enforce ownership, inject Apache/PHP configs, and initialize Cron
RUN mkdir -p /var/www/data/moodledata && \
    chown -R www-data:www-data /var/www/data/moodledata && \
    chmod -R 700 /var/www/data/moodledata && \
    a2enmod proxy_fcgi setenvif rewrite && \
    a2dissite 000-default.conf && \
    php_ini_apache="/etc/php/8.3/fpm/php.ini" && \
    php_ini_cli="/etc/php/8.3/cli/php.ini" && \
    sed -i 's/^[[:space:]]*;*[[:space:]]*max_input_vars[[:space:]]*=.*/max_input_vars = 5000/' "$php_ini_apache" "$php_ini_cli" && \
    sed -i 's/^\s*post_max_size\s*=.*/post_max_size = 256M/' "$php_ini_apache" "$php_ini_cli" && \
    sed -i 's/^\s*upload_max_filesize\s*=.*/upload_max_filesize = 256M/' "$php_ini_apache" "$php_ini_cli" && \
    echo "* * * * * /usr/bin/php /var/www/html/sites/moodle/admin/cli/cron.php >/dev/null" | crontab -u www-data -

# 4. Copy and setup Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose Web port
EXPOSE 80

# Run entrypoint
ENTRYPOINT ["/entrypoint.sh"]

