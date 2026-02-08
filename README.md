# ddbj-search

[DDBJ Search](https://ddbj.nig.ac.jp/search) の nginx reverse proxy。

## 概要

DDBJ Search は、BioProject / BioSample / SRA / JGA データを横断的に検索・取得するための Web アプリケーション。
このリポジトリは、フロントエンドと API サーバーへのリクエストルーティングを担う nginx reverse proxy を管理する。

**関連プロジェクト:**

- [ddbj-search-converter](https://github.com/ddbj/ddbj-search-converter) - データ投入用パイプラインツール (Elasticsearch 管理)
- [ddbj-search-api](https://github.com/ddbj/ddbj-search-api) - RESTful API サーバー
- [ddbj-search-front](https://github.com/ddbj/ddbj-search-front) - フロントエンド

### システム構成

```plain
Client
  |
  v
nginx (this project)
  -> /search/api/*        -> ddbj-search-api (API server)
  -> /search/resources/*  -> ddbj-search-es (Elasticsearch, optional)
  -> /search/*            -> ddbj-search-front (frontend SPA)
  -> /resource/*          -> redirect to /search/entry/*
  -> /entry/*             -> redirect to /search/entry/*
```

nginx は ddbj-search-converter が管理する Elasticsearch を参照する API サーバーおよびフロントエンドに対して、リクエストをルーティングする。
同一の Docker network (`ddbj-search-network-{env}`) を通じてアクセスする。
詳細は [docs/network-architecture.md](docs/network-architecture.md) を参照。

## クイックスタート

### 前提条件

- Podman (本番/ステージング) または Docker (開発)
- ddbj-search-api / ddbj-search-front の環境が起動済み

### 環境起動 (Dev)

```bash
# 1. 環境変数を設定
cp env.dev .env

# 2. Docker network 作成（初回のみ、既に存在していてもエラーにならない）
docker network create ddbj-search-network-dev || true

# 3. 起動
docker compose up -d
```

### 環境起動 (Staging / Production)

```bash
# 1. 環境変数と override を設定
cp env.staging .env  # または env.production
cp compose.override.podman.yml compose.override.yml

# 2. Podman network 作成（初回のみ、既に存在していてもエラーにならない）
podman network create ddbj-search-network-staging || true
# production の場合: podman network create ddbj-search-network-production || true

# 3. 起動
podman-compose up -d
```

### 動作確認

```bash
# フロントエンドにアクセス
curl http://localhost:8000/search

# API にアクセス
curl http://localhost:8000/search/api/service-info
```

## 環境構築

### 環境ファイル

| ファイル | 説明 |
|---------|------|
| `compose.yml` | 統合版 Docker Compose |
| `compose.override.podman.yml` | Podman 用の差分設定 |
| `env.dev` | 開発環境 |
| `env.staging` | ステージング環境 |
| `env.production` | 本番環境 |

### .env の主要設定

`env.*` ファイルをコピーして使用する。

```bash
# === Environment ===
DDBJ_SEARCH_ENV=production   # dev, staging, production
```

`DDBJ_SEARCH_ENV` により、コンテナ名 (`ddbj-search-nginx-{env}`)、Docker network 名 (`ddbj-search-network-{env}`)、および nginx upstream のコンテナ名 (`ddbj-search-front-{env}`, `ddbj-search-api-{env}`) が自動決定される。

### Elasticsearch Proxy (オプション)

フロントエンドの ReactiveSearch が Elasticsearch に直接アクセスする必要がある場合、読み取り専用の ES proxy を有効化できる。

`.env` で `DDBJ_SEARCH_ES_ENABLED=true` のコメントを外す:

```bash
# === Elasticsearch Proxy (optional) ===
DDBJ_SEARCH_ES_ENABLED=true
```

有効化すると `/search/resources` で以下のエンドポイントのみ許可される:

| パス | メソッド | 用途 |
|------|---------|------|
| `/{indices}/_search` | GET, POST | 検索クエリ |
| `/{indices}/_msearch` | GET, POST | マルチ検索 (ReactiveSearch) |
| `/{type}/_doc/{id}` | GET | ドキュメント取得 |

上記以外のパス (`_bulk`, `_delete`, インデックス操作等) はすべて 404 を返す。
ES コンテナ名は `DDBJ_SEARCH_ENV` から `ddbj-search-es-{env}:9200` として自動解決される。

### nginx テンプレート

nginx の公式 Docker image は `/etc/nginx/templates/*.template` を envsubst で処理する機能を内蔵している。
`NGINX_ENVSUBST_FILTER=DDBJ_SEARCH` を設定することで、`DDBJ_SEARCH_` prefix を持つ変数のみが置換され、nginx 固有変数 (`$host`, `$remote_addr` 等) は保護される。

テンプレートは `nginx/templates/default.conf.template` に配置されている。

## ドキュメント

- [docs/network-architecture.md](docs/network-architecture.md) - ネットワーク構成

## License

This project is licensed under the [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) license. See the [LICENSE](./LICENSE) file for details.
