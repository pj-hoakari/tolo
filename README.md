# TOLO
Traffic Observation & Live Operations

このリポジトリは、TOLO の全サービスを実物の RPC でつないで確かめる結合環境になる  
各サービスの実装リポジトリにある compose は、そのサービス単体を RPC のモックで確かめるためのものになる  
サービス同士が実際に噛み合うかは、このリポジトリの compose で確かめる  
どの compose も開発と検証のためのもので、本番では使わない

## 前提

- Docker（Compose v2）
- [Task](https://taskfile.dev)
- `curl`・`jq`（トークンの発行と `task e2e` で使う）
- `NPM_TOKEN`（tolo-web のビルドで使う。作り方は [docs/setup-for-npm-package.md](docs/setup-for-npm-package.md)。`gh auth token` の値も使える）

## 起動

```bash
cp .env.example .env    # NPM_TOKEN を書く
task up
task fakeidp:up
task tokens
```

`task tokens` は `TENANT_ACCESS_TOKEN`・`GRAPH_ACCESS_TOKEN`・`OBSERVATION_ACCESS_TOKEN` の 3 行を出力する  
この 3 行を `.env` に書き、もう一度 `task up` を実行すると、トークンを読み込んだ `web` が作り直される

| 画面 | URL |
| --- | --- |
| テナントの管理 | `http://0123456789abcdef.localhost:3000/management` |
| イベントの管理 | `http://0123456789abcdef.localhost:3000/event/fedcba9876543210/management` |

止めるときは、先に `task fakeidp:down` で fake IdP を止めてから `task down` を実行する  
fake IdP がネットワーク `tolo-idp` につながったままだと、そのネットワークを削除できない  
ボリュームも消すときは `task down -- -v` を実行する

## compose ファイル

構成は `compose.yml` に、サービスごとのオーバーライドを重ねる形になる  
`Taskfile.yml` は、`COMPOSE_FILE` が未設定なら `compose.yml`・`compose.tm.yml`・`compose.ga.yml`・`compose.obs.yml`・`compose.flow.yml`・`compose.edge.yml`・`compose.web.yml` を重ねる  
プロジェクト名は `tolo` になる

| ファイル | 加えるもの |
| --- | --- |
| `compose.yml` | `keygen` と Service Gateway（`server`、ホストの 8080） |
| `compose.tm.yml` | Tenant Management とその DB・マイグレーション・固定テナントの seed |
| `compose.ga.yml` | Graph Authoring とその DB・マイグレーション |
| `compose.obs.yml` | Observation とその DB・マイグレーション |
| `compose.flow.yml` | Flow Control と、profile `runn` の `runn` |
| `compose.edge.yml` | Firebase Emulator（ホストの 8081・9099・4000）と edge-bridge（ホストの 8787） |
| `compose.web.yml` | tolo-web の `dev` ターゲット（ホストの 3000）。`compose.edge.yml` と `NPM_TOKEN` が要る |
| `compose.idp.yml` | 実物の IdP（tolo-idp）。`server` はホストの 18090 に移る |
| `compose.o11y.yml` | Jaeger |

`web` には `GATEWAY_URL=http://server:8080` と `SIGNALING_URL=http://edge-bridge:8787` を渡し、モックを無効にしてある

## イメージの差し替え

各サービスのイメージは環境変数で差し替えられる  
別のリポジトリで手元にビルドしたイメージを、この環境で試すときに使う

| 環境変数 | サービス | 既定 |
| --- | --- | --- |
| `TOLO_GATEWAY_IMAGE` | `server` | tolo-service-gateway の固定コミットからビルド |
| `TOLO_TM_IMAGE` | `tenant-management` | ghcr の固定した版 |
| `TOLO_TM_MIGRATE_IMAGE` | `tenant-management-migrate` | ghcr の固定した版 |
| `TOLO_GA_IMAGE` | `graph-authoring` | ghcr の固定した版 |
| `TOLO_GA_MIGRATE_IMAGE` | `graph-authoring-migrate` | ghcr の固定した版 |
| `TOLO_OBS_IMAGE` | `observation` | ghcr の固定した版 |
| `TOLO_OBS_MIGRATE_IMAGE` | `observation-migrate` | ghcr の固定した版 |
| `TOLO_FLOW_IMAGE` | `flow-control` | ghcr の固定した版 |
| `TOLO_EDGE_BRIDGE_IMAGE` | `edge-bridge` | ghcr の固定した版 |
| `TOLO_FIREBASE_EMULATOR_IMAGE` | `firebase-emulator` | tolo-edge-bridge の固定コミットからビルド |
| `TOLO_WEB_IMAGE` | `web` | tolo-web の固定コミットからビルド |
| `TOLO_IDP_IMAGE` | `idp`（`compose.idp.yml`） | ghcr の固定した版 |

`server`・`firebase-emulator`・`web` は公開イメージが無いため、固定したコミットの git URL をビルドコンテキストにしている  
この 3 つは、既定のタグのイメージが手元にあるとき、または `TOLO_*_IMAGE` が手元のイメージを指すとき、そのイメージをそのまま使う  
`docker compose up --build`（`task up -- --build`）を実行すると git からビルドし直し、そのタグを上書きする  
手元でビルドしたイメージを使うときは `--build` を付けない

## 固定のテナントとイベント

Web から使うテナントとイベントは固定してある

| 環境変数 | 既定 | 内容 |
| --- | --- | --- |
| `TOLO_TENANT_ID` | `0123456789abcdef` | テナントの ID |
| `TOLO_EVENT_ID` | `fedcba9876543210` | イベントの ID |
| `TOLO_OWNER_SUB` | `user-owner` | 所有者の `sub` |

`tenant-management-seed` が `config/seed/tenant-management.sql` でこれらを Tenant Management の DB に入れ、`tenant-management` は seed の後に起動する  
seed は何度実行しても同じ結果になる  
SQL は固定した tenant-management 0.1.0 のスキーマに合わせて書いてあるので、そのイメージを変えるときは SQL も直す

## fake IdP

tolo-idp が追いつくまでは、開発用の fake IdP でトークンを発行する  
fake IdP は暫定なので、Docker Compose には含めず `task fakeidp:up` で手動で起動する  
`task fakeidp:up` は tolo-service-gateway の固定コミット（`2f92e01`）の `fakeidp` ターゲットをビルドし、`docker run` でネットワーク `tolo-idp` に別名 `fakeidp` で参加させる  
ホストからは `http://localhost:8082` で届く  
失効照会の secret は、`keygen` が書いた名前付きボリューム `tolo-idp-introspection` から読む

ネットワーク `tolo-idp` とボリューム `tolo-idp-introspection` の名前はプロジェクト名によらず固定なので、fake IdP を使えるのは一度に 1 つのプロジェクトだけになる

トークンは `task tokens` で手動で発行する  
固定のテナントとイベントに対して、決まった claim と 24 時間の有効期限で発行する

fake IdP は起動のたびに署名鍵を作り直す  
fake IdP を起動し直したら、`task tokens` でトークンを発行し直し、`.env` を書き換えて `task up` を実行する  
Gateway と edge-bridge は JWKS を最大 5 分キャッシュするため、新しいトークンが通るまで最大 5 分かかることがある

## タスク

| タスク | 内容 |
| --- | --- |
| `task up` | `COMPOSE_FILE` のサービスを `docker compose up -d --wait` で起動する |
| `task down` | サービスを止める。`task down -- -v` でボリュームも消す |
| `task fakeidp:up` | fake IdP を起動する。`task up` の後に実行する |
| `task fakeidp:down` | fake IdP を止める。発行したトークンは使えなくなる |
| `task tokens` | Web 用のトークンを `.env` の行の形で出力する |
| `task e2e` | オンボーディング・Graph Authoring・Observation の確認、到達性の確認、Gateway のログにトークンが出ていないかの確認を実行する |
| `task proposal` | runn の `integration-proposal.yml` で、Flow Control が迂回の提案を保存するまで計測値を送る |

GitHub Actions の `E2E`（`.github/workflows/e2e.yml`）は、PR と `develop` への push のたびに、`compose.edge.yml` と `compose.web.yml` を除いた構成で `task up`・`task fakeidp:up` を実行し、Gateway の `/readyz` を待ってから `task e2e` を実行する

## ドキュメント

- [実在の Tenant Management での開発](docs/dev_tenant_management.md)
- [Graph Authoring からのサービス間呼び出しの確認](docs/dev_graph_authoring.md)
- [Observation からのサービス間呼び出しの確認](docs/dev_observation.md)
- [提案機構の結合環境](docs/dev_integration.md)
- [実物の IdP での開発](docs/dev_real_idp.md)
- [NPM パッケージ用の開発環境セットアップ](docs/setup-for-npm-package.md)
