# Тестовое задание — Junior DevOps

PHP-приложение Laravel за nginx-балансировщиком, две БД MariaDB с master→slave репликацией, мониторинг на Prometheus + Grafana + Alertmanager.

Запуск одной командой:

```bash
cp .env.example .env
docker compose up -d --build
```

После старта:

| Сервис | URL | Логин/пароль |
| --- | --- | --- |
| Приложение (TODO List) | http://localhost:8080 | — |
| Grafana | http://localhost:3000 | admin / admin |
| Prometheus | http://localhost:9090 | — |
| Alertmanager | http://localhost:9093 | — |
| MariaDB master | localhost:3307 | app / app |
| MariaDB slave | localhost:3308 | app / app |

При первом запуске уйдёт 5–10 минут: собирается образ приложения (composer install + npm install + npm run prod), поднимаются обе БД, настраивается репликация, прогоняются миграции и сидеры.

## Что внутри

```
.
├── docker-compose.yml          стек целиком
├── .env.example                все переменные с дефолтами
├── Makefile                    типовые операции (make up, make logs, ...)
├── src/                        исходники Laravel-приложения как есть
├── docker/
│   ├── php/                    Dockerfile (multi-stage), php.ini, www.conf, entrypoint
│   ├── nginx/                  балансировщик и веб-сервер
│   ├── mariadb/                my.cnf master/slave + скрипт инициализации репликации
│   ├── prometheus/             конфиг и правила алертов
│   ├── alertmanager/           маршрутизация уведомлений
│   ├── grafana/                provisioning + три дашборда
│   └── nginxlog-exporter/      парсер access.log для метрик по 5xx
└── docs/
    ├── architecture.md         схема и пояснения
    └── api.md                  описание REST-методов
```

## Архитектура (коротко)

```
        ┌──────────────┐
        │   browser    │
        └──────┬───────┘
               │ :8080
        ┌──────▼───────┐
        │    nginx     │  балансировщик + раздача статики из public/
        └──────┬───────┘
               │ fastcgi (least_conn)
       ┌───────┴────────┐
       ▼                ▼
   ┌──────┐         ┌──────┐
   │ app1 │         │ app2 │     php-fpm 8.2 (Laravel 9)
   └──┬───┘         └──┬───┘
      │ writes          │ reads
      ▼                 ▼
 ┌────────┐         ┌────────┐
 │ master │ ──repl──▶ slave  │     MariaDB 10.11
 └────────┘         └────────┘
```

Подробная схема и описание потоков — в [docs/architecture.md](docs/architecture.md).

## Требования к хосту

- Docker Engine 24+ / Docker Compose v2
- 4 GB свободной памяти (на старте сборки)
- свободные порты: 8080, 8081, 3000, 9090, 9093, 3307, 3308 (переопределяются в `.env`)

## Запуск пошагово

```bash
git clone <repo>
cd junior-devops
cp .env.example .env
docker compose up -d --build
```

Что произойдёт:

1. Сборка образа `equip-todo-app:latest` (multi-stage: nodejs собирает фронт, php устанавливает зависимости).
2. Старт master и slave, создание базы и пользователя приложения.
3. Сервис `replication-init` создаёт пользователя репликации на master, выполняет `RESET MASTER`, читает `SHOW MASTER STATUS` и выставляет slave на нужную позицию.
4. Сервис `migrate` дожидается master, прогоняет `migrate:fresh --seed` — данные через бинлог попадают на slave.
5. Стартуют 2 PHP-FPM-воркера (app1, app2) и nginx-балансировщик.
6. Поднимается мониторинг.

Полезные команды:

```bash
make ps                  # статус
make logs                # логи
make replication-status  # проверить slave (Slave_IO_Running, Slave_SQL_Running, лаг)
make seed                # переналить базу
make shell               # bash внутри app1
make down                # остановить
make clean               # остановить и удалить тома
```

## Проверка, что репликация работает

```bash
# создаём задачу через API (попадёт в writer = master)
curl -X POST http://localhost:8080/api/item \
  -H 'Content-Type: application/json' \
  -d '{"item":{"name":"проверка репликации"}}'

# читаем напрямую со slave (реплика приехала через бинлог)
docker compose exec db-slave mariadb -uapp -papp app \
  -e "SELECT id, name, created_at FROM items ORDER BY id DESC LIMIT 5;"
```

Состояние самой репликации:

```bash
make replication-status
```

Должно быть `Slave_IO_Running: Yes`, `Slave_SQL_Running: Yes`, `Seconds_Behind_Master: 0`.

## Мониторинг и алерты

Grafana (http://localhost:3000, admin/admin) — три дашборда:

- **Equip TODO — обзор**: CPU, память, swap, контейнеры, RPS, 5xx, репликация.
- **MariaDB — master/slave**: QPS, соединения, лаг, потоки репликации.
- **Nginx + PHP-FPM**: статус-коды, время ответа upstream, очередь воркеров.

Алерты лежат в [docker/prometheus/rules/alerts.yml](docker/prometheus/rules/alerts.yml). Покрывают всё, что просили в задании:

| Алерт | Условие |
| --- | --- |
| `HostCpuIdleLow` | CPU idle < 10% за 10 минут |
| `HostDiskSpaceLow` | свободно на разделе < 10% |
| `HostInodesLow` | свободных inodes < 10% |
| `HostDiskIoSaturated` | загрузка диска по iostat > 95% за 3 минуты |
| `HostSwapHigh` | swap > 90% за 5 минут |
| `DockerCadvisorDown` | cadvisor не отвечает — индикатор недоступности docker |
| `DockerContainerCountChanged` | изменилось число запущенных контейнеров |
| `DockerContainerRestarting` | контейнер находится в цикле рестартов |
| `NginxNoTraffic` | RPS = 0 в течение 10 минут |
| `Nginx5xxErrors` | пятисотки в приложении |
| `PhpFpmNoTraffic` | принято запросов = 0 за 3 минуты |
| `PhpFpmMaxChildrenReached` | пул упёрся в pm.max_children |
| `MysqlDown` | master/slave недоступны |
| `MysqlReplicationBroken` | один из потоков репликации не работает |
| `MysqlReplicationLag` | лаг > 60 секунд |

Текущее состояние алертов: http://localhost:9090/alerts, маршрутизация: http://localhost:9093.

## Принятые решения и допущения

- **Версии**: PHP 8.2-fpm на bookworm, MariaDB 10.11 LTS, Nginx 1.27, Node 18 (для сборки ассетов). Версии зафиксированы тегами, без `latest`.
- **Балансировщик**: один nginx, балансирует FastCGI-запросы по пулу `app1, app2` стратегией `least_conn` с health-check (`max_fails=3, fail_timeout=10s`). Этого хватает для горизонтального масштабирования приложения. Можно добавить ещё инстансы — достаточно поднять `app3, app4` и дописать их в upstream.
- **Репликация**: классическая позиционная (file/position), не GTID. Так проще диагностируется и переинициализируется. На master включён `binlog_format=ROW`, `sync_binlog=1`, `innodb_flush_log_at_trx_commit=1` — надёжность важнее скорости. Slave стартует с `skip_slave_start=1`, репликацию запускает отдельный one-shot сервис `replication-init` — это даёт идемпотентность и понятный лог.
- **Бэкап и failover не реализованы** — в ТЗ их нет, и для junior-задания это перебор. В разделе «Что дальше» написано, как их добавлять.
- **APP_KEY** зашит в `.env.example` для воспроизводимости стенда. В реальной среде ключ должен лежать в секрет-сторе (vault, sops, aws sm) и инжектиться в env-переменные.
- **Сессии и кэш** — file-driver внутри контейнера. Для прод-режима с несколькими репликами правильнее redis (`SESSION_DRIVER=redis`, `CACHE_DRIVER=redis`), но это уже выходит за объём задания.
- **Сборка фронта** делается на этапе образа (`node:18 → npm ci → npm run prod`), результат копируется в финальный image. Контейнеры запускаются мгновенно, без необходимости тянуть node_modules в рантайме.
- **Volumes**: `app_public` — именованный volume, шарится между nginx (RO) и обоими php-fpm. На первом старте volume инициализируется содержимым из образа.
- **Метрики 5xx**: nginx-prometheus-exporter не отдаёт метрики по статус-кодам (только stub_status). Поэтому добавлен второй экспортёр — `prometheus-nginxlog-exporter`, который парсит access.log и публикует `nginx_http_response_count_total{status_class="5xx"}`.

## Что дальше (если бы было ещё время)

- redis для session/cache/queue
- supervisor для laravel queue worker
- бэкап master через `mariabackup` + offsite-хранилище
- автоматический failover (orchestrator / proxysql)
- TLS на nginx + автообновление сертификатов
- canary-выкатка через две версии образа (`app-blue` / `app-green`)
- Loki + Promtail для логов
- алерты на бизнес-метрики (CRUD по items, 99-перцентиль времени ответа)

## API

| Метод | Путь | Описание |
| --- | --- | --- |
| GET | `/api/items` | список задач |
| GET | `/api/item/{id}` | задача по id |
| POST | `/api/item` | создать (`{"item":{"name":"..."}}`) |
| PUT/PATCH | `/api/item/{id}` | пометить выполненной (`{"item":{"completed":true}}`) |
| DELETE | `/api/item/{id}` | удалить |

Подробнее — в [docs/api.md](docs/api.md).
