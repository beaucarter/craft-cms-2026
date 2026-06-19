FROM node:22-alpine AS assets
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY src ./src
COPY templates ./templates
COPY vite.config.js ./
RUN pnpm build

FROM composer:2 AS dependencies
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install \
    --no-dev \
    --no-interaction \
    --no-scripts \
    --optimize-autoloader \
    --prefer-dist \
    --ignore-platform-reqs

FROM php:8.4-apache-bookworm AS runtime

ENV APACHE_DOCUMENT_ROOT=/var/www/html/web

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libcurl4-openssl-dev \
        libfreetype6-dev \
        libicu-dev \
        libjpeg62-turbo-dev \
        libmagickwand-dev \
        libonig-dev \
        libpng-dev \
        libpq-dev \
        libwebp-dev \
        libzip-dev \
        unzip \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
        bcmath \
        curl \
        exif \
        gd \
        intl \
        mbstring \
        opcache \
        pdo_pgsql \
        zip \
    && pecl install imagick \
    && docker-php-ext-enable imagick \
    && php -r '$required = ["bcmath", "curl", "dom", "gd", "imagick", "intl", "mbstring", "pdo_pgsql", "zip"]; foreach ($required as $extension) { if (!extension_loaded($extension)) { fwrite(STDERR, "Missing PHP extension: $extension\n"); exit(1); } }' \
    && a2enmod expires headers remoteip rewrite \
    && sed -ri -e "s!/var/www/html!${APACHE_DOCUMENT_ROOT}!g" /etc/apache2/sites-available/*.conf \
    && sed -ri -e "s!/var/www/!${APACHE_DOCUMENT_ROOT}!g" /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf \
    && rm -rf /var/lib/apt/lists/* /tmp/pear

COPY docker/php.ini /usr/local/etc/php/conf.d/craft.ini
COPY --chown=www-data:www-data . /var/www/html
COPY --from=dependencies --chown=www-data:www-data /app/vendor /var/www/html/vendor
COPY --from=assets --chown=www-data:www-data /app/web/dist /var/www/html/web/dist
COPY docker/entrypoint.sh /usr/local/bin/craft-entrypoint

RUN chmod +x /usr/local/bin/craft-entrypoint \
    && mkdir -p storage/runtime storage/logs web/cpresources web/uploads \
    && chown -R www-data:www-data storage web/cpresources web/uploads

ENTRYPOINT ["craft-entrypoint"]
CMD ["apache2-foreground"]
