package home

let C = cluster

// openbao-ca-page — distributes the OpenBao root CA so household
// devices can trust certs issued by the `openbao-example-internal`
// ClusterIssuer (covers every *.example.internal hostname served from
// this cluster).
//
// Served plain HTTP at http://ca.example.internal on the LAN. No TLS,
// deliberately:
//   - The asset on offer IS the trust anchor. Signing the page with a
//     cert issued from the same PKI would be circular trust.
//   - Routing through Let's Encrypt on a example.com hostname would
//     touch Cloudflare for what is a LAN-only artifact.
//   - The cert PEM is a public-by-design artifact. Integrity is
//     verified by the SHA-256 digest the page displays alongside the
//     download link (plus the standard `shasum` recipe per OS).
//
// How the pod assembles its content (single init container, busybox):
//   1. Copy ConfigMap files (index.html) into shared emptyDir.
//   2. wget OpenBao's unauthenticated PKI PEM endpoint at
//      /v1/pki_home/ca/pem and save as openbao-root.crt.
//   3. Compute SHA-256 of the cert and save as openbao-root.sha256.
//   4. nginx-unprivileged serves /usr/share/nginx/html from the
//      shared emptyDir. Visitors see index.html; the page fetches
//      /openbao-root.sha256 client-side to render the digest.
//
// To refresh the served CA: kubectl rollout restart
// deployment/openbao-ca-page -n cert-distribution. Init re-fetches.
// Root CA validity is 10 years; rotations are rare.
let _openbaoCAPageImage = "nginxinc/nginx-unprivileged:1.27-alpine@sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0"
let _busyboxImage = "busybox:1.36.1@sha256:768e5c6f5cb6db0794eec98dc7a967f40631746c32232b78a3105fb946f3ab83"

// HTML page served at http://ca.example.internal. Kept inline so the
// content lives next to the deployment that serves it. Layout: title,
// download + digest box, per-OS install commands, post-install verify.
let _openbaoCAIndexHTML = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>example.internal trust setup</title>
<style>
  :root { color-scheme: light dark; --bg:#fafafa; --fg:#1a1a1a; --accent:#3b82f6; --card:#fff; --border:#e5e7eb; --code:#f3f4f6; }
  @media (prefers-color-scheme: dark) { :root { --bg:#0f172a; --fg:#e5e7eb; --card:#1e293b; --border:#334155; --code:#0b1220; } }
  * { box-sizing:border-box; }
  body { background:var(--bg); color:var(--fg); font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; margin:0; padding:2rem 1rem; }
  main { max-width:760px; margin:0 auto; }
  h1 { font-size:1.6rem; margin:0 0 0.5rem; }
  h2 { font-size:1.15rem; margin-top:2rem; border-bottom:1px solid var(--border); padding-bottom:0.35rem; }
  p.lede { color:#6b7280; margin:0 0 1.5rem; }
  .card { background:var(--card); border:1px solid var(--border); border-radius:8px; padding:1rem 1.25rem; margin:1rem 0; }
  a.btn { display:inline-block; background:var(--accent); color:#fff !important; padding:0.65rem 1.1rem; border-radius:6px; text-decoration:none; font-weight:600; }
  a.btn:hover { filter:brightness(1.1); }
  code, pre { background:var(--code); border-radius:4px; }
  code { padding:0.1rem 0.35rem; font-size:0.92em; }
  pre { padding:0.85rem 1rem; overflow-x:auto; font-size:0.88rem; }
  details { margin:0.6rem 0; }
  summary { cursor:pointer; font-weight:600; padding:0.35rem 0; }
  small { color:#6b7280; }
  .digest { font-family:ui-monospace,SFMono-Regular,monospace; word-break:break-all; }
</style>
</head>
<body>
<main>
  <h1>Trust the example.internal services</h1>
  <p class="lede">
    Services on this cluster that live under <code>*.example.internal</code> use
    TLS certs signed by a private root CA. Install that root cert once on
    each device and the browser warnings go away. This page is served
    plain HTTP on purpose — the asset itself is the trust anchor, so
    verifying via the SHA-256 digest below is the protection.
  </p>

  <h2>Install per platform</h2>

  <details open>
    <summary>macOS</summary>
    <p>Verifies the SHA-256 against the server-published digest before installing. Requires admin password:</p>
    <pre><code>curl -fsSL http://ca.example.internal/openbao-root.sha256 -o /tmp/openbao-root.sha256 &amp;&amp; \
curl -fsSL http://ca.example.internal/openbao-root.crt -o /tmp/openbao-example-root.crt &amp;&amp; \
echo "$(cat /tmp/openbao-root.sha256)  /tmp/openbao-example-root.crt" | shasum -a 256 -c - &amp;&amp; \
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain /tmp/openbao-example-root.crt</code></pre>
    <p>Restart browsers afterwards. To verify trust: <code>curl https://it-tools.example.internal</code> should succeed without <code>-k</code>.</p>
  </details>

  <details>
    <summary>iOS / iPadOS</summary>
    <ol>
      <li>Open <a href="/openbao-root.crt">/openbao-root.crt</a> in Safari.</li>
      <li>Tap <em>Allow</em> to download the profile.</li>
      <li>Open <em>Settings → General → VPN &amp; Device Management</em>, tap the downloaded profile, and check that the listed fingerprint matches the SHA-256 shown above.</li>
      <li>Tap <em>Install</em>.</li>
      <li>Open <em>Settings → General → About → Certificate Trust Settings</em>, toggle the Home Cluster Root CA on.</li>
    </ol>
  </details>

  <details>
    <summary>Windows</summary>
    <p>From an Administrator PowerShell — verifies SHA-256 then installs:</p>
    <pre><code>$tmp=$env:TEMP; $crtPath=Join-Path $tmp "openbao-root.crt"; Invoke-WebRequest "http://ca.example.internal/openbao-root.crt" -OutFile $crtPath; $expected=[System.Text.Encoding]::UTF8.GetString((Invoke-WebRequest "http://ca.example.internal/openbao-root.sha256").Content).Trim().ToLower(); $actual=(Get-FileHash $crtPath -Algorithm SHA256).Hash.ToLower(); if ($expected -ne $actual) { throw "SHA-256 mismatch: expected $expected, got $actual" }; certutil -addstore -f Root $crtPath</code></pre>
    <p>Restart browsers. Edge and Chrome use the system store; Firefox keeps its own (<em>Settings → Privacy &amp; Security → Certificates → View Certificates → Authorities → Import</em>).</p>
  </details>

  <details>
    <summary>Linux — Debian / Ubuntu</summary>
    <pre><code>curl -fsSL http://ca.example.internal/openbao-root.sha256 -o /tmp/openbao-root.sha256 &amp;&amp; \
curl -fsSL http://ca.example.internal/openbao-root.crt -o /tmp/openbao-example-root.crt &amp;&amp; \
echo "$(cat /tmp/openbao-root.sha256)  /tmp/openbao-example-root.crt" | sha256sum -c - &amp;&amp; \
sudo install -m 0644 /tmp/openbao-example-root.crt \
  /usr/local/share/ca-certificates/openbao-example-root.crt &amp;&amp; \
sudo update-ca-certificates</code></pre>
  </details>

  <details>
    <summary>Linux — Fedora / RHEL / Rocky</summary>
    <pre><code>curl -fsSL http://ca.example.internal/openbao-root.sha256 -o /tmp/openbao-root.sha256 &amp;&amp; \
curl -fsSL http://ca.example.internal/openbao-root.crt -o /tmp/openbao-example-root.crt &amp;&amp; \
echo "$(cat /tmp/openbao-root.sha256)  /tmp/openbao-example-root.crt" | sha256sum -c - &amp;&amp; \
sudo install -m 0644 /tmp/openbao-example-root.crt \
  /etc/pki/ca-trust/source/anchors/openbao-example-root.crt &amp;&amp; \
sudo update-ca-trust extract</code></pre>
  </details>

  <details>
    <summary>Linux — Arch / Manjaro</summary>
    <pre><code>curl -fsSL http://ca.example.internal/openbao-root.sha256 -o /tmp/openbao-root.sha256 &amp;&amp; \
curl -fsSL http://ca.example.internal/openbao-root.crt -o /tmp/openbao-example-root.crt &amp;&amp; \
echo "$(cat /tmp/openbao-root.sha256)  /tmp/openbao-example-root.crt" | sha256sum -c - &amp;&amp; \
sudo install -m 0644 /tmp/openbao-example-root.crt \
  /etc/ca-certificates/trust-source/anchors/openbao-example-root.crt &amp;&amp; \
sudo trust extract-compat</code></pre>
  </details>

  <h2>Verify</h2>
  <pre><code>curl -v https://it-tools.example.internal 2&gt;&amp;1 | grep -E "subject:|issuer:|verify"</code></pre>
  <p>The line <code>SSL certificate verify ok</code> means the root is trusted.</p>

  <h2>After install — refresh your browser</h2>
  <p>The cert is now in your system trust store, but browsers can still be caching the old "this cert is bad" decision. The section matching the browser you're viewing this page in is opened by default.</p>

  <details data-browser="safari">
    <summary>Safari</summary>
    <p>Usually picks up new trust without a restart. If a <code>.example.internal</code> tab is still warning, close the tab and reopen it.</p>
  </details>

  <details data-browser="chromium">
    <summary>Chrome / Edge / Arc / Brave (Chromium)</summary>
    <p>Quit and reopen the browser (<kbd>⌘Q</kbd> on macOS; fully close on Windows/Linux). Chromium reads the system keychain live but caches the per-session TLS verify decision — hard-refresh (<kbd>⌘⇧R</kbd>) is often not enough.</p>
  </details>

  <details data-browser="firefox">
    <summary>Firefox</summary>
    <p>Restarting won't help. Firefox keeps its own NSS cert store, not the system one. Import the cert there:</p>
    <ol>
      <li>Open <code>about:preferences#privacy</code>.</li>
      <li>Scroll to <em>Certificates</em>, click <em>View Certificates…</em>.</li>
      <li><em>Authorities</em> tab → <em>Import…</em>.</li>
      <li>Pick the downloaded <code>openbao-example-root.crt</code>.</li>
      <li>Check <em>Trust this CA to identify websites</em>, click OK.</li>
    </ol>
  </details>

  <details data-browser="cli">
    <summary>CLI tools (curl, openssl, git)</summary>
    <p>No restart needed — each invocation re-reads the system trust store. Sanity-check with: <code>curl -v https://it-tools.example.internal 2&gt;&amp;1 | grep "SSL certificate verify"</code>.</p>
  </details>

  <h2>Download</h2>
  <div class="card">
    <a class="btn" href="/openbao-root.crt" download="openbao-example-root.crt">Download root.crt</a>
    <p>SHA-256: <code class="digest" id="sha256">loading…</code></p>
    <p><small>PEM, ~1.7 KB. Issuer: <code>Home Cluster Root CA</code>. Valid through April 2036.
    After downloading, compare your local digest:
    <code>shasum -a 256 openbao-example-root.crt</code> (macOS/Linux) or
    <code>certutil -hashfile openbao-example-root.crt SHA256</code> (Windows).</small></p>
  </div>

  <p><small>Detailed troubleshooting: see <code>docs/trust-internal-ca.md</code> in the k8-infra repo.</small></p>
</main>
<script>
fetch("/openbao-root.sha256").then(function(r){return r.text();}).then(function(t){
  document.getElementById("sha256").textContent = t.trim();
}).catch(function(){
  document.getElementById("sha256").textContent = "(unavailable — pod init may have failed)";
});
(function(){
  var ua = navigator.userAgent;
  var target = null;
  if (ua.indexOf("Firefox") !== -1) target = "firefox";
  else if (ua.indexOf("Edg") !== -1 || ua.indexOf("Chrome") !== -1) target = "chromium";
  else if (ua.indexOf("Safari") !== -1) target = "safari";
  if (target) {
    var el = document.querySelector('details[data-browser="' + target + '"]');
    if (el) el.open = true;
  }
})();
</script>
</body>
</html>
"""#

staticSites: [
	{
		name:      "openbao-ca-page"
		namespace: "cert-distribution"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			image:    _openbaoCAPageImage
			port:     8080
			replicas: 1
			files: {
				"index.html": _openbaoCAIndexHTML
			}
			// Single init container does three things, in order:
			//   1. Copy ConfigMap files (index.html) into /shared.
			//   2. wget the OpenBao PKI's unauthenticated root cert PEM
			//      from /v1/pki_home/ca/pem (the endpoint is public by
			//      design — Vault/OpenBao serve every PKI root cert
			//      unauthenticated; the private key never leaves
			//      OpenBao). Save as openbao-root.crt.
			//   3. sha256sum the cert and save the hex digest to
			//      openbao-root.sha256 so the HTML can fetch + render.
			//
			// If OpenBao is sealed or unreachable the wget fails and the
			// pod stays in Init — desired, since we don't want to serve
			// stale or missing content and lie about success.
			initContainers: [
				{
					name:  "prepare"
					image: _busyboxImage
					command: ["sh", "-eu", "-c", #"""
						cp -RL /configmap/. /shared/ 2>/dev/null || cp -RL /configmap/* /shared/
						wget -q --timeout=15 -O /shared/openbao-root.crt \
							http://openbao.openbao.svc.cluster.local:8200/v1/pki_home/ca/pem
						sha256sum /shared/openbao-root.crt | awk '{print $1}' > /shared/openbao-root.sha256
						ls -la /shared/
						"""#,
					]
					securityContext: {
						allowPrivilegeEscalation: false
						readOnlyRootFilesystem:   true
						capabilities: drop: ["ALL"]
					}
					volumeMounts: [
						{name: "configmap", mountPath: "/configmap", readOnly: true},
						{name: "shared", mountPath:    "/shared"},
					]
					resources: {
						requests: {cpu: "10m", memory: "16Mi"}
						limits: {cpu:   "100m", memory: "32Mi"}
					}
				},
			]
			resources: {
				requests: {cpu: "10m", memory: "16Mi"}
				limits: {cpu:   "100m", memory: "64Mi"}
			}
		}
	},
]
