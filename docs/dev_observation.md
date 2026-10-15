# Observation からのサービス間呼び出しの確認

`compose.obs.yml` は、`compose.yml`・`compose.tm.yml`・`compose.ga.yml` の上に [tolo-observation](https://github.com/pj-hoakari/tolo-observation) を加えるオーバーライドになる  
Observation は `ReportMeasurements` を受けると、受け取った内部 JWT を `Authorization` に載せたまま、Gateway の内部用 listener（`http://server:8090`）を通して Graph Authoring の `GetCurrentRevision`・`GetObservationPointMappings`・`GetQrLocations` を呼ぶ  
これを重ねると、公開用 listener で受けた外部トークンが Observation 宛ての `event_access` 内部 JWT になり、Observation がそれを提示し、Gateway が Graph Authoring 宛てに再発行する流れを実機で確かめられる

## 構成

```bash
docker compose -p toloobscheck -f compose.yml -f compose.tm.yml -f compose.ga.yml -f compose.obs.yml up -d
task fakeidp:up
```

追加されるサービスは `observation`・`observation-db`（PostgreSQL 18）・`observation-migrate`（マイグレーションの init サービス）になる  
`observation` と `observation-migrate` は、tolo-observation の main の固定コミットからビルドする。手元でビルドしたイメージは `TOLO_OBS_IMAGE` と `TOLO_OBS_MIGRATE_IMAGE` で差し替える  
`config/destinations.json` が `tolo-observation` を `http://observation:8080` へ向けているため、サービス名は `observation` で固定になる

| サービス | ホスト | コンテナ内 |
| --- | --- | --- |
| `server`（公開用） | `http://localhost:8080` | `http://server:8080` |
| `server`（内部用） | （公開しない） | `http://server:8090` |
| `observation` | （公開しない） | `http://observation:8080` |
| `observation-db` | （公開しない） | `observation-db:5432` |

`observation` は JWKS を公開用の `http://server:8080/.well-known/jwks.json` から取り、`GRAPH_AUTHORING_URL` には内部用の `http://server:8090` を使う  
Flow Control は Gateway を通らず（ADR-0048）、この構成にも含めない。`FLOW_CONTROL_URL` の宛先は存在しないため、Observation の観測サイクルは GraphSupply の 2 本を呼んだあと `Optimize` で失敗し、警告のログを出す。`ReportMeasurements` の応答はこの失敗の影響を受けない  
PostgreSQL のパスワードは `TOLO_OBS_DB_PASSWORD` で変えられる（既定 `observation`）

片付けは `task fakeidp:down` の後に `docker compose -p toloobscheck -f compose.yml -f compose.tm.yml -f compose.ga.yml -f compose.obs.yml down -v` を実行する

## 確認の流れ

`scripts/observation-measurement-check.sh` は、テナントの作成・所有権の取得・イベント作成・グラフの保存と公開を公開用 listener 越しに行う  
続けて端末を登録し、その端末として `Heartbeat` と `ReportMeasurements` を呼ぶ  
Gateway の監査ログを `docker compose logs` で読み、Observation からの GraphSupply 呼び出しが成功したことを確かめる  
最後に `event_access` トークン（scope `events.read events.manage`）で `UpdateObservationSettings` と `GetObservationSettings` を公開用 listener 越しに呼び、保存した設定値が返ることを確かめる  
想定と違うステータスが返った段階で失敗する

監査ログを読むため、compose の指定は環境変数で渡す

```bash
COMPOSE_PROJECT_NAME=toloobscheck COMPOSE_FILE=compose.yml:compose.tm.yml:compose.ga.yml:compose.obs.yml \
    ./scripts/observation-measurement-check.sh
```

| 段階 | 結果 |
| --- | --- |
| `RegisterEdgeDevice` | `200`。`edgeDeviceId` と観測点の `observationPointId` |
| `Heartbeat` | `200` |
| `ReportMeasurements` | `200`。`acceptedCount` が `1` |
| 監査ログの `GetCurrentRevision`・`GetObservationPointMappings`・`GetQrLocations` | `caller_service=tolo-observation` の記録が `http_status=200` |
| `UpdateObservationSettings` | `200` |
| `GetObservationSettings` | `200`。`historyWindowDays` が `14`、`eventType` が `EVENT_TYPE_LONG_TERM` |

この確認は GitHub Actions の `E2E` でも、Graph Authoring の確認の後に走る
