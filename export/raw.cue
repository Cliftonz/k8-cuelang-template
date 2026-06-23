package export

// Raw-fallback export: same composite inputs as the Crossplane mode, but
// each entry is run through libs/render to produce the equivalent flat
// Kubernetes manifest. Target clusters apply this directly with kubectl —
// no Crossplane, no XRDs, no Compositions required.
//
// Activated by: cue export ./export/ -e manifestsRaw -t cluster=<name>
//
// Coverage: every in-cluster XRD that reduces to a kubectl-applyable
// resource. Helm wrappers, external-API providers (Harbor/Cloudflare),
// and SSA-patch XRDs (ObjectPatch, NodeTaint) are deferred to phase 3 —
// they emit RawExportSkipped placeholders the apply pipeline strips and
// reports separately.

import (
	"list"

	render "github.com/k8-infra/libs/render"
)

_clusterRaw: {
	for _name, _c in _allClusters {
		(_name): list.Concat([
			[for ns in _c.namespaces {(render.#RenderNamespace & {in: ns.spec}).out}],
			[for np in _c.networkPolicies {(render.#RenderNetworkPolicy & {in: np.spec}).out}],
			[for rq in _c.resourceQuotas {(render.#RenderResourceQuota & {in: rq.spec}).out}],
			[for rb in _c.roleBindings {(render.#RenderRoleBinding & {in: rb.spec}).out}],
			[for cr in _c.clusterRoles {(render.#RenderClusterRole & {in: cr.spec}).out}],
			[for crb in _c.clusterRoleBindings {(render.#RenderClusterRoleBinding & {in: crb.spec}).out}],
			[for sa in _c.serviceAccounts {(render.#RenderServiceAccount & {in: sa.spec}).out}],
			[for es in _c.externalSecrets {(render.#RenderExternalSecret & {in: es.spec}).out}],
			[for ces in _c.clusterExternalSecrets {(render.#RenderClusterExternalSecret & {in: ces.spec}).out}],
			[for css in _c.clusterSecretStores {(render.#RenderClusterSecretStore & {in: css.spec}).out}],
			[for cert in _c.certificates {(render.#RenderCertificate & {in: cert.spec}).out}],
			[for cj in _c.cronJobs {(render.#RenderCronJob & {in: cj.spec}).out}],
			[for j in _c.jobs {(render.#RenderJob & {in: j.spec}).out}],
			[for kp in _c.kyvernoPolicies {(render.#RenderKyvernoPolicy & {in: kp.spec}).out}],
			[for x in _c.argoEventBuses {(render.#RenderArgoEventBus & {in: x.spec}).out}],
			[for x in _c.argoEventSources {(render.#RenderArgoEventSource & {in: x.spec}).out}],
			[for x in _c.argoSensors {(render.#RenderArgoSensor & {in: x.spec}).out}],
			[for x in _c.argoAppProjects {(render.#RenderArgoAppProject & {in: x.spec}).out}],
			[for x in _c.argoApplicationSets {(render.#RenderArgoApplicationSet & {in: x.spec}).out}],
			[for x in _c.kelosWorkspaces {(render.#RenderKelosWorkspace & {in: x.spec}).out}],
			[for x in _c.kelosAgentConfigs {(render.#RenderKelosAgentConfig & {in: x.spec}).out}],
			[for x in _c.kelosTaskSpawners {(render.#RenderKelosTaskSpawner & {in: x.spec}).out}],
			[for x in _c.serversTransports {(render.#RenderServersTransport & {in: x.spec}).out}],
			[for x in _c.exposedServices {(render.#RenderExposedService & {in: x.spec}).out}],
			list.FlattenN([for x in _c.externalBackends {(render.#RenderExternalBackend & {in: x.spec}).out}], 1),
			list.FlattenN([for x in _c.metallbPools {(render.#RenderMetalLBPool & {in: x.spec}).out}], 1),
			[for x in _c.storageClasses {(render.#RenderStorageClass & {in: x.spec}).out}],
			[for ig in _c.ingresses {(render.#RenderIngress & {in: ig.spec}).out}],
			[for hr in _c.helmReleases {(render.#RenderHelmRelease & {in: hr.spec}).out}],
			[for op in _c.objectPatches {(render.#RenderObjectPatch & {in: op.spec}).out}],
			[for nt in _c.nodeTaints {(render.#RenderNodeTaint & {in: nt.spec}).out}],
			[for v in _c.verticalPodAutoscalers {(render.#RenderVerticalPodAutoscaler & {in: v.spec}).out}],
			[for w in _c.githubRepositoryWebhooks {(render.#RenderGithubRepositoryWebhookSkipped & {in: {name: w.spec.name, repository: w.spec.repository, url: w.spec.url}}).out}],
			[for awt in _c.argoWorkflowTemplates {(render.#RenderArgoWorkflowTemplateSkipped & {in: {name: awt.spec.name, namespace: awt.spec.namespace, tier: awt.spec.tier, cluster: awt.spec.cluster, owner: awt.spec.owner}}).out}],
			[for bp in _c.backupPolicies {(render.#RenderBackupPolicySkipped & {in: {name: bp.spec.name, schedule: bp.spec.schedule, tier: bp.spec.tier, cluster: bp.spec.cluster, owner: bp.spec.owner}}).out}],
			[for hr in _c.harborRegistries {(render.#RenderHarborSkipped & {in: {name: hr.spec.name, kind: "XHarborRegistry"}}).out}],
			[for hp in _c.harborProjects {(render.#RenderHarborSkipped & {in: {name: hp.spec.name, kind: "XHarborProject"}}).out}],
			[for go in _c.gpuOperators {(render.#RenderGpuOperatorSkipped & {in: {name: go.spec.name, namespace: go.spec.namespace, chartVersion: go.spec.chartVersion, tier: go.spec.tier, cluster: go.spec.cluster, owner: go.spec.owner, if go.spec.driverVariant != _|_ {driverVariant: go.spec.driverVariant}}}).out}],
			list.FlattenN([for ss in _c.staticSites {(render.#RenderStaticSite & {in: ss.spec}).out}], 1),
		])
	}
}

if _cluster != "" {
	manifestsRaw: _clusterRaw[_cluster]
}
if _cluster == "" {
	manifestsRaw: list.Concat([for _name, _r in _clusterRaw {_r}])
}
