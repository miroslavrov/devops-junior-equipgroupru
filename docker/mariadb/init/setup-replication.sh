#!/bin/sh
set -eu

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD не задан}"
: "${MYSQL_REPL_USER:?MYSQL_REPL_USER не задан}"
: "${MYSQL_REPL_PASSWORD:?MYSQL_REPL_PASSWORD не задан}"

MASTER_HOST="${MASTER_HOST:-db-master}"
SLAVE_HOST="${SLAVE_HOST:-db-slave}"

wait_db() {
    host="$1"
    tries=120
    while [ "$tries" -gt 0 ]; do
        if mariadb-admin ping -h "$host" -u root -p"$MYSQL_ROOT_PASSWORD" --silent >/dev/null 2>&1; then
            return 0
        fi
        tries=$((tries - 1))
        sleep 2
    done
    echo "не дождался $host" >&2
    return 1
}

wait_db "$MASTER_HOST"
wait_db "$SLAVE_HOST"

mariadb -h "$MASTER_HOST" -u root -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE USER IF NOT EXISTS '${MYSQL_REPL_USER}'@'%' IDENTIFIED BY '${MYSQL_REPL_PASSWORD}';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${MYSQL_REPL_USER}'@'%';
FLUSH PRIVILEGES;
RESET MASTER;
SQL

STATUS=$(mariadb -h "$MASTER_HOST" -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW MASTER STATUS\G")
MASTER_LOG_FILE=$(echo "$STATUS" | awk '/File:/{print $2}')
MASTER_LOG_POS=$(echo "$STATUS" | awk '/Position:/{print $2}')

if [ -z "$MASTER_LOG_FILE" ] || [ -z "$MASTER_LOG_POS" ]; then
    echo "не удалось прочитать SHOW MASTER STATUS" >&2
    echo "$STATUS"
    exit 1
fi

mariadb -h "$SLAVE_HOST" -u root -p"$MYSQL_ROOT_PASSWORD" <<SQL
STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO
    MASTER_HOST='${MASTER_HOST}',
    MASTER_PORT=3306,
    MASTER_USER='${MYSQL_REPL_USER}',
    MASTER_PASSWORD='${MYSQL_REPL_PASSWORD}',
    MASTER_LOG_FILE='${MASTER_LOG_FILE}',
    MASTER_LOG_POS=${MASTER_LOG_POS},
    MASTER_CONNECT_RETRY=10;
START SLAVE;
SQL

sleep 3
mariadb -h "$SLAVE_HOST" -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW SLAVE STATUS\G" \
    | grep -E "Slave_(IO|SQL)_Running|Seconds_Behind|Last_(IO|SQL)_Error|Master_Log_File|Read_Master_Log_Pos" || true

echo "репликация настроена: ${MASTER_HOST} -> ${SLAVE_HOST} (файл ${MASTER_LOG_FILE}, позиция ${MASTER_LOG_POS})"
