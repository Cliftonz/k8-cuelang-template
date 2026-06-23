# Why ORAS

## Summary

ORAS is the best fit for packaging rendered Kubernetes manifests as OCI artifacts.
It keeps the payload typed as an artifact, avoids container image assumptions,
and works cleanly with GitOps promotion by digest.

Resources:

- ORAS project: https://oras.land
- ORAS docs: https://oras.land/docs
- OCI Artifacts spec: https://github.com/opencontainers/artifacts
- OCI Image spec: https://github.com/opencontainers/image-spec

## Key Reasons

- Artifact-native: ORAS is designed for non-container artifacts.
- Clear intent: a manifest bundle is not a runnable image.
- OCI compatibility: works with any OCI registry.
- Digest promotion: immutable references for GitOps flows.
- Simple CLI: push and pull folders without extra build steps.

## Alternatives Considered

- Docker buildx: produces container images that must be extracted. https://docs.docker.com/buildx/working-with-buildx/
- Crane: easy pushes, but still image-style semantics. https://github.com/google/go-containerregistry/tree/main/cmd/crane
- Skopeo/Buildah: flexible but higher setup complexity for artifacts.
	- Skopeo: https://github.com/containers/skopeo
	- Buildah: https://github.com/containers/buildah

## Operational Fit

- Aligns with this repo's build flow (CUE render -> OCI artifact -> GitOps).
- Easy to automate in CI and Make targets.
- Supports local testing with OCI layout output.

## Example Usage

Publish:

```
make publish CLUSTER=infra-prod OCI_REF=registry.example.com/k8-infra/manifests:infra-prod-20260306
```

Pull:

```
oras pull registry.example.com/k8-infra/manifests:infra-prod-20260306 -o ./manifests
kubectl apply -R -f ./manifests
```
