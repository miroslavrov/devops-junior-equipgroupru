# Архитектура

## Логическая схема

```
                          ┌────────────────────────────────────────────┐
                          │                    хост                    │
                          │                                            │
   user ── :8080 ─────────┼─► nginx :80  ──┐                           │
                          │                │ least_conn (FastCGI)       │
                          │                ├─► app1 (php-fpm 8.2)       │
                          │                │           │                │
                          │                └─► app2 (php-fpm 8.2)       │
                          │                            │                │
                          │             writer ◄───────┘                │
                          │             reader ◄──────┐                 │
                          │                           │                 │
                          │   db-master (mariadb) ────┴─► db-slave      │
                          │   ├ binlog (ROW)              read_only=1   │
                          │   └ user 'repl'               replication   │
                          │                                            │
                          │   мониторинг                               │
                          │   ┌──────────────┐    ┌─────────────┐      │
                          │   │ node-exporter│    │  cadvisor   │      │
                          │   ├──────────────┤    ├─────────────┤      │
                          │   │nginx-exporter│    │nginxlog-exp │      │
                          │   ├──────────────┤    ├─────────────┤      │
                          │   │ php-fpm-exp  │    │mysqld-exp×2 │      │
                          │   └──────┬───────┘    └─────┬───────┘      │
                          │          └──────► prometheus ◄──── alerts  │
                          │                       │                    │
                          │                       ├─► alertmanager     │
                          │                       └─► grafana          │
                          └────────────────────────────────────────────┘
```

## Поток запроса

1. Клиент стучится на `http://<host>:8080`.
2. nginx принимает HTTP, сам отдаёт статику (`/css`, `/js`, `/img`) из `public/`.
3. Для всего, что не файл — пишет в `index.php` и делает FastCGI-запрос в upstream `php_backend`.
4. Балансировщик выбирает app1 или app2 (стратегия least_conn).
5. Laravel читает `READER_DB_*` для SELECT и `WRITER_DB_*` для INSERT/UPDATE/DELETE.
   - SELECT идут на `db-slave:3306`.
   - Запись идёт на `db-master:3306`.
6. master пишет изменение в бинлог; slave-io-thread на slave забирает событие, slave-sql-thread применяет его к данным.

## Поток репликации

1. **Старт master**: образ `mariadb:10.11` создаёт пользователя `app`, базу `app`, применяет `docker/mariadb/master/my.cnf` (server-id=1, log-bin=ROW, sync_binlog=1).
2. **Старт slave**: то же самое + `server-id=2, read_only=1, skip_slave_start=1`. Slave стартует «пустым» и ждёт инструкций.
3. **replication-init** (one-shot контейнер):
   - дожидается обоих экземпляров;
   - на master создаёт `repl@%` с `REPLICATION SLAVE, REPLICATION CLIENT`, выполняет `RESET MASTER` (чистим бинлог от служебных событий);
   - читает `SHOW MASTER STATUS` (`File`, `Position`);
   - на slave выполняет `STOP SLAVE; RESET SLAVE ALL; CHANGE MASTER TO ...; START SLAVE;`.
4. **migrate** (one-shot): прогоняет `php artisan migrate:fresh --seed` на master. События уходят в бинлог, slave подтягивает их и реплицирует структуру и данные.
5. **exporter-init** (one-shot): создаёт пользователя `exporter` на обоих экземплярах с минимальными правами (`PROCESS, REPLICATION CLIENT, SELECT`) — нужен для mysqld_exporter.

После этого master и slave работают штатно. При перезапуске стека `replication-init` идемпотентно настроит репликацию заново.

## Сборка PHP-образа (multi-stage)

```
stage 1: node:18-bookworm-slim
  └─ npm ci
  └─ npm run prod          (laravel-mix собирает app.js, app.css)

stage 2: php:8.2-fpm-bookworm
  └─ apt: git, curl, default-mysql-client, libs для GD/zip/intl
  └─ docker-php-ext-install: bcmath, exif, gd, intl, opcache, pcntl, pdo_mysql, zip
  └─ composer 2.7
  └─ composer install --no-dev --optimize-autoloader
  └─ COPY из stage 1: /public/css, /public/js
  └─ composer dump-autoload --optimize
  └─ entrypoint.sh + CMD: php-fpm -F
```

Итог: один образ `equip-todo-app:latest`, который используется и для `app1/app2`, и для одноразовых задач `migrate`. Поведение задаётся через `APP_ROLE` (`app`/`migrate`).

## Сеть

Две Docker-сети:

- `backend` — БД, приложения, балансировщик, mysqld/php-fpm экспортёры. Изолирована от внешнего интернета на уровне docker.
- `monitoring` — prometheus, grafana, alertmanager и все экспортёры. Балансировщик подключён к обеим сетям, чтобы prometheus мог стучаться в `nginx-exporter`.

Наружу проброшены только порты приложения, БД (для отладки) и UI мониторинга — список в `.env.example`.

## Тома

| Том | Назначение |
| --- | --- |
| `mariadb_master_data` | данные master |
| `mariadb_slave_data` | данные slave |
| `app_public` | собранный `public/` Laravel-приложения, делится между nginx и app-контейнерами |
| `app_storage_app1/2` | `storage/` Laravel — кэш/сессии/логи каждого инстанса |
| `nginx_logs` | `/var/log/nginx`, читается nginxlog-exporter'ом |
| `prometheus_data` | TSDB |
| `alertmanager_data` | состояние тишин/групп |
| `grafana_data` | дашборды/настройки |

## Безопасность

- внешние порты можно закрыть в `.env` (`MYSQL_MASTER_PORT`, `MYSQL_SLAVE_PORT`) — нужны только для локальной отладки;
- `mysqld_exporter` ходит под отдельным пользователем `exporter` с минимальными правами;
- `php-fpm` доступен только внутри docker-сети `backend`;
- grafana по умолчанию открыта анонимно в режиме `Viewer`, доступ admin/admin — нужно менять в `.env` перед прод-использованием;
- секреты заданы переменными окружения, в `.env.example` лежат демо-значения.
