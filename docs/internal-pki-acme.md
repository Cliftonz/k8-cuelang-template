# Internal PKI: self-signed root CA + ACME issuance

How the home cluster's private certificate authority is built, why it is
shaped the way it is, and how services get certs from it — both inside
the cluster (cert-manager) and outside it (ACME).

Companion doc: [trust-internal-ca.md](trust-internal-ca.md) covers the
**client** side — installing the root into device trust stores. This doc
covers the **server** side — minting the CA and issuing leaf certs.

> **The one rule this doc exists to enforce:** leaf certificates from
> this PKI live **45 days**. Any cert obtained manually becomes a
> recurring chore that comes due every ~30 days, forever, and a missed
> renewal is a user-visible TLS outage. Manual issuance is break-glass
> only. Every certificate must be owned by an automation loop —
> cert-manager in-cluster, an ACME client out-of-cluster — before it is
> allowed to become load-bearing.

---

## Theory

### Why a private CA at all

Services on the LAN live under `*.example.internal`. No public CA can
issue for those names: Let's Encrypt (and every other WebPKI CA) must
verify control of a name that resolves on the public internet, and
`example.internal` deliberately does not. The options were:

1. **Per-service self-signed certs** — every service mints its own.
   Every browser on every device throws a warning per service; there is
   no single trust decision a device can make. Scales as
   `devices × services`.
2. **Public names + Let's Encrypt for everything** — works (we do it
   for `*.example.com`), but forces every LAN-only service through
   public DNS and couples internal availability to Cloudflare.
3. **One private root CA** — devices make a single trust decision
   (install one root, see [trust-internal-ca.md](trust-internal-ca.md))
   and every internal service is covered. Scales as `devices + services`.

Option 3 is what I chooese. "Self-signed" then applies to exactly one
certificate: the root. That is the trust anchor in
the WebPKI is self-signed; what makes a root trustworthy is controlled
distribution and a protected private key, not who signed it.

### The chain: root → intermediate → leaf

```
Home Cluster Root CA            self-signed, 10-year, OpenBao pki_home/
  └── intermediate CA           signed by root, OpenBao pki_int/
        └── leaf certs          45-day, issued per service
```

The root never signs leaf certificates directly. The split buys two
things:

- **Blast-radius containment.** The intermediate's key is the one that
  does daily work. If it is compromised or its parameters need to
  change, the root signs a replacement intermediate and no device
  re-installs anything — the trust anchor is unchanged.
- **Rotation asymmetry.** Root rotation requires touching every device
  on the LAN (the expensive operation, documented in
  [trust-internal-ca.md](trust-internal-ca.md#when-the-root-rotates)).
  By keeping the root long-lived (2026-04-29 → 2036-04-26) and doing
  all operational rotation at the intermediate and leaf layers, the
  expensive operation happens roughly once a decade.

Both CAs live inside OpenBao's PKI secrets engine. The private keys
never leave OpenBao (`generate/internal` keeps key material
server-side); issuance is an API call, which is what makes automation
possible at all.

### Why short-lived leaves — the 45-day theory

45-day leaf certs are a deliberate policy, not a limitation:

- **Revocation infrastructure becomes optional.** Running CRL
  distribution points or OCSP for a LAN is real operational surface. A
  cert that expires in 45 days self-revokes on a schedule; a leaked key
  has a bounded, short window of usefulness.
- **It matches where the public web is going.** CA/Browser Forum ballot
  SC-081 steps public cert lifetimes down to a 47-day maximum by March
  2029. Mirroring that internally means our tooling and habits are
  already correct, and nothing in the stack quietly assumes year-long
  certs.
- **It forces the automation question immediately** instead of letting
  manual issuance feel sustainable for a year and then bite.

The cost is cadence, and this is the caution: a 45-day cert must
actually be replaced around day 30 (renewing at two-thirds of lifetime,
cert-manager's default, leaves a 15-day buffer for things being broken).
That is **8–12 rotations per service per year**. At ~20 internal
services, manual rotation is ~200 cert operations a year, each one a
silent outage if missed — and an expired internal cert presents exactly
like broken infrastructure ("CA is not correct", connection refused
warnings) rather than like an expired cert. This is not a toil you
absorb; it is one you design out.

### Why ACME as the issuance protocol

For workloads cert-manager can't reach (anything not running in the
cluster), the issuance protocol is ACME — the same protocol Let's
Encrypt speaks — served by OpenBao itself. The reasoning:

- **Renewal is part of the protocol's culture.** Every ACME client
  (certbot, acme.sh, Caddy, Traefik, TrueNAS's built-in support, lego)
  ships with a renewal timer as the default mode of operation. Handing
  someone an ACME directory URL hands them automation; handing them a
  PEM file hands them a chore.
- **Proof of control is built in.** ACME validates that the requester
  actually controls the hostname (HTTP-01 challenge) before issuing —
  no shared API tokens to distribute to every box that needs a cert.
- **Zero client lock-in.** Any device that can speak ACME to Let's
  Encrypt can speak it to OpenBao by changing one URL.

---

## What exists today

| Component | Location | Notes |
| --- | --- | --- |
| Root CA (`Home Cluster Root CA`) | OpenBao `pki_home/` | Self-signed, valid 2026-04-29 → 2036-04-26 |
| Intermediate CA | OpenBao `pki_int/` | Signed by root; role `example-internal` |
| In-cluster issuer | ClusterIssuer `openbao-example-internal` | cert-manager Vault issuer → `pki_int/sign/example-internal`; defined in [composites/home/helmreleases.cue](../composites/home/helmreleases.cue) `extraObjects` |
| Public issuer | ClusterIssuer `letsencrypt-example-public` | Let's Encrypt ACME DNS-01 via Cloudflare, for `*.example.com` only |
| Root distribution | `openbao-ca-page` in `cert-distribution` ns | [composites/home/staticsites.cue](../composites/home/staticsites.cue); serves root PEM + SHA-256 at `http://ca.example.internal` |
| ACME server | OpenBao `pki_int/` ACME directory | For out-of-cluster services — setup below |

Two issuance paths, one CA:

```
                         OpenBao pki_int/ (intermediate)
                          /                        \
        sign API (authenticated)              ACME directory (proof-of-control)
                 │                                      │
           cert-manager                       certbot / acme.sh / Caddy /
        (in-cluster Ingresses,                TrueNAS / any LAN host
         renews at 2/3 lifetime)              (systemd timer / cron renews)
```

> Current in-cluster certs are issued at 90 days (cert-manager's
> default `spec.duration`). The 45-day policy applies to ACME-issued
> leaves now; tightening cert-manager's certs to 45 days for parity is
> a one-line `duration: 1080h` on the Certificate spec once we choose
> to — the renewal loop already makes lifetime irrelevant to operations
> in-cluster.

---

## Process 1 — the self-signed root (done 2026-04-29; recorded for rebuild)

Run against OpenBao with a token that can manage secrets mounts. The
key never leaves OpenBao — `generate/internal` returns only the
certificate.

```sh
# Mount a PKI engine for the root, long max TTL (10 years)
bao secrets enable -path=pki_home pki
bao secrets tune -max-lease-ttl=87600h pki_home

# Self-signed root. This is the only self-signed cert in the system.
bao write -field=certificate pki_home/root/generate/internal \
  common_name="Home Cluster Root CA" \
  issuer_name="home-root-2026" \
  ttl=87600h > openbao-root.crt

# AIA URLs embedded in everything the root signs
bao write pki_home/config/urls \
  issuing_certificates="http://openbao.openbao.svc:8200/v1/pki_home/ca" \
  crl_distribution_points="http://openbao.openbao.svc:8200/v1/pki_home/crl"
```

The root PEM is public-by-design (it is the thing devices install);
distribution and integrity-checking are handled by the ca-page — see
[trust-internal-ca.md](trust-internal-ca.md).

## Process 2 — the intermediate

```sh
# Separate mount, working CA. Max TTL bounds every leaf it can issue.
bao secrets enable -path=pki_int pki
bao secrets tune -max-lease-ttl=43800h pki_int   # 5 years for the intermediate itself

# CSR generated inside OpenBao (key stays server-side)
bao write -field=csr pki_int/intermediate/generate/internal \
  common_name="Home Cluster Intermediate CA" > pki_int.csr

# Root signs the intermediate
bao write -field=certificate pki_home/root/sign-intermediate \
  csr=@pki_int.csr format=pem_bundle ttl=43800h > pki_int.crt

# Install the signed cert back into the intermediate mount
bao write pki_int/intermediate/set-signed certificate=@pki_int.crt

bao write pki_int/config/urls \
  issuing_certificates="http://openbao.openbao.svc:8200/v1/pki_int/ca" \
  crl_distribution_points="http://openbao.openbao.svc:8200/v1/pki_int/crl"

# The role every leaf is issued under. THIS is where the 45-day
# lifetime is enforced — clients can ask for less, never more.
bao write pki_int/roles/example-internal \
  allowed_domains="example.internal" \
  allow_subdomains=true \
  allow_bare_domains=false \
  allow_wildcard_certificates=false \
  max_ttl=1080h \
  ttl=1080h \
  key_type=ec key_bits=256
```

`1080h = 45 days`. The role is the policy chokepoint: no matter which
path a request arrives by (sign API or ACME), it cannot mint a cert for
a non-`example.internal` name or for longer than 45 days.

## Process 3 — in-cluster issuance (cert-manager)

Already wired; recorded here because it is half of the "no manual
certs" answer.

1. OpenBao Kubernetes auth role `cert-manager` is bound to the
   cert-manager ServiceAccount and grants `pki_int/sign/example-internal`.
2. The ClusterIssuer ships inside the cert-manager HelmRelease's
   `extraObjects` in
   [composites/home/helmreleases.cue](../composites/home/helmreleases.cue)
   — deliberately, so a cluster recreate cannot forget it (it was
   previously a hand-applied manifest and *was* forgotten; every
   internal cert failed with "ClusterIssuer not found").
3. Services opt in with one Ingress annotation
   (`cert-manager.io/cluster-issuer: openbao-example-internal`, applied
   by the shared helper in
   [composites/home/ingresses.cue](../composites/home/ingresses.cue)).
   cert-manager creates the Certificate, stores it in `<name>-tls`, and
   renews at two-thirds of lifetime with no human involved.

If a workload runs in the cluster, this is its path. Full stop. Do not
point in-cluster workloads at the ACME directory — cert-manager's
Vault issuer is fewer moving parts and already authenticated.

## Process 4 — the ACME server (out-of-cluster services)

For everything that is not a cluster workload: TrueNAS, UniFi, bare
VMs, the Kali box, anything on the LAN that terminates TLS itself.

OpenBao's PKI engine (2.x) serves ACME natively — no step-ca, no extra
deployment. Enable it on the intermediate mount:

```sh
# ACME requires these headers to pass through the mount
bao secrets tune \
  -passthrough-request-headers=If-Modified-Since \
  -allowed-response-headers=Last-Modified \
  -allowed-response-headers=Location \
  -allowed-response-headers=Replay-Nonce \
  -allowed-response-headers=Link \
  pki_int

# Tell the mount its externally-reachable URL (used in directory + AIA)
bao write pki_int/config/cluster \
  path="https://openbao.example.internal/v1/pki_int" \
  aia_path="https://openbao.example.internal/v1/pki_int"

# Turn ACME on, restricted to the existing role
bao write pki_int/config/acme \
  enabled=true \
  allowed_roles="example-internal" \
  default_directory_policy="role:example-internal"
```

The directory URL clients use:

```
https://openbao.example.internal/v1/pki_int/roles/example-internal/acme/directory
```

Role-scoped on purpose — every ACME-issued cert inherits the role's
constraints (45-day cap, `*.example.internal` only).

### Challenge type on a LAN

Use **HTTP-01**. The validation flow: client asks for
`foo.example.internal`, OpenBao connects to
`http://foo.example.internal:80/.well-known/acme-challenge/<token>` and
must get the token back. Consequences:

- The OpenBao pod must have **egress to LAN port 80**. The
  default-deny NetworkPolicy in
  [composites/home/networkpolicies.cue](../composites/home/networkpolicies.cue)
  will eat this silently — the ACME order just sits in `pending` —
  so the openbao egress rule must allow it before the first client is
  onboarded.
- `foo.example.internal` must resolve (UniFi DNS record) **before**
  requesting the cert, and must resolve to the machine running the
  ACME client.

DNS-01 is not practical here (UniFi's DNS has no API the clients
support), and TLS-ALPN-01 requires control of port 443 during issuance,
which conflicts with the service already using it. HTTP-01 it is.

### Client onboarding (each one ends with a timer, or it didn't happen)

The root CA must be in the host's trust store first
([trust-internal-ca.md](trust-internal-ca.md)) — ACME clients verify
the directory's TLS like anything else.

**certbot** (bare Linux host):

```sh
certbot certonly --standalone \
  --server https://openbao.example.internal/v1/pki_int/roles/example-internal/acme/directory \
  -d foo.example.internal \
  --key-type ecdsa --register-unsafely-without-email
# certbot's packaged systemd timer handles renewal; verify it:
systemctl list-timers | grep certbot
```

**acme.sh** (anything with a shell, incl. UniFi via community hooks):

```sh
acme.sh --issue --standalone \
  --server https://openbao.example.internal/v1/pki_int/roles/example-internal/acme/directory \
  -d foo.example.internal
# acme.sh installs its own cron entry on first run; verify:
crontab -l | grep acme.sh
```

**TrueNAS**: Credentials → Certificates → ACME DNS/Authenticators is
DNS-01-shaped; for HTTP-01 run acme.sh on the host with a deploy hook
into the TrueNAS API. **Caddy/Traefik on a VM**: set the ACME CA URL in
config; renewal is built in.

Onboarding checklist per service — treat as gating, not advisory:

1. DNS record exists for the hostname.
2. Root CA trusted on the host.
3. First issuance succeeds.
4. **Renewal timer exists and a forced renewal (`certbot renew
   --force-renewal` / `acme.sh --renew --force`) succeeds.**
5. Reload hook actually makes the service serve the new cert
   (issuance without reload is the classic silent failure — the cert
   on disk rotates, the one in memory expires).

Step 4 is the whole point. An ACME client without a working timer is a
manual cert with extra steps.

---

## The toil math, explicitly

If certs from this PKI were fetched manually (`bao write
pki_int/issue/example-internal ...`, copy PEM to host, restart
service):

| | |
| --- | --- |
| Leaf lifetime | 45 days |
| Safe renewal point | day ~30 (2/3 lifetime, 15-day failure buffer) |
| Rotations per service per year | 8–12 |
| At 20 services | **~200 manual cert operations / year** |
| Cost of one miss | TLS outage that presents as broken infrastructure, on a date no one is watching |

There is no calendar discipline that survives this at solo scale — and
the lifetime is *intended* to make that true (see theory above), the
same way the public WebPKI's march to 47-day certs is intended to kill
manual issuance industry-wide. The conclusion is structural, not
behavioral:

- **In-cluster** → cert-manager Ingress annotation. Never anything else.
- **Out-of-cluster** → ACME client with a verified renewal timer.
- **Manual issuance** → break-glass only (an outage where the
  automation itself is what's down), and the manually-issued cert gets
  a tracking issue to re-home it onto an automation path before its
  45 days are up.

## Rotation summary

| Layer | Lifetime | Rotated by | Human work |
| --- | --- | --- | --- |
| Leaf certs | 45 days (ACME) / 90 days (cert-manager, today) | cert-manager / ACME client timers | None — that's the design |
| Intermediate (`pki_int`) | 5 years | Re-run Process 2 against the same root | One session; no device touches |
| Root (`pki_home`) | 10 years (to 2036-04) | Process 1 + re-sign intermediate + ca-page restart | Every device re-trusts — see [trust-internal-ca.md](trust-internal-ca.md#when-the-root-rotates) |

## Verification

```sh
# ACME directory is live (from a LAN host):
curl -s https://openbao.example.internal/v1/pki_int/roles/example-internal/acme/directory | jq .

# Everything cert-manager owns, with expiry + renewal schedule:
kubectl get certificate -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status,NOTAFTER:.status.notAfter,RENEWAL:.status.renewalTime'

# Chain check against any service:
echo | openssl s_client -connect it-tools.example.internal:443 -servername it-tools.example.internal 2>/dev/null \
  | openssl x509 -noout -issuer -dates
```

Anything with a `notAfter` inside 15 days and no renewal in flight is
an incident, not a todo.
