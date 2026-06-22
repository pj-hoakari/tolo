# NPMパッケージ用の開発環境セットアップ

## .envファイルの作成

`.env.example`ファイルをコピー

```bash
cp .env.example .env
```

## トークンの設定

### GitHubトークンの作成

1. GitHubのトークンページを開く  
  [Personal Access Tokens (Classic)](https://github.com/settings/tokens)
2. 「Generate new token」をクリック
3. 「Generate new token (classic)」を選択  
  ⚠「(clssic)」であることを確認
4. 「Note」に任意の名前を入力
5. 「Expiration」を選択
6. 「Select scopes」で以下の権限を選択  
    - `read:packages`（パッケージの読み取り）  
7. 「Generate token」をクリック  
  ⚠次の画面でトークンが表示される，コピーを忘れずに閉じることがないように注意
8. 生成されたトークンをコピー  
  ⚠コピーを忘れて閉じないように注意


トークンの「Select scopes」については以下の画像を参照
![Select scops](./assets/token-scopes-for-npm-package.png)

### トークンの.envファイルへの設定

`.env`ファイルの`NPM_TOKEN`行にトークンを記載

```env
NPM_TOKEN=ghp_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```


## direnvのセットアップ
任意，direnvを使用する場合のみ

[direnv – unclutter your .profile | direnv](https://direnv.net/)

### direnvのインストール
[Installation | direnv](https://direnv.net/docs/installation.html)

Ubuntuの場合
```bash
sudo apt install direnv
```

macOSの場合
```bash
brew install direnv
```

### direnvとシェルの連携
[Setup | direnv](https://direnv.net/docs/hook.html)

Ubuntuの場合（bashを使用している場合）
```bash
echo 'eval "$(direnv hook bash)"' >> ~/.bashrc
```

macOSの場合（zshを使用している場合）
```bash
echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc
```

### .envrcファイルの作成

`.envrc.example`ファイルをコピー

```bash
cp .envrc.example .envrc
```

### direnvの許可

```bash
direnv allow
```
