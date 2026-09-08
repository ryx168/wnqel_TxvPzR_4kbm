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

# Pages linked only as https://<apex>/... are a different host to wget, so the
# first pass silently misses them (trupack.ca links its contact page that way).
# Read the links back out of what we did fetch and pull anything still absent.
echo "  looking for pages the crawl missed"
apex="${SITE_HOST#www.}"
for round in 1 2; do
  grep -rhoE 'href="https?://(www\.)?'"${apex//./\.}"'/[^"#?]*"' "$OUT" --include='*.html' 2>/dev/null     | sed -E 's#^href="https?://[^/]+##; s#"$##' | sort -u > /tmp/paths || true
  added=0
  while read -r path; do
    [ -z "$path" ] && continue
    case "$path" in
      */wp-json/*|*/feed/*|*/wp-admin/*|*wp-content/*|*wp-includes/*) continue;;
      *.css|*.js|*.png|*.jpg|*.jpeg|*.gif|*.webp|*.svg|*.ico|*.xml) continue;;
    esac
    target="$OUT${path%/}/index.html"
    [ "$path" = "/" ] && target="$OUT/index.html"
    if [ ! -f "$target" ]; then
      echo "    recovering: $path"
      wget --page-requisites --adjust-extension --convert-links --no-verbose            --execute robots=off --tries=2 --timeout=25            --directory-prefix "$OUT" --no-host-directories            "http://${SITE_HOST}:8080${path}" >/dev/null 2>&1 || true
      added=$((added+1))
    fi
  done < /tmp/paths
  echo "    round ${round}: recovered ${added} page(s)"
  [ "$added" -eq 0 ] && break
done

pages=$(find "$OUT" -name '*.html' | wc -l)
echo "  exported ${pages} html pages, $(find "$OUT" -type f | wc -l) files total"
find "$OUT" -name '*.html' | sed "s#$OUT##" | sort | sed 's/^/    page: /'

# Guard 1: a broken export must never replace a working site. MIN_PAGES is a
# per-site floor - trupack.ca genuinely has only four pages, so a fixed 5 was
# wrong. Set it to just below the real page count for each site.
MIN_PAGES="${MIN_PAGES:-3}"
if [ "$pages" -lt "$MIN_PAGES" ]; then
  echo "REFUSING to publish: only ${pages} pages exported (floor ${MIN_PAGES})"
  exit 1
fi
# Guard 2: wget saves 404 pages under the asset's name when a resource is
# missing, and --convert-links then rewires the site to those stubs. The page
# count alone does not catch it.
# grep -q exits on its first match, the find upstream takes SIGPIPE, and under
# pipefail the whole condition reads as false - so this guard never fired.
stubs=$(find "$OUT" -type f \( -name '*.jpg.html' -o -name '*.png.html' -o -name '*.gif.html' \
        -o -name '*.css.html' -o -name '*.js.html' \) | head -5)
if [ -n "$stubs" ]; then
  echo "REFUSING to publish: the export contains 404 stubs named as assets"
  echo "$stubs"
  exit 1
fi

# The crawl records the runner's port; the published site must not.
grep -rl ":8080" "$OUT" --include='*.html' --include='*.css' --include='*.js' \
     > /tmp/hits8080 2>/dev/null || true
if [ -s /tmp/hits8080 ]; then
  xargs -r sed -i "s#http://${SITE_HOST}:8080#https://${SITE_HOST}#g; s#${SITE_HOST}:8080#${SITE_HOST}#g" < /tmp/hits8080
fi

# wget --adjust-extension saves "main.css?ver=9" on disk as "main.css%3Fver=9.css",
# and --convert-links then rewires pages to that encoded name. The FIRST page
# crawled keeps absolute URLs, so the homepage looks perfect while every
# recovered inner page silently loads no CSS at all. Put the references back to
# clean root-relative paths, and drop the duplicate mangled files.
# -type f, and [?] not ?, because ? is a glob wildcard in find - '*?*'
# matches every name there is, directories included.
find "$OUT" -depth -type f \( -name '*%3F*' -o -name '*[?]*' \) -print0 2>/dev/null > /tmp/mangled || true
if [ -s /tmp/mangled ]; then
  while IFS= read -r -d '' f; do
    t="${f%%'%3F'*}"; t="${t%%'?'*}"
    if [ -e "$t" ]; then rm -f "$f"; else mv -f "$f" "$t"; fi
  done < /tmp/mangled
  echo "  removed $(tr -dc '\0' < /tmp/mangled | wc -c) query-mangled duplicate file(s)"
fi
grep -rlZ -F "%3F" "$OUT" --include='*.html' --include='*.css' \
     > /tmp/hitsq 2>/dev/null || true
grep -rlZ -E "(href|src)=[\"']((\.\./)+|)wp-(content|includes)/" "$OUT" \
     --include='*.html' >> /tmp/hitsq 2>/dev/null || true
if [ -s /tmp/hitsq ]; then
  # In a heredoc nothing needs shell escaping, which this expression is full of.
  cat > /tmp/unmangle.sed <<'SED'
s#(href|src)=(.)(\.\./)*(wp-(content|includes)/)#\1=\2/\4#g
s#%3F[^'")]*##g
SED
  xargs -0 -r sed -i -E -f /tmp/unmangle.sed < /tmp/hitsq
  left=$({ grep -rhoF "%3F" "$OUT" --include='*.html' 2>/dev/null || true; } | wc -l)
  echo "  query-mangled asset references repaired; remaining: ${left}"
fi

# Normalise internal links to SITE_HOST. The content links to the bare apex
# more often than to www, and a zone apex cannot be a CNAME - so those links
# would route through the old server on every click today, and break entirely
# once it is retired. Only www can point at Pages.
apex="${SITE_HOST#www.}"
if [ "$apex" != "$SITE_HOST" ]; then
  # Fixed-string grep, and xargs -0, because upload filenames can contain
  # spaces and the host contains dots that a regex would treat as wildcards.
  for scheme in http https; do
    grep -rlZ -F "${scheme}://${apex}/" "$OUT" \
         --include='*.html' --include='*.css' --include='*.js' --include='*.xml' \
         > /tmp/hits 2>/dev/null || true
    # A grep that matches nothing exits 1, and under pipefail that would kill
    # the whole publish silently - so collect first, then act.
    if [ -s /tmp/hits ]; then
      xargs -0 -r sed -i "s|${scheme}://${apex}/|https://${SITE_HOST}/|g" < /tmp/hits
    fi
  done
  # Success here means zero matches, and a grep that matches nothing exits 1.
  left=$({ grep -rhoF "//${apex}/" "$OUT" --include='*.html' 2>/dev/null || true; } | wc -l)
  echo "  internal links normalised to ${SITE_HOST}; apex references left: ${left}"
fi

# wget crawls the PHP built-in server concurrently and it refuses connections
# under burst - the log says "Connection refused" and a few assets are simply
# absent, with nothing else to show for it. They are ordinary files sitting in
# the WordPress tree, so copy them across rather than trusting another HTTP round.
python3 "$(dirname "$0")/check-assets.py" "$OUT" "$SITE_HOST" --list > /tmp/missing.txt || true
if [ -s /tmp/missing.txt ]; then
  recovered=0; absent=0
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    src="$WORK/${rel#/}"
    if [ -f "$src" ]; then
      mkdir -p "$OUT$(dirname "$rel")"
      cp -f "$src" "$OUT$rel"
      recovered=$((recovered+1))
    else
      absent=$((absent+1))
      echo "    not in the WordPress tree either: $rel"
    fi
  done < /tmp/missing.txt
  echo "  copied ${recovered} asset(s) the crawl missed; ${absent} genuinely absent"
fi

# Guard 3: every local asset a page references must exist in the export.
# Counting pages, diffing text, even counting stylesheet LINKS all called a
# broken export healthy - the links were there and pointed at nothing.
python3 "$(dirname "$0")/check-assets.py" "$OUT" "$SITE_HOST"

echo "::endgroup::"

if [ "$MODE" = "true" ]; then
  echo "export_only - not publishing"
  exit 0
fi

# -------------------------------------------------------------------- publish
echo "::group::Publish"
# The Pages Function that proxies /wp-admin to the editing tunnel must ship
# with the site: Pages has no Worker in front of it.
if [ -f public/_worker.js ]; then
  cp public/_worker.js "$OUT/_worker.js"
  echo "  included _worker.js ($(stat -c%s "$OUT/_worker.js") bytes)"
else
  echo "  WARNING: public/_worker.js missing - the admin proxy will not be deployed"
fi
npm install -g wrangler@3 >/dev/null 2>&1
npx wrangler pages deploy "$OUT" --project-name="$PAGES_PROJECT" --branch=main --commit-dirty=true
echo "::endgroup::"
