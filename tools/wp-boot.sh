#!/usr/bin/env bash
# Restore the site's state from object storage and start WordPress on the runner.
set -euo pipefail

WORK=/tmp/wp
STATE=/tmp/state
mkdir -p "$WORK" "$STATE"

echo "::group::Restore state"
r2get() {  # r2get <key> <dest>
  curl -sSf -m 900 -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"     "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/r2/buckets/$STATE_BUCKET/objects/$1"     -o "$2"
}
r2get db-latest.sql.gz "$STATE/db.sql.gz"
r2get wp-content.tar.gz "$STATE/wp-content.tar.gz"
ls -lh "$STATE"
echo "::endgroup::"

echo "::group::Database"
sudo systemctl start mysql
# Wait for it rather than assuming; a cold runner is not instant.
for i in $(seq 1 30); do
  mysqladmin -uroot -proot ping >/dev/null 2>&1 && break
  sleep 1
done
mysql -uroot -proot -e "CREATE DATABASE IF NOT EXISTS wp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
gunzip -c "$STATE/db.sql.gz" | mysql -uroot -proot wp
echo "  tables restored: $(mysql -N -uroot -proot -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema="wp";')"
echo "::endgroup::"

echo "::group::WordPress core"
cd "$WORK"
# The origin's core is old; run a current one unless a version is pinned.
if [ -n "${WP_VERSION:-}" ]; then
  curl -sSL "https://wordpress.org/wordpress-${WP_VERSION}.tar.gz" -o wp.tar.gz
else
  curl -sSL "https://wordpress.org/latest.tar.gz" -o wp.tar.gz
fi
tar xzf wp.tar.gz --strip-components=1
rm -rf wp-content
tar xzf "$STATE/wp-content.tar.gz"
echo "  plugins: $(ls wp-content/plugins 2>/dev/null | tr '\n' ' ')"
echo "  themes : $(ls wp-content/themes 2>/dev/null | tr '\n' ' ')"
echo "::endgroup::"

echo "::group::wp-config"
# WP_HOME/WP_SITEURL are the LIVE host so the login cookie lands on the domain
# the browser is actually talking to, and admin links point there too.
cat > wp-config.php <<PHP
<?php
define('DB_NAME','wp');
define('DB_USER','root');
define('DB_PASSWORD','root');
define('DB_HOST','127.0.0.1');
define('DB_CHARSET','utf8mb4');
\$table_prefix = 'wp_';

// Behind Cloudflare the request arrives as http; without this wp-admin
// redirect-loops trying to force https.
if (!empty(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    \$_SERVER['HTTPS'] = 'on';
}
define('WP_HOME','https://${SITE_HOST}');
define('WP_SITEURL','https://${SITE_HOST}');

// A runner is disposable: never let the editor write code into it.
define('DISALLOW_FILE_EDIT', true);
define('DISALLOW_FILE_MODS', true);
define('AUTOMATIC_UPDATER_DISABLED', true);
define('WP_AUTO_UPDATE_CORE', false);
define('WP_DEBUG', false);
if (!defined('ABSPATH')) define('ABSPATH', __DIR__ . '/');
require_once ABSPATH . 'wp-settings.php';
PHP
echo "  wp-config written"
echo "::endgroup::"

echo "::group::Mail"
# The runner has no MTA, so wp_mail() fails outright without this - which
# breaks "lost your password" at exactly the wrong moment.
mkdir -p wp-content/mu-plugins
cat > wp-content/mu-plugins/00-smtp.php <<'PHP'
<?php
add_action('phpmailer_init', function ($m) {
    if (!getenv('SMTP_HOST')) { return; }
    $m->isSMTP();
    $m->Host       = getenv('SMTP_HOST');
    $m->Port       = (int) (getenv('SMTP_PORT') ?: 587);
    $m->SMTPAuth   = true;
    $m->Username   = getenv('SMTP_USER');
    $m->Password   = getenv('SMTP_PASS');
    $m->SMTPSecure = 'tls';
    $from = getenv('SMTP_FROM');
    if ($from) { $m->setFrom($from, get_bloginfo('name'), false); }
});
PHP
# WP Rocket caches to disk; on a disposable runner that is pure noise and can
# serve stale pages into the export.
if [ -d wp-content/plugins/wp-rocket ]; then
  mv wp-content/plugins/wp-rocket /tmp/wp-rocket-parked
  echo "  wp-rocket parked for the session"
fi
echo "::endgroup::"

echo "::group::Start PHP"
# Without PHP_CLI_SERVER_WORKERS the built-in server is single-threaded and
# wp-admin deadlocks waiting on its own sub-requests.
# setsid so the server survives into the next workflow step.
cd "$WORK"
PHP_CLI_SERVER_WORKERS=6 setsid nohup php -S 0.0.0.0:8080 -t "$WORK" > /tmp/php.log 2>&1 < /dev/null &
sleep 4
# Probe with the real Host header: a bare 127.0.0.1 request correctly 301s
# because WordPress canonicalises to WP_HOME.
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${SITE_HOST}" http://127.0.0.1:8080/ || true)
echo "  homepage responds: $code"
admin=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${SITE_HOST}" http://127.0.0.1:8080/wp-admin/ || true)
echo "  wp-admin responds: $admin (302 to login is correct)"

# The runner always installs CURRENT WordPress core, while the database comes
# from whichever version the site was last saved at. WordPress then blocks
# wp-admin with "Database Update Required" until somebody clicks a button - so
# run the migration here rather than making the editor deal with it. It is a
# no-op when the schema already matches.
up="http://127.0.0.1:8080/wp-admin/upgrade.php?step=1"
curl -s -H "Host: ${SITE_HOST}" "$up" > /tmp/upgrade.html 2>/dev/null || true
schema=$({ grep -oiE "update complete|no update required" /tmp/upgrade.html 2>/dev/null || true; } | head -1)
echo "  database schema: ${schema:-could not tell}"

tail -5 /tmp/php.log || true
echo "::endgroup::"
