# GitHub Bot User Setup for Kelos

How to make Kelos agent comments, PRs, and commits appear under a dedicated
bot identity instead of your personal GitHub handle — **without creating
a GitHub App.**

Audience: cluster admin (you). One-time setup, ~10 minutes end to end.

---

## Why not a GitHub App?

Kelos **does** support GitHub App auth natively — see upstream
[docs/reference.md § Workspace Authentication](https://github.com/kelos-dev/kelos/blob/main/docs/reference.md#workspace-authentication)
and kelos-dev/kelos#471. Since kelos-dev/kelos#971 (merged 2026-Q1) tokens
are minted in-process inside the spawner / ghproxy / webhook pods — no
token-refresher sidecar to run, no JWT plumbing on your side. You pass
`appID`, `installationID`, and the private key via a Secret and Kelos
handles the rest.

So the App path is real and first-class. It's just still heavier for a
single-org solo platform:

- Register the App, install per-org, manage the private key rotation.
- Apps can't be "invited as a collaborator" — install-only. Fine for
  `example-org` repos, extra friction if you ever agent against a repo
  in someone else's org.
- Commit author shows as `<app-name>[bot]` — nice UX, but you lose the
  human-readable handle in PR review threads.

A **machine user** — just a regular GitHub account created for the bot —
is the lighter path: one PAT, one user to invite, works identically to
any human collaborator. That's what this doc walks through. Pick the
App path instead if you want `[bot]` identity in the UI, per-install
revoke, or the 15k req/hr rate limit.

Tradeoff: the machine user is a normal user, so you manage 2FA, email,
and password for it like any other account. Use a password manager.

---

## Step-by-step

### 1. Create a dedicated email alias

You need an email address GitHub hasn't seen before. Options:

- **Gmail `+` alias:** `your-address+example-org-bot@gmail.com` — routes
  to your existing inbox. Free, instant, zero config.
- **Google Workspace shared mailbox or distribution list** (e.g.
  `bots@example.com`) — survives individual people leaving.
- **iCloud / ProtonMail alias** — same idea as Gmail `+`.

Pick one. Call it `BOT_EMAIL` for the rest of this doc.

### 2. Create the GitHub account

1. https://github.com/join (sign out of your personal account first or
   use a private browser window).
2. Username: something recognizably a bot. Suggestions:
   - `example-org-bot`
   - `example-org-kelos`
   - `bb-ai`
3. Email: `BOT_EMAIL`
4. Set a strong password; store it in your password manager.
5. **Enable 2FA** (required to be an org member and highly recommended
   either way). Use a TOTP app; store the recovery codes in the password
   manager too.
6. Verify the email from `BOT_EMAIL` inbox.

Call the resulting username `BOT_USER`.

### 3. Invite the bot to the `example-org` org

From your personal account (with org admin rights):

- https://github.com/organizations/example-org/people → **Invite
  member** → enter `BOT_USER` → Member role (not Owner).
- Log into the bot account, accept the invitation.

### 4. Grant the bot access to repos it will operate on

The bot doesn't need access to every repo — only the ones Kelos will
clone/push/comment against. For each repo (e.g. `example-org/SalesSage`
and `example-org/k8-infra`):

- Repo → **Settings → Collaborators and teams** → **Add people** →
  `BOT_USER` → **Write** permission.

(Or: create a `kelos-bot` team, add the bot, grant the team Write on
each repo. Cleaner if you expect more than 2 repos.)

### 5. Mint the bot's fine-grained PAT

Logged in as the bot:

1. https://github.com/settings/tokens?type=beta → **Generate new token**
2. **Token name:** `kelos-in-cluster` (anything descriptive)
3. **Expiration:** 1 year (calendar a rotation reminder)
4. **Resource owner:** `example-org`
5. **Repository access:** _Only select repositories_ → pick exactly the
   repos Kelos should touch (SalesSage, k8-infra, and any future ones)
6. **Repository permissions**:
   - **Contents:** Read and write _(clone + push)_
   - **Issues:** Read and write _(post + read comments)_
   - **Pull requests:** Read and write _(post PR comments, open PRs)_
   - **Metadata:** Read _(implicit)_
   - **Webhooks:** Admin _only if_ you want Kelos to manage webhooks
     for you; otherwise skip
7. **Organization permissions:**
   - **Members:** Read _(lets the TaskSpawner's `commentPolicy.minimumPermission`
     check work — it queries org membership)_
8. Generate. Copy the token string (`github_pat_11...`) immediately; it
   won't be shown again. Call it `BOT_PAT`.

### 6. Update OpenBao to use the bot's credentials

From your laptop (or wherever you normally seed OpenBao):

```bash
kubectl port-forward -n openbao svc/openbao 8200:8200 >/dev/null 2>&1 &
sleep 3
export BAO_ADDR=http://localhost:8200
export BAO_TOKEN=$(kubectl get secret openbao-keys -n openbao -o jsonpath='{.data.root-token}' | base64 -d)

bao kv put -mount=secret preview/github-pat \
  GITHUB_USER="<BOT_USER>" \
  GITHUB_TOKEN="<BOT_PAT>"
```

This overwrites the existing entry. All consumers (Argo CD
ApplicationSet, Argo Events sensors, Kelos workspace clone, agent
comments) pick up the bot's credentials on next ESO sync.

### 7. Force ESO to sync immediately

```bash
kubectl annotate externalsecret github-pat -n kelos-system \
  force-sync="$(date +%s)" --overwrite
kubectl annotate externalsecret github-token -n argocd \
  force-sync="$(date +%s)" --overwrite
kubectl annotate externalsecret argocd-notifications-secret -n argocd \
  force-sync="$(date +%s)" --overwrite
kubectl annotate externalsecret github-webhook-secret -n argo-events \
  force-sync="$(date +%s)" --overwrite
kubectl annotate clusterexternalsecret ghcr-pull-secret \
  force-sync="$(date +%s)" --overwrite
```

(The `ghcr-pull-secret` one pulls the PAT's docker auth for pulling
images; the bot's PAT needs `packages: read` for that to keep working.
Add it to step 5 if you're using GHCR pulls.)

### 8. Restart the Kelos spawner pods so they pick up the new Secret

```bash
kubectl rollout restart deploy -n kelos-system \
  salessage-pr-reviewer secret-wiring
```

### 9. Verify with a new `@agent review` comment

On any open PR, comment `@agent review`. Within ~60 seconds:

- A new Task spawns (`kubectl get task -n kelos-system -w`)
- The agent clones the PR branch using the bot's token
- The review comment appears **under `<BOT_USER>`'s handle** (not yours)

That's the whole setup.

---

## Update the Kelos Workspace to report the bot user

Currently `composites/preview/kelos.cue` references `secretRef.name:
"github-pat"` which is unchanged — so no CUE edit is needed. The Workspace
resolves the Secret at runtime and uses whatever `GITHUB_USER` and
`GITHUB_TOKEN` it finds.

Optional: if you want the agent's self-identification (in its review
comment body) to match the bot, tweak the AgentConfig prompt in
`composites/preview/kelos.cue`:

```diff
 ## :robot: AI review
-
+(posted by @example-org-bot on behalf of @{{issue-author}})

 **Summary:** ...
```

Minor polish; skip if you don't care.

---

## Commit authorship (for agents that `git push`)

The review-only agent doesn't commit. But if you add a `pr-fixer` or
`docs-updater` agent later that pushes commits, those commits will show
the bot user **if** the Workspace is configured correctly.

Kelos sets `git config user.name/email` from the GITHUB_TOKEN owner by
default, so committing should already attribute to the bot. If not, you
can pin it in the Workspace's `spec.files` (inject a `.git/config` or
tell the agent to run `git config user.name`/`email` as a first step).

---

## Rotation

- PAT expires in 1 year — GitHub emails the bot's inbox 10 days prior.
  Mint a new PAT, repeat step 6 + 7.
- If the bot is compromised (PAT leak, 2FA lost), revoke the PAT at
  https://github.com/settings/tokens immediately, then re-mint and
  re-seed. If worse, remove the bot from the org.
- When rotating, do NOT delete the bot account — that severs commit
  authorship on any past commits it made.

---

## Alternative: keep personal identity, add a human-readable prefix

If a dedicated account is too much ceremony, our current setup already
prefixes agent comments with `## :robot: AI review`. That visual cue
is usually enough — humans reading the PR know it's not a person.
Trade-off: notifications, merge blockers, and @-mentions still route
to your personal GitHub account.

You can take this approach now and revisit the bot user when:
- A second person joins example-org and needs their own agent-free commits
- You want blameless merge reviews (your handle no longer appears as
  approver on PRs you've clearly reviewed-via-bot)
- Compliance/audit asks for a non-human identity on automated changes

---

## Why this is usually enough (machine user over App)

GitHub App advantages that matter:

- **Public marketplace distribution** (installing on arbitrary orgs you
  don't own) — N/A here
- **Per-installation fine-grained permissions** — fine-grained PATs
  cover this
- **Very high rate limits** (~15k req/hr vs PAT's 5k) — irrelevant for
  a small platform polling one spawner per minute
- **`[bot]` identity in PR UI and commit authorship** — nice, not
  load-bearing for internal previews
- **No human account to 2FA/rotate** — the biggest real win once you
  scale past one operator

Kelos itself no longer charges you for the App path (tokens are minted
in-process per kelos-dev/kelos#971), so the historical "refresher
sidecar infra" cost is gone. The remaining cost is the GitHub-side
registration + private-key rotation + install-only (no external-org
collab) model.

For an in-cluster agent on a single-org platform with a solo operator,
a machine user with a fine-grained PAT stays the right amount of
ceremony. Revisit the App path when: a second operator joins, you need
`[bot]` identity for audit, or you want to stop managing a shadow
human account.
