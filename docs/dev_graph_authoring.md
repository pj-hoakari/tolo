# Graph Authoring からのサービス間呼び出しの確認

`compose.ga.yml` は、`compose.yml` と `compose.tm.yml` の上に [tolo-graph-authoring](https://github.com/pj-hoakari/tolo-graph-authoring) を加えるオーバーライドになる  
Graph Authoring は `SaveGraph` などの編集の前に、Gateway の内部用 listener（`http://server:8090`）を通して Tenant Management の `GetEvent` を呼び、イベントの存在を確かめる  
これを重ねると、公開用 listener で受けた外部トークンが Graph Authoring 宛ての `event_access` 内部 JWT になり、Graph Authoring がそれを文脈内部JWTとして提示し、Gateway が Tenant Management 宛ての `token_use=service` へ再発行する流れを実機で確かめられる

## 構成

```bash
docker compose -p tologacheck -f compose.yml -f compose.tm.yml -f compose.ga.yml up -d
task fakeidp:up
```

追加されるサービスは `graph-authoring`・`graph-authoring-db`（PostgreSQL 18）・`graph-authoring-migrate`（マイグレーションの init サービス）になる  
`graph-authoring` と `graph-authoring-migrate` は、tolo-graph-authoring の main の固定コミットからビルドする。手元でビルドしたイメージは `TOLO_GA_IMAGE` と `TOLO_GA_MIGRATE_IMAGE` で差し替える  
`config/destinations.json` が `tolo-graph-authoring` を `http://graph-authoring:8080` へ向けているため、サービス名は `graph-authoring` で固定になる

| サービス | ホスト | コンテナ内 |
| --- | --- | --- |
| `server`（公開用） | `http://localhost:8080` | `http://server:8080` |
| `server`（内部用） | （公開しない） | `http://server:8090` |
| `graph-authoring` | （公開しない） | `http://graph-authoring:8080` |
| `graph-authoring-db` | （公開しない） | `graph-authoring-db:5432` |

`graph-authoring` は JWKS を公開用の `http://server:8080/.well-known/jwks.json` から取り、`TENANT_MANAGEMENT_URL` には内部用の `http://server:8090` を使う  
PostgreSQL のパスワードは `TOLO_GA_DB_PASSWORD` で変えられる（既定 `graph_authoring`）

片付けは `task fakeidp:down` の後に `docker compose -p tologacheck -f compose.yml -f compose.tm.yml -f compose.ga.yml down -v` を実行する

## 確認の流れ

`scripts/graph-authoring-event-check.sh` が、テナントの作成・所有権の取得・イベント作成を公開用 listener 越しに行い、そのイベントの `event_access` トークンで `SaveGraph` を呼ぶ  
想定と違うステータスが返った段階で失敗する

```bash
./scripts/graph-authoring-event-check.sh
```

| 段階 | 結果 |
| --- | --- |
| Tenant Management に無いイベント ID で `SaveGraph` | `400 failed_precondition`（`event not found`） |
| 作成したイベントで `SaveGraph` | `200`。`eventId` と `draftRevisionId` |

前者は、Graph Authoring の `GetEvent` が内部用 listener を通って Tenant Management まで届き、`not_found` が返ったことを示す  
内部用 listener の監査ログには `caller_service=tolo-graph-authoring`・`origin=user`・`sub=tolo-graph-authoring`・`origin_sub`（外部トークンの `sub`）が入る

```bash
docker compose -p tologacheck -f compose.yml -f compose.tm.yml -f compose.ga.yml logs server | grep 'TenantService/GetEvent'
```

この確認は GitHub Actions の `E2E` でも、オンボーディングの通しの後に走る
