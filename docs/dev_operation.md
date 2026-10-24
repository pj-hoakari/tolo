# Operation への提案の配信の確認

`compose.op.yml` は、`compose.yml`・`compose.tm.yml`・`compose.ga.yml`・`compose.obs.yml` の上に [tolo-operation](https://github.com/pj-hoakari/tolo-operation) を加えるオーバーライドになる  
Observation は Flow Control の `Optimize` の後に、Gateway の内部用 listener（`http://server:8090`）を通して Operation の `RecordFeedbackValues` を毎サイクル呼ぶ  
結果が `VERDICT_OPTIMIZED` で提案を含むときは、`RequestProposalDelivery` も呼ぶ  
Operation は、そのイベントで接続状態を登録したスタッフのうち、接続中のスタッフには Realtime へ、未接続のスタッフには Notification の `SendPush` で提案を届ける  
Realtime への配信は `realtime-delivery` へ、スタッフのメッセージのうち来場者向けのものは `guest-messages` へ、NATS JetStream を通して publish する

publish したメッセージは、中継の `push-relay` が Guest Service と Realtime の受け口へ届ける  
Notification はこの環境に含めていないので、`SendPush` は当面ログに出すだけのスケルトンになる

## 構成

```bash
export COMPOSE_FILE=compose.yml:compose.tm.yml:compose.ga.yml:compose.obs.yml:compose.op.yml:compose.flow.yml:compose.edge.yml:compose.guest.yml:compose.rt.yml
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
4. Operation のログで、`SendPush` のスケルトンの出力を確かめる
5. 中継が届けた内容を、受け取ったサービスの RPC で確かめる。Guest Service の `ListGuestMessages` と `GetCrowd` は匿名で、Realtime の `FetchDeliveries` は `staff-online` の `event_access` トークン（scope `events.read`）で呼ぶ
6. Realtime の `IssueFirestoreToken` で得たカスタムトークンで Auth エミュレータにサインインし、Firestore エミュレータの `deliveryNotifications` を読む。エミュレータには `firebase-emulator/firestore.rules`（本番相当のルール）が入っている

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
| ログの `notification SendPush (log-only skeleton)` | `recipient_user_ids` が `["staff-offline"]` |
| Guest Service の `ListGuestMessages`（固定のイベント） | 送ったメッセージを、送った本文で含む |
| Guest Service の `GetCrowd`（runn が作ったイベント） | `takenAt` が空でない。Observation が観測サイクルごとに publish した `guest-status` が届いている |
| Realtime の `FetchDeliveries`（runn が作ったイベント、`staff-online`） | `SendPush` と同じ `delivery_id` の配信を含む |
| Firestore の `deliveryNotifications/<runn が作ったイベント>` | `200`。`latestDeliveryId` が `SendPush` と同じ `delivery_id` |
| Firestore の `deliveryNotifications/<固定のイベント>` | `403`。トークンのイベントと違うので、ルールが読み取りを拒む |

届くまでの遅れを見込み、5 の確認は 1 秒おきに 20 回まで呼び直す  
Guest Service の復旧 pull は起動時と 10 分おきなので、確認の時間内に届いたものは push で届いたことになる

ログは、スクリプトの開始より後のものだけを読む  
この確認は GitHub Actions の `E2E` でも、Observation の確認の後に走る。提案を待つ分、`E2E` の時間は 6 分ほど延びる
