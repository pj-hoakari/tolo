# 実物の IdP での開発

`compose.idp.yml` は、開発用の fake IdP の代わりに実物の IdP（[tolo-idp](https://github.com/pj-hoakari/tolo-idp)）へ `server` を向けるオーバーライドになる  
IdP は所属を Tenant Management の所属参照 API から引くので、`compose.tm.yml` と一緒に使う

## 構成

```bash
docker compose -p toloidpcheck -f compose.yml -f compose.tm.yml -f compose.idp.yml up -d
```

追加されるサービスは `ingress`（Caddy。ホストの 80 番）・`idp`・`idp-db`（PostgreSQL 18）・`idp-redis`（Redis 8。IdP のレート制限に必須）・`idp-seed-secret`（失効照会用の secret を書き出す init サービス）になる  
fake IdP は compose のサービスではないので、この構成では `task fakeidp:up` を実行しない。`server` の `depends_on` には `idp-seed-secret` と `idp` が加わる

公開ポートは base の `server`（8080）と fake IdP（8082）に重ならないようにずらしてある  
ただしネットワーク `tolo-idp` の名前はプロジェクト名によらず固定なので、base の構成と同時に動かすと、そのネットワークの `server` という名前が両方のプロジェクトの `server` に当たる

| サービス | ホスト | コンテナ内 |
| --- | --- | --- |
| `server`（公開用） | `http://localhost:18090` | `http://server:8080` |
| `server`（内部用） | （公開しない） | `http://server:8090` |
| `ingress` | `http://auth.tolo.localhost`、`http://tolo.localhost`、`http://*.tolo.localhost` | `http://auth.tolo.localhost` |
| `idp` | （`ingress` 越し） | `http://idp:8080` |
| `tenant-management` | （公開しない） | `http://tenant-management:8080` |

### ingress と issuer

issuer は `http://auth.tolo.localhost` で、ブラウザ・ホストの curl・コンテナのどれからも同じ URL で IdP に届く  
本番で IdP を `auth.<ルートドメイン>` に置き、ingress の前で振り分ける形（ADR-0121）を、手元で同じように組んでいる

- ホストからは`*.localhost` の名前がループバックに解決され、ホストの 80 番の `ingress` に届く
- コンテナからはネットワーク `tolo-idp` の別名 `auth.tolo.localhost` で `ingress` に届く。本番でクラスタ内の DNS が `auth.<ルートドメイン>` を IdP に向けるのに当たる
- `ingress` は Host で振り分け、`auth.tolo.localhost` を `idp:8080` へ、`tolo.localhost` とその下のホストを `web:3000` へ転送する（`config/ingress/Caddyfile`）

`server` の `IDP_ISSUER`、IdP の `TOLO_IDP_ISSUER`、発行されるトークンの `iss` がこの 1 つの文字列で一致し、Discovery の検証が通る

ルートドメインを `localhost` ではなく `tolo.localhost` にしているのは、ブラウザが `localhost` の下のホストどうしを別のサイトとして扱うためである  
`localhost` と `auth.localhost` は別のサイトになり、ログイン画面から IdP の `/api/login` を呼んで作った IdP の Cookie（`SameSite=Lax`）が、そのあとの IdP への遷移に付かない  
`tolo.localhost`・`auth.tolo.localhost`・`test.tolo.localhost` は、本番の `example.com` とその下のホストと同じく、同じサイトになる

片付けは `docker compose -p toloidpcheck -f compose.yml -f compose.idp.yml -f compose.tm.yml down -v` になる

### イメージ

ghcr に公開されている native ビルドのイメージ（`ghcr.io/pj-hoakari/tolo-idp` の `0.5.0`）を、digest まで固定して使う  
ほかのサービスと違い、git からはビルドしない  
`0.5.0` は linux/amd64 と linux/arm64 の両方が公開されていて、arm64 のマシン（Apple Silicon）でも起動する  
手元でビルドしたイメージは `TOLO_IDP_IMAGE` で差し替える

### プロファイル

IdP には `SPRING_PROFILES_ACTIVE=dev-native` を渡す  
client（`client-123` と `service-gateway`）は、tolo-idp の `application.yaml` の dev プロファイルにしか定義されていない  
native イメージは何も指定しないと production プロファイルで起動し、client が 1 つも登録されない  
DB・Redis・relation の参照先・issuer・ログイン画面の URL（`http://tolo.localhost/login`）は、プロファイルの値を環境変数で上書きしている

tolo-web 用の client `console-ui` は、`config/idp/console-ui.yaml` に定義し、`SPRING_CONFIG_ADDITIONAL_LOCATION` で読ませる  
`redirect_uri` は `http://tolo.localhost/api/auth/callback/tolo-idp`、`post_logout_redirect_uri` は `http://tolo.localhost/auth/logged-out` で、secret は `TOLO_IDP_CONSOLE_UI_CLIENT_SECRET`（既定 `console-secret`）になる

### 所属の参照先

IdP は、トークンを発行するときに `TOLO_IDP_RELATION_BASE_URL` の `GET /tenants/{tenant_id}/users/{sub}/memberships` で所属を引く  
参照先は Tenant Management で、`idp` はネットワーク `tenant-management` にもつながる  
所有権の取得や招待の受諾で Tenant Management に作られた所属は、そのまま IdP から見える  
IdP は所属を Redis と DB に 5 分キャッシュするので、所属を変えた直後のトークンには古い値が載ることがある

### 失効照会の資格情報

失効照会の対象である管理系書き込みの RPC では、Gateway が IdP の `introspection_endpoint` へ `client_secret_basic` で照会する  
IdP は Introspection を許可した client（`service-gateway`）にしか照会を許さないため、`server` には `IDP_INTROSPECTION_CLIENT_ID: service-gateway` を渡す

Gateway は secret をファイルで受け取るので、init サービス `idp-seed-secret` が `${TOLO_IDP_SERVICE_GATEWAY_CLIENT_SECRET:-gateway-secret}` の値を名前付きボリューム `idp-seed-introspection` へ書き出し、`server` が `/etc/tolo/idp-seed` に読み込み専用でマウントする  
同じ値を `idp` の `TOLO_IDP_SERVICE_GATEWAY_CLIENT_SECRET` にも渡すので、IdP 側の secret と必ず一致する  
secret はボリュームの中だけに存在し、リポジトリにもイメージにも入らない

base の `keygen` が作る乱数 secret のボリューム `tolo-idp-introspection` は fake IdP 用で、こちらとは別になる（`server` には両方が別のパスでマウントされるが、実物の IdP を使うときに読むのは `/etc/tolo/idp-seed` の方だけになる）

トークンの取得に使う `client-123` の secret は `TOLO_IDP_SEED_CLIENT_SECRET`（既定 `secret`）で、`scripts/idp-token.sh` と `scripts/idp-revoke.sh` の `IDP_CLIENT_SECRET` をこれに合わせる  
起動ログの `the IdP metadata is resolved` に `"introspection":true` が出ていれば有効になっている

## ユーザーと所属の用意

IdP はユーザーをテナントごとに持ち、ログインするテナントは認可要求の `resource`（`https://api.example.com/tenants/<tenant_id>`）で指定する  
IdP の seed ユーザー（`user-123`）は固定テナント `0123456789abcdef` に作られるが、Tenant Management にその `sub` の所属がないので、IdP はログインを `403` で拒否する  
代わりに、`scripts/idp-signup.sh` で固定テナント（`0123456789abcdef`）にユーザーを作り、その `sub` で Tenant Management の seed を入れ直す

```bash
SUB=$(./scripts/idp-signup.sh)
TOLO_OWNER_SUB="$SUB" docker compose -p toloidpcheck -f compose.yml -f compose.idp.yml -f compose.tm.yml run --rm tenant-management-seed
```

`idp-signup.sh` は `tenant.join` の認可要求で challenge を受け取り、`/api/signup` でユーザーを作って `sub` を標準出力へ出す  
ユーザーが作成済み（`409`）のときは、`/api/login` でログインして同じ `sub` を出す  
ただし IdP は所属のないユーザーのログインを `403` で拒否するので、所属を入れる前に 2 回目を実行すると失敗する

`sub` は IdP が作成時に発行する UUID で、`idp-db` を作り直すたびに変わる  
`down -v` のあとは、ユーザーの作成と seed をやり直す  
seed は既存の行を残して足すだけなので、compose の起動時に入る `user-owner` の所属も残る

ユーザー名・パスワード・テナントは `IDP_USERNAME`（既定 `user-owner`）・`IDP_PASSWORD`（既定 `password`）・`IDP_TENANT_ID` で変えられる

## トークンの取得

`scripts/idp-token.sh` がログインから token までを curl で行い、アクセストークンだけを標準出力へ出す

```bash
TOKEN=$(./scripts/idp-token.sh -s "openid tenant.read events.read")
```

| 引数 | 環境変数 | 既定 |
| --- | --- | --- |
| `-u` | `IDP_BASE_URL` | `http://auth.tolo.localhost` |
| `-t` | `IDP_TENANT_ID` | `0123456789abcdef` |
| `-s` | `IDP_SCOPE` | `openid tenant.read events.read` |
| `-e` | `IDP_EVENT_ID` | （空。指定すると Token Exchange で `event_access` にする） |

流れは次の 4 段になる

1. `resource` 付きの authorize がログイン画面（`http://tolo.localhost/login`）へ `challenge` を付けて 302 を返す
2. `/api/login` に資格情報と `challenge` を送り、IdP のセッションを作る
3. `/oauth2/authorize?challenge=…` で元の認可要求を再開し、認可コードを受け取る
4. 認可コードを token に交換する

ログイン画面は開かず、302 の `Location` から `challenge` だけを取り出す  
`/api/login` には、ログイン画面の origin（`IDP_WEB_ORIGIN`、既定 `http://tolo.localhost`）を `Origin` に付けて送る  
PKCE の verifier と challenge はスクリプト内で `openssl` を使って生成する  
client と redirect_uri は tolo-idp の dev プロファイルの値を既定にしていて、`IDP_USERNAME`・`IDP_PASSWORD`・`IDP_CLIENT_ID`・`IDP_CLIENT_SECRET`・`IDP_REDIRECT_URI` で変えられる

## トークンの失効

`scripts/idp-revoke.sh` が IdP の `POST /oauth2/revoke` を叩く

```bash
./scripts/idp-revoke.sh "$TOKEN"
```

IdP は `204` ではなく `200` と空の本文で応答する  
失効後に `POST /oauth2/introspect` を叩くと `{"active":false}` だけが返る

失効させたトークンでも、署名と期限が有効な間は**失効照会の対象でない RPC は通る**（`ListEvents` など）  
対象の RPC でだけ照会が走り、`unauthenticated`（監査 `failure_reason=token_revoked`）になる

照会の結果は jti 単位で 60 秒キャッシュされるので、**一度通った直後に失効させても最大 60 秒は通り続ける**  
失効をすぐ確かめたいときは、Gateway を 1 度も呼んでいない新しいトークンを失効させてから呼ぶ

## スモークテスト

ユーザーと所属を用意したあと、次の 4 つが通れば、実物の IdP のトークンが Gateway の検証・認可・失効照会を通って Tenant Management まで届いている

```bash
TID=0123456789abcdef
TOKEN=$(./scripts/idp-token.sh -s "openid tenant.read tenant.write events.read events.manage")

curl -s -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d "{\"tenantId\":\"$TID\"}" http://localhost:18090/tolo.tenant.v1.TenantService/ListEvents

curl -s -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d "{\"tenantId\":\"$TID\",\"tenantRole\":\"ROLE_STAFF\",\"displayName\":\"smoke\"}" \
  http://localhost:18090/tolo.relation.v1.RelationAdminService/CreateTenantInvitation

EVENT_TOKEN=$(./scripts/idp-token.sh -s "openid tenant.read events.read events.manage" -e fedcba9876543210)
```

| 確かめること | 結果 |
| --- | --- |
| `ListEvents` | seed のイベントが返る |
| `CreateTenantInvitation`（失効照会の対象） | 招待と招待トークンが返る |
| 失効させたトークンでの `CreateTenantInvitation` | `unauthenticated` |
| `-e` での Token Exchange | `token_use` が `event_access` で、`event_id` が載ったトークンが返る |

## tolo-web からのログイン

`compose.idp-web.yml` は、tolo-web を認証のモックではなく実物の IdP につなぐオーバーライドになる  
`compose.edge.yml`・`compose.web.yml`・`compose.idp.yml`・`compose.tm.yml` と一緒に使う

```bash
NPM_TOKEN=... docker compose -p toloidpcheck \
  -f compose.yml -f compose.tm.yml -f compose.idp.yml \
  -f compose.edge.yml -f compose.web.yml -f compose.idp-web.yml up -d
```

- `web` は `ROOT_DOMAIN=tolo.localhost`、`AUTH_MOCKING=disabled` で動き、client `console-ui` で IdP にログインする
- `web` のホストの 3000 番は外し、`ingress` 越しの `http://tolo.localhost` と `http://test.tolo.localhost` で開く。tolo-web はルートドメインの origin にポートを付けないので、80 番で公開する必要がある
- Better Auth の DB は `web-auth-db`（PostgreSQL 18）で、tolo-web のイメージの `db/auth.sql` を `web-auth-schema` が取り出し、DB の初回の起動で流す
- `edge-bridge` も issuer と JWKS を `http://auth.tolo.localhost` に向ける

ユーザーと所属を「ユーザーと所属の用意」の手順で入れたあと、`http://test.tolo.localhost/management` を開くと、ルートドメインのログイン画面（`http://tolo.localhost/login`）に移る  
`user-owner` と `password` でログインすると、`test.tolo.localhost` にセッションが引き渡され、管理画面に seed のイベントが出る  
メンバーの管理画面から招待 URL を作ると、Gateway の監査に `CreateTenantInvitation` の `result=ok` が出る

新しいテナントは `http://tolo.localhost/onboarding` から作れる  
テナント名・サブドメイン名・オーナーの表示名を送ると、ログイン画面にアカウントの作成の入力が出るので、ID とパスワードを決める  
所有権の取得が済むと `http://<サブドメイン名>.tolo.localhost/management` に移る

招待 URL は、別のブラウザ（または別のプロファイル）で開いて「参加する」を押す  
同じくアカウントを作ると受諾され、そのテナントの管理画面に移る  
使用済みの招待で参加しようとすると、「この招待は使えません」と表示される

## 既知の制約

tolo-idp は、`scope` のない Token Exchange に、イベントロール・交換元の scope・client の登録 scope の積を発行する（0.5.0 から）  
tolo-web はスタッフの交換に `scope` を付けないので、`event_access` には `events.*` のほかに `tenant.read` が載り、owner では `tenant.write` も載る  
Gateway で `event_access` を受ける RPC は、どれも `events.*` しか要求しない  
Token Exchange には `openid` scope を渡せない（`invalid_scope` になる）ため、スクリプトは交換時に `openid` を落とす  
IdP が発行するトークンには Gateway の仕様に無い `resource` claim（`https://api.example.com/tenants/<tenant_id>` 形式）が入るが、Gateway は無視する  
JWT ヘッダに `typ` は入らず、`alg` は RS256、`kid` は IdP が起動ごとに作る ephemeral な鍵の UUID になる（`TOLO_IDP_JWK_ALLOW_EPHEMERAL=true`）  
アクセストークンの有効期限は 15 分（`event_access` は 10 分）で、`idp` を作り直すと署名鍵が変わるため古いトークンは使えなくなる
