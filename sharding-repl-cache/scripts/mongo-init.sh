#!/usr/bin/env bash

set -Eeuo pipefail

wait_for_mongo() {
  local service="$1"
  local port="$2"

  echo "Ожидаем готовности ${service}:${port}..."

  until docker compose exec -T "${service}" \
    mongosh --port "${port}" --quiet \
    --eval 'db.adminCommand({ ping: 1 }).ok' 2>/dev/null |
    grep -q "1"; do
    sleep 2
  done
}

wait_for_replica_set() {
  local service="$1"
  local port="$2"
  local expected_members="$3"
  local expected_secondaries=$((expected_members - 1))

  echo "Ожидаем готовности replica set через ${service}:${port}..."

  until docker compose exec -T "${service}" \
    mongosh --port "${port}" --quiet \
    --eval "
      const status = rs.status();

      const primaryCount = status.members.filter(
        member => member.stateStr === 'PRIMARY'
      ).length;

      const secondaryCount = status.members.filter(
        member => member.stateStr === 'SECONDARY'
      ).length;

      print(
        status.members.length === ${expected_members} &&
        primaryCount === 1 &&
        secondaryCount === ${expected_secondaries}
      );
    " 2>/dev/null | grep -q "true"; do
    sleep 2
  done
}

wait_for_redis() {
  echo "Ожидаем готовности Redis..."

  until docker compose exec -T redis \
    redis-cli ping 2>/dev/null |
    grep -q "PONG"; do
    sleep 2
  done
}

wait_for_api() {
  echo "Ожидаем готовности API..."

  until curl --silent --fail \
    http://localhost:8080 >/dev/null; do
    sleep 2
  done
}

echo "=== 1. Запускаем Config Server и узлы шардов ==="

docker compose up -d \
  config-srv \
  shard1-1 \
  shard1-2 \
  shard1-3 \
  shard2-1 \
  shard2-2 \
  shard2-3

wait_for_mongo config-srv 27019

wait_for_mongo shard1-1 27018
wait_for_mongo shard1-2 27018
wait_for_mongo shard1-3 27018

wait_for_mongo shard2-1 27018
wait_for_mongo shard2-2 27018
wait_for_mongo shard2-3 27018

echo "=== 2. Инициализируем Config Server Replica Set ==="

docker compose exec -T config-srv \
  mongosh --port 27019 --quiet <<'MONGO'
try {
  rs.status();
  print("configReplSet уже инициализирован");
} catch (error) {
  printjson(
    rs.initiate({
      _id: "configReplSet",
      configsvr: true,
      members: [
        {
          _id: 0,
          host: "config-srv:27019"
        }
      ]
    })
  );
}
MONGO

wait_for_replica_set config-srv 27019 1

echo "=== 3. Инициализируем первый шард ==="

docker compose exec -T shard1-1 \
  mongosh --port 27018 --quiet <<'MONGO'
try {
  rs.status();
  print("shard1ReplSet уже инициализирован");
} catch (error) {
  printjson(
    rs.initiate({
      _id: "shard1ReplSet",
      members: [
        {
          _id: 0,
          host: "shard1-1:27018",
          priority: 2
        },
        {
          _id: 1,
          host: "shard1-2:27018",
          priority: 1
        },
        {
          _id: 2,
          host: "shard1-3:27018",
          priority: 1
        }
      ]
    })
  );
}
MONGO

wait_for_replica_set shard1-1 27018 3

echo "=== 4. Инициализируем второй шард ==="

docker compose exec -T shard2-1 \
  mongosh --port 27018 --quiet <<'MONGO'
try {
  rs.status();
  print("shard2ReplSet уже инициализирован");
} catch (error) {
  printjson(
    rs.initiate({
      _id: "shard2ReplSet",
      members: [
        {
          _id: 0,
          host: "shard2-1:27018",
          priority: 2
        },
        {
          _id: 1,
          host: "shard2-2:27018",
          priority: 1
        },
        {
          _id: 2,
          host: "shard2-3:27018",
          priority: 1
        }
      ]
    })
  );
}
MONGO

wait_for_replica_set shard2-1 27018 3

echo "=== 5. Запускаем маршрутизатор mongos ==="

docker compose up -d mongos

wait_for_mongo mongos 27017

echo "=== 6. Регистрируем шарды в кластере ==="

docker compose exec -T mongos \
  mongosh --port 27017 --quiet <<'MONGO'
const existingShards = new Set(
  db.adminCommand({ listShards: 1 }).shards.map(
    shard => shard._id
  )
);

if (!existingShards.has("shard1ReplSet")) {
  printjson(
    sh.addShard(
      "shard1ReplSet/" +
      "shard1-1:27018," +
      "shard1-2:27018," +
      "shard1-3:27018"
    )
  );
} else {
  print("shard1ReplSet уже добавлен");
}

if (!existingShards.has("shard2ReplSet")) {
  printjson(
    sh.addShard(
      "shard2ReplSet/" +
      "shard2-1:27018," +
      "shard2-2:27018," +
      "shard2-3:27018"
    )
  );
} else {
  print("shard2ReplSet уже добавлен");
}
MONGO

echo "=== 7. Включаем шардирование и загружаем данные ==="

docker compose exec -T mongos \
  mongosh --port 27017 --quiet <<'MONGO'
sh.enableSharding("somedb");

const configDatabase = db.getSiblingDB("config");
const collectionNamespace = "somedb.helloDoc";

if (
  !configDatabase.collections.findOne({
    _id: collectionNamespace
  })
) {
  printjson(
    sh.shardCollection(
      collectionNamespace,
      { age: "hashed" }
    )
  );
} else {
  print("Коллекция somedb.helloDoc уже шардирована");
}

const applicationDatabase = db.getSiblingDB("somedb");

applicationDatabase.helloDoc.deleteMany({});

const documents = [];

for (let index = 0; index < 1000; index++) {
  documents.push({
    age: index,
    name: "ly" + index
  });
}

const insertResult =
  applicationDatabase.helloDoc.insertMany(documents);

print(
  "Добавлено документов: " +
  Object.keys(insertResult.insertedIds).length
);

print(
  "Количество документов: " +
  applicationDatabase.helloDoc.countDocuments({})
);
MONGO

echo "=== 8. Запускаем Redis ==="

docker compose up -d redis

wait_for_redis

echo "Очищаем кеш перед проверкой..."

docker compose exec -T redis \
  redis-cli FLUSHDB

echo "=== 9. Запускаем приложение ==="

docker compose up -d pymongo-api

wait_for_api

echo "=== 10. Проверяем зарегистрированные шарды ==="

docker compose exec -T mongos \
  mongosh --port 27017 --quiet <<'MONGO'
print("Зарегистрированные шарды:");

printjson(
  db.adminCommand({ listShards: 1 })
);

const applicationDatabase = db.getSiblingDB("somedb");

print("\nКоличество документов:");

print(
  applicationDatabase.helloDoc.countDocuments({})
);

print("\nРаспределение документов:");

applicationDatabase.helloDoc.getShardDistribution();
MONGO

echo "=== 11. Проверяем реплики первого шарда ==="

docker compose exec -T shard1-1 \
  mongosh --port 27018 --quiet <<'MONGO'
printjson(
  rs.status().members.map(
    member => ({
      name: member.name,
      state: member.stateStr,
      health: member.health
    })
  )
);
MONGO

echo "=== 12. Проверяем реплики второго шарда ==="

docker compose exec -T shard2-1 \
  mongosh --port 27018 --quiet <<'MONGO'
printjson(
  rs.status().members.map(
    member => ({
      name: member.name,
      state: member.stateStr,
      health: member.health
    })
  )
);
MONGO

echo "=== 13. Проверяем Redis ==="

docker compose exec -T redis \
  redis-cli ping

echo "Количество ключей до запроса:"

docker compose exec -T redis \
  redis-cli DBSIZE

echo "=== 14. Проверяем скорость кеширования ==="

first_request_time=$(
  curl --silent \
    --output /dev/null \
    --write-out "%{time_total}" \
    http://localhost:8080/helloDoc/users
)

second_request_time=$(
  curl --silent \
    --output /dev/null \
    --write-out "%{time_total}" \
    http://localhost:8080/helloDoc/users
)

echo "Первый запрос, cache miss: ${first_request_time} сек."
echo "Второй запрос, cache hit:  ${second_request_time} сек."

echo "Количество ключей после запросов:"

docker compose exec -T redis \
  redis-cli DBSIZE

echo "=== Контейнеры проекта ==="

docker compose ps

echo
echo "Инициализация завершена."
echo "Приложение: http://localhost:8080"
echo "Swagger:     http://localhost:8080/docs"