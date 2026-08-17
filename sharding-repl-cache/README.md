# Шардирование, репликация и кеширование MongoDB

## Цель этапа

Развернуть локальный стенд, который объединяет:

- шардирование MongoDB;
- репликацию каждого шарда;
- кеширование запросов с помощью Redis;
- FastAPI-приложение для проверки работы решения.

Шардирование распределяет данные между двумя шардами и повышает пропускную способность системы.

Репликация создаёт несколько копий данных внутри каждого шарда и обеспечивает отказоустойчивость.

Redis уменьшает количество повторных обращений к MongoDB и ускоряет получение данных.

## Архитектура

В состав стенда входят десять контейнеров:

- `config-srv` — хранит метаданные шардированного кластера;
- `mongos` — маршрутизирует запросы к нужному шарду;
- `shard1-1`, `shard1-2`, `shard1-3` — участники `shard1ReplSet`;
- `shard2-1`, `shard2-2`, `shard2-3` — участники `shard2ReplSet`;
- `redis` — хранит кешированные ответы API;
- `pymongo-api` — FastAPI-приложение.

```text
Клиент
   │
   ▼
pymongo-api
   │
   ├──────────────► Redis
   │                │
   │         ответ найден в кеше
   │                │
   │◄───────────────┘
   │
   │ при отсутствии ответа в кеше
   ▼
 mongos ◄────────► config-srv
   │
   ├──────────────► shard1ReplSet
   │                 ├── shard1-1
   │                 ├── shard1-2
   │                 └── shard1-3
   │
   └──────────────► shard2ReplSet
                     ├── shard2-1
                     ├── shard2-2
                     └── shard2-3
```

Приложение не подключается к узлам шардов напрямую. Все обращения к MongoDB выполняются через `mongos`.

## Как работает кеширование

Для эндпоинта `GET /helloDoc/users` применяется стратегия Cache-Aside:

1. приложение проверяет наличие готового ответа в Redis;
2. при попадании в кеш ответ сразу возвращается клиенту;
3. при промахе приложение читает данные из MongoDB через `mongos`;
4. полученный ответ сохраняется в Redis;
5. следующие одинаковые запросы обслуживаются из кеша.

```text
Первый запрос:
клиент → API → Redis (cache miss) → MongoDB → Redis → клиент

Повторный запрос:
клиент → API → Redis (cache hit) → клиент
```

MongoDB остаётся источником истины. Потеря кеша не приводит к потере основных данных. Время жизни кешированной записи — 60 секунд.

## Шардирование и репликация

Коллекция `somedb.helloDoc` распределяется между двумя шардами по hashed-ключу `age`:

```text
somedb.helloDoc
├── часть документов → shard1ReplSet
└── часть документов → shard2ReplSet
```

Каждый шард состоит из трёх узлов:

```text
replica set
├── PRIMARY
├── SECONDARY
└── SECONDARY
```

Записи принимает `PRIMARY`. Узлы `SECONDARY` копируют изменения через `oplog`. При отказе основного узла оставшиеся участники сохраняют кворум и выбирают новый `PRIMARY`.

## Состав replica set

| Replica set | Узел | Предпочтительная роль | Порт |
|---|---|---|---:|
| `configReplSet` | `config-srv` | PRIMARY | `27019` |
| `shard1ReplSet` | `shard1-1` | PRIMARY | `27018` |
| `shard1ReplSet` | `shard1-2` | SECONDARY | `27018` |
| `shard1ReplSet` | `shard1-3` | SECONDARY | `27018` |
| `shard2ReplSet` | `shard2-1` | PRIMARY | `27018` |
| `shard2ReplSet` | `shard2-2` | SECONDARY | `27018` |
| `shard2ReplSet` | `shard2-3` | SECONDARY | `27018` |

Роли могут изменяться после автоматических выборов. Узлы `shard1-1` и `shard2-1` имеют повышенный приоритет и при нормальной работе предпочтительно выбираются как `PRIMARY`.

## Сетевые порты

| Компонент | Порт внутри Docker-сети | Порт на хосте |
|---|---:|---:|
| `config-srv` | `27019` | не опубликован |
| узлы шардов | `27018` | не опубликован |
| `mongos` | `27017` | не опубликован |
| `redis` | `6379` | не опубликован |
| `pymongo-api` | `8080` | `8080` |

MongoDB и Redis доступны только внутри Docker-сети. На хост опубликован только API.

## Параметры стенда

- база данных: `somedb`;
- коллекция: `helloDoc`;
- namespace: `somedb.helloDoc`;
- ключ шардирования: `age`;
- стратегия: `{ age: "hashed" }`;
- тестовых документов: 1000;
- MongoDB URI: `mongodb://mongos:27017`;
- Redis URI: `redis://redis:6379`;
- TTL кеша: 60 секунд.

## Структура каталога

```text
sharding-repl-cache/
├── api_app/
│   ├── Dockerfile
│   ├── app.py
│   └── requirements.txt
├── scripts/
│   └── mongo-init.sh
├── compose.yaml
└── README.md
```

- `compose.yaml` описывает десять контейнеров и их связи;
- `scripts/mongo-init.sh` разворачивает, инициализирует и проверяет стенд;
- `api_app/` содержит FastAPI-приложение.

## Требования

- Docker с поддержкой Docker Compose;
- Bash;
- `curl`;
- минимум 2 CPU и 4 ГБ оперативной памяти;
- свободный порт `8080`;
- доступ к registry с используемыми Docker-образами.

## Запуск

Из корня репозитория выполните:

```bash
cd sharding-repl-cache
chmod +x ./scripts/mongo-init.sh
./scripts/mongo-init.sh
```

Скрипт автоматически:

1. запускает config server и шесть узлов шардов;
2. инициализирует три replica set;
3. ожидает появления `PRIMARY` и `SECONDARY`;
4. запускает `mongos` и регистрирует оба шарда;
5. включает шардирование `somedb.helloDoc`;
6. добавляет 1000 тестовых документов;
7. запускает и очищает Redis;
8. запускает FastAPI-приложение;
9. проверяет MongoDB, репликацию и Redis;
10. сравнивает время первого и повторного запросов.

## Проверка контейнеров

```bash
docker compose ps
```

Должны быть запущены десять контейнеров. Redis должен иметь состояние `healthy`.

## Проверка API

Общая информация:

```bash
curl -s http://localhost:8080 | python3 -m json.tool
```

Ожидаемые признаки:

- `mongo_topology_type` — `Sharded`;
- `mongo_is_mongos` — `true`;
- `cache_enabled` — `true`;
- `status` — `OK`;
- коллекция `helloDoc` содержит 1000 документов;
- присутствуют `shard1ReplSet` и `shard2ReplSet`;
- у каждого шарда перечислены три узла.

Количество документов:

```bash
curl -s http://localhost:8080/helloDoc/count | python3 -m json.tool
```

Ожидаемый ответ:

```json
{
    "status": "OK",
    "mongo_db": "somedb",
    "items_count": 1000
}
```

Swagger UI доступен по адресу <http://localhost:8080/docs>.

## Проверка Redis и кеширования

Проверка доступности Redis:

```bash
docker compose exec -T redis redis-cli ping
```

Ожидаемый ответ — `PONG`.

Очистите кеш перед измерением:

```bash
docker compose exec -T redis redis-cli FLUSHDB
```

Первый запрос без готового кеша:

```bash
curl -s -o /dev/null -w "Первый запрос: %{time_total} сек.\n" \
  http://localhost:8080/helloDoc/users
```

Повторный запрос:

```bash
curl -s -o /dev/null -w "Повторный запрос: %{time_total} сек.\n" \
  http://localhost:8080/helloDoc/users
```

В контрольном запуске получены результаты:

```text
Первый запрос: 1.041297 сек.
Повторный запрос: 0.008073 сек.
```

Повторный запрос выполняется менее чем за 100 мс благодаря чтению ответа из Redis.

Проверка количества ключей:

```bash
docker compose exec -T redis redis-cli DBSIZE
```

После запроса Redis должен содержать не менее одного ключа.

## Проверка репликации

Первый шард:

```bash
docker compose exec -T shard1-1 \
  mongosh --port 27018 --quiet \
  --eval 'rs.status().members.forEach(m => print(m.name + " | " + m.stateStr + " | health=" + m.health))'
```

Второй шард:

```bash
docker compose exec -T shard2-1 \
  mongosh --port 27018 --quiet \
  --eval 'rs.status().members.forEach(m => print(m.name + " | " + m.stateStr + " | health=" + m.health))'
```

В каждом replica set должны отображаться один `PRIMARY`, два `SECONDARY` и `health=1`.

## Проверка распределения данных

```bash
docker compose exec -T mongos \
  mongosh --port 27017 --quiet \
  --eval 'db.getSiblingDB("somedb").helloDoc.getShardDistribution()'
```

В выводе должны присутствовать `shard1ReplSet` и `shard2ReplSet`, а суммарное количество документов должно быть равно 1000.

## Остановка и полный сброс

Остановить стенд без удаления данных:

```bash
docker compose down
```

Удалить контейнеры, сеть и тома:

```bash
docker compose down -v --remove-orphans
```

Повторное создание после полного сброса:

```bash
./scripts/mongo-init.sh
```

## Apple Silicon

Образ `kazhem/pymongo_api:1.0.0` может запускаться на Apple Silicon через эмуляцию `amd64`. Предупреждение о несовпадении `linux/amd64` и `linux/arm64/v8` допустимо, если API находится в состоянии `Up` и отвечает на порте `8080`.

При необходимости:

```bash
export DOCKER_DEFAULT_PLATFORM=linux/amd64
./scripts/mongo-init.sh
```

## Ограничения учебного стенда

- config server и Redis представлены одним узлом;
- не настроены аутентификация и TLS;
- не настроено резервное копирование;
- все контейнеры работают на одном Docker-хосте;
- изменение данных не очищает кеш немедленно;
- ответ может оставаться устаревшим до истечения TTL.

В промышленной системе следует использовать отказоустойчивые config server и Redis, распределять реплики между зонами доступности и настроить безопасность, мониторинг и инвалидацию кеша.

## Признаки успешного запуска

- запущены все десять контейнеров;
- Redis отвечает `PONG` и имеет состояние `healthy`;
- зарегистрированы два шарда;
- каждый шард состоит из трёх узлов;
- в каждом replica set есть один `PRIMARY` и два `SECONDARY`;
- коллекция содержит 1000 документов;
- документы распределены между обоими шардами;
- API показывает топологию `Sharded` и `cache_enabled: true`;
- после первого запроса в Redis появляется ключ;
- повторный запрос выполняется менее чем за 100 мс.
