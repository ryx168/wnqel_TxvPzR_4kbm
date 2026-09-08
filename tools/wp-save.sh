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
if ! zcat /tmp/db.sql.gz | grep -q "CREATE TABLE \`wp_posts\`"; then
  echo "REFUSING to save: the dump has no wp_posts table"
  exit 1
fi
aws s3 cp /tmp/db.sql.gz "s3://$STATE_BUCKET/db-latest.sql.gz" --endpoint-url "$R2_ENDPOINT" --no-progress
aws s3 cp /tmp/db.sql.gz "s3://$STATE_BUCKET/history/${STAMP}-db.sql.gz" --endpoint-url "$R2_ENDPOINT" --no-progress

tar czf /tmp/wp-content.tar.gz -C "$WORK" \
  --exclude='wp-content/cache' --exclude='wp-content/upgrade' \
  --exclude='wp-content/upgrade-temp-backup' wp-content
aws s3 cp /tmp/wp-content.tar.gz "s3://$STATE_BUCKET/wp-content.tar.gz" --endpoint-url "$R2_ENDPOINT" --no-progress
echo "  state saved"
echo "::endgroup::"

[ "$MODE" = "autosave" ] && { echo "autosave only - not exporting"; exit 0; }

# --------------------------------------------------------------- export site
echo "::group::Export static site"
rm -rf "$OUT"; mkdir -p "$OUT"
# Point the live hostname at this runner so the crawl produces real URLs.
echo "127.0.0.1 ${SITE_HOST}" | sudo tee -a /etc/hosts >/dev/null

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
