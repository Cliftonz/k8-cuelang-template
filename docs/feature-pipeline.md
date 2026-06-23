# Feature Pipeline — Issue to Merge AI Automation

End-to-end AI pipeline that turns a GitHub issue into a reviewed,
ready-to-merge PR on any example-org repo with a Kelos Workspace.

## Stages

| Stage | Trigger | Actor | Output |
|---|---|---|---|
| Branch Creation | Issue labeled `ai-feature` | `feature-branch-create` Job | Branch `feature/issue-{N}-{slug}` + announce comment + `branch-created` label |
| Ideation | Comment on `ai-feature` issue | `feature-ideator` Kelos Task | Clarifying question, proposed scope, or ready-for-impl summary |
| Implementation | Issue labeled `ready:ai-implement` | `feature-implementer` Kelos Task | Draft PR on the feature branch, marked ready, `pending-review` label |
| Tier 1 Review | PR `pending-review` label | 2 Kelos Tasks (security + architect) | Formal PR reviews with verdict markers |
| Orchestrator | `pull_request_review` / push | `feature-orchestrator` Job | Next action: spawn tier 2, fixer, ready-to-merge, or escalate |
| Tier 2 Review | Orchestrator decision | 5 Kelos Tasks (lead-dev, designer, devrel, qa, devops) | Formal PR reviews |
| Fix Loop | Any `CHANGES_REQUESTED` | `feature-review-fixer` Kelos Task | Fix commit pushed to PR branch |
| Approval | All 7 APPROVE on HEAD SHA | Orchestrator | `ready-to-merge` label + ping to repo owner |
| Escalation | 3 fix rounds exhausted | Orchestrator | Summary comment + `review-failed` + `awaiting-human` |

## Labels

| Label | Applied by | Meaning |
|---|---|---|
| `ai-feature` | Human | Activates branch creation + ideation |
| `branch-created` | Branch Job | Branch exists, ideation can proceed |
| `ready:ai-implement` | Human | Triggers implementation |
| `awaiting-human` | Any agent | Pipeline paused, needs human input |
| `pending-review` | Implementer | Triggers review panel |
| `ready-to-merge` | Orchestrator | All 7 approved on HEAD SHA |
| `review-failed` | Orchestrator | 3 fix rounds exhausted |

All label names are defined in [composites/preview/labels.cue](../composites/preview/labels.cue).
To rename any label: edit that file, re-render (`make export-cluster ...`),
re-apply, and rename the label on GitHub. All Sensor filters, agent prompts,
and scripts pick up the new name automatically.

## How to use (human workflow)

### 1. Open an issue

Title + body describe the feature. Add label `ai-feature`.

Within ~5 seconds, a branch is created and announced in a comment:

> Branch created: `feature/issue-42-add-hello-endpoint`
>
> Push WIP commits here during ideation. When requirements are clear,
> apply the `ready:ai-implement` label — the AI will push final code and open
> a PR on this branch.

### 2. Ideate

Comment your thoughts. Within ~1 minute, the ideator responds:

- Clarifying questions (numbered)
- Proposed scope / design
- 1-3-1 decision frame when a fork blocks progress
- Ready-for-implementation handoff with a machine-readable spec
  block (`<!-- spec --> … <!-- /spec -->`) containing the
  acceptance-criteria checklist and out-of-scope items. The
  implementer reads this block as its contract; QA reviews
  against it.

Iterate by posting more comments. Rate-limited to 1 ideator response
per minute per issue to avoid comment floods.

If the ideator is blocked on you, it posts a comment starting with
`<!-- needs-human-input -->` and applies the `awaiting-human` label.
No agent activity resumes until you remove the label.

### 3. Implement

When the ideator says "ready for implementation" (or you agree the
scope is clear), apply the `ready:ai-implement` label.

Within ~5-10 minutes:
- Implementer checks out the existing feature branch
- Extracts the `<!-- spec -->` block from the most recent
  ideator comment as its contract (fails to `awaiting-human`
  if no block exists)
- Implements the feature (scope = acceptance criteria only)
- Runs full CI locally (`pnpm install`, `typecheck`, `lint`, `test`)
- Pushes + opens a draft PR whose body copies the spec block
  verbatim, ticks satisfied criteria, and lists deviations
- Marks ready, applies `pending-review`

### 4. Review panel (automatic)

Tier 1 (security + architect) run in parallel. Each posts a formal
PR review (APPROVE / REQUEST_CHANGES / COMMENT) via the GitHub
Reviews API — appears in the PR's Files/Conversation tabs as a
proper reviewer block, not timeline comments.

If both tier-1 approve, tier 2 spawns automatically: lead-dev,
designer, devrel, qa, devops — 5 more formal reviews. The QA
reviewer is the **acceptance gate**: it validates every
criterion in the PR's `<!-- spec -->` block against the diff
and blocks merge on any acceptance miss, missing spec block,
or out-of-scope addition.

### 5. Fix loop (if needed)

If any reviewer requests changes, the fixer Task:
- Reads all inline review comments
- Aggregates findings by severity
- Fixes files in scope
- Runs full CI locally
- Pushes a `fix(review): address N findings from round K` commit
- Replies to each inline comment with "Fixed in <sha>"

New push → fresh reviews on new SHA. Max 3 rounds.

### 6. Ready to merge

When all 7 reviewers APPROVE on the same HEAD SHA, the orchestrator
posts a `ready-to-merge` comment pinging the repo owner and applies
the label.

Human merges. Issue auto-closes via `Closes #N`.

### 7. Escalation

After 3 failed fix rounds, the orchestrator posts a summary of
remaining blockers and applies `review-failed` + `awaiting-human`.
Human resolves, removes `awaiting-human`, push → orchestrator resumes.

## Example flow

```
Issue #42 opened: "add hello endpoint"
├── human applies `ai-feature` label
│
├── T+5s:  Branch `feature/issue-42-add-hello-endpoint` created
│          Comment: branch link + instructions
│          Label: `branch-created`
│
├── human comments: "should return JSON {hello: 'world'}"
├── T+1m:  Ideator: "Q1: authentication required? Q2: route path?"
├── human: "no auth, /api/hello"
├── T+2m:  Ideator: "Ready for implementation. Apply `ready:ai-implement` label."
│
├── human applies `ready:ai-implement` label
│
├── T+5m:  Implementer pushes feat commit
│          Opens draft PR #43, marks ready
│          Label: `pending-review`
│
├── T+6m:  Security Review posted (APPROVE, no findings)
├── T+6m:  Architect Review posted (APPROVE, 1 nit comment)
│
├── T+7m:  Orchestrator: tier 1 both approved → spawning tier 2
├── T+9m:  Lead-Dev Review posted (REQUEST_CHANGES, 2 major)
├── T+10m: Designer Review posted (APPROVE)
├── T+10m: DevRel Review posted (APPROVE)
├── T+10m: QA Review posted (REQUEST_CHANGES, 1 blocker)
├── T+11m: DevOps Review posted (APPROVE)
│
├── T+11m: Orchestrator: 3 changes-requested → spawning fixer (round 1/3)
├── T+15m: Fixer pushes `fix(review): address 3 findings from round 1`
│
├── T+16m: Tier 1 + 2 re-run on new SHA
├── T+20m: All 7 APPROVE
│
└── T+20m: Orchestrator: all approved → "ready-to-merge" + ping
```

## Caveman mode

All agents run with caveman mode at level `full`. Conversational text
(issue comments, review findings, summaries) is terse:

> `src/auth.ts:42` — missing CSRF check on POST. fix: `validateCsrf(req)` before session mutation.

Code, commit messages, PR bodies, and security warnings stay normal
prose. The caveman preamble in each AgentConfig explicitly exempts
those from terseness.

## Architecture

```
GitHub webhook (events.example.com/github/pr)
  │
  ▼
Argo Events EventSource (github-webhook)
  │
  ├── Sensor: feature-branch-create (label.added = feature)
  │     → Job (gh clone k8-infra, run feature-branch-create.sh)
  │
  ├── Sensor: feature-ideator (issue_comment, rate-limited)
  │     → Kelos Task (feature-ideator AgentConfig)
  │
  ├── Sensor: feature-implementer (label.added = implement)
  │     → Kelos Task (feature-implementer AgentConfig, repo workspace)
  │
  ├── Sensor: feature-review-tier1 (PR ready_for_review / push)
  │     → 2 parallel Kelos Tasks (security, architect)
  │
  ├── Sensor: feature-review-orchestrator (pull_request_review / push)
  │     → Job (gh clone k8-infra, run feature-orchestrator.sh)
  │         Decides: spawn tier-2 / spawn fixer / ready-to-merge / escalate
  │
  └── Sensor: feature-human-resume (label.removed = awaiting-human)
        → Job (posts "unblocked" note on issue/PR)
```

All scripts live in [ci/scripts/](../ci/scripts/). Sensors git-clone
the repo at Job run time, so script changes don't require re-rendering
or re-applying the Sensor manifests.

## Required GitHub webhook events

The example-org org webhook must include:

- `issues` (label events on issues)
- `issue_comment` (ideation triggers)
- `pull_request` (ready_for_review, labeled, synchronize)
- `pull_request_review` (orchestrator verdict counting)
- `push` (re-review after fixer commits)

Verify: `gh api orgs/example-org/hooks --jq '.[].events'`

## Files

- [composites/preview/kelos.cue](../composites/preview/kelos.cue) — 10 AgentConfigs
- [composites/preview/argoevents.cue](../composites/preview/argoevents.cue) — 6 Sensors
- [composites/preview/jobs.cue](../composites/preview/jobs.cue) — feature-orchestrator ServiceAccount
- [composites/preview/clusterroles.cue](../composites/preview/clusterroles.cue) — feature-orchestrator ClusterRole
- [composites/preview/clusterrolebindings.cue](../composites/preview/clusterrolebindings.cue) — binding
- [ci/scripts/feature-branch-create.sh](../ci/scripts/feature-branch-create.sh)
- [ci/scripts/feature-orchestrator.sh](../ci/scripts/feature-orchestrator.sh)

## Quiet hours (LLM quota protection)

Claude Pro/Max session quota is shared between the operator's interactive
Claude usage and all automated Kelos Tasks. To avoid the agent pipeline
competing with interactive work, a quiet-hours feature pauses LLM-consuming
automation during weekday work hours.

### Schedule

- **Enter**: 8am America/New_York, weekdays (CronJob `quiet-hours-enter`)
- **Exit**: 2pm America/New_York, weekdays (CronJob `quiet-hours-exit`)

Time zone is `spec.timeZone: America/New_York` — K8s 1.25+ handles DST
automatically.

### What gets paused

**Paused during quiet hours:**

| Resource | Mechanism | State during quiet hours |
|---|---|---|
| TaskSpawners in `kelos-system` | `spec.suspend: true` | No new polling-based Tasks |
| LLM-creating Sensors in `argo-events` | `spec.replicas: 0` | Sensor pod down, events dropped |

LLM-creating Sensors (scale-to-0 targets):
- `feature-ideator`
- `feature-implementer`
- `feature-review-tier1`
- `feature-review-orchestrator`
- `code-explain`

**NOT paused** — these don't consume LLM quota and stay running:
- `feature-branch-create` — creates Job (gh api calls only)
- `feature-human-resume` — creates Job (posts a notice comment)
- `palette-init` — creates Job (posts static palette comment)
- `slash-help` — creates Job (posts static help reply)
- `preview-deploy` — creates argocd sync Job
- Watchdog CronJobs (oauth, reaper) — keep running

### Bypass

**Per-TaskSpawner bypass** — annotate the spawner to exclude it from
suspension:

```bash
kubectl annotate taskspawner <name> -n kelos-system \
  open-warren.io/always-on=true --overwrite
```

The CronJob skips any TaskSpawner with this annotation. Use sparingly
(e.g., `secret-wiring` if urgent secret requests are common).

**Global disable** — set the ConfigMap override:

```bash
kubectl patch configmap open-warren-quiet-hours -n kelos-system \
  --type merge -p '{"data":{"disabled":"true"}}'
```

When `data.disabled == "true"`, both CronJobs exit early with no action.
Current state persists (nothing un-suspended).

To re-enable: `kubectl patch ... -p '{"data":{"disabled":"false"}}'`.
The next scheduled CronJob run applies the appropriate state.

**Manual one-off resume** during quiet hours (e.g., urgent PR fix):

```bash
# Unsuspend a specific spawner
kubectl patch taskspawner ci-fixer-salessage -n kelos-system \
  --type merge -p '{"spec":{"suspend":false}}'

# Scale a Sensor back up
kubectl patch sensor feature-ideator -n argo-events \
  --type merge -p '{"spec":{"replicas":1}}'
```

The next `quiet-hours-enter` run re-suspends unless you annotate
`always-on=true`.

### Known limitation: per-PR bypass

A per-PR `urgent` label bypass is NOT implemented in v1. The scale-to-0
mechanism means scaled-down Sensors can't evaluate events at all —
including events for urgent-labeled PRs. Workarounds:

1. Manually unsuspend / scale up specific resources (see above).
2. Use the global disable ConfigMap for extended crunch periods.
3. Wait until 2pm ET — quiet hours end automatically.

A v2 implementation would duplicate LLM Sensors (one "normal" scaled
down during quiet hours, one "urgent-only" always-on filtered by PR
label). Deferred.

### Files

- [ci/scripts/quiet-hours-toggle.sh](../ci/scripts/quiet-hours-toggle.sh) — enter/exit script
- [composites/preview/cronjobs.cue](../composites/preview/cronjobs.cue) — 2 CronJobs
- [composites/preview/clusterroles.cue](../composites/preview/clusterroles.cue) — `quiet-hours-toggle` ClusterRole
- [composites/preview/jobs.cue](../composites/preview/jobs.cue) — `quiet-hours-toggle` ServiceAccount

## Limits + known issues

- **Review quality depends on context window.** Large PRs may overwhelm
  the reviewer's ability to reason about the whole diff. Consider
  splitting very large features before applying `ready:ai-implement`.
- **Caveman + inline comments** — GitHub renders inline review comments
  with markdown. Caveman fragments are fine; backticks around file:line
  references render as code.
- **Fixer conflict resolution** — when two reviewers disagree, higher
  severity wins. Tie breaks with security reviewer. Fixer replies
  inline noting the choice.
- **HMAC not validated on webhook.** Tunnel-only endpoint; accepted
  risk. Proper proxy-based HMAC is a v2 item.
- **Max fix rounds hardcoded at 3.** Adjust via `MAX_FIX_ROUNDS` env
  on the orchestrator Job.
- **Quiet hours per-PR bypass deferred.** See Quiet Hours section above.
