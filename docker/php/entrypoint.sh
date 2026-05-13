#!/usr/bin/env bash
set -euo pipefail

APP_PATH=/var/www/html
ROLE="${APP_ROLE:-app}"

cd "$APP_PATH"

cat > .env <<EOF
APP_NAME=${APP_NAME:-Laravel}
APP_ENV=${APP_ENV:-production}
APP_KEY=${APP_KEY:-}
APP_DEBUG=${APP_DEBUG:-false}
APP_URL=${APP_URL:-http://localhost}

LOG_CHANNEL=${LOG_CHANNEL:-stderr}
LOG_LEVEL=${LOG_LEVEL:-info}

WRITER_DB_CONNECTION=${WRITER_DB_CONNECTION:-mysql}
WRITER_DB_HOST=${WRITER_DB_HOST:-db-master}
WRITER_DB_PORT=${WRITER_DB_PORT:-3306}
WRITER_DB_DATABASE=${WRITER_DB_DATABASE:-app}
WRITER_DB_USERNAME=${WRITER_DB_USERNAME:-app}
WRITER_DB_PASSWORD=${WRITER_DB_PASSWORD:-app}

READER_DB_CONNECTION=${READER_DB_CONNECTION:-mysql}
READER_DB_HOST=${READER_DB_HOST:-db-slave}
READER_DB_PORT=${READER_DB_PORT:-3306}
READER_DB_DATABASE=${READER_DB_DATABASE:-app}
READER_DB_USERNAME=${READER_DB_USERNAME:-app}
READER_DB_PASSWORD=${READER_DB_PASSWORD:-app}

BROADCAST_DRIVER=log
CACHE_DRIVER=${CACHE_DRIVER:-file}
FILESYSTEM_DISK=local
QUEUE_CONNECTION=${QUEUE_CONNECTION:-sync}
SESSION_DRIVER=${SESSION_DRIVER:-file}
SESSION_LIFETIME=120
EOF

if ! grep -q '^APP_KEY=base64:' .env; then
    php artisan key:generate --force --ansi
fi

mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views storage/framework/testing storage/logs bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache
chmod -R ug+rwX storage bootstrap/cache

php artisan config:clear >/dev/null 2>&1 || true
php artisan route:clear >/dev/null 2>&1 || true
php artisan view:clear >/dev/null 2>&1 || true

wait_for_db() {
    local host="$1" port="${2:-3306}" user="$3" pass="$4"
    local tries=60
    until mysqladmin ping -h "$host" -P "$port" -u "$user" -p"$pass" --silent >/dev/null 2>&1; do
        tries=$((tries-1))
        if [ "$tries" -le 0 ]; then
            echo "не дождался $host:$port" >&2
            exit 1
        fi
        sleep 2
    done
}

if [ "$ROLE" = "migrate" ]; then
    wait_for_db "$WRITER_DB_HOST" "$WRITER_DB_PORT" "$WRITER_DB_USERNAME" "$WRITER_DB_PASSWORD"
    php artisan migrate:fresh --seed --force --ansi
    exit 0
fi

exec "$@"
