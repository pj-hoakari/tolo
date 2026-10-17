# Operation への提案の配信の確認

`compose.op.yml` は、`compose.yml`・`compose.tm.yml`・`compose.ga.yml`・`compose.obs.yml` の上に [tolo-operation](https://github.com/pj-hoakari/tolo-operation) を加えるオーバーライドになる  
Observation は Flow Control の `Optimize` の後に、Gateway の内部用 listener（`http://server:8090`）を通して Operation の `RecordFeedbackValues` を毎サイクル呼ぶ  
結果が `VERDICT_OPTIMIZED` で提案を含むときは、`RequestProposalDelivery` も呼ぶ  
Operation は、そのイベントで接続状態を登録したスタッフのうち、接続中のスタッフには Realtime へ、未接続のスタッフには Notification の `SendPush` で提案を届ける  
スタッフのメッセージのうち来場者向けのものは、Pub/Sub の `guest-messages` へ publish する

Realtime・Notification・Guest Service はこの環境に含めていない  
そのため `guest-messages`・`realtime-delivery` への publish と `SendPush` は、当面ログに出すだけのスケルトンになる

## 構成

```bash
export COMPOSE_FILE=compose.yml:compose.tm.yml:compose.ga.yml:compose.obs.yml:compose.op.yml:compose.flow.yml
docker compose up -d
task fakeidp:up
```

追加されるサービスは `operation`・`operation-db`（PostgreSQL 18）・`operation-migrate`（マイグレーションの init サービス）になる  
`operation` と `operation-migrate` は、tolo-operation の固定コミットからビルドする。手元でビルドしたイメージは `TOLO_OP_IMAGE` と `TOLO_OP_MIGRATE_IMAGE` で差し替える  
`config/destinations.json` が `tolo-operation` を `http://operation:8080` へ向けているため、サービス名は `operation` で固定になる

| サービス | ホスト | コンテナ内 |
| --- | --- | --- |
| `server`（公開用） | `http://localhost:8080` | `http://server:8080` |
| `server`（内部用） | （公開しない） | `http://server:8090` |
| `operation` | （公開しない） | `http://operation:8080` |
| `operation-db` | （公開しない） | `operation-db:5432` |

`operation` は JWKS を公開用の `http://server:8080/.well-known/jwks.json` から取る  
`observation` の `OPERATION_URL` には内部用の `http://server:8090` を使う  
`RequestProposalDelivery` と `RecordFeedbackValues` は公開用 listener では受け付けないので、ホストからは呼べない  
PostgreSQL のパスワードは `TOLO_OP_DB_PASSWORD` で変えられる（既定 `operation`）

片付けは、`task fakeidp:down` の後に、同じ環境変数のまま `docker compose down -v` を実行する

## 確認の流れ

`scripts/operation-delivery-check.sh` は、次の順に確かめる

1. 固定のテナントとイベントの `event_access` トークン（scope `events.read events.operate`）で、来場者向けのメッセージを `SendStaffMessage` で送り、`ListStaffMessages` で読み返す
2. runn の `integration-proposal.yml` を `surgeStart` を `0` にして実行する。runbook は事前データを作った後、`staff-online`（接続中）と `staff-offline`（未接続）の接続状態を、それぞれの `sub` のトークンで `UpdateConnectionState` に登録する。続けて、迂回路の提案が保存されるまで計測値を送る
3. Gateway の監査ログで、`caller_service=tolo-observation` の `RequestProposalDelivery` と `RecordFeedbackValues` が `http_status=200` であることを確かめる
4. Operation のログで、スケルトンの出力を確かめる

`UpdateConnectionState` は、`userId` がトークンの `sub` と一致しないと拒否する。そのためスタッフごとにトークンを発行する  
提案はホストから直接は出せないので、Observation に実際の観測サイクルを回させて出す  
`surgeStart` を `0` にすると、最初のサイクルから流量が増え始める。手元では約 6 分で提案が出た（2026-10-17 時点）

```bash
./scripts/operation-delivery-check.sh
```

| 段階 | 結果 |
| --- | --- |
| `SendStaffMessage`（`AUDIENCE_GUEST`） | `200`。`messageId` |
| `ListStaffMessages`（`AUDIENCE_GUEST`） | `200`。送ったメッセージを含む |
| 監査ログの `RequestProposalDelivery`・`RecordFeedbackValues` | `caller_service=tolo-observation`・`token_use=service` の記録が `http_status=200` |
| ログの `pubsub publish (log-only skeleton)` | `topic=guest-messages` で、`payload.upserts` に送ったメッセージを含む |
| ログの `notification SendPush (log-only skeleton)` | `recipient_user_ids` が `["staff-offline"]` |
| ログの `pubsub publish (log-only skeleton)` | `topic=realtime-delivery` で、`SendPush` と同じ `delivery_id`、`recipient_user_ids` が `["staff-online"]` |

ログは、スクリプトの開始より後のものだけを読む  
この確認は GitHub Actions の `E2E` でも、Observation の確認の後に走る。提案を待つ分、`E2E` の時間は 6 分ほど延びる
