.PHONY: setup doctor install-hooks pre-push validate lint-argo-event-ids lint-cronjob-rbac lint-deprecated-apis export export-cluster export-split export-raw apply apply-raw watch docs-xrd diff clean delete-xrds delete publish test-kyverno test-e2e test-raw test-raw-coverage test-raw-postprocessors test-raw-goldens test-raw-parity test-raw-validity test-eso-session-watchdog check-np-post-dnat helm-immutable-check helm-immutable-fix

# Dev-env gate — every public target depends on `$(JARVY_SENTINEL)`, which runs
# `jarvy doctor` against jarvy.toml the first time `make` is invoked in a fresh
# checkout (or after jarvy.toml changes). Passes → touch sentinel, future
# invocations skip; fails → print "run make setup" and exit.
#
# Escape hatch: SKIP_JARVY_DOCTOR=1 bypasses the gate. Useful when jarvy
# itself is buggy (false-positive notinstalled on tools it found by path,
# overstrict semver on `~0.16` etc.) and you've already verified the tools
# you actually need are on PATH.
JARVY_SENTINEL := .make/jarvy-ready

# Git ref the helm-immutable check renders the "old" chart state from.
# Local default HEAD = working-tree edits vs last commit; in CI set to the
# PR base, e.g. BASE_REF=origin/main.
BASE_REF ?= HEAD

$(JARVY_SENTINEL): jarvy.toml
	@mkdir -p .make
	@if [ -n "$$SKIP_JARVY_DOCTOR" ]; then \
	  echo "[jarvy] SKIP_JARVY_DOCTOR set — bypassing doctor gate"; \
	  touch $@; \
	elif ! command -v jarvy >/dev/null 2>&1; then \
	  echo "jarvy is not installed."; \
	  echo "Install: brew install jarvy   (see https://jarvy.dev/quickstart/)"; \
	  echo "Or bypass: SKIP_JARVY_DOCTOR=1 make <target>"; \
	  exit 1; \
	elif ! jarvy doctor -f jarvy.toml >.make/jarvy-doctor.log 2>&1; then \
	  cat .make/jarvy-doctor.log; \
	  echo ""; \
	  echo "Dev environment is missing tools or has the wrong versions."; \
	  echo "Run: make setup   (or bypass: SKIP_JARVY_DOCTOR=1 make <target>)"; \
	  exit 1; \
	else \
	  touch $@; \
	fi

# Install/refresh every tool declared in jarvy.toml.
setup:
	@command -v jarvy >/dev/null 2>&1 || { \
	  echo "jarvy is not installed. Install one of:"; \
	  echo "  brew install jarvy"; \
	  echo "  curl -fsSL https://raw.githubusercontent.com/example-org/jarvy/main/dist/scripts/install.sh | bash"; \
	  exit 1; \
	}
	@jarvy setup -f jarvy.toml
	@mkdir -p .make && touch $(JARVY_SENTINEL)

# Verify the dev environment without installing anything.
doctor:
	@jarvy doctor -f jarvy.toml

# Point git at the versioned hooks in .githooks/ (enables the pre-push gate).
install-hooks:
	@git config core.hooksPath .githooks
	@echo "[hooks] core.hooksPath -> .githooks (pre-push gate active)"
	@echo "[hooks] bypass once with: SKIP_PREPUSH=1 git push"

# Run the full CI + publish gate locally (what the pre-push hook runs).
pre-push:
	@./ci/scripts/pre-push-check.sh

# Include Crossplane XRDs and Compositions in export (default: true)
PLATFORM ?= true

# Include shared composite resources in export (default: true)
SHARED ?= true

# Enable optional ExternalDNS UniFi webhook stack (default: false).
# Set UNIFI=true on a per-call basis to render the unifi extras.
UNIFI ?= false

# Paths to watch for changes (exclude clusters/ to avoid export loops)
WATCH_PATHS ?= export platform composites libs infrastructure ci docs cue.mod Makefile

# XRDs with immutable scope that may need recreation
XRD_RECREATE ?= xnamespaces.infra.k8 xstorageclasses.infra.k8 xnodetaints.infra.k8

# Recreate immutable-scope XRDs during apply (default: false)
XRD_RECREATE_ENABLED ?= false

# Validate all CUE schemas and definitions + run sensor-template lint
validate: lint-argo-event-ids | $(JARVY_SENTINEL)
	cue vet ./...

# Lint argo-events sensor templates for unsafe GitHub-ID rendering.
# Catches the class of bug where unwrapped {{ .Input.body.*.id }}
# renders as scientific notation for IDs > 2^32 (see
# docs/argo-events-large-int-pitfall.md).
lint-argo-event-ids: | $(JARVY_SENTINEL)
	@bash ci/scripts/lint-argo-event-ids.sh composites/home/argoevents.cue

# Cross-check CronJob bash bodies against the ClusterRoles their
# ServiceAccounts are bound to. Catches RBAC drift where a kubectl
# call is added to a script without bumping the role.
# Requires rendered output under clusters/home-raw/.
lint-cronjob-rbac: | $(JARVY_SENTINEL)
	@bash ci/scripts/lint-cronjob-rbac.sh

# Replay-test the ESO session-staleness watchdog against the regression
# fixtures that pin the 2026-05-15 OpenBao-cached-session incident.
# Runs the script body extracted from the rendered cronjob YAML against
# stubbed kubectl + curl; asserts patch is/isn't issued per case.
test-eso-session-watchdog: | $(JARVY_SENTINEL)
	@bash tests/scenarios/eso-session-watchdog/run.sh

# Export rendered YAML for all clusters (multi-doc, kubectl-ready)
export: validate | $(JARVY_SENTINEL)
	@rm -rf clusters/
	@mkdir -p clusters/
	cue export ./export/ -e manifests -t platform=$(PLATFORM) -t shared=$(SHARED) -t unifi=$(UNIFI) --out yaml | yq '.[]' > clusters/all.yaml

# Export rendered YAML for a specific cluster (multi-doc, kubectl-ready)
# Usage: make export-cluster CLUSTER=new-dev
# Export rendered YAML for a specific cluster, split per resource
# Usage: make export-cluster CLUSTER=new-dev
export-cluster: validate | $(JARVY_SENTINEL)
	@test -n "$(CLUSTER)" || (echo "Usage: make export-cluster CLUSTER=new-dev" && exit 1)
	@rm -rf clusters/$(CLUSTER)
	@mkdir -p clusters/$(CLUSTER)
	@echo "Exporting $(CLUSTER)..."
	@cue export ./export/ -e manifests -t cluster=$(CLUSTER) -t platform=$(PLATFORM) -t shared=$(SHARED) -t unifi=$(UNIFI) --out yaml | yq '.[]' | ./ci/scripts/split-manifests.sh clusters/$(CLUSTER)

# Export individual files per resource for a specific cluster (alias)
# Usage: make export-split CLUSTER=new-dev
export-split: export-cluster
# Export individual files per resource for a specific cluster
# Usage: make export-split CLUSTER=new-dev
export-split: validate | $(JARVY_SENTINEL)
	@test -n "$(CLUSTER)" || (echo "Usage: make export-split CLUSTER=new-dev" && exit 1)
	@rm -rf clusters/$(CLUSTER)
	@mkdir -p clusters/$(CLUSTER)
	@echo "Exporting $(CLUSTER)..."
	@cue export ./export/ -e manifests -t cluster=$(CLUSTER) -t platform=$(PLATFORM) -t unifi=$(UNIFI) --out yaml | yq '.[]' | ./ci/scripts/split-manifests.sh clusters/$(CLUSTER)

# Export raw flat YAML for a cluster — Crossplane-free fallback mode.
# No XRDs, no Compositions, no XNamespace claims — just Namespace/NetworkPolicy/
# ResourceQuota/RoleBinding/Ingress applyable against a vanilla kubectl context.
# Usage: make export-raw CLUSTER=home
export-raw: validate | $(JARVY_SENTINEL)
	@test -n "$(CLUSTER)" || (echo "Usage: make export-raw CLUSTER=home" && exit 1)
	@./ci/scripts/export-raw.sh $(CLUSTER)

# Apply raw manifests against the current kubectl context. Target cluster
# does NOT need Crossplane installed.
# Usage: make apply-raw CLUSTER=home
apply-raw: export-raw | $(JARVY_SENTINEL)
	@kubectl apply -R -f clusters/$(CLUSTER)-raw

# Run the full raw-fallback test suite (coverage + post-processors + goldens
# + parity + validity + cronjob-rbac drift + watchdog replay). Mirrors what
# CI does on every PR.
test-raw: test-raw-coverage test-raw-postprocessors test-raw-goldens test-raw-parity test-raw-validity lint-deprecated-apis lint-cronjob-rbac test-eso-session-watchdog

# Assert every _xrdMap entry has a dispatch line in export/raw.cue.
test-raw-coverage: | $(JARVY_SENTINEL)
	@./ci/scripts/test-raw-coverage.sh

# Edge-case unit tests for render-helm.sh + strip-skipped.sh.
test-raw-postprocessors: | $(JARVY_SENTINEL)
	@./ci/scripts/test-postprocessors.sh

# Byte-stable golden regression for raw output (RAW_HELM=skip).
test-raw-goldens: | $(JARVY_SENTINEL)
	@./ci/scripts/test-raw-export.sh

# Count-parity check: raw output count matches composite-input count per kind.
test-raw-parity: | $(JARVY_SENTINEL)
	@./ci/scripts/test-raw-parity.sh

# Validate rendered manifests against real Kubernetes OpenAPI schemas.
test-raw-validity: | $(JARVY_SENTINEL)
	@./ci/scripts/test-raw-validity.sh

# Scan rendered manifests for deprecated / removed Kubernetes APIs using
# Pluto. Operates on whatever currently sits under clusters/ — most useful
# right after `make export-raw` since Helm charts are expanded into raw
# manifests at that point. Target k8s pin matches Talos 1.13.2's bundled
# kubelet (v1.34). Exits non-zero on deprecated OR removed APIs.
lint-deprecated-apis: | $(JARVY_SENTINEL)
	@if [ ! -d clusters ] || [ -z "$$(find clusters -name '*.yaml' -type f -print -quit 2>/dev/null)" ]; then \
	    echo "no rendered manifests under clusters/ — run make export-raw CLUSTER=home first"; \
	    exit 1; \
	fi
	@pluto detect-files -d clusters/ --target-versions k8s=v1.34.0

# Export and apply manifests for a cluster
# Usage: make apply CLUSTER=new-dev
apply: export-split | $(JARVY_SENTINEL)
	@if [ "$(XRD_RECREATE_ENABLED)" = "true" ]; then \
		$(MAKE) delete-xrds; \
	fi
	@if [ -d "clusters/$(CLUSTER)/xrds" ]; then \
		kubectl apply -R -f clusters/$(CLUSTER)/xrds; \
		kubectl wait --for=condition=Established -f clusters/$(CLUSTER)/xrds --timeout=120s; \
	fi
	@kubectl apply -R -f clusters/$(CLUSTER)

# Pre-upgrade safety gate: detect chart-version bumps that would change an
# IMMUTABLE Kubernetes field, which `helm upgrade` cannot patch in place
# (wedges the provider-helm Release in STATE=failed). Read-only.
# Usage: make helm-immutable-check CLUSTER=home [BASE_REF=origin/main]
helm-immutable-check: | $(JARVY_SENTINEL)
	@BASE_REF=$(BASE_REF) bash ci/scripts/check-helm-immutable.sh $(CLUSTER)

# Same detection, then execute the kubectl deletes it recommends so the
# next `make apply` lands cleanly. Deletes are gated behind CONFIRM=1.
# Usage: make helm-immutable-fix CLUSTER=home CONFIRM=1
helm-immutable-fix: | $(JARVY_SENTINEL)
	@mkdir -p .make
	@rm -f .make/helm-immutable-remediation.txt
	@BASE_REF=$(BASE_REF) REMEDIATION_FILE=.make/helm-immutable-remediation.txt \
		bash ci/scripts/check-helm-immutable.sh $(CLUSTER) || true
	@if [ ! -s .make/helm-immutable-remediation.txt ]; then \
		echo "no immutable-field remediation needed."; \
	elif [ "$(CONFIRM)" != "1" ]; then \
		echo ""; echo ">> Re-run with CONFIRM=1 to execute the deletes above, then 'make apply CLUSTER=$(CLUSTER)'."; \
		exit 1; \
	else \
		echo ">> executing remediation deletes (CONFIRM=1):"; \
		while IFS= read -r cmd; do [ -z "$$cmd" ] && continue; echo "+ $$cmd"; $$cmd || true; done < .make/helm-immutable-remediation.txt; \
		echo ">> done. Now run: make apply CLUSTER=$(CLUSTER)"; \
	fi

# Delete rendered manifests for a cluster
# Usage: make delete CLUSTER=new-dev
delete: export-split | $(JARVY_SENTINEL)
	kubectl delete -R -f clusters/$(CLUSTER)

# Delete XRDs that require recreation (immutable scope changes)
delete-xrds: | $(JARVY_SENTINEL)
	@kubectl delete compositeresourcedefinition $(XRD_RECREATE) --ignore-not-found --wait=false

# Watch for changes, re-export, and re-apply
# Usage: make watch CLUSTER=new-dev
watch: | $(JARVY_SENTINEL)
	@test -n "$(CLUSTER)" || (echo "Usage: make watch CLUSTER=new-dev" && exit 1)
	@command -v fswatch >/dev/null 2>&1 || command -v entr >/dev/null 2>&1 || (echo "Install fswatch (brew install fswatch) or entr (brew install entr)" && exit 1)
	@make apply CLUSTER=$(CLUSTER) PLATFORM=$(PLATFORM)
	@echo "Watching: $(WATCH_PATHS)"
	@if command -v fswatch >/dev/null 2>&1; then \
		fswatch -o $(WATCH_PATHS) | while read -r _; do \
			make apply CLUSTER=$(CLUSTER) PLATFORM=$(PLATFORM); \
		done; \
	else \
		find $(WATCH_PATHS) -type f | entr -r make apply CLUSTER=$(CLUSTER) PLATFORM=$(PLATFORM); \
	fi

# Generate markdown docs from XRDs
docs-xrd: | $(JARVY_SENTINEL)
	@./ci/scripts/xrd-docs.sh

# Show diff between current rendered output and fresh export
diff: | $(JARVY_SENTINEL)
	@echo "Checking for drift in clusters/..."
	@ci/scripts/export.sh --dry-run

# Publish rendered manifests as an OCI artifact using ORAS
# Usage: make publish CLUSTER=new-dev OCI_REF=registry.example.com/k8-infra/manifests:tag
# Usage (docker registry): make publish CLUSTER=new-dev DOCKER_REF=localhost:5000/k8-infra/manifests:tag
# Local output: make publish CLUSTER=new-dev LOCAL_OUTPUT=oci-out [LOCAL_TAG=manifests]
publish: export-cluster | $(JARVY_SENTINEL)
	@./ci/scripts/publish.sh

# Run Kyverno tests against current kubectl context
# Usage: make test-kyverno CLUSTER=new-dev
# Optional: KYVERNO_INSTALL_URL=https://.../kyverno.yaml
test-kyverno: export-cluster | $(JARVY_SENTINEL)
	@./ci/scripts/test-kyverno.sh

# Run end-to-end tests against current kubectl context
# Usage: make test-e2e CLUSTER=new-dev
# Optional: KIND_CLUSTER_NAME=e2e-tests
test-e2e: export-cluster | $(JARVY_SENTINEL)
	@./ci/scripts/test-e2e.sh

# Audit live cluster for post-DNAT NetworkPolicy gaps — every Ingress is
# checked against the destination namespace's NPs to confirm the pod's
# actual containerPort is allowed (Cilium evaluates NPs after Service
# DNAT). Reads from the current kubectl context.
check-np-post-dnat: | $(JARVY_SENTINEL)
	@./ci/scripts/check-np-post-dnat.sh

# Remove CUE caches
clean:
	rm -rf cue.mod/pkg/ cue.mod/usr/
