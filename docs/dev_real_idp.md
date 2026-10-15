# 実物の IdP での開発

`compose.idp.yml` は、開発用の fake IdP の代わりに実物の IdP（[tolo-idp](https://github.com/pj-hoakari/tolo-idp)）へ `server` を向けるオーバーライドになる  
tolo-idp 側には何も変更を加えず、`server` の `IDP_ISSUER` と relation のデータだけで噛み合わせている

## 構成

```bash
docker compose -p toloidpcheck -f compose.yml -f compose.idp.yml up -d
```

追加されるサービスは `idp`・`idp-db`（PostgreSQL 18）・`idp-redis`（Redis 8。IdP のレート制限に必須）・`idp-relation-stub`（所属の参照先）・`idp-seed-secret`（失効照会用の secret を書き出す init サービス）になる  
fake IdP は compose のサービスではないので、この構成では `task fakeidp:up` を実行しない。`server` の `depends_on` には `idp-seed-secret` と `idp` が加わる

公開ポートは base の `server`（8080）と fake IdP（8082）に重ならないようにずらしてある  
ただしネットワーク `tolo-idp` の名前はプロジェクト名によらず固定なので、base の構成と同時に動かすと、そのネットワークの `server` という名前が両方のプロジェクトの `server` に当たる

| サービス | ホスト | コンテナ内 |
| --- | --- | --- |
| `server`（公開用） | `http://localhost:18090` | `http://server:8080` |
| `server`（内部用） | （公開しない） | `http://server:8090` |
| `idp` | `http://localhost:18080` | `http://idp:8080` |
| `idp-relation-stub` | `http://localhost:18081` | `http://idp-relation-stub:8080` |

issuer はコンテナ内の名前 `http://idp:8080` で統一してある  
`server` の `IDP_ISSUER`、IdP の `TOLO_IDP_ISSUER`、発行されるトークンの `iss` がこの 1 つの文字列で一致し、Discovery の検証が通る  
IdP は Discovery 文書にも `iss` にも設定値をそのまま使い、リクエストの Host を見ないため、ホストから `http://localhost:18080` で叩いてもトークンは取得できる

片付けは `docker compose -p toloidpcheck -f compose.yml -f compose.idp.yml down -v` になる

### イメージ

ghcr に公開されている native ビルドのイメージ（`ghcr.io/pj-hoakari/tolo-idp` の `0.2.0`）を、digest まで固定して使う  
ほかのサービスと違い、git からはビルドしない  
`0.2.0` は linux/amd64 と linux/arm64 の両方が公開されていて、arm64 のマシン（Apple Silicon）でも起動する  
手元でビルドしたイメージは `TOLO_IDP_IMAGE` で差し替える  
`idp-relation-stub` は IdP が参照するスタブなので、公開イメージ（`ghcr.io/pj-hoakari/tolo-relation-stub`）のまま使う

### relation のデータ

IdP はログイン時に選んだ tenant の ID をそのまま `tenant_id` claim に載せる（IdP 側の形式は `^[A-Za-z0-9_-]{1,64}$`）  
Gateway は `tenant_id`・`event_id` が 16 桁の小文字 hex であることを要求するため、`config/idp/relation.json` では ID を hex にしてある

`config/idp/relation-nonhex.json` は形式が合わない場合を試すためのデータで、`TOLO_RELATION_DATA` で切り替える

```bash
TOLO_RELATION_DATA=/data/relation-nonhex.json docker compose -p toloidpcheck -f compose.yml -f compose.idp.yml up -d idp-relation-stub idp
```

relation-stub は 1 人のユーザーが所属できる tenant を 1 つに限るため、hex と非 hex を 1 つのファイルには入れられない  
IdP は所属を Redis と DB にキャッシュするので、データを差し替えたら `idp` も作り直す

### 失効照会の資格情報

失効照会の対象である管理系書き込みの RPC では、Gateway が IdP の `introspection_endpoint` へ `client_secret_basic` で照会する  
実物の IdP では seed の client（`client-123`）をそのまま照会用の client として使うため、`server` には `IDP_INTROSPECTION_CLIENT_ID: client-123` を渡す

Gateway は secret をファイルで受け取るので、init サービス `idp-seed-secret` が `${TOLO_IDP_SEED_CLIENT_SECRET:-secret}` の値を名前付きボリューム `idp-seed-introspection` へ書き出し、`server` が `/etc/tolo/idp-seed` に読み込み専用でマウントする  
同じ値を `idp` の `TOLO_IDP_SEED_CLIENT_SECRET` にも渡すので、IdP 側の seed secret と必ず一致する  
secret はボリュームの中だけに存在し、リポジトリにもイメージにも入らない

base の `keygen` が作る乱数 secret のボリューム `tolo-idp-introspection` は fake IdP 用で、こちらとは別になる（`server` には両方が別のパスでマウントされるが、実物の IdP を使うときに読むのは `/etc/tolo/idp-seed` の方だけになる）

既定の secret を変えるときは、`server` と `idp` の両方に同じ値が渡るよう `TOLO_IDP_SEED_CLIENT_SECRET` を1か所で指定する

```bash
TOLO_IDP_SEED_CLIENT_SECRET=... docker compose -p toloidpcheck -f compose.yml -f compose.idp.yml up -d
```

この場合は `scripts/idp-token.sh` と `scripts/idp-revoke.sh` にも `IDP_CLIENT_SECRET` で同じ値を渡す  
起動ログの `the IdP metadata is resolved` に `"introspection":true` が出ていれば有効になっている

## トークンの取得

`scripts/idp-token.sh` がログイン・authorize・token の 3 段階を curl で行い、アクセストークンだけを標準出力へ出す

```bash
TOKEN=$(./scripts/idp-token.sh -s "openid tenant.read events.read")
```

| 引数 | 環境変数 | 既定 |
| --- | --- | --- |
| `-u` | `IDP_BASE_URL` | `http://localhost:18080` |
| `-t` | `IDP_TENANT_ID` | `0123456789abcdef` |
| `-s` | `IDP_SCOPE` | `openid tenant.read events.read` |
| `-e` | `IDP_EVENT_ID` | （空。指定すると Token Exchange で `event_access` にする） |

PKCE の verifier と challenge はスクリプト内で `openssl` を使って生成する  
ユーザー・client・redirect_uri は tolo-idp の seed（`TOLO_IDP_SEED_ENABLED=true`）の値を既定にしていて、`IDP_USERNAME`・`IDP_PASSWORD`・`IDP_CLIENT_ID`・`IDP_CLIENT_SECRET`・`IDP_REDIRECT_URI` で変えられる

## トークンの失効

`scripts/idp-revoke.sh` が IdP の `POST /oauth2/revoke` を叩く

```bash
./scripts/idp-revoke.sh "$TOKEN"
```

IdP は本体を返さず `204` ではなく `200` と空の本文で応答する  
失効後に `POST /oauth2/introspect` を叩くと `{"active":false}` だけが返る

失効させたトークンでも、署名と期限が有効な間は**失効照会の対象でない RPC は通る**（`ListEvents` など）  
対象の RPC でだけ照会が走り、`unauthenticated`（監査 `failure_reason=token_revoked`）になる

照会の結果は jti 単位で 60 秒キャッシュされるので、**一度通った直後に失効させても最大 60 秒は通り続ける**  
失効をすぐ確かめたいときは、Gateway を 1 度も呼んでいない新しいトークンを失効させてから呼ぶ

## 通る RPC と通らない RPC

`tolo-tenant-management` のコンテナは compose に無いため、認証と認可を通った要求は `unavailable`（`upstream unavailable`）で終わる  
これが「実物のトークンが検証・認可・入口変換まで通った」ことの印になる

| RPC | 必要な scope | 結果 | 理由 |
| --- | --- | --- | --- |
| `TenantService/ListEvents` | `events.read` | `unavailable` | 宛先が居ないところまで到達する |
| `RelationAdminService/ListMemberships` | `tenant.read` | `unavailable` | 同上 |
| `TenantService/CreateEvent` | `events.manage` | `permission_denied`（`missing_scope`） | IdP は `events.manage` を発行できない |
| `TenantService/CreateEvent`（読み替えを有効にし、`events.write` のトークン） | `events.manage` | `unavailable` | `events.write` を新しい 3 つの scope として扱う（後述） |
| `TenantService/ArchiveTenant` | `tenant.write` | `unavailable` | 失効照会を通って宛先まで到達する |
| `TenantService/ArchiveTenant`（失効済み） | `tenant.write` | `unauthenticated`（`token_revoked`） | IdP が `active: false` を返す |
| `TenantService/GetEvent` | — | `permission_denied`（`internal_only`） | 内部オンリーの RPC |

失効照会の資格情報は `IDP_ISSUER` を設定したら必須で、揃っていなければ `server` は設定エラーで起動しない  
`IDP_INTROSPECTION=disabled` を明示すると資格情報なしで起動できるが、対象の 6 RPC は `unauthenticated`（`introspection_unavailable`）で拒否され続ける

IdP が発行できる scope は `openid`・`tenant.read`・`tenant.write`・`events.read`・`events.write` だけで、登録表が要求する `events.manage`・`tenant.claim`・`greeting.read` は出せない  
`tenant.claim`・`greeting.read` を必要とする RPC は実物の IdP では試せない

### `events.write` の読み替え

`events.manage` を要求する RPC は、移行用の読み替えを有効にすると `events.write` のトークンで通せる  
`IDP_LEGACY_EVENTS_WRITE_SCOPE=enabled` を与えて起動すると、Gateway は `events.write` を `events.manage`・`events.operate`・`events.report` として扱い、後段へ渡す内部 JWT の `scope` にも読み替え後の値を載せる  
既定は無効で、`compose.idp.yml` は環境変数をそのまま `server` へ渡す

```bash
IDP_LEGACY_EVENTS_WRITE_SCOPE=enabled docker compose -p toloidpcheck -f compose.yml -f compose.idp.yml up -d

TOKEN=$(IDP_SCOPE="openid tenant.read events.write" ./scripts/idp-token.sh)
curl -s -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -d '{}' http://localhost:18090/tolo.tenant.v1.TenantService/CreateEvent
```

無効のときは `permission_denied`、有効のときは宛先不達の `unavailable` を返し、起動ログに警告が 1 回出る  
この読み替えは仕様からの意図的な逸脱で、IdP が新しい scope を発行するようになったら削除する

`-e` で得た `event_access` トークンは形式としては Gateway の要求を満たすが、登録表に `external=event_access` の RPC が 1 つも無いため、どの RPC でも `token_use_mismatch` になる

## 既知の制約

Token Exchange には `openid` scope を渡せない（`invalid_scope` になる）ため、スクリプトは交換時に `openid` を落とす  
IdP が発行するトークンには Gateway の仕様に無い `resource` claim（`https://api.example.com/tenants/<tenant_id>` 形式）が入るが、Gateway は無視する  
JWT ヘッダに `typ` は入らず、`alg` は RS256、`kid` は IdP が起動ごとに作る ephemeral な鍵の UUID になる（`TOLO_IDP_JWK_ALLOW_EPHEMERAL=true`）  
アクセストークンの有効期限は 15 分（`event_access` は 10 分）で、`idp` を作り直すと署名鍵が変わるため古いトークンは使えなくなる
