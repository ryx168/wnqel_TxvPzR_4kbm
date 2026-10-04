#!/usr/bin/env bash
# Open the tunnel, hold the editing session, autosave, and stop when idle.
# Alongside the admin tunnel this also runs a web FILE MANAGER (filebrowser)
# over a throwaway cloudflared quick tunnel, rooted at wp-content, so the hub's
# 檔案 button can edit theme/plugin/upload files directly. Its URL is published
# to the files-session branch for the hub to read. Edits persist through the
# normal save step (wp-save.sh tars wp-content back to R2 and re-exports).
set -euo pipefail

IDLE_MIN="${1:-15}"
WORK=/tmp/wp
FB_ROOT="$WORK/wp-content"   # the editable part; WP core is reinstalled each session

echo "::group::Tunnel"
curl -sSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cloudflared
chmod +x /tmp/cloudflared
setsid nohup /tmp/cloudflared tunnel --no-autoupdate run --token "$TUNNEL_TOKEN" > /tmp/tunnel.log 2>&1 < /dev/null &
for i in $(seq 1 30); do
  grep -qi "Registered tunnel connection" /tmp/tunnel.log && break
  sleep 2
done
grep -ci "Registered tunnel connection" /tmp/tunnel.log | sed 's/^/  tunnel connections: /'
echo "::endgroup::"

# ---- File manager (filebrowser) over a quick tunnel -----------------------
# Best-effort and fully isolated: a failure here must never take down the admin
# session, so the whole block runs with set -e disabled (`{ ... } || true`).
echo "::group::File manager"
FB_URL=""
{
  mkdir -p "$FB_ROOT"
  # Pin classic filebrowser v2.27.0 (get.sh now installs a fork whose noauth is broken).
  curl -fsSL --retry 6 --retry-all-errors --retry-delay 3 -o /tmp/fb.tar.gz \
    https://github.com/filebrowser/filebrowser/releases/download/v2.27.0/linux-amd64-filebrowser.tar.gz
  tar xzf /tmp/fb.tar.gz -C /tmp filebrowser 2>/dev/null
  sudo mv /tmp/filebrowser /usr/local/bin/filebrowser && sudo chmod +x /usr/local/bin/filebrowser
  FB_DB=/tmp/filebrowser.db
  filebrowser config init -d "$FB_DB" --root "$FB_ROOT" >/tmp/fb-init.log 2>&1
  # Per-domain login: if the owner set a username+password for this domain in the
  # hub, require it; else stay no-login (the random tunnel URL still gates it).
  FM_DOM="${SITE_HOST#www.}"
  FM_USER=""; FM_PW=""
  if [ -n "${FMAUTH_KEY:-}" ] && [ -n "$FM_DOM" ]; then
    creds=$(curl -s -m 10 -H "authorization: Bearer $FMAUTH_KEY" "https://conanhub.supere.ca/fmauth/$FM_DOM" 2>/dev/null || echo '{}')
    FM_USER=$(printf '%s' "$creds" | python3 -c "import sys,json;print(json.load(sys.stdin).get('u',''))" 2>/dev/null || true)
    FM_PW=$(printf '%s' "$creds" | python3 -c "import sys,json;print(json.load(sys.stdin).get('p',''))" 2>/dev/null || true)
  fi
  if [ -n "$FM_USER" ] && [ -n "$FM_PW" ]; then
    filebrowser config set -d "$FB_DB" --auth.method=json >>/tmp/fb-init.log 2>&1
    filebrowser users add "$FM_USER" "$FM_PW" --perm.admin -d "$FB_DB" >/tmp/fb-user.log 2>&1 \
      || filebrowser users update "$FM_USER" --password "$FM_PW" -d "$FB_DB" >>/tmp/fb-user.log 2>&1
    { [ "$FM_USER" != "admin" ] && filebrowser users rm admin -d "$FB_DB" >/dev/null 2>&1; } || true
    echo "  web login: password required (user $FM_USER)"
  else
    filebrowser config set -d "$FB_DB" --auth.method=noauth >>/tmp/fb-init.log 2>&1
    filebrowser users add -d "$FB_DB" admin "${FB_PASS:-changeme}" --perm.admin >/tmp/fb-user.log 2>&1 || true
    echo "  web login: none (no per-domain credentials set)"
  fi
  setsid nohup filebrowser -d "$FB_DB" -a 127.0.0.1 -p 8090 --root "$FB_ROOT" >/tmp/filebrowser.log 2>&1 < /dev/null &
  # Quick tunnel (anonymous trycloudflare), separate from the named admin tunnel.
  setsid nohup /tmp/cloudflared tunnel --url http://127.0.0.1:8090 --no-autoupdate >/tmp/fbcf.log 2>&1 < /dev/null &
  for i in $(seq 1 20); do
    sleep 2
    FB_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/fbcf.log | head -1 || true)
    [ -n "$FB_URL" ] && break
  done
} || true
echo "  file manager: ${FB_URL:-unavailable}"
echo "::endgroup::"

# Publish the file-manager URL for the hub on branch files-session (file files.json).
publish_files() {
  [ -n "$FB_URL" ] || { echo "  no file-manager URL to publish"; return 0; }
  local json blob tree commit
  json=$(printf '{"domain":"%s","url":"%s","since":"%s"}\n' "${SITE_HOST:-}" "$FB_URL" "$(date -u +%FT%TZ)")
  blob=$(printf '%s' "$json" | git hash-object -w --stdin)
  tree=$(printf '100644 blob %s\tfiles.json\n' "$blob" | git mktree)
  commit=$(git -c user.email=superesolutions@gmail.com -c user.name="conan editor" commit-tree "$tree" -m "files $(date -u +%FT%TZ)")
  git push -q -f origin "$commit:refs/heads/files-session" 2>/dev/null && echo "  file session published" || echo "  file session publish failed (check contents:write)"
}
publish_files

echo "session open; idle stop after ${IDLE_MIN} min"

# Activity is measured from the PHP access log: an open wp-admin tab
# heartbeats roughly once a minute, so a real session stays alive on its own.
# Activity means a PERSON in the admin: anything under /wp-admin/ (the open
# editor's heartbeat included) or a login POST. Not the size of the log - that
# counts scanners probing /wp-json and WordPress cron, and a session kept alive
# by those never ends. File-manager traffic counts too, so a person editing
# files (but not in wp-admin) does not get timed out.
admin_hits() { grep -cE '\]: ((GET|POST|HEAD) /wp-admin/|POST /wp-login\.php)' /tmp/php.log 2>/dev/null || true; }
fb_hits()    { grep -cE '"(GET|POST|PUT|PATCH|DELETE) '                      /tmp/filebrowser.log 2>/dev/null || true; }
last_hits=$(admin_hits)
last_fb=$(fb_hits)
idle_secs=0
elapsed=0
autosave_every=300      # 5 minutes - a runner can die with no usable hook,
                        # so never rely on saving only at shutdown
since_save=0

while true; do
  sleep 30
  elapsed=$((elapsed + 30))
  since_save=$((since_save + 30))

  hits=$(admin_hits)
  fbh=$(fb_hits)
  if [ "${hits:-0}" -ne "${last_hits:-0}" ] || [ "${fbh:-0}" -ne "${last_fb:-0}" ]; then
    idle_secs=0
    last_hits=$hits
    last_fb=$fbh
  else
    idle_secs=$((idle_secs + 30))
  fi

  if [ "$since_save" -ge "$autosave_every" ]; then
    bash tools/wp-save.sh autosave || echo "  autosave failed (continuing)"
    echo "autosaved (periodic) after ${elapsed}s"
    since_save=0
  fi

  if [ "$idle_secs" -ge $((IDLE_MIN * 60)) ]; then
    echo "idle for ${IDLE_MIN} min - closing the session"
    break
  fi
done

# Clear the published file-manager URL so the hub stops showing a dead tunnel.
git push -q origin --delete files-session 2>/dev/null || true
