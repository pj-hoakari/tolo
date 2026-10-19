# 実在の Tenant Management での開発

`compose.tm.yml` は、base の compose に後段サービス [tolo-tenant-management](https://github.com/pj-hoakari/tolo-tenant-management) を加えるオーバーライドになる  
`config/destinations.json` が `tolo-tenant-management` を `http://tenant-management:8080` へ向けているため、サービス名は `tenant-management` で固定になる

これを重ねると、Gateway が発行した内部 JWT を後段が検証し、業務応答まで返るところまでを実機で確かめられる

## 構成

```bash
docker compose -p tolotmcheck -f compose.yml -f compose.tm.yml up -d
task fakeidp:up
```

トークンを発行する fake IdP は compose のサービスではないので、起動後に `task fakeidp:up` で起動する（README の「fake IdP」を参照）

追加されるサービスは `tenant-management`・`tenant-management-db`（PostgreSQL 18）・`tenant-management-migrate`（マイグレーションの init サービス）・`tenant-management-seed`（固定のテナントとイベントを入れる init サービス）になる  
`tenant-management` の `INTERNAL_JWKS_URL` は Gateway（`http://server:8080/.well-known/jwks.json`）を指し、`INTERNAL_JWT_ISSUER` と `INTERNAL_JWT_AUDIENCE` は base の `server` が発行する内部 JWT の `iss`・`aud` に合わせてある

ホストへ公開するポートは増やさない  
後段は Gateway 経由で呼ぶのが目的で、`tenant-management` 自体をホストから直接叩く必要が無いためになる（後述の制約も参照）

| サービス | ホスト | コンテナ内 |
| --- | --- | --- |
| `server`（公開用） | `http://localhost:8080` | `http://server:8080` |
| `server`（内部用） | （公開しない） | `http://server:8090` |
| fake IdP（`task fakeidp:up`） | `http://localhost:8082` | `http://fakeidp:8080` |
| `tenant-management` | （公開しない） | `http://tenant-management:8080` |
| `tenant-management-db` | （公開しない） | `tenant-management-db:5432` |

片付けは `task fakeidp:down` の後に `docker compose -p tolotmcheck -f compose.yml -f compose.tm.yml down -v` を実行する

### イメージ

tolo-tenant-management の develop の固定コミット（`a2ea479`）を git URL のビルドコンテキストにして、サーバーとマイグレーション用（`migrate` ターゲット）のイメージを作る  
`config/seed/tenant-management.sql` はこのコミットのスキーマに合わせて書いてあるので、コミットを上げるときは seed も直す

未公開の版で試すときは、tolo-tenant-management のリポジトリでイメージを作り、`TOLO_TM_IMAGE` と `TOLO_TM_MIGRATE_IMAGE` で差し替える

```bash
docker build -t tolo-tenant-management:dev ../tolo-tenant-management
docker build -t tolo-tenant-management-migrate:dev --target migrate ../tolo-tenant-management

TOLO_TM_IMAGE=tolo-tenant-management:dev TOLO_TM_MIGRATE_IMAGE=tolo-tenant-management-migrate:dev \
    docker compose -p tolotmcheck -f compose.yml -f compose.tm.yml up -d
```

PostgreSQL のパスワードは `TOLO_TM_DB_PASSWORD` で変えられる（既定 `tenant_management`）  
`tenant-management` と `tenant-management-migrate` の `DATABASE_URL` の両方に同じ値が入る

## トークンの取得

`scripts/fakeidp-token.sh` が fake IdP の `POST /token` を叩き、アクセストークンだけを標準出力へ出す

```bash
TOKEN=$(./scripts/fakeidp-token.sh -k tenant_access -b user-owner -t 0123456789abcdef -s "tenant.read events.read")
```

| 引数 | 環境変数 | 既定 |
| --- | --- | --- |
| `-u` | `FAKEIDP_BASE_URL` | `http://localhost:8082` |
| `-k` | `FAKEIDP_TOKEN_USE` | `tenant_access` |
| `-b` | `FAKEIDP_SUB` | `user-123` |
| `-s` | `FAKEIDP_SCOPE` | `tenant.read tenant.write events.read events.manage` |
| `-t` | `FAKEIDP_TENANT_ID` | （空。`registration` では指定しない） |
| `-e` | `FAKEIDP_EVENT_ID` | （空） |
| `-c` | `FAKEIDP_CLIENT_ID` | `client-123` |
| `-l` | `FAKEIDP_TTL_SECONDS` | `0`（fakeidp の既定 5 分のまま） |

`tenant_id`・`event_id` は Gateway が 16 桁の小文字 hex を要求する  
`tenant_id` は Tenant Management が `StartTenantRegistration` で採番した値をそのまま渡す

失効は fake IdP の `POST /revoke` になる

```bash
curl -sS -H 'Content-Type: application/json' -d "$(jq -nc --arg t "$TOKEN" '{token: $t}')" http://localhost:8082/revoke
```

## オンボーディングの流れ

`scripts/tenant-management-onboarding.sh` が、仮テナントの作成から所有権の取得とサブドメインの解決・イベント作成・メンバー追加・権限の境界・失効までを通しで実行し、各段階の HTTP ステータスと本文を出す  
想定と違うステータスが返った段階で失敗する

```bash
./scripts/tenant-management-onboarding.sh
```

この通しは GitHub Actions の `E2E`（`.github/workflows/e2e.yml`）でも走り、PR と `develop` への push のたびに、`compose.edge.yml` と `compose.web.yml` を除いた構成を起動して確かめる  
手元で失敗するときは CI でも失敗するため、直してから push する

手で追うときの最小の流れは次になる

```bash
TENANT=$(curl -sS -X POST -H 'Content-Type: application/json' -d '{"name":"acme","contractPlan":"standard"}' \
    http://localhost:8080/tolo.tenant.v1.TenantService/StartTenantRegistration)
TID=$(printf '%s' "$TENANT" | jq -r .tenant.tenantId)
CLAIM=$(printf '%s' "$TENANT" | jq -r .ownershipClaimToken)

REG=$(./scripts/fakeidp-token.sh -k registration -b user-owner -s "tenant.claim")
curl -sS -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $REG" \
    -d "{\"tenantId\":\"$TID\",\"ownershipClaimToken\":\"$CLAIM\",\"subdomain\":\"acme\"}" \
    http://localhost:8080/tolo.tenant.v1.TenantService/ClaimTenantOwnership

TOKEN=$(./scripts/fakeidp-token.sh -k tenant_access -b user-owner -t "$TID")
curl -sS -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
    -d "{\"tenantId\":\"$TID\",\"name\":\"spring-expo\"}" \
    http://localhost:8080/tolo.tenant.v1.TenantService/CreateEvent
```

Connect の JSON は lowerCamelCase になる（`tenantId`・`ownershipClaimToken`・`contractPlan` など）  
enum は `ROLE_STAFF` のような完全な名前の文字列で渡す  
`ClaimTenantOwnership` は `token_use=registration` を要求し、`registration` のトークンは `tenant_id` を持たない  
対象のテナントはリクエストの `tenantId` と一回限りの `ownershipClaimToken` で指定する  
`subdomain` は必須で、すでに使われているサブドメインを指定すると `already_exists`（HTTP 409）になる

## 通る RPC と通らない RPC

`user-owner` が所有者になったテナントの `tenant_access` トークン（scope `tenant.read tenant.write events.read events.manage`）で、業務応答まで到達する

| RPC | 必要な scope | 結果 |
| --- | --- | --- |
| `TenantService/StartTenantRegistration` | （匿名） | `200`。`tenantId` と `ownershipClaimToken` |
| `TenantService/ClaimTenantOwnership` | `tenant.claim`（`registration`） | `200`。`ownershipState` が `OWNED` になり、`subdomain` が入る |
| `TenantService/ResolveTenantSubdomain` | （匿名） | `200`。サブドメインに対応する `tenantId` |
| `TenantService/ChangeTenantContract` | `tenant.write` | `200` |
| `TenantService/CreateEvent` | `events.manage` | `200` |
| `TenantService/TransitionEventStatus` | `events.manage` | `200` |
| `TenantService/ListEvents` | `events.read` | `200` |
| `TenantService/ArchiveTenant` | `tenant.write` | `200` |
| `RelationAdminService/AddTenantMember` | `tenant.write` | `200` |
| `RelationAdminService/ChangeTenantRole` | `tenant.write` | `200` |
| `RelationAdminService/GrantEventRole` | `tenant.write` | `200` |
| `RelationAdminService/RevokeRole` | `tenant.write` | `200` |
| `RelationAdminService/ListMemberships` | `tenant.read` | `200` |
| `TenantService/GetEvent` | — | `403 permission_denied`（監査 `internal_only`） |

拒否の出どころは 2 つあり、監査ログの `failure_reason` で見分けられる

| 条件 | 応答 | 監査の `failure_reason` | 拒否したところ |
| --- | --- | --- | --- |
| scope 不足（`tenant.read` だけで `CreateEvent`） | `403 permission denied` | `missing_scope` | Gateway |
| 内部オンリーの RPC を外部トークンで | `403 permission denied` | `internal_only` | Gateway |
| 失効照会の対象 RPC を失効済みトークンで | `401 unauthenticated` | `token_revoked` | Gateway |
| テナントの非メンバーが `AddTenantMember` | `403 current permission denied` | `upstream_refused` | Tenant Management |
| トークンの `tenant_id` とリクエストの `tenantId` が違う | `403 tenant ID does not match context` | `upstream_refused` | Tenant Management |
| 存在しない `tenant_id` で `ListEvents` | `404 tenant not found` | `upstream_refused` | Tenant Management |
| archive 済みテナントへの書き込み | `400 tenant is archived` | `upstream_refused` | Tenant Management |

失効照会の対象は `ChangeTenantContract`・`ArchiveTenant` と `RelationAdminService` の書き込み 4 つになる  
対象でない RPC は、失効済みのトークンでも署名と期限が有効な間は通る（`ListEvents` など）  
照会の結果は jti 単位でキャッシュされるため、失効をすぐ確かめたいときは Gateway を 1 度も呼んでいない新しいトークンを失効させてから呼ぶ

後段が書き込みのたびに現在の権限を読み直すため、Gateway の認可（scope）を通っても、そのテナントのメンバーでなければ `permission_denied` で止まる  
読みの `ListMemberships` は現在の権限を読み直さず、トークンの `tenant_id` だけを根拠にテナント全体の所属一覧を返す

## trace の伝搬

Gateway の監査ログの `trace_id` は W3C trace context で後段まで伝わり、Tenant Management のログの `logging.googleapis.com/trace` と一致する

`compose.o11y.yml` を重ねると Gateway の span が Jaeger（`http://localhost:16686`）へ出る  
`compose.o11y.yml` は `server` にしか OTLP の宛先を渡さないため、後段の span まで Jaeger で見たいときは `tenant-management` にも `OTEL_EXPORTER_OTLP_ENDPOINT: http://jaeger:4318` を渡す  
そうすると 1 つの trace に Gateway の RPC span・Tenant Management の RPC span・その SQL span が並ぶ

Tenant Management は正常な要求を 1 行も記録しないため、ログで追えるのは内部 JWT を拒否したときの `internal JWT rejected` だけになる  
業務応答まで到達したことは、Gateway の監査の `result=ok` と Connect の応答本文で確かめる

## 既知の制約

Tenant Management は同じポート 8080 に、内部 JWT を要さない HTTP API `GET /tenants/{tenant_id}/users/{user_id}/memberships` も載せている  
compose ネットワークの中からは資格情報なしで所属一覧が取れるため、このポートはホストへ公開しない  
Gateway は登録表に無いパスを転送しないので、`http://localhost:8080` 越しには `404` になる

後段が内部 JWT を拒否すると、Gateway は `unauthenticated` を透過せず `500 internal`（監査 `failure_reason=upstream_rejected_internal_token`）を返す  
クライアントから見ると後段の設定ずれと自分のトークンの問題が区別できないため、原因は監査ログと `docker compose logs tenant-management` の `internal JWT rejected` で切り分ける

後段が返した業務上の拒否（`400`・`403`・`404`）は、監査では `failure_reason=upstream_refused` になる  
後段の障害（`upstream_error`・`upstream_internal`・`upstream_unreachable`）とは別の値なので、「宛先が断った」のか「宛先が壊れた」のかは `failure_reason` で区別できる

実物の IdP との組み合わせ（`-f compose.yml -f compose.idp.yml -f compose.tm.yml`）は構成としては成立し、サービス名もポートも衝突しない  
ただし IdP は所属を `idp-relation-stub` の静的なデータから引くため、Tenant Management が採番した `tenant_id` を持つトークンは発行できない（IdP と Tenant Management の所属参照 API が噛み合っていない既知の問題）  
実物の IdP は `tenant.claim` も発行できないため、所有権の取得も試せない  
この組み合わせで確かめられるのは構成が成立することまでで、業務フローは通らない
