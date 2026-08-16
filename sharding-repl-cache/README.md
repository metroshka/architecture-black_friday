# Шардирование и репликация MongoDB

## Цель этапа

Развернуть локальный шардированный кластер MongoDB с репликацией данных и проверить автоматическое переключение на новую PRIMARY-реплику при отказе основного узла.

Решение объединяет два механизма:

- шардирование распределяет документы между двумя шардами;
- репликация создаёт три копии данных внутри каждого шарда.

Шардирование повышает пропускную способность и позволяет горизонтально масштабировать объём данных. Репликация повышает отказоустойчивость и доступность каждого шарда.

## Архитектура

В состав решения входят девять контейнеров:

- `config-srv` — хранит метаданные шардированного кластера;
- `mongos` — маршрутизирует запросы к нужному шарду;
- `shard1-1`, `shard1-2`, `shard1-3` — участники `shard1ReplSet`;
- `shard2-1`, `shard2-2`, `shard2-3` — участники `shard2ReplSet`;
- `pymongo-api` — FastAPI-приложение, подключённое к `mongos`.

```text
                              ┌─ shard1ReplSet
                              │  ├─ shard1-1
                              │  ├─ shard1-2
                              │  └─ shard1-3
pymongo-api → mongos ─────────┤
                              │
                              └─ shard2ReplSet
                                 ├─ shard2-1
                                 ├─ shard2-2
                                 └─ shard2-3

                   mongos ↔ config-srv
```

Приложение не подключается к узлам шардов напрямую. Все запросы проходят через `mongos`.

## Шардирование и репликация

Данные коллекции разделяются между двумя шардами:

```text
somedb.helloDoc
├── часть документов → shard1ReplSet
└── часть документов → shard2ReplSet
```

Внутри каждого шарда данные копируются на три узла:

```text
shard1ReplSet
├── PRIMARY
├── SECONDARY
└── SECONDARY
```

Операции записи принимает `PRIMARY`. Узлы `SECONDARY` получают и применяют изменения из журнала операций `oplog`.

При отказе `PRIMARY` два оставшихся участника сохраняют большинство голосов и могут автоматически выбрать новый основной узел.

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

Роли внутри replica set могут изменяться в результате автоматических выборов.

Узлы `shard1-1` и `shard2-1` имеют повышенный приоритет и при нормальной работе предпочтительно выбираются как `PRIMARY`.

## Сетевые порты

| Компонент | Порт внутри Docker-сети | Порт на хосте |
|---|---:|---:|
| `config-srv` | `27019` | не опубликован |
| узлы `shard1ReplSet` | `27018` | не опубликован |
| узлы `shard2ReplSet` | `27018` | не опубликован |
| `mongos` | `27017` | не опубликован |
| `pymongo-api` | `8080` | `8080` |

Одинаковый порт `27018` может использоваться всеми узлами шардов, потому что каждый контейнер имеет собственное сетевое пространство.

## Параметры данных

- база данных: `somedb`;
- коллекция: `helloDoc`;
- namespace: `somedb.helloDoc`;
- ключ шардирования: `age`;
- стратегия: `{ age: "hashed" }`;
- количество тестовых документов: 1000.

Hashed-ключ равномерно распределяет документы между двумя шардами.

## Структура каталога

```text
mongo-sharding-repl/
├── api_app/
│   ├── Dockerfile
│   ├── app.py
│   └── requirements.txt
├── scripts/
│   └── mongo-init.sh
├── compose.yaml
└── README.md
```

- `compose.yaml` описывает инфраструктуру кластера;
- `scripts/mongo-init.sh` автоматически настраивает replica set и шардирование;
- `api_app/` содержит исходный код FastAPI-приложения.

## Требования

Для запуска нужны:

- Docker с поддержкой Docker Compose;
- Bash;
- `curl`;
- минимум 2 CPU и 4 ГБ оперативной памяти;
- свободный порт `8080`;
- доступ к registry с используемыми Docker-образами.

## Запуск

Перейдите в каталог проекта:

```bash
cd mongo-sharding-repl
```

При необходимости добавьте скрипту право на выполнение:

```bash
chmod +x ./scripts/mongo-init.sh
```

Запустите автоматическую инициализацию:

```bash
./scripts/mongo-init.sh
```

Скрипт:

1. запускает config server и шесть узлов шардов;
2. ожидает готовности всех процессов MongoDB;
3. инициализирует `configReplSet`;
4. создаёт трёхузловой `shard1ReplSet`;
5. создаёт трёхузловой `shard2ReplSet`;
6. ожидает выбора PRIMARY и перехода остальных узлов в SECONDARY;
7. запускает `mongos`;
8. регистрирует оба replica set как шарды;
9. включает шардирование `somedb.helloDoc`;
10. добавляет 1000 документов;
11. запускает API;
12. выводит распределение данных и состояние реплик.

## Проверка контейнеров

```bash
docker compose ps
```

Все девять контейнеров должны находиться в состоянии `Up`.

## Проверка API

Основная информация о MongoDB:

```bash
curl http://localhost:8080
```

Ожидаемые признаки успешного ответа:

- `mongo_topology_type` имеет значение `Sharded`;
- `mongo_is_mongos` имеет значение `true`;
- `status` имеет значение `OK`;
- коллекция `helloDoc` содержит 1000 документов;
- в `shards` присутствуют `shard1ReplSet` и `shard2ReplSet`;
- для каждого шарда перечислены три узла.

Проверка количества документов:

```bash
curl http://localhost:8080/helloDoc/count
```

Ожидаемый результат:

```json
{
  "status": "OK",
  "mongo_db": "somedb",
  "items_count": 1000
}
```

Swagger UI:

<http://localhost:8080/docs>

## Проверка первого replica set

```bash
docker compose exec -T shard1-1 \
  mongosh --port 27018 --quiet \
  --eval '
    rs.status().members.forEach(
      member => print(
        member.name +
        " | " +
        member.stateStr +
        " | health=" +
        member.health
      )
    )
  '
```

Должны отображаться один `PRIMARY`, два `SECONDARY` и `health=1`.

## Проверка второго replica set

```bash
docker compose exec -T shard2-1 \
  mongosh --port 27018 --quiet \
  --eval '
    rs.status().members.forEach(
      member => print(
        member.name +
        " | " +
        member.stateStr +
        " | health=" +
        member.health
      )
    )
  '
```

Должны отображаться один `PRIMARY`, два `SECONDARY` и `health=1`.

## Проверка распределения данных

```bash
docker compose exec -T mongos \
  mongosh --port 27017 --quiet \
  --eval '
    db.getSiblingDB("somedb")
      .helloDoc
      .getShardDistribution()
  '
```

В выводе должны присутствовать `shard1ReplSet` и `shard2ReplSet`. Суммарное количество документов должно быть равно 1000.

## Проверка автоматического переключения

Сначала проверьте текущие роли участников `shard1ReplSet`.

Если `shard1-1` является `PRIMARY`, остановите его:

```bash
docker compose stop shard1-1
```

Подождите завершения выборов:

```bash
sleep 15
```

Проверьте новые роли через доступный узел:

```bash
docker compose exec -T shard1-2 \
  mongosh --port 27018 --quiet \
  --eval '
    rs.status().members.forEach(
      member => print(
        member.name +
        " | " +
        member.stateStr +
        " | health=" +
        member.health
      )
    )
  '
```

Один из оставшихся узлов должен получить роль `PRIMARY`.

Проверьте доступность приложения:

```bash
curl http://localhost:8080/helloDoc/count
```

API должен продолжить работу и вернуть 1000 документов.

Верните остановленный узел:

```bash
docker compose start shard1-1
sleep 20
```

После синхронизации в replica set снова должны быть один `PRIMARY`, два `SECONDARY` и три узла с `health=1`.

## Остановка и полный сброс

Остановить контейнеры без удаления данных:

```bash
docker compose down
```

Удалить контейнеры, сеть и все тома проекта:

```bash
docker compose down -v --remove-orphans
```

После полного сброса кластер можно создать заново:

```bash
./scripts/mongo-init.sh
```

## Apple Silicon

Образ `kazhem/pymongo_api:1.0.0` может запускаться на Apple Silicon через эмуляцию `amd64`.

Предупреждение о несовпадении `linux/amd64` и `linux/arm64/v8` допустимо, если контейнер API находится в состоянии `Up` и отвечает на `http://localhost:8080`.

При необходимости перед запуском можно задать платформу:

```bash
export DOCKER_DEFAULT_PLATFORM=linux/amd64
./scripts/mongo-init.sh
```

Эмуляция может увеличить время запуска приложения.

## Ограничения учебного стенда

- config server состоит из одного узла;
- не настроена аутентификация MongoDB;
- не используется TLS;
- не настроено резервное копирование;
- все контейнеры работают на одном Docker-хосте.

В промышленной системе config server также следует развернуть как replica set из трёх узлов, а реплики необходимо распределить между независимыми серверами или зонами доступности.

## Признаки успешного запуска

Этап выполнен успешно, если:

- запущены все девять контейнеров;
- зарегистрированы два шарда;
- каждый шард состоит из трёх узлов;
- в каждом replica set есть один PRIMARY и два SECONDARY;
- все реплики имеют `health=1`;
- коллекция содержит 1000 документов;
- документы распределены между обоими шардами;
- API показывает топологию `Sharded`;
- после отказа PRIMARY выбирается новый основной узел;
- API продолжает работать во время отказа;
- остановленный узел успешно возвращается в replica set.