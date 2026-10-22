# php-oct2026-hotfix

Zero-Lag Emergency Patch Builder

2026-10-21 に公開された PHP の RCE 脆弱性 2 件に対応する PHP コンテナイメージを、公式 Docker イメージやディストリビューションのパッケージ配信を待たずに自前でビルドし、ghcr.io に配信するデモです。

- **CVE-2026-109618** ([GHSA-w8hw-w9fx-j79w](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w)): OOM 時の状態破損による RCE
- **CVE-2026-109619** ([GHSA-6wmf-4rv5-p3rp](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp)): リクエスト間に残った状態による RCE
- 参考: [PHP Foundation blog](https://thephp.foundation/blog/2026/10/21/todays-php-security-release-and-how-were-strengthening-php-security/), [php.net announcement](https://www.php.net/archive/2026.php#2026-10-21-5)

## 対応バージョン

| ブランチ | ソース | イメージタグ（CLI / FPM） |
|---|---|---|
| 8.5 / 8.4 / 8.3 / 8.2 | php.net の修正済み tarball（8.5.12 / 8.4.27 / 8.3.36 / 8.2.35） | `8.5.12`, `8.5.12-r0`, `8.5` / `8.5.12-fpm`, `8.5-fpm` など |
| 8.1 / 8.0 / 7.4（EOL） | 最終 tarball（8.1.34 / 8.0.30 / 7.4.33）＋ PHP セキュリティチームの公式バックポート（`patches/<branch>/`） | `7.4.33-r1`, `7.4` / `7.4.33-r1-fpm`, `7.4-fpm` など |

EOL ブランチ用のパッチは、php-src の `PHP-{7.4,8.0,8.1}-CVE-2026-109618-109619` ブランチにある修正コミット "Avoid state corruption via bailout" を `git format-patch` で取り出したものです。パッチを当てたビルドはリビジョン `-r1` になります。素の tarball ビルドと同じタグを名乗らないように、`7.4.33` のような素のバージョンタグは付けません。

```sh
docker run --rm ghcr.io/yowatari/php-oct2026-hotfix:8.5 -v
docker run --rm ghcr.io/yowatari/php-oct2026-hotfix:7.4.33-r1 -v
docker run -d -p 9000:9000 ghcr.io/yowatari/php-oct2026-hotfix:8.5-fpm   # php-fpm -F, listen 9000
```

署名は GitHub Actions のキーレス署名（cosign）です。次のコマンドで確認できます。

```sh
cosign verify ghcr.io/yowatari/php-oct2026-hotfix:8.5 \
  --certificate-identity-regexp '^https://github.com/yowatari/php-oct2026-hotfix/.github/workflows/build.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## 仕組み

```
scripts/render.sh <version>
  ├─ php.net/releases の JSON から tarball の sha256 を取得
  ├─ patches/<major.minor>/*.patch を build/<version>/src/patches にコピー
  └─ melange.tmpl.yaml / apko.tmpl.yaml から build/<version>/ を生成
melange build   Wolfi 上で公式 tarball を取得（sha256 で検証）→ パッチ適用 → ビルド
                → 署名付き apk 3 つに分割し、それぞれの test: を実行
                    php-hotfix      php CLI, php.ini, 拡張
                    php-hotfix-fpm  php-fpm と設定（listen 9000, stderr ログ）
                    php-hotfix-dev  phpize, php-config, ヘッダ（拡張モジュールのビルド用）
apko publish    Wolfi ベースの distroless イメージ 2 種（nonroot, uid 65532, シェルなし）＋ SBOM を push
                    apko.yaml      php-hotfix                  → :<tag>
                    apko-fpm.yaml  php-hotfix + php-hotfix-fpm → :<tag>-fpm
cosign sign     GitHub OIDC によるキーレス署名
```

- `.github/workflows/build.yml` は全バージョンを matrix で並列にビルドします。`workflow_dispatch` の `versions` に `["7.4.33"]` のような JSON を渡すと、指定したバージョンだけをビルドします。
- 7.4 / 8.0 / 8.1 は、Wolfi が提供する OpenSSL 3.6 と libxml2 2.15 ではビルドできません。`legacy-deps.inc.yaml` で OpenSSL 1.1.1w（共有ライブラリ）と libxml2 2.11.9（静的リンク）を同じパイプライン内でビルドして使います。

## 新しい修正が出たら

- **修正済み tarball がリリースされた場合:** `DEFAULT_VERSIONS`（workflow）のバージョンを上げるだけです。sha256 は render.sh が php.net から取得します。
- **tarball はまだなく、パッチだけが出た場合:** `patches/<major.minor>/NNNN-*.patch` を置いて push します。ビルドは `-r1` になります。

## ローカルでのビルド

```sh
scripts/render.sh 8.5.12
docker run --rm -v "$PWD":/work -w /work cgr.dev/chainguard/melange keygen melange.rsa
docker run --privileged --rm -v "$PWD":/work -w /work cgr.dev/chainguard/melange \
  build build/8.5.12/melange.yaml --arch x86_64 --signing-key melange.rsa \
  --source-dir build/8.5.12/src --out-dir build/8.5.12/packages
docker run --rm -v "$PWD":/work -w /work cgr.dev/chainguard/apko \
  build build/8.5.12/apko.yaml php-hotfix:8.5.12 build/8.5.12/image.tar   # FPM は apko-fpm.yaml
docker load < build/8.5.12/image.tar
```

## 注意事項

- EOL ブランチのバックポートは、セキュリティチームによる「最小限の緩和策」です。ほかの未修正の脆弱性は残っています。また同梱している OpenSSL 1.1.1w もアップストリームのサポートが終了しています。8.2 以降への移行までのつなぎとして使ってください。
- 脆弱性スキャナが修正済みと判定するかどうかは、スキャナ側のデータ次第です。このイメージの PHP は Wolfi の `php-*` パッケージではなく独自パッケージ `php-hotfix` なので、パッチ適用済みかどうかは SBOM とイメージの annotation で確認してください。
- 拡張モジュールは最小構成です（mbstring, openssl, curl, zlib, mysqli/pdo_mysql, pdo_sqlite, bcmath, sockets, pcntl など。8.5 は OPcache 内蔵、8.4 以前は opcache.so をビルドするが既定では無効）。必要に応じて `melange.tmpl.yaml` の configure を編集してください。
