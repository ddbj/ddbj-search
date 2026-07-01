# Network Architecture

DDBJ Search システム全体のネットワーク構成。

## コンポーネント一覧

| Component | Repository | Container 名 (env suffix) | Port |
|-----------|-----------|-----------|------|
| Frontend | [ddbj-search-front](https://github.com/ddbj/ddbj-search-front) | `ddbj-search-front-${env}` | 3000 |
| API Server | [ddbj-search-api](https://github.com/ddbj/ddbj-search-api) | `ddbj-search-api-${env}` | 8080 |
| Converter | [ddbj-search-converter](https://github.com/ddbj/ddbj-search-converter) | `ddbj-search-converter-${env}` | - |
| Elasticsearch | - | `ddbj-search-es-${env}` | 9200 |
| Internal nginx | [ddbj-search](https://github.com/ddbj/ddbj-search) (this repo) | `ddbj-search-nginx-${env}` | 80 |

`${env}` は `DDBJ_SEARCH_ENV` (= `dev` / `staging` / `production` のいずれか)。全コンテナは Docker network `ddbj-search-network-${env}` に接続する。converter の compose が network を作成し、他 service は `external: true` で参照する。

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

Frontend / API Server ともに、base path を設定で受け取る。ただし API Server (FastAPI) の router は root (`/`) に mount されており、`DDBJ_SEARCH_API_URL_PREFIX=/search/api` は OpenAPI schema の `servers` block にだけ反映される (public 側から見た base URL の告知)。したがって nginx は `/search/api/` prefix を strip してから backend に転送する。Frontend (SPA) は `/search` prefix ごと受け取り、basePath として使う。

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
  |        -> rewrite to /entries/{type}/{id}.(json|jsonld)
  |        -> ddbj-search-api:8080
  |
  |  [2] /search/api/*
  |        -> strip /search/api/ prefix
  |        -> ddbj-search-api:8080
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
  |     router mounted at "/" (root)
  |     url_prefix=/search/api (openapi servers only)
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

### API Server: `/search/api/` prefix を strip

FastAPI router は root (`/`) に mount されている (= 個別 endpoint は `/entries/...` や `/db-portal/search` として登録される)。`DDBJ_SEARCH_API_URL_PREFIX=/search/api` は OpenAPI schema の `servers` にだけ反映され、router 自体の path は書き換えない。したがって nginx で prefix を strip して backend に転送する必要がある。strip し忘れると api 側で 404 になる。

```nginx
# /search/api/ prefix を strip (location + proxy_pass の両方に trailing slash が必要)
location /search/api/ {
    proxy_pass http://ddbj-search-api/;
    # /search/api/entries/... -> backend receives /entries/...
}

# /search/api (trailing slash 無し) は exact match で拾って、sibling SPA route
# (例: /search/api-doc/) を巻き込まないようにする
location = /search/api {
    proxy_pass http://ddbj-search-api/;
}
```

### Frontend: pass-through

Frontend (SPA) は basePath `/search` を含めて受け取る。パス trim なし。

```nginx
location /search {
    proxy_pass http://ddbj-search-front;
    # /search/entry/bioproject/PRJNA16 -> backend receives /search/entry/bioproject/PRJNA16
}
```

### 特殊ケース: entry detail の rewrite

`/search/entry/{type}/{id}.(json|jsonld)` は frontend のパス体系に属するが、
実際のデータ提供は API Server が行う。nginx で API の router path に rewrite する。API Server は root mount なので rewrite 先も unprefixed で指す (`/entries/...`)。

```nginx
location ~ ^/search/entry/([^/]+)/([^/]+)\.(json|jsonld)$ {
    rewrite ^/search/entry/(.+)\.(json|jsonld)$ /entries/$1.$2 break;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_pass http://ddbj-search-api;
}
```

これにより API Server は `/entries/{type}/{id}.(json|jsonld)` として通常の router endpoint と統一的に処理できる。

## upstream の静的解決

internal nginx は `upstream` block で backend の container 名を静的に解決する (起動時に 1 度だけ DNS lookup してその IP を hold)。したがって backend を再作成した場合は internal nginx も `podman-compose --env-file .env restart` で再起動して upstream を解決し直す。起動順は `converter → api → front → nginx`。

## Backward Compatibility

旧 URL (ddbj-ld 時代) からのリダイレクト。

| 旧 URL | リダイレクト先 | 状態 |
|--------|---------------|------|
| `/resource/{type}/{accession}` | 301 -> `/search/entry/{type}/{accession}` | 維持 (ブックマーク対応) |
| `/entry/{type}/{accession}` | 301 -> `/search/entry/{type}/{accession}` | 維持 (ブックマーク対応) |
| `/resources/*` | - | 廃止 (ES 外部公開の廃止に伴い不要、`/search/resources/*` も含めて削除) |

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

## 並走 env (release cutover 時の一時構成)

新リリースを本番化する前に、staging と同じホスト上で `staging` と並走させる一時 env を立てることがある。`DDBJ_SEARCH_ENV` に **一時 suffix** (例: `staging-release-v2025`) を渡し、container / network / image を prev (= `staging`) と衝突させずに同居させる。cutover が完了したら一時 env は破棄する。

### 命名

| 要素 | prev (永続) | new (一時) |
|---|---|---|
| `DDBJ_SEARCH_ENV` | `staging` | `staging-release-v<id>` (例: `staging-release-v2025`) |
| network | `ddbj-search-network-staging` | `ddbj-search-network-staging-release-v<id>` (= 新規) |
| api container | `ddbj-search-api-staging` | `ddbj-search-api-staging-release-v<id>` |
| front container | `ddbj-search-front-staging` | `ddbj-search-front-staging-release-v<id>` |
| 内部 nginx container | `ddbj-search-nginx-staging` | `ddbj-search-nginx-staging-release-v<id>` |
| 公開 port (内部 nginx) | a012:18080 | a012:19080 (一時) |
| Elasticsearch | `ddbj-search-es-staging` (prev) | **作らない** (prev ES を共有) |
| converter container | `ddbj-search-converter-staging` (prev) | **動かさない** (= 一時 env では indexing pipeline は走らない) |

prev と new で 1 系統の ES / dblink / const dir を共有する設計。スキーマ互換であることが前提で、書き込み (indexing) は prev converter pipeline でのみ実施し、new 側 api は read 専用で参照する。

### network 構成

```plain
+-------------------------------+      +----------------------------------------+
| ddbj-search-network-staging   |      | ddbj-search-network-staging-release... |
| (prev、converter が作成)      |      | (new、new 側 compose が作成)           |
|                               |      |                                        |
|  ddbj-search-es-staging       |<---+ |  ddbj-search-api-staging-release-...   |
|  ddbj-search-converter-staging|    | |  ddbj-search-front-staging-release-... |
|  ddbj-search-api-staging      |    | |  ddbj-search-nginx-staging-release-... |
|  ddbj-search-front-staging    |    | |                                        |
|  ddbj-search-nginx-staging    |    +-|--- multi-network join (api のみ)       |
+-------------------------------+      +----------------------------------------+
        ^                                          ^
        | a012:18080                               | a012:19080
        | (external gateway)                       | (external gateway)
```

new 側 api コンテナは prev ES (`ddbj-search-es-staging`) を解決するために `ddbj-search-network-staging` にも multi-network join する。具体的には起動後に `podman network connect ddbj-search-network-staging ddbj-search-api-staging-release-v<id>` を 1 度叩く (compose.yml には書かず deploy 手順に分離、prev / production の通常 compose を汚さないため)。

new 側 front / 内部 nginx は backend が同じ `ddbj-search-network-staging-release-v<id>` 上にいるので multi-network join は不要。

### 起動順序

内部 nginx は `upstream` block で backend を静的に解決するため、nginx 起動時点で api / front コンテナが同じ network 上に存在している必要がある。`api -> front -> nginx` の順に `podman-compose up -d` する。backend を作り直したら nginx も `podman-compose restart` で IP 再解決する。

### 落とし穴

- **prev の compose を down してはいけない**: new 側 api が `ddbj-search-network-staging` に multi-network join しているため、prev compose を down すると network ごと消えて new 側 api も切断される
- **new env の suffix は cutover 後に compose / env から消す**: 永続側 (`production` / `staging`) に経緯を持ち込まない。cutover の段取りは 各リポジトリの `docs/deployment.md` を参照
