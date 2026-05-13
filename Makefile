SHELL := /bin/bash
COMPOSE ?= docker compose

.PHONY: help up down build rebuild logs ps migrate seed shell tinker test \
        replication-status slave-status grafana prometheus clean nuke

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

up: ## поднять весь стек
	$(COMPOSE) up -d --build

down: ## остановить
	$(COMPOSE) down

build: ## пересобрать образ приложения
	$(COMPOSE) build app1

rebuild: ## down + полная пересборка + up
	$(COMPOSE) down -v
	$(COMPOSE) build --no-cache
	$(COMPOSE) up -d

logs: ## логи всех сервисов
	$(COMPOSE) logs -f --tail=100

ps: ## статус контейнеров
	$(COMPOSE) ps

migrate: ## прогнать миграции вручную
	$(COMPOSE) run --rm migrate

seed: ## переналить базу демо-данными
	$(COMPOSE) exec app1 php artisan migrate:fresh --seed --force

shell: ## войти в контейнер app1
	$(COMPOSE) exec app1 bash

tinker: ## tinker laravel
	$(COMPOSE) exec app1 php artisan tinker

test: ## phpunit
	$(COMPOSE) exec app1 vendor/bin/phpunit

replication-status: ## проверить статус репликации (slave)
	$(COMPOSE) exec db-slave mariadb -uroot -p$$MYSQL_ROOT_PASSWORD -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind|Last_(IO|SQL)_Error|Read_Master_Log_Pos"

slave-status: replication-status

grafana: ## открыть grafana
	@echo "http://localhost:$${GRAFANA_PORT:-3000} (admin/admin)"

prometheus: ## открыть prometheus
	@echo "http://localhost:$${PROMETHEUS_PORT:-9090}"

clean: ## остановить и удалить тома
	$(COMPOSE) down -v

nuke: clean ## clean + удалить локальные образы
	docker image rm equip-todo-app:latest 2>/dev/null || true
