# Проектная работа 4-го спринта: масштабирование MongoDB

Проект демонстрирует последовательное развитие инфраструктуры интернет-магазина для подготовки к высокой нагрузке:

1. шардирование MongoDB;
2. репликацию каждого шарда;
3. кеширование запросов с помощью Redis;
4. горизонтальное масштабирование приложения, Service Discovery и API Gateway;
5. доставку статического контента через CDN.

Финальный исполняемый стенд находится в каталоге [`sharding-repl-cache`](./sharding-repl-cache). Он объединяет шардирование, репликацию и кеширование. API Gateway, Consul и CDN представлены на архитектурных диаграммах согласно условиям заданий 5 и 6.

## Структура репозитория

```text
.
├── mongo-sharding/             # этап 1: два шарда MongoDB
├── mongo-sharding-repl/        # этап 2: по три реплики в каждом шарде
├── sharding-repl-cache/        # этап 3 и финальный исполняемый стенд с Redis
├── diagrams/
│   ├── 01-mongo-sharding.drawio
│   ├── 02-mongo-replication.drawio
│   ├── 03-mongo-cache.drawio
│   ├── 04-service-discovery-gateway.drawio
│   └── 05-final-cdn.drawio
├── api_app/                    # исходное приложение
├── compose.yaml                # исходный одноузловой стенд
└── README.md
```

Подробная документация финального стенда находится в [`sharding-repl-cache/README.md`](./sharding-repl-cache/README.md).

Итоговая архитектура представлена в [`diagrams/05-final-cdn.drawio`](./diagrams/05-final-cdn.drawio).

## Финальный исполняемый стенд

В состав финального Docker Compose-проекта входят десять сервисов:

- `config-srv` — config server MongoDB;
- `mongos` — маршрутизатор запросов;
- `shard1-1`, `shard1-2`, `shard1-3` — первый replica set;
- `shard2-1`, `shard2-2`, `shard2-3` — второй replica set;
- `redis` — кеш ответов API;
- `pymongo-api` — FastAPI-приложение.

Параметры данных:

- база данных — `somedb`;
- коллекция — `helloDoc`;
- ключ шардирования — `{ age: "hashed" }`;
- количество тестовых документов — 1000;
- срок жизни кеша — 60 секунд.

## Требования

- Docker с поддержкой Docker Compose;
- Bash;
- `curl`;
- минимум 2 CPU и 4 ГБ оперативной памяти;
- свободный порт `8080`;
- доступ к registry с используемыми Docker-образами.

## Запуск финального стенда

Из корня репозитория выполните:

```bash
cd sharding-repl-cache
chmod +x ./scripts/mongo-init.sh
./scripts/mongo-init.sh
```

Скрипт автоматически:

1. запускает config server и шесть узлов шардов;
2. инициализирует replica set;
3. запускает `mongos` и регистрирует два шарда;
4. включает шардирование `somedb.helloDoc`;
5. добавляет 1000 тестовых документов;
6. запускает и проверяет Redis;
7. запускает FastAPI-приложение;
8. проверяет репликацию и распределение данных;
9. сравнивает время запроса без кеша и из кеша;
10. выводит состояние контейнеров.

## Быстрая проверка

Проверить контейнеры:

```bash
docker compose ps
```

Все десять контейнеров должны находиться в состоянии `Up`, а Redis — в состоянии `healthy`.

Проверить общую информацию о MongoDB и кеше:

```bash
curl -s http://localhost:8080 | python3 -m json.tool
```

В ответе ожидаются:

- `mongo_topology_type: "Sharded"`;
- `cache_enabled: true`;
- `status: "OK"`;
- два зарегистрированных шарда;
- три узла в каждом шарде;
- 1000 документов в коллекции `helloDoc`.

Проверить количество документов:

```bash
curl -s http://localhost:8080/helloDoc/count | python3 -m json.tool
```

Проверить Redis:

```bash
docker compose exec -T redis redis-cli ping
```

Ожидаемый ответ:

```text
PONG
```

Swagger UI доступен по адресу <http://localhost:8080/docs>.

Дополнительные проверки replica set, распределения данных, отказоустойчивости и скорости кеша приведены в [`sharding-repl-cache/README.md`](./sharding-repl-cache/README.md).

## Остановка и полный сброс

Остановить контейнеры без удаления данных:

```bash
docker compose down
```

Удалить контейнеры, сеть и все тома финального стенда:

```bash
docker compose down -v --remove-orphans
```

После полного сброса стенд можно создать заново:

```bash
./scripts/mongo-init.sh
```

## Apple Silicon

Образ `kazhem/pymongo_api:1.0.0` может запускаться на Apple Silicon через эмуляцию `amd64`. Предупреждение о несовпадении платформ `linux/amd64` и `linux/arm64/v8` допустимо, если контейнер API работает и отвечает на порте `8080`.

## Признаки успешного запуска

- работают все десять контейнеров;
- Redis отвечает `PONG`;
- MongoDB имеет топологию `Sharded`;
- зарегистрированы два шарда;
- каждый шард состоит из трёх реплик;
- коллекция содержит 1000 документов;
- документы распределены между обоими шардами;
- API возвращает `cache_enabled: true`;
- повторный запрос к `/helloDoc/users` выполняется менее чем за 100 мс.
