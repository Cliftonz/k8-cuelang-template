# Argo Events template gotcha — GitHub IDs render as scientific notation

## TL;DR

Argo Events parameter templates use Go's `text/template`, and the JSON
parser they use puts numbers into `float64`. When a GitHub identifier
crosses `2^32 ≈ 4.29 × 10⁹`, the default render becomes scientific
notation (`4.433828475e+09`), which contains `+` and `.` in positions
that Kubernetes resource names forbid. Sensors then **silently fail**
with an `error`-level log:

```
Task.kelos.dev "feature-ideator-example-bot-2-c4.433828475e+09" is invalid:
  metadata.name: Invalid value: "feature-ideator-example-bot-2-c4.433828475e+09":
  a lowercase RFC 1123 subdomain must consist of lower case alphanumeric
  characters, '-' or '.', and must start and end with an alphanumeric character
```

**Fix:** wrap any integer ID with `printf "%.0f"` in the template.

```cue
// Before
dataTemplate: "foo-{{ .Input.body.comment.id }}"

// After
dataTemplate: "foo-{{ printf \"%.0f\" .Input.body.comment.id }}"
```

## What it looks like to the operator

The user reports: "I commented on the issue, but the AI agent didn't
respond." No warning in `kubectl get tasks`, no failed sensor, no
sensor pod restart — everything looks healthy.

Diagnostic dead-ends that *look* relevant but aren't:

- Webhook delivery panels show `200 OK` — GitHub did deliver.
- EventSource pod logs `Succeeded to publish an event` — the event
  reached NATS.
- Sensor pod is `Running`, recently connected to NATS, no restarts.
- `grep -i warn` of sensor logs shows nothing for `issue_comment` —
  the sensor's WARN-level filter-rejection logger never fires, because
  the filter *passes*. The trigger then fails *after* the filter, at
  k8s-create time, and that failure is logged at `error` level — so
  you have to specifically `grep level.:.error` to see it.

## Why this is a step-change failure mode

GitHub IDs are monotonically increasing 64-bit integers. The IDs for
new comments, PRs, check-runs, etc. crossed the `2³²` threshold over
the course of 2024–2026. Before that, any naive
`{{ .Input.body.*.id }}` rendered as an integer-looking decimal
without scientific notation, because `float64` prints small integers
exactly. Above the threshold, Go's default `%v` formatter switches to
scientific notation for any float that needs more than ~7 significant
digits of mantissa.

There is no warning at the point of the change — it just starts
breaking when the next new comment/PR/check happens to land an ID
past the threshold.

## Sites that need the fix

Any sensor template that interpolates a GitHub integer ID into:

1. A **Kubernetes resource name** (most critical — fails the trigger):
   ```
   dataTemplate: "foo-{{ printf \"%.0f\" .Input.body.comment.id }}"
   ```
2. A **URL path** (silently 404s when the agent tries to hit it):
   ```
   /repos/{owner}/{repo}/issues/{{ printf "%.0f" .Input.body.issue.id }}
   ```
3. A **shell variable** that's later used in either of the above:
   ```
   COMMENT_ID='{{ printf "%.0f" .Input.body.comment.id }}'
   ```
4. **Cosmetic prompt text** (least critical, but worth fixing for
   readability and to keep the agent from being confused):
   ```
   Comment ID:      {{ printf "%.0f" .Input.body.comment.id }}
   ```

The same pitfall applies to any field GitHub emits as a JSON number:
`comment.id`, `issue.id`, `pull_request.id`, `check_run.id`,
`installation_id`, `user.id`, `repository.id`, `hook_id`,
`run_id`, etc. The repo-scoped numeric `pull_request.number` and
`issue.number` are usually safe (small per-repo counters), but
`pull_request.id` (global) and `comment.id` (global) are not.

## Detecting the same class of bug

1. **Sensor pod log scrape for `level":"error"`** — argo-events logs
   trigger failures at error level. Add a `kelos-oauth-watchdog`-style
   CronJob that periodically tails sensor pods for error lines and
   posts to Discord if anything new appears.

2. **CUE lint** — a `cue/internal/argo` lint that flags any
   `dataTemplate` containing `.Input.body.*.id` without a
   `printf "%.0f"` wrapper. Catches the bug class at PR time.

3. **End-to-end smoke** — a periodic (weekly?) synthetic webhook fire
   per sensor with a known-good payload using a comment ID > 2³². If
   the expected Task doesn't appear, alert.

## Why `text/template` does this

Go's standard library `encoding/json` decodes any JSON number into
`float64` when targeting an `interface{}`. Argo Events parameter
substitution does that. When Go's `text/template` then renders that
float through `{{ . }}` (no format specifier), it uses `fmt.Sprintf("%v", v)`,
which falls back to `%g` for `float64`. `%g` chooses between `%e`
(scientific) and `%f` (decimal) automatically — and for large
integers it picks scientific.

Workarounds inside the template:

| Approach | Pros | Cons |
|---|---|---|
| `{{ printf "%.0f" .X }}` | minimal, in-place | floats lose precision beyond `2⁵³ ≈ 9 × 10¹⁵` — fine for GitHub IDs (currently ~10¹⁰), but not infinite |
| `{{ .X | int64 }}` | precise | requires Sprig template functions, which argo-events doesn't enable by default |
| Use a string field like `.Input.body.comment.node_id` | no number formatting at all | node_id contains uppercase + underscore — invalid as a k8s name without further mangling |

`printf "%.0f"` is the right answer for the current scale.

## Related references

- argo-events parameter substitution: https://argoproj.github.io/argo-events/sensors/triggers/k8s-object-trigger/#parameterization
- Go `text/template` default formatting: https://pkg.go.dev/text/template#hdr-Actions
- Kubernetes RFC-1123 subdomain rules: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/

## Fix commits

- `891cb59 fix(home): comment.id rendered with %.0f to avoid scientific notation` — name-rendering call sites
- `ec45340 fix(home): apply %.0f comment.id fix to the remaining three call sites` — shell var + URL + prompt sites
