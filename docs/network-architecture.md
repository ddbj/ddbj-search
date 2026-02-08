# Network Architecture

DDBJ Search システム全体のネットワーク構成。

## コンポーネント一覧

| Component | Repository | Container | Port |
|-----------|-----------|-----------|------|
| Frontend | [ddbj-search-front](https://github.com/ddbj/ddbj-search-front) | ddbj-search-front | 3000 |
| API Server | [ddbj-search-api](https://github.com/ddbj/ddbj-search-api) | ddbj-search-api | 8080 |
| Converter | [ddbj-search-converter](https://github.com/ddbj/ddbj-search-converter) | ddbj-search-converter | - |
| Elasticsearch | - | ddbj-search-elasticsearch | 9200 |
| Internal nginx | [ddbj-search](https://github.com/ddbj/ddbj-search) (this repo) | ddbj-search-nginx | 80 |

全コンテナは Docker network `ddbj-search-network` に接続する。

## URL 設計

### 外部公開 URL

本番環境のベース URL: `https://ddbj.nig.ac.jp`

```plain
/search                                 -> Frontend (top page)
/search/entry                           -> Frontend (search page)
/search/entry/{type}                    -> Frontend (type search page)
/search/entry/{type}/{accession}        -> Frontend (entry page)
/search/entry/{type}/{accession}.json   -> API Server (entry detail, JSON)
/search/entry/{type}/{accession}.jsonld -> API Server (entry detail, JSON-LD)
/search/api/entries/                    -> API Server (search)
/search/api/entries/{type}/             -> API Server (type search)
/search/api/entries/{type}/bulk         -> API Server (bulk get)
/search/api/count/types/                -> API Server (type counts)
/search/api/service-info                -> API Server (service info)
/search/api/docs                        -> API Server (Swagger UI)
```

### ベースパス

| Component | Base path | 環境変数 / 設定 |
|-----------|-----------|----------------|
| Frontend | `/search` | `BASE_PATH=/search` (Next.js basePath) |
| API Server | `/search/api` | `DDBJ_SEARCH_API_URL_PREFIX=/search/api` |

Frontend / API Server ともに、base path を設定で受け取り、そのまま処理する。
nginx はパスを trim せず、そのまま転送する (pass-through 方式)。

## ネットワーク構成図

```plain
Client (Browser / curl)
  |
  | HTTPS
  v
External nginx (*.nig.ac.jp)
  |  /search   -> proxy to internal nginx
  |  /resource -> proxy to internal nginx (backward compat)
  |  /entry    -> proxy to internal nginx (backward compat)
  |
  | HTTP (internal)
  v
Internal nginx (ddbj-search-network:80)
  |
  |  [1] /search/entry/{type}/{id}.(json|jsonld)
  |        -> rewrite to /search/api/entries/{type}/{id}.(json|jsonld)
  |        -> ddbj-search-api:8080
  |
  |  [2] /search/api/*
  |        -> ddbj-search-api:8080 (pass-through)
  |
  |  [3] /search/*
  |        -> ddbj-search-front:3000 (pass-through, catch-all)
  |
  |  [4] /resource/*
  |        -> 301 redirect to /search/entry/* (backward compat)
  |
  |  [5] /entry/*
  |        -> 301 redirect to /search/entry/* (backward compat)
  |
  +-- ddbj-search-api:8080
  |     url_prefix=/search/api
  |
  +-- ddbj-search-front:3000
  |     basePath=/search
  |
  +-- ddbj-search-elasticsearch:9200
        (internal only, no external access)
```

**nginx の location 評価順序** (上が優先):

1. `regex`: `/search/entry/{type}/{id}.(json|jsonld)` -> API (rewrite + proxy)
2. `prefix`: `/search/api` -> API (pass-through proxy)
3. `prefix`: `/search` -> Frontend (pass-through proxy, catch-all)
4. `prefix`: `/resource` -> 301 redirect
5. `prefix`: `/entry` -> 301 redirect

## nginx proxy 方式

### pass-through

パスを trim せず、そのまま backend / frontend に転送する。

```nginx
# API Server: pass-through (no trailing slash)
location /search/api {
    proxy_pass http://ddbj-search-api;
    # /search/api/entries/ -> backend receives /search/api/entries/
}

# Frontend: pass-through (no trailing slash)
location /search {
    proxy_pass http://ddbj-search-front;
    # /search/entry/bioproject/PRJNA16 -> backend receives /search/entry/bioproject/PRJNA16
}
```

メリット:

- nginx 設定がシンプル (rewrite 不要)
- backend が自身の URL を正しく生成できる (JSON-LD `@id`, Swagger UI, エラーの `instance`)
- nginx とアプリのログで同じパスが記録される

### 特殊ケース: entry detail の rewrite

`/search/entry/{type}/{id}.(json|jsonld)` は frontend のパス体系に属するが、
実際のデータ提供は API Server が行う。nginx で API のパスに rewrite する。

```nginx
location ~ ^/search/entry/([^/]+)/([^/]+)\.(json|jsonld)$ {
    rewrite ^/search/entry/(.+)\.(json|jsonld)$ /search/api/entries/$1.$2 break;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_pass http://ddbj-search-api;
}
```

これにより API Server は `/search/api/entries/{type}/{id}.(json|jsonld)` として統一的に処理できる。

## Backward Compatibility

旧 URL (ddbj-ld 時代) からのリダイレクト。

| 旧 URL | リダイレクト先 | 状態 |
|--------|---------------|------|
| `/resource/{type}/{accession}` | 301 -> `/search/entry/{type}/{accession}` | 維持 (ブックマーク対応) |
| `/entry/{type}/{accession}` | 301 -> `/search/entry/{type}/{accession}` | 維持 (ブックマーク対応) |
| `/resources/*` | - | 廃止 (ES 外部公開の廃止に伴い不要) |

### External nginx 側

外部 nginx で `/resource`, `/entry` を内部に転送し、内部 nginx で 301 リダイレクトを行う。

```nginx
# External nginx
location /resource {
    proxy_pass http://ddbj-search-internal/resource;
}

location /entry {
    proxy_pass http://ddbj-search-internal/entry;
}
```

```nginx
# Internal nginx
location /resource {
    rewrite ^/resource(.*)$ https://$host/search/entry$1 permanent;
}

location /entry {
    rewrite ^/entry(.*)$ https://$host/search/entry$1 permanent;
}
```

### 廃止する旧ルート

以下は ES の外部公開廃止に伴い削除する。

- `/resources` -> `/search/resources` (旧 ES リダイレクト)
- `/search/resources/*` (ES direct access)
- `/search/resources/{indices}/_msearch` (ES multi-search)
