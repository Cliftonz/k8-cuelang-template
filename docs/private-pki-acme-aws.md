# Private PKI Setup

This the same design I run in my home datacenter (self-signed root CA → intermediate → ACME server → every service renews itself) with translation to AWS primitives instead of cloud native ones.

> **The 45-day lifetime**: The certs in this design
> live **45 days**. That is deliberate (reasons below), but it means
> the manual path — generate a cert, scp it to the box, restart the
> service — becomes a chore that comes due every ~30 days, per service,
> forever. Miss one and you get a TLS outage that looks like broken
> infrastructure, on a date nobody is watching. If you take one thing
> from this doc: **never issue a cert by hand except in an emergency.
> Every cert must be owned by a renewal timer and system from day one.** The whole
> point of the ACME server is that the renewal loop comes free.

---

## Part 1 — The theory (why this shape)

### "Self-signed" only happens once

The thing people get wrong trying to do this: they self-sign a cert
*per service*. Then every browser/client on every machine needs a trust
exception for every service — it scales as `machines × services` and
never stops hurting.

The fix is to self-sign exactly **one** certificate — a root CA — and
have it sign everything else. Every machine makes **one** trust
decision (install the root), and every service you ever add is
automatically trusted. Scales as `machines + services`.

A self-signed root is not a hack. Every root CA on the planet is
self-signed — that's what a trust anchor is. What makes a root
trustworthy is that its private key is protected and its distribution
is controlled, not who signed it.

### Root → intermediate → leaf

```
Root CA            self-signed, 10-year, key locked away
  └── Intermediate CA     signed by root, does all daily signing
        └── Leaf certs    45-day, one per service, auto-renewed
```

The root signs exactly one thing — the intermediate — and then its key
does nothing. All daily issuance comes from the intermediate. Why
bother:

- **Blast radius.** If the intermediate's key is compromised, the root
  signs a replacement and *no machine re-installs anything* — the trust
  anchor never changed.
- **Rotation asymmetry.** Rotating the root means touching every
  machine's trust store (expensive). Keep the root 10-year and rotate
  at the intermediate/leaf layers, and the expensive operation happens
  once a decade.

### Why an ACME server instead of handing out cert files

ACME is the protocol Let's Encrypt speaks. Running your *own* ACME
server means every standard client — certbot, acme.sh, Caddy, Traefik,
cert-manager, lego — works against your private CA by changing one URL.
Three reasons this is the move:

1. **Renewal is the default behavior of every ACME client.** certbot
   installs a systemd timer on day one. Handing someone an ACME
   directory URL hands them automation; handing them a PEM file hands
   them a recurring chore.
2. **Proof of control is built in.** The CA verifies the requester
   actually controls the hostname (HTTP-01 challenge) before issuing.
   No API keys to distribute to every box.
3. **No lock-in.** Anything that can talk to Let's Encrypt can talk to
   your CA.

### Why 45-day certs on purpose

- Short lifetimes make revocation infrastructure (CRL/OCSP) optional —
  a leaked key is only useful for days, and a bad cert ages out on its
  own.
- The public web is headed there anyway: CA/Browser Forum ballot SC-081
  caps public certs at **47 days by March 2029**. Building your
  internal habits around short certs now means nothing in your stack
  quietly assumes year-long certs.
- It forces the automation question on day one, instead of letting
  manual issuance feel fine for a year and then bite.

The math if you ignore the warning: renew at 2/3 lifetime (day ~30, so
you have 15 days of buffer when something breaks) → 8–12 rotations per
service per year → at 20 services that's **~200 manual cert operations
a year**. No calendar discipline survives that. Automate or don't
build this.

---

## Part 2 — Picking your AWS implementation

One problem — TLS on internal AWS services with automatic renewal —
three ways to do it:

### Option A: No private CA at all (check this first)

If you own a public domain, AWS makes public certs nearly free and
fully automated:

- **ACM public certs** — $0, auto-renewed forever, if TLS terminates on
  ALB/NLB/CloudFront/API Gateway. If all your services sit behind ALBs,
  you may not need *any* of this doc.
- **Let's Encrypt DNS-01 via Route 53** — for certs on the instances
  themselves. `certbot-dns-route53` + an instance role with
  `route53:ChangeResourceRecordSets` on your zone. Works even for
  hosts with no inbound internet access (validation is DNS-only).
  Internal hostnames work as long as the *zone* is public
  (`internal.yourdomain.com` records can point at private IPs).

**Pros:** zero CA to run; every device on earth already trusts the
certs. **Cons:** hostnames become public (DNS + Certificate
Transparency logs); requires owning a domain; couples internal TLS to
public infra.

### Option B: OpenBao / Vault PKI, run cloud-native

This is exactly what I run at home: OpenBao's PKI secrets engine *is*
the CA, and it serves ACME natively — no separate CA product. On AWS
you run it the cloud-native way, not as a pet box:

- **Self-hosted on EKS** — official Helm chart, 3-replica Raft HA,
  **KMS auto-unseal** (pods restart and unseal themselves — this kills
  the classic Vault toil), backups are one scheduled Raft snapshot to
  S3. It's a platform component managed like any other chart, not a
  server you SSH into.
- **HCP Vault Dedicated** — the fully managed version of the same
  engine. Same API, same commands (swap `bao` for `vault`), zero
  operations; meaningful monthly cost, verify current pricing.

**Pros:** native ACME (every client works); truly private (no names
leak anywhere); same architecture as my homelab so this doc maps 1:1;
you get a real secrets manager (DB creds, KV, k8s auth) in the same
deployment — you'll want one eventually anyway.
**Cons:** self-hosted is still a stateful platform component (HA,
snapshots, upgrades) even with auto-unseal removing the worst of it;
the managed escape hatch costs real money.

> **What about step-ca on an EC2 instance?** Smallstep's `step-ca` is a
> fine, lightweight ACME CA — for a lab or a POC. But it's a pet
> server: one box you patch, back up, and resurrect by hand. For
> anything production- or compliance-bearing, run the CA as either a
> managed service (Option C, or HCP Vault) or a cloud-native platform
> component (OpenBao on EKS). Don't build new pets.

### Option C: AWS Private CA

The managed version. KMS-backed keys, CloudTrail audit, integrates with
ACM so ALB certs from your private CA auto-renew; `aws-privateca-issuer`
plugs it into cert-manager on EKS.

**Pros:** nothing to operate; HSM-protected root. **Cons:** **~$400/month
per CA** (a short-lived-cert mode exists at ~$50/mo but caps certs at
7 days — verify current pricing), per-cert fees, and **it does not speak
ACME** — renewal automation only exists where AWS integrates it for you;
plain EC2-hosted services need custom renewal plumbing.

### Recommendation

**Option B or C — pick by where your renewal automation has to live.
Either way, managed or cloud-native: do not hand-operate a CA on an
EC2 instance.**

- **Option C (AWS Private CA)** if your TLS endpoints are
  AWS-integrated — ALB/NLB certs via ACM, EKS via
  `aws-privateca-issuer`. You manage nothing, keys are HSM-backed, and
  renewal is AWS's problem. The $400/mo is the price of having no CA
  operations at all; for a team that bills hours, that's cheap.
- **Option B (OpenBao/Vault)** if you need ACME — i.e. you have
  clients AWS won't renew for you: plain EC2-hosted services, on-prem
  boxes, non-AWS containers, developer laptops. Run it on EKS with KMS
  auto-unseal (or pay for HCP Vault if you want it fully managed), and
  it doubles as your secrets manager.

And genuinely check Option A first: if everything you run terminates
TLS on an ALB, ACM public certs dissolve the whole problem for $0.

### Where to terminate TLS based on your compliance requirements

Before picking an option, answer one question: **where is TLS allowed
to stop?** This is a compliance decision, not a technical preference,
and it changes which option above is even viable. Three termination
points, in decreasing order of centralization:

1. **Edge load balancer (ALB/NLB)** — traffic is plaintext from the LB
   to the application, inside the VPC.
2. **Cluster / internal LB layer (ingress controller, internal ALB)** —
   TLS terminates at the layer *in front of* the application
   deployment. **This is the ideal default**: the application never
   handles key material, cert automation is concentrated at exactly one
   layer, and rotating a cert never means touching an app deployment.
3. **Inside the application pod/process or in a service mesh** — fully end-to-end. Maximum assurance, maximum cert sprawl: now every app owns a keypair and a renewal path.

How compliance maps onto that:

- **SOC 2 / ISO 27001** — generally accept plaintext on internal VPC
  segments if it's documented and compensating controls exist
  (security groups, private subnets). Terminating at the edge LB is
  usually defensible.
- **PCI-DSS, HIPAA, FedRAMP** — increasingly expect encryption in
  transit *past* the edge, not just over the public internet; the
  "it's inside our network" exception keeps narrowing with each
  revision. Assume you need TLS at least to the cluster/LB layer
  (point 2), and confirm with your auditor whether pod-level (point 3)
  is required.

AWS-specific gotchas once you go past the edge:

- **ALB → target "HTTPS" encrypts but does not authenticate.** The ALB
  will not validate the backend's certificate chain — any cert,
  including self-signed, is accepted. That satisfies
  "encryption in transit" checkboxes but is not mutual trust. If the
  regime requires *authenticated* end-to-end TLS, use an NLB in TLS
  passthrough to your cluster ingress (which holds a real cert from
  the CA), or
- **service mesh mTLS** (Linkerd, Istio) for pod-to-pod — the mesh
  issues and rotates workload certs itself, which gets you point 3
  without applications ever managing key material.

How this feeds back into the option choice: if your regime lets you
terminate at the edge ALB, Option A (ACM public certs) may be the
entire answer. The moment TLS must reach the cluster/LB layer or
deeper on *internal* names, you need a private issuance path behind
the edge — which is exactly what Options B/C exist for.

---

## Part 3 — Operating rules (the part that keeps it working)

| Layer | Lifetime | Renewed by | Your work |
| --- | --- | --- | --- |
| Leaf certs | 45 days | certbot timer / Caddy / cert-manager | None — by design |
| Intermediate | 5 years (set when you sign it) | re-sign against same root | One session, no client impact |
| Root | 10 years | full ceremony + fleet re-trust | Once a decade |

1. **Onboarding a service is not done until a forced renewal succeeds
   and the reload hook works.** An ACME client without a working timer
   is a manual cert with extra steps.
2. **No manual issuance** except break-glass — and a manually-issued
   cert gets a ticket to move it onto an ACME client before its 45
   days run out.
3. **Watch expiry, not the calendar.** A trivial cron that alerts on
   any cert with <15 days left catches every failure mode at once:
   ```sh
   echo | openssl s_client -connect app1.internal.example.com:443 \
     -servername app1.internal.example.com 2>/dev/null \
     | openssl x509 -noout -enddate
   ```
   Anything inside 15 days with no renewal in flight is an incident,
   not a todo.

## Quick debugging map

| Symptom | Cause |
| --- | --- |
| ACME order stuck `pending` | CA can't reach client on port 80 — cluster egress + client security group, both directions |
| Client: `certificate signed by unknown authority` against the CA itself | Root not in the client's trust store (or certbot not told via `REQUESTS_CA_BUNDLE`) |
| Directory URL errors `acme feature is disabled` / 404 | PKI mount's `config/cluster` path unset or `config/acme` not enabled |
| Clients fail with nonce/header errors against a working-looking server | PKI mount isn't tuned to pass ACME response headers through |
| Cert came back with a lifetime you didn't expect | The PKI role decides lifetime, not the client — check the role's `ttl`/`max_ttl` |
| Cert renewed on disk but browser still shows old/expired | Missing reload/deploy hook — service never re-read the file |
| Firefox warns when Chrome doesn't | Firefox uses its own cert store; import the root there separately |
