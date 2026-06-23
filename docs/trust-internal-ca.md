# Trusting the example.internal root CA

Services on the home cluster that live under `*.example.internal`
(it-tools, home-assistant, n8n, metube, recipes, webui, traefik
dashboard, openbao UI, …) use TLS certs signed by a **private** root CA
that lives inside OpenBao's `pki_home/` mount. Browsers and tools won't
trust those certs until that root is installed in the device's trust
store.

This doc covers installation. The same steps are also rendered on
[ca.example.com](http://ca.example.internal) (LAN-only). For how the
CA itself is built and how services obtain certs from it (cert-manager
+ ACME), see [internal-pki-acme.md](internal-pki-acme.md).

---

## Where the root CA lives

| | |
| --- | --- |
| OpenBao mount | `pki_home/` |
| Validity (current) | 2026-04-29 → 2036-04-26 |
| Issuer CN | `Home Cluster Root CA` |
| Distribution URL | <http://ca.example.internal/openbao-root.crt> |
| Digest URL | <http://ca.example.internal/openbao-root.sha256> |
| Source endpoint | `http://openbao.openbao.svc.cluster.local:8200/v1/pki_home/ca/pem` (in-cluster, unauthenticated) |
| Issuer doc | [infrastructure/cert-manager/clusterissuer-openbao.yaml](../infrastructure/cert-manager/clusterissuer-openbao.yaml) |

The CA is delivered to clients by the [`openbao-ca-page`
deployment](../composites/home/staticsites.cue) in the
`cert-distribution` namespace. The pod's init container fetches the
PEM from OpenBao on every start (and computes its SHA-256), so a
rollout restart picks up rotations.

The page is served **plain HTTP** on purpose. The asset being served
*is* the trust anchor — signing the page with a cert from the same
PKI would be circular trust, and routing through Let's Encrypt on a
`example.com` hostname would touch Cloudflare for what is a LAN-only
artifact. Integrity is enforced by the SHA-256 digest shown on the
page and re-checkable locally with `shasum -a 256`. The cert PEM
itself is a public-by-design object (anyone who has it can verify
chains; nobody can sign anything with it without OpenBao's private
key).

---

## Install per platform

### macOS

Verifies the SHA-256 against the digest the page publishes (catches
truncation or in-transit corruption) before touching the keychain:

```sh
curl -fsSL http://ca.example.internal/openbao-root.sha256 -o /tmp/openbao-root.sha256 && \
curl -fsSL http://ca.example.internal/openbao-root.crt -o /tmp/openbao-example-root.crt && \
echo "$(cat /tmp/openbao-root.sha256)  /tmp/openbao-example-root.crt" | shasum -a 256 -c - && \
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain /tmp/openbao-example-root.crt
```

Then quit and reopen any Chromium browsers (Chrome, Edge, Arc all
use the system keychain but cache TLS verify decisions per session).
Safari usually picks the new trust up without restart. Firefox uses
its own NSS store — see the Firefox section below.

Verify:

```sh
curl -v https://it-tools.example.internal 2>&1 | grep -E "subject:|issuer:|SSL certificate verify"
```

You want to see `SSL certificate verify ok`.

To uninstall:

```sh
sudo security delete-certificate -c "Home Cluster Root CA" \
  /Library/Keychains/System.keychain
```

### iOS / iPadOS

1. Open <http://ca.example.internal/openbao-root.crt> in Safari (must
   be Safari, not Chrome — only Safari can install profiles).
2. Tap **Allow** on the "This website is trying to download a
   configuration profile" prompt.
3. Open **Settings → General → VPN & Device Management** → tap the
   downloaded "Home Cluster Root CA" profile → **Install**, enter
   passcode, **Install** again.
4. Open **Settings → General → About → Certificate Trust Settings**,
   find "Home Cluster Root CA", toggle it **on**, confirm.

Step 4 is mandatory and easy to miss. Without it the cert is
installed but not actively trusted for TLS.

To uninstall: **Settings → General → VPN & Device Management** →
profile → **Remove Profile**.

### Windows

From an Administrator PowerShell. Verifies SHA-256 then installs into
the Local Machine `Root` store:

```powershell
$tmp = $env:TEMP
Invoke-WebRequest http://ca.example.internal/openbao-root.crt -OutFile "$tmp\openbao-root.crt"
$expected = (Invoke-WebRequest http://ca.example.internal/openbao-root.sha256).Content.Trim()
$actual = (Get-FileHash "$tmp\openbao-root.crt" -Algorithm SHA256).Hash.ToLower()
if ($expected -ne $actual) { throw "SHA-256 mismatch: expected $expected, got $actual" }
certutil -addstore -f Root "$tmp\openbao-root.crt"
```

Edge and Chrome will trust it after the next browser restart. Firefox
uses its own store — see the next section.

To uninstall:

```powershell
certutil -delstore Root "Home Cluster Root CA"
```

### Firefox (any OS)

Firefox keeps its own cert store and ignores the system root list.

1. Open <about:preferences#privacy>.
2. Scroll to **Certificates**, click **View Certificates…**.
3. **Authorities** tab → **Import…**.
4. Pick the downloaded `openbao-root.crt`.
5. Check **Trust this CA to identify websites.**, click OK.

### Linux — Debian / Ubuntu

```sh
curl -fsSL http://ca.example.internal/openbao-root.sha256 -o /tmp/openbao-root.sha256 && \
curl -fsSL http://ca.example.internal/openbao-root.crt -o /tmp/openbao-example-root.crt && \
echo "$(cat /tmp/openbao-root.sha256)  /tmp/openbao-example-root.crt" | sha256sum -c - && \
sudo install -m 0644 /tmp/openbao-example-root.crt \
  /usr/local/share/ca-certificates/openbao-example-root.crt && \
sudo update-ca-certificates
```

The file installed under `/usr/local/share/ca-certificates/` **must**
end in `.crt` or `update-ca-certificates` silently ignores it.

### Linux — Fedora / RHEL / Rocky / Alma

```sh
curl -fsSL http://ca.example.internal/openbao-root.sha256 -o /tmp/openbao-root.sha256 && \
curl -fsSL http://ca.example.internal/openbao-root.crt -o /tmp/openbao-example-root.crt && \
echo "$(cat /tmp/openbao-root.sha256)  /tmp/openbao-example-root.crt" | sha256sum -c - && \
sudo install -m 0644 /tmp/openbao-example-root.crt \
  /etc/pki/ca-trust/source/anchors/openbao-example-root.crt && \
sudo update-ca-trust extract
```

### Linux — Arch / Manjaro

```sh
curl -fsSL http://ca.example.internal/openbao-root.sha256 -o /tmp/openbao-root.sha256 && \
curl -fsSL http://ca.example.internal/openbao-root.crt -o /tmp/openbao-example-root.crt && \
echo "$(cat /tmp/openbao-root.sha256)  /tmp/openbao-example-root.crt" | sha256sum -c - && \
sudo install -m 0644 /tmp/openbao-example-root.crt \
  /etc/ca-certificates/trust-source/anchors/openbao-example-root.crt && \
sudo trust extract-compat
```

Or equivalently with the `trust` CLI (from `p11-kit`), after the
same SHA-256 verification step:

```sh
sudo trust anchor --store /tmp/openbao-example-root.crt
```

### Android

Android distinguishes between user-installed and system-installed CAs.
User-installed CAs are trusted by browsers (Chrome, Firefox) but **not**
by most apps (each app opts in via networkSecurityConfig).

1. On the device, open <http://ca.example.internal/openbao-root.crt>.
2. Settings → **Security & privacy → More security settings →
   Encryption & credentials → Install a certificate → CA certificate
   → Install anyway**.
3. Pick the downloaded file.

For the apps that don't honor user CAs (most Google apps, banking
apps) you'd need a rooted device + a Magisk module that copies the
cert to the system store. Out of scope here.

---

## After install — what to do per browser

The cert is now in your system trust store, but browsers can still be
caching the old "this cert is bad" decision from before you installed
the root.

| Browser | What to do |
| --- | --- |
| **Safari** | Usually picks up new trust without a restart. If a `.example.internal` tab is still warning, close the tab and reopen it. |
| **Chrome / Edge / Arc / Brave** (Chromium) | Quit and reopen the browser (⌘Q on macOS; fully close on Windows/Linux). They read the system keychain live but cache the per-session TLS verify decision — hard-refresh (⌘⇧R) is often not enough. |
| **Firefox** | Restarting won't help. Firefox uses its own NSS cert store, not the system one. Import the cert there: `about:preferences#privacy` → *Certificates* → *View Certificates…* → *Authorities* → *Import…* → pick `openbao-example-root.crt` → check *Trust this CA to identify websites* → OK. |
| **CLI** (curl, openssl, git) | No restart needed — each invocation re-reads the system trust store. |

## Verifying without installing

To curl an internal service one-off without installing the CA:

```sh
curl --cacert openbao-root.crt https://it-tools.example.internal
```

To skip verification entirely (don't habit-form this):

```sh
curl -k https://it-tools.example.internal
```

---

## When the root rotates

The current root is good until April 2036. When it does need to
rotate:

1. Mint a new root inside OpenBao (`bao write pki_home/root/generate/internal …`).
2. Re-enable the intermediate's cert chain (`bao write pki_int/intermediate/set-signed certificate=@new-chain.pem`).
3. `kubectl rollout restart deployment/openbao-ca-page -n cert-distribution`
   — the page now serves the new root.
4. Every device needs to install the new root before the old one
   expires. Both can be trusted at the same time during the overlap.

The page does not auto-refresh; only pod restart pulls a new cert.
That's intentional — stale-but-correct is better than racing a
rotation mid-request.

---

## Troubleshooting

**`curl: (60) SSL certificate problem` after installing on macOS** —
quit the browser fully (Cmd+Q), then reopen. Browsers cache the
cert chain validity decision across sessions.

**Firefox still warning after system install** — Firefox uses its
own store. See the Firefox section above.

**iOS shows the profile as installed but cert is "untrusted"** —
the Certificate Trust Settings toggle (step 4) wasn't enabled.

**Linux: `update-ca-certificates` says `0 added, 0 removed`** — the
cert file extension must be exactly `.crt`. `.pem` is silently
ignored.

**`/openbao-root.crt` 404s** — the openbao-ca-page pod failed its
`fetch-ca` init container. Check `kubectl logs -n cert-distribution
deploy/openbao-ca-page -c fetch-ca` — usually OpenBao is sealed or
the NetworkPolicy was changed.

**Cert installed but `curl https://foo.example.internal` says
`name mismatch`** — the Ingress's cert was issued for a different
hostname. Check `kubectl get ingress -A -o jsonpath='{.items[*].spec.tls}'`
and `kubectl get certificate -A`.
