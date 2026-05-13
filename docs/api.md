# API приложения

Базовый URL: `http://localhost:8080/api`

Все эндпоинты возвращают JSON. Авторизация не требуется (приложение — учебное).

## GET /items

Список всех задач, отсортированных по `created_at DESC`.

```bash
curl http://localhost:8080/api/items
```

Ответ:

```json
[
  {"id": 50, "name": "купить хлеб", "completed": false, "completed_at": null,
   "created_at": "2024-01-01T10:00:00.000000Z", "updated_at": "..."},
  ...
]
```

## POST /item

Создать задачу. Запись идёт в writer (master).

```bash
curl -X POST http://localhost:8080/api/item \
  -H 'Content-Type: application/json' \
  -d '{"item":{"name":"новая задача"}}'
```

Ответ — созданная модель.

## PATCH /item/{id}

Переключить флаг `completed`. При `completed=true` проставляется `completed_at = now()`.

```bash
curl -X PATCH http://localhost:8080/api/item/1 \
  -H 'Content-Type: application/json' \
  -d '{"item":{"completed":true}}'
```

## DELETE /item/{id}

Удалить задачу.

```bash
curl -X DELETE http://localhost:8080/api/item/1
```

## Service endpoints

| URL | Назначение |
| --- | --- |
| `GET /healthz` | liveness для балансировщика |
| `GET /nginx_status` (порт 8081, только из docker-сети) | stub_status nginx |
| `GET /fpm-status` (порт 8081) | статус php-fpm пула |
| `GET /fpm-ping` (порт 8081) | пинг php-fpm |
