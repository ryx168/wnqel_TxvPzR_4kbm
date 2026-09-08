#!/usr/bin/env bash
# Save the session's state back to object storage, then export the site as
# static files and publish it.
#
#   wp-save.sh            -> save + export + publish
#   wp-save.sh autosave   -> save state only (called every 5 minutes)
#   wp-save.sh true       -> save + export, but DO NOT publish (export_only)
set -euo pipefail

MODE="${1:-}"
WORK=/tmp/wp
OUT=/tmp/export
STAMP=$(date -u +%Y%m%d-%H%M%S)

# ---------------------------------------------------------------- save state
echo "::group::Save state"
mysqldump -uroot -proot --single-transaction --quick --default-character-set=utf8mb4 wp \
  | gzip -9 > /tmp/db.sql.gz
size=$(stat -c%s /tmp/db.sql.gz)
echo "  database dump: ${size} bytes"
# A dump that lost the posts table would otherwise overwrite a good backup.
# grep -c not -q: -q exits on the first match, gzip takes SIGPIPE, and
# pipefail then reports the whole pipeline as failed.
posts=$(zcat /tmp/db.sql.gz | grep -c "CREATE TABLE .wp_posts." || true)
if [ "${posts:-0}" -lt 1 ]; then
  echo "REFUSING to save: the dump has no wp_posts table"
  exit 1
fi
echo "  wp_posts present in dump: yes"
r2put() {  # r2put <file> <key>
  curl -sSf -m 900 -X PUT -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"     -H "Content-Type: application/gzip" --data-binary @"$1"     "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/r2/buckets/$STATE_BUCKET/objects/$2"     -o /dev/null
}
r2put /tmp/db.sql.gz db-latest.sql.gz
r2put /tmp/db.sql.gz "history/${STAMP}-db.sql.gz"

tar czf /tmp/wp-content.tar.gz -C "$WORK" \
  --exclude='wp-content/cache' --exclude='wp-content/upgrade' \
  --exclude='wp-content/upgrade-temp-backup' wp-content
r2put /tmp/wp-content.tar.gz wp-content.tar.gz
echo "  state saved"
echo "::endgroup::"

[ "$MODE" = "autosave" ] && { echo "autosave only - not exporting"; exit 0; }

# --------------------------------------------------------------- export site
echo "::group::Export static site"
rm -rf "$OUT"; mkdir -p "$OUT"

# The PHP server started in an earlier workflow step does NOT reliably survive
# into this one - each step gets its own session. Start our own if it is gone.
if ! curl -sf -o /dev/null -m 5 -H "Host: ${SITE_HOST}" http://127.0.0.1:8080/ ; then
  echo "  php server not answering - starting one for the export"
  cd "$WORK"
  PHP_CLI_SERVER_WORKERS=6 setsid nohup php -S 0.0.0.0:8080 -t "$WORK" > /tmp/php-export.log 2>&1 < /dev/null &
  for i in $(seq 1 20); do
    curl -sf -o /dev/null -m 3 -H "Host: ${SITE_HOST}" http://127.0.0.1:8080/ && break
    sleep 1
  done
  cd - >/dev/null
fi
code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 -H "Host: ${SITE_HOST}" http://127.0.0.1:8080/ || true)
echo "  php server responds: ${code}"
# Point the live hostname at this runner so the crawl produces real URLs.
grep -q " ${SITE_HOST}\$" /etc/hosts || echo "127.0.0.1 ${SITE_HOST}" | sudo tee -a /etc/hosts >/dev/null

# WordPress canonicalises every request to WP_HOME. While that is https, the
# crawler is 301'd to port 443 on this runner, where nothing listens, and every
# fetch fails with "Connection refused". Point WP at the http export URL for
# the duration of the crawl; the state was already saved above, and the runner
# is thrown away afterwards. Published URLs are rewritten back below.
sed -i "s#define('WP_HOME','https://${SITE_HOST}');#define('WP_HOME','http://${SITE_HOST}:8080');#" "$WORK/wp-config.php"
sed -i "s#define('WP_SITEURL','https://${SITE_HOST}');#define('WP_SITEURL','http://${SITE_HOST}:8080');#" "$WORK/wp-config.php"
pkill -f "php -S 0.0.0.0:8080" || true
sleep 2
cd "$WORK"
PHP_CLI_SERVER_WORKERS=6 setsid nohup php -S 0.0.0.0:8080 -t "$WORK" > /tmp/php-export.log 2>&1 < /dev/null &
cd - >/dev/null
for i in $(seq 1 20); do
  c=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://${SITE_HOST}:8080/" || true)
  [ "$c" = "200" ] && break
  sleep 1
done
echo "  export URL responds: $(curl -s -o /dev/null -w '%{http_code}' -m 8 "http://${SITE_HOST}:8080/" || true) (200 expected)"

# Must crawl over http: with WP_HOME set to https, WordPress 301s every
# request to a port nothing is listening on.
wget --mirror --page-requisites --adjust-extension --convert-links \
     --no-parent --restrict-file-names=windows --no-verbose \
     --execute robots=off --tries=2 --timeout=25 \
     --reject-regex '(wp-admin|wp-login|xmlrpc|wp-json|/feed|\?)' \
     --directory-prefix "$OUT" --no-host-directories \
     "http://${SITE_HOST}:8080/" || true

pages=$(find "$OUT" -name '*.html' | wc -l)
echo "  exported ${pages} html pages, $(find "$OUT" -type f | wc -l) files total"

# Guard 1: a broken export must never replace a working site.
if [ "$pages" -lt 5 ]; then
  echo "REFUSING to publish: only ${pages} pages exported"
  exit 1
fi
# Guard 2: wget saves 404 pages under the asset's name when a resource is
# missing, and --convert-links then rewires the site to those stubs. The page
# count alone does not catch it.
if find "$OUT" -type f \( -name '*.jpg.html' -o -name '*.png.html' -o -name '*.gif.html' \
        -o -name '*.css.html' -o -name '*.js.html' \) | grep -q .; then
  echo "REFUSING to publish: the export contains 404 stubs named as assets"
  find "$OUT" -type f -name '*.*.html' | head -5
  exit 1
fi

# The crawl records the runner's port; the published site must not.
grep -rl ":8080" "$OUT" --include='*.html' --include='*.css' --include='*.js' 2>/dev/null \
  | xargs -r sed -i "s#http://${SITE_HOST}:8080#https://${SITE_HOST}#g; s#${SITE_HOST}:8080#${SITE_HOST}#g"
echo "::endgroup::"

if [ "$MODE" = "true" ]; then
  echo "export_only - not publishing"
  exit 0
fi

# -------------------------------------------------------------------- publish
echo "::group::Publish"
npm install -g wrangler@3 >/dev/null 2>&1
npx wrangler pages deploy "$OUT" --project-name="$PAGES_PROJECT" --branch=main --commit-dirty=true
echo "::endgroup::"
