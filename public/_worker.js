// Pages Function for the static site + the on-demand WordPress admin.
//
// Static pages come from Pages itself (env.ASSETS). The admin paths are
// proxied to the editing tunnel, which only exists while a session is running.
// Pages has no Worker in front of it, so this file does the job the Worker
// does on the other sites in this estate.

const ADMIN = /^\/(wp-admin|wp-login\.php|wp-signup\.php|wp-cron\.php|wp-json|wp-includes)(\/|$|\?)/i;

// wp-content is deliberately NOT proxied: theme and uploads are already in the
// published site, and the public pages need them whether or not a session runs.

function page(title, body, status = 200) {
  return new Response(
    `<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<style>
 body{margin:0;font:16px/1.6 -apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#1e2430;background:#f6f7f9}
 .box{max-width:560px;margin:16vh auto;padding:34px 38px;background:#fff;border-radius:10px;
      box-shadow:0 1px 3px rgba(0,0,0,.08)}
 h1{font-size:21px;margin:0 0 12px}
 p{margin:0 0 18px;color:#48505e}
 button{font:inherit;padding:11px 20px;border:0;border-radius:7px;background:#2b6cb0;color:#fff;cursor:pointer}
 button:hover{background:#245a94}
 .spin{display:inline-block;width:15px;height:15px;border:2px solid #cbd5e0;border-top-color:#2b6cb0;
       border-radius:50%;animation:s .8s linear infinite;vertical-align:-2px;margin-right:8px}
 @keyframes s{to{transform:rotate(360deg)}}
</style>
<div class="box">${body}</div>`,
    { status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } }
  );
}

// A session costs a runner and puts a login on the internet, so only start one
// for something that looks like a person driving a browser. This is mitigation,
// not authentication - it is why starting requires a POST from the button.
function looksLikeAPerson(request) {
  const ua = (request.headers.get("user-agent") || "").toLowerCase();
  const accept = request.headers.get("accept") || "";
  if (!ua || !accept.includes("text/html")) return false;
  return !/(bot|crawl|spider|slurp|curl|wget|python|go-http|java|libwww|scan|headless|okhttp)/.test(ua);
}

async function sessionRunning(env) {
  if (!env.GH_TOKEN) return false;
  const url = `https://api.github.com/repos/${env.GH_OWNER}/${env.GH_REPO}/actions/workflows/${env.GH_WORKFLOW}/runs?per_page=5`;
  const r = await fetch(url, {
    headers: {
      authorization: `Bearer ${env.GH_TOKEN}`,
      accept: "application/vnd.github+json",
      "user-agent": "site-editor",
    },
  });
  if (!r.ok) return false;
  const d = await r.json();
  return (d.workflow_runs || []).some(
    (x) => x.status === "queued" || x.status === "in_progress"
  );
}

async function startSession(env) {
  const url = `https://api.github.com/repos/${env.GH_OWNER}/${env.GH_REPO}/actions/workflows/${env.GH_WORKFLOW}/dispatches`;
  return fetch(url, {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.GH_TOKEN}`,
      accept: "application/vnd.github+json",
      "content-type": "application/json",
      "user-agent": "site-editor",
    },
    body: JSON.stringify({
      ref: "main",
      inputs: { tunnel: true, idle_minutes: env.IDLE_MINUTES || "15", export_only: false },
    }),
  });
}

const NOT_RUNNING = `
  <h1>The editor is not running</h1>
  <p>WordPress is started only while you are editing, so it takes about a
     minute to come up. Start it, then sign in as usual.</p>
  <form method="POST" action="/__editor-start">
    <button type="submit">Start the editor</button>
  </form>`;

const WAITING = `
  <h1><span class="spin"></span>Starting the editor</h1>
  <p>This usually takes a minute or two. The login page will open by itself.</p>
  <script>
    (function poll(){
      fetch('/__editor-status',{cache:'no-store'})
        .then(r=>r.json())
        .then(d=>{ if(d.ready){ location.href='/wp-admin/'; } else { setTimeout(poll,5000); } })
        .catch(()=>setTimeout(poll,5000));
    })();
  </script>`;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // Has WordPress answered yet? Used by the waiting page.
    if (path === "/__editor-status") {
      let ready = false;
      try {
        const probe = await fetch(`https://${env.EDIT_HOST}/wp-login.php`, {
          method: "HEAD",
          redirect: "manual",
        });
        ready = probe.status < 500;
      } catch { ready = false; }
      return new Response(JSON.stringify({ ready }), {
        headers: { "content-type": "application/json", "cache-control": "no-store" },
      });
    }

    // The ONLY path that spends a runner, and only on a POST from the button.
    // An unauthenticated GET must never be treated as consent: scanners walk
    // /wp-admin constantly and would otherwise keep a login permanently online.
    if (path === "/__editor-start") {
      if (request.method !== "POST") return Response.redirect(`${url.origin}/wp-admin/`, 303);
      if (looksLikeAPerson(request) && env.GH_TOKEN) {
        if (!(await sessionRunning(env))) await startSession(env);
      }
      return page("Starting the editor", WAITING);
    }

    if (ADMIN.test(path)) {
      if (!env.EDIT_HOST) return page("Editing is not configured", NOT_RUNNING, 503);
      const target = new URL(request.url);
      target.hostname = env.EDIT_HOST;
      target.protocol = "https:";
      target.port = "";
      const headers = new Headers(request.headers);
      // WordPress builds its links from this, and the browser is on the live
      // host, not the tunnel - so keep the original Host.
      headers.set("x-forwarded-proto", "https");
      let upstream;
      try {
        upstream = await fetch(new Request(target, {
          method: request.method,
          headers,
          body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
          redirect: "manual",
        }));
      } catch {
        return page("The editor is not running", NOT_RUNNING, 503);
      }
      // 530/502 from the edge means the tunnel has no listener: no session.
      if (upstream.status === 530 || upstream.status === 502 || upstream.status === 523) {
        return page("The editor is not running", NOT_RUNNING, 503);
      }
      const out = new Headers(upstream.headers);
      out.delete("content-security-policy");
      out.delete("content-security-policy-report-only");
      return new Response(upstream.body, { status: upstream.status, headers: out });
    }

    // Everything else is the published static site.
    return env.ASSETS.fetch(request);
  },
};
