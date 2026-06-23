package home

let C = cluster

// ──────────────────────────────────────────────────────────────────────
// Preview-build WorkflowTemplate.
//
// Argo Events spawns one Workflow per PR-labeled event with these
// parameters (see argoevents.cue preview-build sensor):
//   - owner       (e.g. "example-org")
//   - repo        (e.g. "SalesSage")
//   - slug        (lowercase, e.g. "salessage")
//   - sha         (full 40-char commit SHA)
//   - prNumber    (e.g. "182")
//
// Pipeline:
//   1. clone   — git clone via x-access-token (App installation token)
//                into a shared emptyDir.
//   2. build   — BuildKit rootless. Builds the monorepo Dockerfile and
//                pushes to ghcr.io/{owner}/{slug}:sha-{sha}. Auth uses
//                the same App token (works for both GHCR push and
//                git LFS / submodule fetch).
//   3. notify  — POST the registry-push event to events.example.com
//                so the existing preview-deploy Sensor force-syncs the
//                ArgoCD Application without waiting for the 3-minute
//                ApplicationSet poll.
//
// All three steps share `/workspace` via an emptyDir-backed volume.
// Build resource budget: 4 GiB / 2 cores limit — Next.js standalone
// builds for makerkit-sized monorepos peak ~3.5 GiB.
// ──────────────────────────────────────────────────────────────────────
argoWorkflowTemplates: [
	{
		name:      "preview-build"
		namespace: "argo-workflows"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			entrypoint: "build-and-push"
			// Arguments default values exist so `argo submit` from the CLI
			// works as a smoke test; the Sensor overrides them on every
			// real invocation.
			arguments: parameters: [
				{name: "owner",    value: "example-org"},
				{name: "repo",     value: "SalesSage"},
				{name: "slug",     value: "salessage"},
				{name: "sha",      value: "HEAD"},
				{name: "prNumber", value: "0"},
			]
			// Reuse the workflow SA created by the chart. The SA has no
			// cluster-wide rights — it can only list/get its own pod log
			// for status reporting, which the chart wires automatically.
			serviceAccountName: "argo-workflow"

			// 30 minutes hard ceiling. Cold pnpm install + Next.js build
			// of a makerkit monorepo is ~12-18 minutes; warm cache trims
			// to ~5. Anything past 30 means something is wedged.
			activeDeadlineSeconds: 1800

			// Workspace volume shared by clone + build + notify. emptyDir
			// avoids PVC contention on Longhorn (the home cluster has
			// limited Longhorn headroom — see reference_home_storage).
			volumes: [{
				name: "workspace"
				emptyDir: sizeLimit: "8Gi"
			}, {
				name: "github-app-token"
				secret: {
					secretName: "github-app-token"
					items: [{key: "token", path: "token"}]
				}
			}]

			templates: [
				// ───────────────────────────────────────────────────────
				// Orchestration template — sequences build → notify.
				// `build` clones the repo via an initContainer + builds
				// the image in the main container of the same Pod so the
				// /workspace emptyDir is shared without needing a PVC.
				// ───────────────────────────────────────────────────────
				{
					name: "build-and-push"
					steps: [
						[{name: "build",  template: "buildkit"}],
						[{name: "notify", template: "notify"}],
					]
				},

				// ───────────────────────────────────────────────────────
				// buildkit — single Pod with:
				//   - initContainer `clone`: alpine/git, writes PR HEAD
				//     into /workspace (emptyDir, Pod-local).
				//   - main: moby/buildkit:rootless, builds Dockerfile from
				//     /workspace and pushes to GHCR via App token.
				// Argo Workflows steps are per-Pod, so the same Pod is
				// required to share the workspace volume.
				// `buildctl-daemonless.sh` boots a temporary buildkitd
				// alongside buildctl, then tears it down on exit — no
				// sidecar needed.
				// ───────────────────────────────────────────────────────
				{
					name: "buildkit"
					// Privileged BuildKit (not rootless). Talos kernel's
					// user-namespace limits make rootless BuildKit fail at
					// `unshare(CLONE_NEWUSER)` with "no space left on device"
					// even though sysctls look correct — Talos restricts the
					// runtime's unshare path independently of user.max_user_namespaces.
					// PSA on argo-workflows ns is already `privileged`, so
					// this is allowed. Blast radius: container has full
					// host capabilities, but only inside the workflow pod
					// — no persistent root mount.
					initContainers: [{
						name:  "clone"
						image: "alpine/git:2.45.2"
						command: ["/bin/sh", "-eu", "-c"]
						args: [#"""
							TOKEN=$(cat /run/github-app/token)
							URL="https://x-access-token:${TOKEN}@github.com/{{workflow.parameters.owner}}/{{workflow.parameters.repo}}.git"
							cd /workspace
							# emptyDir may be pre-owned root via implicit
							# mountPath; whitelist it before any git op
							# to avoid git's "dubious ownership" refusal.
							git config --global --add safe.directory /workspace
							git init -q
							git remote add origin "$URL"
							git fetch --depth=1 origin {{workflow.parameters.sha}}
							git -c advice.detachedHead=false checkout FETCH_HEAD
							echo "cloned {{workflow.parameters.owner}}/{{workflow.parameters.repo}}@{{workflow.parameters.sha}}"
							echo "tree size: $(du -sh /workspace | cut -f1)"
							"""#,
						]
						volumeMounts: [{
							name:      "workspace"
							mountPath: "/workspace"
						}, {
							name:      "github-app-token"
							mountPath: "/run/github-app"
							readOnly:  true
						}]
						resources: {
							requests: {cpu: "100m", memory: "256Mi"}
							limits: {cpu: "500m", memory: "512Mi"}
						}
					}]
					container: {
						// Privileged (root) BuildKit. The `-rootless` image
						// tag would be safer but requires kernel features
						// that Talos's userns sandbox blocks. The non-rootless
						// image runs buildkitd as PID 1 and listens on a
						// unix socket; the same shell wraps the build call.
						image: "moby/buildkit:v0.15.2"
						securityContext: privileged: true
						command: ["/bin/sh", "-eu", "-c"]
						args: [#"""
							# Build registry auth — GHCR accepts a GitHub App
							# installation token as the password with any
							# username (the token's scope is checked, not
							# the username). x-access-token is the canonical
							# username for clarity.
							TOKEN=$(cat /run/github-app/token)
							mkdir -p /root/.docker
							AUTH=$(printf '%s' "x-access-token:${TOKEN}" | base64 -w 0)
							cat > /root/.docker/config.json <<EOF
							{"auths":{"ghcr.io":{"auth":"${AUTH}"}}}
							EOF

							IMAGE="ghcr.io/{{workflow.parameters.owner}}/{{workflow.parameters.slug}}:sha-{{workflow.parameters.sha}}"
							echo "building $IMAGE"

							# Start buildkitd in the background, then run
							# buildctl. The image ships both binaries; the
							# unix socket path defaults to /run/buildkit/buildkitd.sock.
							buildkitd --addr unix:///run/buildkit/buildkitd.sock &
							for i in $(seq 1 20); do
								[ -S /run/buildkit/buildkitd.sock ] && break
								sleep 1
							done
							buildctl --addr unix:///run/buildkit/buildkitd.sock build \
								--frontend=dockerfile.v0 \
								--local context=/workspace \
								--local dockerfile=/workspace \
								--opt platform=linux/amd64 \
								--output "type=image,name=$IMAGE,push=true,registry.insecure=false"

							echo "pushed $IMAGE"
							"""#,
						]
						volumeMounts: [{
							name:      "workspace"
							mountPath: "/workspace"
						}, {
							name:      "github-app-token"
							mountPath: "/run/github-app"
							readOnly:  true
						}]
						resources: {
							// SalesSage's pnpm install pulls 1871 packages and
							// the subsequent Next.js standalone build spikes
							// resident memory hard — the first run OOMKilled
							// at 6Gi. Allocate generously; the node has
							// plenty of headroom (11Gi free) and the cgroup
							// limit is only enforced during the build's
							// lifetime.
							requests: {cpu: "1",    memory: "4Gi"}
							limits: {cpu: "4",    memory: "10Gi"}
						}
					}
				},

				// ───────────────────────────────────────────────────────
				// notify — fire BOTH halves of the existing preview-deploy
				// sensor's correlation expression:
				//   1. POST registry-push event (image-ready dependency)
				//   2. POST GitHub status check ci/preview-build=success
				//      (ci-success dependency)
				// Once both fire, preview-deploy creates the argocd sync Job.
				// ───────────────────────────────────────────────────────
				{
					name: "notify"
					container: {
						image: "curlimages/curl:8.10.0"
						command: ["/bin/sh", "-eu", "-c"]
						args: [#"""
							# 1. Registry-push event → image-ready dependency.
							PAYLOAD=$(printf '{"repository":"%s/%s","tag":"sha-%s","pr_number":%s}' \
								"{{workflow.parameters.owner}}" \
								"{{workflow.parameters.repo}}" \
								"{{workflow.parameters.sha}}" \
								"{{workflow.parameters.prNumber}}")
							echo "registry-push: $PAYLOAD"
							curl -sfS -X POST \
								-H 'Content-Type: application/json' \
								-d "$PAYLOAD" \
								https://events.example.com/registry/push

							# 2. GitHub status check ci/preview-build=success → ci-success dependency.
							TOKEN=$(cat /run/github-app/token)
							RUN_URL="https://argo-workflows.example.internal/workflows/argo-workflows/{{workflow.name}}"
							STATUS_BODY=$(printf '{"state":"success","context":"ci/preview-build","description":"Preview image pushed","target_url":"%s"}' "$RUN_URL")
							echo "github status: $STATUS_BODY"
							curl -sfS -X POST \
								-H "Authorization: token ${TOKEN}" \
								-H "Accept: application/vnd.github+json" \
								-d "$STATUS_BODY" \
								"https://api.github.com/repos/{{workflow.parameters.owner}}/{{workflow.parameters.repo}}/statuses/{{workflow.parameters.sha}}"
							echo "ArgoCD sync should trigger now"
							"""#,
						]
						volumeMounts: [{
							name:      "github-app-token"
							mountPath: "/run/github-app"
							readOnly:  true
						}]
						resources: {
							requests: {cpu: "50m", memory: "32Mi"}
							limits: {cpu: "200m", memory: "64Mi"}
						}
					}
				},
			]
		}
	},
]
