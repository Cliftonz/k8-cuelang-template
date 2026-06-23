# Infrastructure Manifests

This directory holds static, version-pinned install manifests for core
platform components. Crossplane UXP is installed directly, while Kyverno,
Kubescape, and External Secrets are managed via Crossplane Provider Helm.

Provider Helm, Provider Kubernetes, and required functions are installed via
manifest applies in the UXP install script. Provider Helm and Provider
Kubernetes are configured with ProviderConfigs under
infrastructure/crossplane/providers. Each component folder contains a
Crossplane Helm Release manifest. Environment overrides are applied via
composites under composites/<cluster>/helmreleases.cue.
Kustomize wrappers are intentionally not used here.
