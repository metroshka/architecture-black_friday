#!/usr/bin/env bash

set -Eeuo pipefail

wait_for_mongo() {
  local service="$1"
  local port="$2"

  echo "Ожидаем готовности ${service}:${port}..."

  until docker compose exec -T "${service}" \
    mongosh --port "${port}" --quiet \
    --eval 'db.adminCommand({ ping: 1 }).ok' 2>/dev/null | grep -q "1"; do
    sleep 2
  done
}

wait_for_primary() {
  local service="$1"
  local port="$2"

  echo "Ожидаем выбора PRIMARY для ${service}..."

  until docker compose exec -T "${service}" \
    mongosh --port "${port}" --quiet \
    --eval 'db.hello().isWritablePrimary' 2>/dev/null | grep -q "true"; do
    sleep 2
  done
}

echo "=== 1. Запускаем Config Server и узлы шардов ==="

docker compose up -d config-srv shard1 shard2

wait_for_mongo config-srv 27019
wait_for_mongo shard1 27018
wait_for_mongo shard2 27018

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

wait_for_primary config-srv 27019

echo "=== 3. Инициализируем первый шард ==="

docker compose exec -T shard1 \
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
          host: "shard1:27018"
        }
      ]
    })
  );
}
MONGO

wait_for_primary shard1 27018

echo "=== 4. Инициализируем второй шард ==="

docker compose exec -T shard2 \
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
          host: "shard2:27018"
        }
      ]
    })
  );
}
MONGO

wait_for_primary shard2 27018

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
    sh.addShard("shard1ReplSet/shard1:27018")
  );
} else {
  print("shard1ReplSet уже добавлен");
}

if (!existingShards.has("shard2ReplSet")) {
  printjson(
    sh.addShard("shard2ReplSet/shard2:27018")
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

echo "=== 8. Запускаем приложение ==="

docker compose up -d pymongo-api

echo "=== 9. Проверяем состояние кластера ==="

docker compose exec -T mongos \
  mongosh --port 27017 --quiet <<'MONGO'
print("\nЗарегистрированные шарды:");
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

echo "=== Контейнеры проекта ==="

docker compose ps

echo
echo "Инициализация завершена."
echo "Приложение: http://localhost:8080"
echo "Swagger:     http://localhost:8080/docs"
