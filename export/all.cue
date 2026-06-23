package export

import (
	"list"

	"github.com/k8-infra/libs/constants"
	preview "github.com/k8-infra/composites/preview:preview"
	home "github.com/k8-infra/composites/home:home"
	shared "github.com/k8-infra/composites/shared:shared"
	platformCompositions "github.com/k8-infra/platform/compositions:compositions"
	xrd "github.com/k8-infra/platform/xrd:xrd"
)

// Tag for single-cluster export: cue export ./export/ -t cluster=preview
_cluster: *"" | string @tag(cluster)

// Tag to include/exclude platform resources (XRDs + Compositions).
// Use -t platform=false to render only composite resources.
_platform: *"true" | string @tag(platform)
_includePlatform: _platform == "true"

// Tag to include/exclude shared composite resources.
// Use -t shared=false to skip shared resources.
_shared: *"true" | string @tag(shared)
_includeShared: _shared == "true"

// Tag to enable the optional ExternalDNS UniFi webhook stack.
// Use -t unifi=true to render the external-dns namespace, HelmRelease,
// and ExternalSecret defined in composites/preview/externaldns.cue.
// Default is off — the cluster works fine without it.
_unifi: *"false" | string @tag(unifi)
_includeUnifi: _unifi == "true"

_apiVersion: "\(constants.ApiGroup)/v1alpha1"
_platformXRDs: [...] | *[]
_platformComps: [...] | *[]
if _includePlatform {
	if _cluster != "" {
		// Per-cluster: only XRDs/Compositions whose composite list is
		// populated on this cluster.
		_platformXRDs:  _platformXRDsPerCluster[_cluster]
		_platformComps: _platformCompsPerCluster[_cluster]
	}
	if _cluster == "" {
		// Multi-cluster export: union of every cluster's used XRDs.
		_platformXRDs:  _unionXRDs
		_platformComps: _unionComps
	}
}

// _xrdMap is the single source of truth that ties a composite list field
// (e.g. `helmReleases`) to its XRD definition and matching Composition.
// To register a new platform API: add a key here. To retire one: delete
// the key. Per-cluster trimming below uses this map to avoid deploying
// XRDs whose composite list is empty on a given cluster.
_xrdMap: {
	namespaces: {definition:             xrd.xNamespace,             composition:        platformCompositions.namespaceComposition}
	roleBindings: {definition:           xrd.xRoleBinding,           composition:      platformCompositions.roleBindingComposition}
	resourceQuotas: {definition:         xrd.xResourceQuota,         composition:    platformCompositions.resourceQuotaComposition}
	networkPolicies: {definition:        xrd.xNetworkPolicy,         composition:   platformCompositions.networkPolicyComposition}
	helmReleases: {definition:           xrd.xHelmRelease,           composition:      platformCompositions.helmReleaseComposition}
	harborRegistries: {definition:       xrd.xHarborRegistry,        composition:  platformCompositions.harborRegistryComposition}
	harborProjects: {definition:         xrd.xHarborProject,         composition:    platformCompositions.harborProjectComposition}
	storageClasses: {definition:         xrd.xStorageClass,          composition:    platformCompositions.storageClassComposition}
	nodeTaints: {definition:             xrd.xNodeTaint,             composition:        platformCompositions.nodeTaintComposition}
	kyvernoPolicies: {definition:        xrd.xKyvernoPolicy,         composition:   platformCompositions.kyvernoPolicyComposition}
	argoEventBuses: {definition:         xrd.xArgoEventBus,          composition:    platformCompositions.argoEventBusComposition}
	argoEventSources: {definition:       xrd.xArgoEventSource,       composition:  platformCompositions.argoEventSourceComposition}
	argoSensors: {definition:            xrd.xArgoSensor,            composition:       platformCompositions.argoSensorComposition}
	argoWorkflowTemplates: {definition:  xrd.xArgoWorkflowTemplate,  composition: platformCompositions.argoWorkflowTemplateComposition}
	argoAppProjects: {definition:        xrd.xArgoAppProject,        composition:   platformCompositions.argoAppProjectComposition}
	argoApplicationSets: {definition:    xrd.xArgoApplicationSet,    composition: platformCompositions.argoApplicationSetComposition}
	kelosWorkspaces: {definition:        xrd.xKelosWorkspace,        composition:   platformCompositions.kelosWorkspaceComposition}
	kelosAgentConfigs: {definition:      xrd.xKelosAgentConfig,      composition:  platformCompositions.kelosAgentConfigComposition}
	kelosTaskSpawners: {definition:      xrd.xKelosTaskSpawner,      composition:  platformCompositions.kelosTaskSpawnerComposition}
	certificates: {definition:           xrd.xCertificate,           composition:      platformCompositions.certificateComposition}
	clusterExternalSecrets: {definition: xrd.xClusterExternalSecret, composition: platformCompositions.clusterExternalSecretComposition}
	cronJobs: {definition:               xrd.xCronJob,               composition:          platformCompositions.cronJobComposition}
	clusterRoles: {definition:           xrd.xClusterRole,           composition:      platformCompositions.clusterRoleComposition}
	clusterRoleBindings: {definition:    xrd.xClusterRoleBinding,    composition: platformCompositions.clusterRoleBindingComposition}
	externalSecrets: {definition:        xrd.xExternalSecret,        composition:   platformCompositions.externalSecretComposition}
	clusterSecretStores: {definition:    xrd.xClusterSecretStore,    composition: platformCompositions.clusterSecretStoreComposition}
	jobs: {definition:                   xrd.xJob,                   composition:              platformCompositions.jobComposition}
	serviceAccounts: {definition:        xrd.xServiceAccount,        composition:   platformCompositions.serviceAccountComposition}
	objectPatches: {definition:          xrd.xObjectPatch,           composition:     platformCompositions.objectPatchComposition}
	ingresses: {definition:              xrd.xIngress,               composition:         platformCompositions.ingressComposition}
	metallbPools: {definition:           xrd.xMetalLBPool,           composition:      platformCompositions.metallbPoolComposition}
	externalBackends: {definition:       xrd.xExternalBackend,       composition:  platformCompositions.externalBackendComposition}
	serversTransports: {definition:      xrd.xServersTransport,      composition: platformCompositions.serversTransportComposition}
	exposedServices: {definition:        xrd.xExposedService,        composition:   platformCompositions.exposedServiceComposition}
	githubRepositoryWebhooks: {definition: xrd.xGithubRepositoryWebhook, composition: platformCompositions.githubRepositoryWebhookComposition}
	gpuOperators: {definition:           xrd.xGpuOperator,           composition:      platformCompositions.gpuOperatorComposition}
	verticalPodAutoscalers: {definition: xrd.xVerticalPodAutoscaler, composition: platformCompositions.verticalPodAutoscalerComposition}
	staticSites: {definition:            xrd.xStaticSite,            composition:       platformCompositions.staticSiteComposition}
	backupPolicies: {definition:         xrd.xBackupPolicy,          composition:    platformCompositions.backupPolicyComposition}
}

// _clusterUsedFields[clusterName] is the list of composite field names
// where that cluster has at least one entry in the rendered output.
_clusterUsedFields: {
	for _name, _c in _allClusters {
		(_name): [for k, _ in _xrdMap if len(_c[k]) > 0 {k}]
	}
}

// Per-cluster XRD + Composition lists, derived from usage.
_platformXRDsPerCluster: {
	for _name, _fields in _clusterUsedFields {
		(_name): [for f in _fields {_xrdMap[f].definition}]
	}
}
_platformCompsPerCluster: {
	for _name, _fields in _clusterUsedFields {
		(_name): [for f in _fields {_xrdMap[f].composition}]
	}
}

// Union across all clusters — used when no cluster tag is set.
// A field is "used" if total entries across every cluster > 0.
_anyClusterUsesField: {
	for k, _ in _xrdMap {
		(k): list.Sum([for _name, _c in _allClusters {len(_c[k])}]) > 0
	}
}
_unionXRDs: [for k, used in _anyClusterUsesField if used {_xrdMap[k].definition}]
_unionComps: [for k, used in _anyClusterUsesField if used {_xrdMap[k].composition}]

// Default empty lists for optional composite resource types.
// Unify with a cluster import so missing fields resolve to [].
_compositeDefaults: {
	namespaces:             *[] | [...]
	roleBindings:           *[] | [...]
	resourceQuotas:         *[] | [...]
	networkPolicies:        *[] | [...]
	helmReleases:           *[] | [...]
	harborRegistries:       *[] | [...]
	harborProjects:         *[] | [...]
	storageClasses:         *[] | [...]
	nodeTaints:             *[] | [...]
	kyvernoPolicies:        *[] | [...]
	argoEventBuses:         *[] | [...]
	argoEventSources:       *[] | [...]
	argoSensors:            *[] | [...]
	argoWorkflowTemplates:  *[] | [...]
	argoAppProjects:        *[] | [...]
	argoApplicationSets:    *[] | [...]
	kelosWorkspaces:        *[] | [...]
	kelosAgentConfigs:      *[] | [...]
	kelosTaskSpawners:      *[] | [...]
	certificates:           *[] | [...]
	clusterExternalSecrets: *[] | [...]
	cronJobs:               *[] | [...]
	clusterRoles:           *[] | [...]
	clusterRoleBindings:    *[] | [...]
	externalSecrets:        *[] | [...]
	clusterSecretStores:    *[] | [...]
	jobs:                   *[] | [...]
	serviceAccounts:        *[] | [...]
	objectPatches:          *[] | [...]
	ingresses:              *[] | [...]
	metallbPools:           *[] | [...]
	externalBackends:       *[] | [...]
	serversTransports:      *[] | [...]
	exposedServices:        *[] | [...]
	githubRepositoryWebhooks: *[] | [...]
	gpuOperators:           *[] | [...]
	verticalPodAutoscalers: *[] | [...]
	staticSites:            *[] | [...]
	backupPolicies:         *[] | [...]
	...
}
_preview: _compositeDefaults & preview
_home:    _compositeDefaults & home
_sharedDefaults: _compositeDefaults & shared
if !_includeShared {
	_sharedDefaults: _compositeDefaults
}
_sharedPreview: _sharedDefaults & {cluster: preview.cluster}
_sharedHome:    _sharedDefaults & {cluster: home.cluster}

// XRDs and Compositions are now derived from `_xrdMap` + per-cluster
// composite usage above (`_platformXRDsPerCluster`, `_unionXRDs`).
// XRDs whose composite list is empty on a cluster are not deployed
// to that cluster — keeps apiserver memory + watch caches lean.

// Optional unifi extras — empty when -t unifi is not "true".
_unifiExtras: {
	namespaces:       [...]
	helmReleases:     [...]
	externalSecrets:  [...]
}
if _includeUnifi {
	_unifiExtras: _preview.unifiExtras
}
if !_includeUnifi {
	_unifiExtras: {namespaces: [], helmReleases: [], externalSecrets: []}
}

_allClusters: {
	"preview": {
		metadata: preview.cluster
		namespaces: [for ns in list.Concat([_sharedPreview.namespaces, _preview.namespaces, _unifiExtras.namespaces]) {
			apiVersion: _apiVersion
			kind:       "XNamespace"
			metadata: name: ns.name
			spec: {
				name:    ns.name
				tier:    ns.tier
				cluster: ns.cluster
				owner:   ns.owner
				if ns.labels != _|_ {
					labels: ns.labels
				}
			}
		}]
		roleBindings: [for rb in list.Concat([_sharedPreview.roleBindings, _preview.roleBindings]) {
			apiVersion: _apiVersion
			kind:       "XRoleBinding"
			metadata: name: rb.name
			spec: {
				name:      rb.name
				namespace: rb.namespace
				tier:      rb.tier
				cluster:   rb.cluster
				owner:     rb.owner
				roleRef:   rb.roleRef
				subjects:  rb.subjects
			}
		}]
		resourceQuotas: [for rq in list.Concat([_sharedPreview.resourceQuotas, _preview.resourceQuotas]) {
			apiVersion: _apiVersion
			kind:       "XResourceQuota"
			metadata: name: rq.name
			spec: {
				name:      rq.name
				namespace: rq.namespace
				tier:      rq.tier
				cluster:   rq.cluster
				owner:     rq.owner
				hard:      rq.hard
			}
		}]
		networkPolicies: [for np in list.Concat([_sharedPreview.networkPolicies, _preview.networkPolicies]) {
			apiVersion: _apiVersion
			kind:       "XNetworkPolicy"
			metadata: name: np.name
			spec: {
				name:      np.name
				namespace: np.namespace
				tier:      np.tier
				cluster:   np.cluster
				owner:     np.owner
				policy:    np.policy
			}
		}]
		helmReleases: [for hr in list.Concat([_sharedPreview.helmReleases, _preview.helmReleases, _unifiExtras.helmReleases]) {
			apiVersion: _apiVersion
			kind:       "XHelmRelease"
			metadata: name: hr.name
			spec: {
				name:      hr.name
				namespace: hr.namespace
				chart:     hr.chart
				values:    hr.values
				tier:      hr.tier
				cluster:   hr.cluster
				owner:     hr.owner
			}
		}]
		harborRegistries: [for reg in list.Concat([_sharedPreview.harborRegistries, _preview.harborRegistries]) {
			apiVersion: _apiVersion
			kind:       "XHarborRegistry"
			metadata: name: reg.name
			spec: {
				name:           reg.name
				endpointUrl:    reg.endpointUrl
				providerName:   reg.providerName
				description:    reg.description
				insecure:       reg.insecure
				deletionPolicy: reg.deletionPolicy
				tier:           reg.tier
				cluster:        reg.cluster
				owner:          reg.owner
			}
		}]
		harborProjects: [for proj in list.Concat([_sharedPreview.harborProjects, _preview.harborProjects]) {
			apiVersion: _apiVersion
			kind:       "XHarborProject"
			metadata: name: proj.name
			spec: {
				name:                    proj.name
				registryRef:             proj.registryRef
				public:                  proj.public
				vulnerabilityScanning:   proj.vulnerabilityScanning
				autoSbomGeneration:      proj.autoSbomGeneration
				enableContentTrust:      proj.enableContentTrust
				enableContentTrustCosign: proj.enableContentTrustCosign
				deletionPolicy:          proj.deletionPolicy
				tier:                    proj.tier
				cluster:                 proj.cluster
				owner:                   proj.owner
			}
		}]
		storageClasses: [for sc in list.Concat([_sharedPreview.storageClasses, _preview.storageClasses]) {
			apiVersion: _apiVersion
			kind:       "XStorageClass"
			metadata: name: sc.name
			spec: {
				name:                 sc.name
				provisioner:          sc.provisioner
				reclaimPolicy:        sc.reclaimPolicy
				allowVolumeExpansion: sc.allowVolumeExpansion
				volumeBindingMode:    sc.volumeBindingMode
				parameters:           sc.parameters
				tier:                 sc.tier
				cluster:              sc.cluster
				owner:                sc.owner
			}
		}]
		nodeTaints: [for nt in list.Concat([_sharedPreview.nodeTaints, _preview.nodeTaints]) {
			apiVersion: _apiVersion
			kind:       "XNodeTaint"
			metadata: name: nt.name
			spec: {
				name:     nt.name
				cluster:  nt.cluster
				owner:    nt.owner
				nodeName: nt.nodeName
				taints:   nt.taints
			}
		}]
		kyvernoPolicies: [for kp in _preview.kyvernoPolicies {
			apiVersion: _apiVersion
			kind:       "XKyvernoPolicy"
			metadata: name: kp.name
			spec: {
				name:    kp.name
				policy:  kp.policy
				tier:    kp.tier
				cluster: kp.cluster
				owner:   kp.owner
			}
		}]
		argoEventBuses: [for eb in _preview.argoEventBuses {
			apiVersion: _apiVersion
			kind:       "XArgoEventBus"
			metadata: name: eb.name
			spec: {
				name:      eb.name
				namespace: eb.namespace
				tier:      eb.tier
				cluster:   eb.cluster
				owner:     eb.owner
				config:    eb.config
			}
		}]
		argoEventSources: [for es in _preview.argoEventSources {
			apiVersion: _apiVersion
			kind:       "XArgoEventSource"
			metadata: name: es.name
			spec: {
				name:      es.name
				namespace: es.namespace
				tier:      es.tier
				cluster:   es.cluster
				owner:     es.owner
				config:    es.config
			}
		}]
		argoSensors: [for s in _preview.argoSensors {
			apiVersion: _apiVersion
			kind:       "XArgoSensor"
			metadata: name: s.name
			spec: {
				name:      s.name
				namespace: s.namespace
				tier:      s.tier
				cluster:   s.cluster
				owner:     s.owner
				config:    s.config
			}
		}]
		argoWorkflowTemplates: [for w in _preview.argoWorkflowTemplates {
			apiVersion: _apiVersion
			kind:       "XArgoWorkflowTemplate"
			metadata: name: w.name
			spec: {
				name:      w.name
				namespace: w.namespace
				tier:      w.tier
				cluster:   w.cluster
				owner:     w.owner
				config:    w.config
			}
		}]
		argoAppProjects: [for ap in _preview.argoAppProjects {
			apiVersion: _apiVersion
			kind:       "XArgoAppProject"
			metadata: name: ap.name
			spec: {
				name:      ap.name
				namespace: ap.namespace
				tier:      ap.tier
				cluster:   ap.cluster
				owner:     ap.owner
				config:    ap.config
			}
		}]
		argoApplicationSets: [for as in _preview.argoApplicationSets {
			apiVersion: _apiVersion
			kind:       "XArgoApplicationSet"
			metadata: name: as.name
			spec: {
				name:      as.name
				namespace: as.namespace
				tier:      as.tier
				cluster:   as.cluster
				owner:     as.owner
				config:    as.config
			}
		}]
		kelosWorkspaces: [for ws in _preview.kelosWorkspaces {
			apiVersion: _apiVersion
			kind:       "XKelosWorkspace"
			metadata: name: ws.name
			spec: {
				name:      ws.name
				namespace: ws.namespace
				tier:      ws.tier
				cluster:   ws.cluster
				owner:     ws.owner
				config:    ws.config
			}
		}]
		kelosAgentConfigs: [for ac in _preview.kelosAgentConfigs {
			apiVersion: _apiVersion
			kind:       "XKelosAgentConfig"
			metadata: name: ac.name
			spec: {
				name:      ac.name
				namespace: ac.namespace
				tier:      ac.tier
				cluster:   ac.cluster
				owner:     ac.owner
				config:    ac.config
			}
		}]
		kelosTaskSpawners: [for ts in _preview.kelosTaskSpawners {
			apiVersion: _apiVersion
			kind:       "XKelosTaskSpawner"
			metadata: name: ts.name
			spec: {
				name:      ts.name
				namespace: ts.namespace
				tier:      ts.tier
				cluster:   ts.cluster
				owner:     ts.owner
				config:    ts.config
			}
		}]
		githubRepositoryWebhooks: [for w in _preview.githubRepositoryWebhooks {
			apiVersion: _apiVersion
			kind:       "XGithubRepositoryWebhook"
			metadata: name: w.name
			spec: {
				name:            w.name
				repository:      w.repository
				events:          w.events
				urlSecretRef:    w.urlSecretRef
				secretSecretRef: w.secretSecretRef
				tier:            w.tier
				cluster:         w.cluster
				owner:           w.owner
			}
		}]
		certificates: [for cert in _preview.certificates {
			apiVersion: _apiVersion
			kind:       "XCertificate"
			metadata: name: cert.name
			spec: {
				name:      cert.name
				namespace: cert.namespace
				tier:      cert.tier
				cluster:   cert.cluster
				owner:     cert.owner
				config:    cert.config
			}
		}]
		clusterExternalSecrets: [for ces in _preview.clusterExternalSecrets {
			apiVersion: _apiVersion
			kind:       "XClusterExternalSecret"
			metadata: name: ces.name
			spec: {
				name:    ces.name
				cluster: ces.cluster
				owner:   ces.owner
				config:  ces.config
			}
		}]
		cronJobs: [for cj in _preview.cronJobs {
			apiVersion: _apiVersion
			kind:       "XCronJob"
			metadata: name: cj.name
			spec: {
				name:      cj.name
				namespace: cj.namespace
				tier:      cj.tier
				cluster:   cj.cluster
				owner:     cj.owner
				config:    cj.config
			}
		}]
		clusterRoles: [for cr in _preview.clusterRoles {
			apiVersion: _apiVersion
			kind:       "XClusterRole"
			metadata: name: cr.name
			spec: {
				name:    cr.name
				cluster: cr.cluster
				owner:   cr.owner
				rules:   cr.rules
			}
		}]
		clusterRoleBindings: [for crb in _preview.clusterRoleBindings {
			apiVersion: _apiVersion
			kind:       "XClusterRoleBinding"
			metadata: name: crb.name
			spec: {
				name:     crb.name
				cluster:  crb.cluster
				owner:    crb.owner
				roleRef:  crb.roleRef
				subjects: crb.subjects
			}
		}]
		externalSecrets: [for es in list.Concat([_preview.externalSecrets, _unifiExtras.externalSecrets]) {
			apiVersion: _apiVersion
			kind:       "XExternalSecret"
			metadata: name: es.name
			spec: {
				name:            es.name
				namespace:       es.namespace
				secretStoreRef:  es.secretStoreRef
				data:            es.data
				refreshInterval: es.refreshInterval
				tier:            es.tier
				cluster:         es.cluster
				owner:           es.owner
				if es.template != _|_ {
					template: es.template
				}
			}
		}]
		clusterSecretStores: [for css in _preview.clusterSecretStores {
			apiVersion: _apiVersion
			kind:       "XClusterSecretStore"
			metadata: name: css.name
			spec: {
				name:    css.name
				cluster: css.cluster
				owner:   css.owner
				config:  css.config
			}
		}]
		jobs: [for j in _preview.jobs {
			apiVersion: _apiVersion
			kind:       "XJob"
			metadata: name: j.name
			spec: {
				name:      j.name
				namespace: j.namespace
				tier:      j.tier
				cluster:   j.cluster
				owner:     j.owner
				config:    j.config
			}
		}]
		serviceAccounts: [for sa in _preview.serviceAccounts {
			apiVersion: _apiVersion
			kind:       "XServiceAccount"
			metadata: name: sa.name
			spec: {
				name:      sa.name
				namespace: sa.namespace
				tier:      sa.tier
				cluster:   sa.cluster
				owner:     sa.owner
			}
		}]
		objectPatches: [for op in _preview.objectPatches {
			apiVersion: _apiVersion
			kind:       "XObjectPatch"
			metadata: name: op.name
			spec: {
				name:        op.name
				targetRef:   op.targetRef
				annotations: op.annotations
				labels:      op.labels
				tier:        op.tier
				cluster:     op.cluster
				owner:       op.owner
			}
		}]
		ingresses: [for ig in _preview.ingresses {
			apiVersion: _apiVersion
			kind:       "XIngress"
			metadata: name: ig.name
			spec: {
				name:             ig.name
				namespace:        ig.namespace
				host:             ig.host
				serviceName:      ig.serviceName
				servicePort:      ig.servicePort
				tier:             ig.tier
				cluster:          ig.cluster
				owner:            ig.owner
				if ig.ingressClassName != _|_ {
					ingressClassName: ig.ingressClassName
				}
				if ig.tlsSecretName != _|_ {
					tlsSecretName: ig.tlsSecretName
				}
				if ig.annotations != _|_ {
					annotations: ig.annotations
				}
			}
		}]
		metallbPools: [for mp in _preview.metallbPools {
			apiVersion: _apiVersion
			kind:       "XMetalLBPool"
			metadata: name: mp.name
			spec: {
				name:      mp.name
				addresses: mp.addresses
				tier:      mp.tier
				cluster:   mp.cluster
				owner:     mp.owner
				if mp.namespace != _|_ {
					namespace: mp.namespace
				}
				if mp.autoAssign != _|_ {
					autoAssign: mp.autoAssign
				}
				if mp.avoidBuggyIPs != _|_ {
					avoidBuggyIPs: mp.avoidBuggyIPs
				}
			}
		}]
		externalBackends: [for eb in _preview.externalBackends {
			apiVersion: _apiVersion
			kind:       "XExternalBackend"
			metadata: name: eb.name
			spec: {
				name:       eb.name
				namespace:  eb.namespace
				port:       eb.port
				targetPort: eb.targetPort
				addresses:  eb.addresses
				tier:       eb.tier
				cluster:    eb.cluster
				owner:      eb.owner
				if eb.protocol != _|_ {
					protocol: eb.protocol
				}
				if eb.portName != _|_ {
					portName: eb.portName
				}
				if eb.annotations != _|_ {
					annotations: eb.annotations
				}
			}
		}]
		serversTransports: [for st in _preview.serversTransports {
			apiVersion: _apiVersion
			kind:       "XServersTransport"
			// XR is cluster-scoped; prefix with namespace so two transports
			// of the same short name in different namespaces don't collide.
			// The downstream Traefik ServersTransport keeps spec.name as
			// its short name in its namespace.
			metadata: name: "\(st.namespace)-\(st.name)"
			spec: {
				name:      st.name
				namespace: st.namespace
				tier:      st.tier
				cluster:   st.cluster
				owner:     st.owner
				if st.insecureSkipVerify != _|_ {
					insecureSkipVerify: st.insecureSkipVerify
				}
			}
		}]
		gpuOperators: [for go in _preview.gpuOperators {
			apiVersion: _apiVersion
			kind:       "XGpuOperator"
			metadata: name: go.name
			spec: {
				name:         go.name
				namespace:    go.namespace
				chartVersion: go.chartVersion
				tier:         go.tier
				cluster:      go.cluster
				owner:        go.owner
				if go.driverVariant != _|_ {
					driverVariant: go.driverVariant
				}
				if go.extraValues != _|_ {
					extraValues: go.extraValues
				}
			}
		}]
		exposedServices: [for es in _preview.exposedServices {
			apiVersion: _apiVersion
			kind:       "XExposedService"
			metadata: name: es.name
			spec: {
				name:       es.name
				namespace:  es.namespace
				selector:   es.selector
				targetPort: es.targetPort
				omniPort:   es.omniPort
				omniLabel:  es.omniLabel
				omniPrefix: es.omniPrefix
				tier:       es.tier
				cluster:    es.cluster
				owner:      es.owner
				if es.port != _|_ {
					port: es.port
				}
				if es.portName != _|_ {
					portName: es.portName
				}
			}
		}]
		verticalPodAutoscalers: [for v in _preview.verticalPodAutoscalers {
			apiVersion: _apiVersion
			kind:       "XVerticalPodAutoscaler"
			metadata: name: v.name
			spec: {
				name:      v.name
				namespace: v.namespace
				targetRef: v.targetRef
				tier:      v.tier
				cluster:   v.cluster
				owner:     v.owner
				if v.updateMode != _|_ {
					updateMode: v.updateMode
				}
				if v.resourcePolicy != _|_ {
					resourcePolicy: v.resourcePolicy
				}
			}
		}]
		staticSites: [for ss in _preview.staticSites {
			apiVersion: _apiVersion
			kind:       "XStaticSite"
			metadata: name: ss.name
			spec: {
				name:      ss.name
				namespace: ss.namespace
				tier:      ss.tier
				cluster:   ss.cluster
				owner:     ss.owner
				config:    ss.config
			}
		}]
		backupPolicies: [for bp in _preview.backupPolicies {
			apiVersion: _apiVersion
			kind:       "XBackupPolicy"
			metadata: name: bp.name
			spec: bp.spec
		}]
	}
	"home": {
		metadata: home.cluster
		namespaces: [for ns in list.Concat([_sharedHome.namespaces, _home.namespaces]) {
			apiVersion: _apiVersion
			kind:       "XNamespace"
			metadata: name: ns.name
			spec: {
				name:    ns.name
				tier:    ns.tier
				cluster: ns.cluster
				owner:   ns.owner
				if ns.labels != _|_ {
					labels: ns.labels
				}
			}
		}]
		roleBindings: [for rb in list.Concat([_sharedHome.roleBindings, _home.roleBindings]) {
			apiVersion: _apiVersion
			kind:       "XRoleBinding"
			metadata: name: rb.name
			spec: {
				name:      rb.name
				namespace: rb.namespace
				tier:      rb.tier
				cluster:   rb.cluster
				owner:     rb.owner
				roleRef:   rb.roleRef
				subjects:  rb.subjects
			}
		}]
		resourceQuotas: [for rq in list.Concat([_sharedHome.resourceQuotas, _home.resourceQuotas]) {
			apiVersion: _apiVersion
			kind:       "XResourceQuota"
			metadata: name: rq.name
			spec: {
				name:      rq.name
				namespace: rq.namespace
				tier:      rq.tier
				cluster:   rq.cluster
				owner:     rq.owner
				hard:      rq.hard
			}
		}]
		networkPolicies: [for np in list.Concat([_sharedHome.networkPolicies, _home.networkPolicies]) {
			apiVersion: _apiVersion
			kind:       "XNetworkPolicy"
			metadata: name: np.name
			spec: {
				name:      np.name
				namespace: np.namespace
				tier:      np.tier
				cluster:   np.cluster
				owner:     np.owner
				policy:    np.policy
			}
		}]
		helmReleases: [for hr in list.Concat([_sharedHome.helmReleases, _home.helmReleases]) {
			apiVersion: _apiVersion
			kind:       "XHelmRelease"
			metadata: name: hr.name
			spec: {
				name:      hr.name
				namespace: hr.namespace
				chart:     hr.chart
				values:    hr.values
				tier:      hr.tier
				cluster:   hr.cluster
				owner:     hr.owner
			}
		}]
		harborRegistries: [for reg in list.Concat([_sharedHome.harborRegistries, _home.harborRegistries]) {
			apiVersion: _apiVersion
			kind:       "XHarborRegistry"
			metadata: name: reg.name
			spec: {
				name:           reg.name
				endpointUrl:    reg.endpointUrl
				providerName:   reg.providerName
				description:    reg.description
				insecure:       reg.insecure
				deletionPolicy: reg.deletionPolicy
				tier:           reg.tier
				cluster:        reg.cluster
				owner:          reg.owner
			}
		}]
		harborProjects: [for proj in list.Concat([_sharedHome.harborProjects, _home.harborProjects]) {
			apiVersion: _apiVersion
			kind:       "XHarborProject"
			metadata: name: proj.name
			spec: {
				name:                    proj.name
				registryRef:             proj.registryRef
				public:                  proj.public
				vulnerabilityScanning:   proj.vulnerabilityScanning
				autoSbomGeneration:      proj.autoSbomGeneration
				enableContentTrust:      proj.enableContentTrust
				enableContentTrustCosign: proj.enableContentTrustCosign
				deletionPolicy:          proj.deletionPolicy
				tier:                    proj.tier
				cluster:                 proj.cluster
				owner:                   proj.owner
			}
		}]
		storageClasses: [for sc in list.Concat([_sharedHome.storageClasses, _home.storageClasses]) {
			apiVersion: _apiVersion
			kind:       "XStorageClass"
			metadata: name: sc.name
			spec: {
				name:                 sc.name
				provisioner:          sc.provisioner
				reclaimPolicy:        sc.reclaimPolicy
				allowVolumeExpansion: sc.allowVolumeExpansion
				volumeBindingMode:    sc.volumeBindingMode
				parameters:           sc.parameters
				tier:                 sc.tier
				cluster:              sc.cluster
				owner:                sc.owner
			}
		}]
		nodeTaints: [for nt in list.Concat([_sharedHome.nodeTaints, _home.nodeTaints]) {
			apiVersion: _apiVersion
			kind:       "XNodeTaint"
			metadata: name: nt.name
			spec: {
				name:     nt.name
				cluster:  nt.cluster
				owner:    nt.owner
				nodeName: nt.nodeName
				taints:   nt.taints
			}
		}]
		kyvernoPolicies: [for kp in _home.kyvernoPolicies {
			apiVersion: _apiVersion
			kind:       "XKyvernoPolicy"
			metadata: name: kp.name
			spec: {
				name:    kp.name
				policy:  kp.policy
				tier:    kp.tier
				cluster: kp.cluster
				owner:   kp.owner
			}
		}]
		argoEventBuses: [for eb in _home.argoEventBuses {
			apiVersion: _apiVersion
			kind:       "XArgoEventBus"
			metadata: name: eb.name
			spec: {
				name:      eb.name
				namespace: eb.namespace
				tier:      eb.tier
				cluster:   eb.cluster
				owner:     eb.owner
				config:    eb.config
			}
		}]
		argoEventSources: [for es in _home.argoEventSources {
			apiVersion: _apiVersion
			kind:       "XArgoEventSource"
			metadata: name: es.name
			spec: {
				name:      es.name
				namespace: es.namespace
				tier:      es.tier
				cluster:   es.cluster
				owner:     es.owner
				config:    es.config
			}
		}]
		argoSensors: [for s in _home.argoSensors {
			apiVersion: _apiVersion
			kind:       "XArgoSensor"
			metadata: name: s.name
			spec: {
				name:      s.name
				namespace: s.namespace
				tier:      s.tier
				cluster:   s.cluster
				owner:     s.owner
				config:    s.config
			}
		}]
		argoWorkflowTemplates: [for w in _home.argoWorkflowTemplates {
			apiVersion: _apiVersion
			kind:       "XArgoWorkflowTemplate"
			metadata: name: w.name
			spec: {
				name:      w.name
				namespace: w.namespace
				tier:      w.tier
				cluster:   w.cluster
				owner:     w.owner
				config:    w.config
			}
		}]
		argoAppProjects: [for ap in _home.argoAppProjects {
			apiVersion: _apiVersion
			kind:       "XArgoAppProject"
			metadata: name: ap.name
			spec: {
				name:      ap.name
				namespace: ap.namespace
				tier:      ap.tier
				cluster:   ap.cluster
				owner:     ap.owner
				config:    ap.config
			}
		}]
		argoApplicationSets: [for as in _home.argoApplicationSets {
			apiVersion: _apiVersion
			kind:       "XArgoApplicationSet"
			metadata: name: as.name
			spec: {
				name:      as.name
				namespace: as.namespace
				tier:      as.tier
				cluster:   as.cluster
				owner:     as.owner
				config:    as.config
			}
		}]
		kelosWorkspaces: [for ws in _home.kelosWorkspaces {
			apiVersion: _apiVersion
			kind:       "XKelosWorkspace"
			metadata: name: ws.name
			spec: {
				name:      ws.name
				namespace: ws.namespace
				tier:      ws.tier
				cluster:   ws.cluster
				owner:     ws.owner
				config:    ws.config
			}
		}]
		kelosAgentConfigs: [for ac in _home.kelosAgentConfigs {
			apiVersion: _apiVersion
			kind:       "XKelosAgentConfig"
			metadata: name: ac.name
			spec: {
				name:      ac.name
				namespace: ac.namespace
				tier:      ac.tier
				cluster:   ac.cluster
				owner:     ac.owner
				config:    ac.config
			}
		}]
		kelosTaskSpawners: [for ts in _home.kelosTaskSpawners {
			apiVersion: _apiVersion
			kind:       "XKelosTaskSpawner"
			metadata: name: ts.name
			spec: {
				name:      ts.name
				namespace: ts.namespace
				tier:      ts.tier
				cluster:   ts.cluster
				owner:     ts.owner
				config:    ts.config
			}
		}]
		githubRepositoryWebhooks: [for w in _home.githubRepositoryWebhooks {
			apiVersion: _apiVersion
			kind:       "XGithubRepositoryWebhook"
			metadata: name: w.name
			spec: {
				name:            w.name
				repository:      w.repository
				events:          w.events
				urlSecretRef:    w.urlSecretRef
				secretSecretRef: w.secretSecretRef
				tier:            w.tier
				cluster:         w.cluster
				owner:           w.owner
			}
		}]
		certificates: [for cert in _home.certificates {
			apiVersion: _apiVersion
			kind:       "XCertificate"
			metadata: name: cert.name
			spec: {
				name:      cert.name
				namespace: cert.namespace
				tier:      cert.tier
				cluster:   cert.cluster
				owner:     cert.owner
				config:    cert.config
			}
		}]
		clusterExternalSecrets: [for ces in _home.clusterExternalSecrets {
			apiVersion: _apiVersion
			kind:       "XClusterExternalSecret"
			metadata: name: ces.name
			spec: {
				name:    ces.name
				cluster: ces.cluster
				owner:   ces.owner
				config:  ces.config
			}
		}]
		cronJobs: [for cj in _home.cronJobs {
			apiVersion: _apiVersion
			kind:       "XCronJob"
			metadata: name: cj.name
			spec: {
				name:      cj.name
				namespace: cj.namespace
				tier:      cj.tier
				cluster:   cj.cluster
				owner:     cj.owner
				config:    cj.config
			}
		}]
		clusterRoles: [for cr in _home.clusterRoles {
			apiVersion: _apiVersion
			kind:       "XClusterRole"
			metadata: name: cr.name
			spec: {
				name:    cr.name
				cluster: cr.cluster
				owner:   cr.owner
				rules:   cr.rules
			}
		}]
		clusterRoleBindings: [for crb in _home.clusterRoleBindings {
			apiVersion: _apiVersion
			kind:       "XClusterRoleBinding"
			metadata: name: crb.name
			spec: {
				name:     crb.name
				cluster:  crb.cluster
				owner:    crb.owner
				roleRef:  crb.roleRef
				subjects: crb.subjects
			}
		}]
		externalSecrets: [for es in _home.externalSecrets {
			apiVersion: _apiVersion
			kind:       "XExternalSecret"
			metadata: name: es.name
			spec: {
				name:            es.name
				namespace:       es.namespace
				secretStoreRef:  es.secretStoreRef
				refreshInterval: es.refreshInterval
				tier:            es.tier
				cluster:         es.cluster
				owner:           es.owner
				// `data` and `dataFrom` are both optional at the XRD layer
				// — at least one must be set. Pass through only what the
				// claim provided.
				if es.data != _|_ {
					data: es.data
				}
				if es.dataFrom != _|_ {
					dataFrom: es.dataFrom
				}
				if es.template != _|_ {
					template: es.template
				}
			}
		}]
		clusterSecretStores: [for css in _home.clusterSecretStores {
			apiVersion: _apiVersion
			kind:       "XClusterSecretStore"
			metadata: name: css.name
			spec: {
				name:    css.name
				cluster: css.cluster
				owner:   css.owner
				config:  css.config
			}
		}]
		jobs: [for j in _home.jobs {
			apiVersion: _apiVersion
			kind:       "XJob"
			metadata: name: j.name
			spec: {
				name:      j.name
				namespace: j.namespace
				tier:      j.tier
				cluster:   j.cluster
				owner:     j.owner
				config:    j.config
			}
		}]
		serviceAccounts: [for sa in _home.serviceAccounts {
			apiVersion: _apiVersion
			kind:       "XServiceAccount"
			metadata: name: sa.name
			spec: {
				name:      sa.name
				namespace: sa.namespace
				tier:      sa.tier
				cluster:   sa.cluster
				owner:     sa.owner
			}
		}]
		objectPatches: [for op in _home.objectPatches {
			apiVersion: _apiVersion
			kind:       "XObjectPatch"
			metadata: name: op.name
			spec: {
				name:        op.name
				targetRef:   op.targetRef
				annotations: op.annotations
				labels:      op.labels
				tier:        op.tier
				cluster:     op.cluster
				owner:       op.owner
			}
		}]
		ingresses: [for ig in _home.ingresses {
			apiVersion: _apiVersion
			kind:       "XIngress"
			metadata: name: ig.name
			spec: {
				name:             ig.name
				namespace:        ig.namespace
				host:             ig.host
				serviceName:      ig.serviceName
				servicePort:      ig.servicePort
				tier:             ig.tier
				cluster:          ig.cluster
				owner:            ig.owner
				if ig.ingressClassName != _|_ {
					ingressClassName: ig.ingressClassName
				}
				if ig.tlsSecretName != _|_ {
					tlsSecretName: ig.tlsSecretName
				}
				if ig.annotations != _|_ {
					annotations: ig.annotations
				}
			}
		}]
		externalBackends: [for eb in _home.externalBackends {
			apiVersion: _apiVersion
			kind:       "XExternalBackend"
			metadata: name: eb.name
			spec: {
				name:       eb.name
				namespace:  eb.namespace
				port:       eb.port
				targetPort: eb.targetPort
				addresses:  eb.addresses
				tier:       eb.tier
				cluster:    eb.cluster
				owner:      eb.owner
				if eb.protocol != _|_ {
					protocol: eb.protocol
				}
				if eb.portName != _|_ {
					portName: eb.portName
				}
				if eb.annotations != _|_ {
					annotations: eb.annotations
				}
			}
		}]
		serversTransports: [for st in _home.serversTransports {
			apiVersion: _apiVersion
			kind:       "XServersTransport"
			// XR is cluster-scoped; prefix with namespace so two transports
			// of the same short name in different namespaces don't collide.
			// The downstream Traefik ServersTransport keeps spec.name as
			// its short name in its namespace.
			metadata: name: "\(st.namespace)-\(st.name)"
			spec: {
				name:      st.name
				namespace: st.namespace
				tier:      st.tier
				cluster:   st.cluster
				owner:     st.owner
				if st.insecureSkipVerify != _|_ {
					insecureSkipVerify: st.insecureSkipVerify
				}
			}
		}]
		gpuOperators: [for go in _home.gpuOperators {
			apiVersion: _apiVersion
			kind:       "XGpuOperator"
			metadata: name: go.name
			spec: {
				name:         go.name
				namespace:    go.namespace
				chartVersion: go.chartVersion
				tier:         go.tier
				cluster:      go.cluster
				owner:        go.owner
				if go.driverVariant != _|_ {
					driverVariant: go.driverVariant
				}
				if go.extraValues != _|_ {
					extraValues: go.extraValues
				}
			}
		}]
		exposedServices: [for es in _home.exposedServices {
			apiVersion: _apiVersion
			kind:       "XExposedService"
			metadata: name: es.name
			spec: {
				name:       es.name
				namespace:  es.namespace
				selector:   es.selector
				targetPort: es.targetPort
				omniPort:   es.omniPort
				omniLabel:  es.omniLabel
				omniPrefix: es.omniPrefix
				tier:       es.tier
				cluster:    es.cluster
				owner:      es.owner
				if es.port != _|_ {
					port: es.port
				}
				if es.portName != _|_ {
					portName: es.portName
				}
			}
		}]
		metallbPools: [for mp in _home.metallbPools {
			apiVersion: _apiVersion
			kind:       "XMetalLBPool"
			metadata: name: mp.name
			spec: {
				name:      mp.name
				addresses: mp.addresses
				tier:      mp.tier
				cluster:   mp.cluster
				owner:     mp.owner
				if mp.namespace != _|_ {
					namespace: mp.namespace
				}
				if mp.autoAssign != _|_ {
					autoAssign: mp.autoAssign
				}
				if mp.avoidBuggyIPs != _|_ {
					avoidBuggyIPs: mp.avoidBuggyIPs
				}
			}
		}]
		verticalPodAutoscalers: [for v in _home.verticalPodAutoscalers {
			apiVersion: _apiVersion
			kind:       "XVerticalPodAutoscaler"
			metadata: name: v.name
			spec: {
				name:      v.name
				namespace: v.namespace
				targetRef: v.targetRef
				tier:      v.tier
				cluster:   v.cluster
				owner:     v.owner
				if v.updateMode != _|_ {
					updateMode: v.updateMode
				}
				if v.resourcePolicy != _|_ {
					resourcePolicy: v.resourcePolicy
				}
			}
		}]
		staticSites: [for ss in _home.staticSites {
			apiVersion: _apiVersion
			kind:       "XStaticSite"
			metadata: name: ss.name
			spec: {
				name:      ss.name
				namespace: ss.namespace
				tier:      ss.tier
				cluster:   ss.cluster
				owner:     ss.owner
				config:    ss.config
			}
		}]
		backupPolicies: [for bp in _home.backupPolicies {
			apiVersion: _apiVersion
			kind:       "XBackupPolicy"
			metadata: name: bp.name
			spec: bp.spec
		}]
	}
}

// When -t cluster=<name> is set, emit only that cluster; otherwise emit all.
if _cluster != "" {
	clusters: (_allClusters & {[_cluster]: _})[_cluster]
}
if _cluster == "" {
	clusters: _allClusters
}

// Flat list of all manifests in apply order: XRDs → Compositions → Composites.
// Use `cue export ./export/ -e manifests --out yaml` to get multi-doc YAML.
_clusterComposites: {
	for _name, _c in _allClusters {
		(_name): list.Concat([
			_c.namespaces,
			_c.roleBindings,
			_c.resourceQuotas,
			_c.networkPolicies,
			_c.helmReleases,
			_c.harborRegistries,
			_c.harborProjects,
			_c.storageClasses,
			_c.nodeTaints,
			_c.kyvernoPolicies,
			_c.argoEventBuses,
			_c.argoEventSources,
			_c.argoSensors,
			_c.argoWorkflowTemplates,
			_c.argoAppProjects,
			_c.argoApplicationSets,
			_c.kelosWorkspaces,
			_c.kelosAgentConfigs,
			_c.kelosTaskSpawners,
			_c.certificates,
			_c.clusterExternalSecrets,
			_c.cronJobs,
			_c.clusterRoles,
			_c.clusterRoleBindings,
			_c.externalSecrets,
			_c.clusterSecretStores,
			_c.jobs,
			_c.serviceAccounts,
			_c.objectPatches,
			_c.ingresses,
			_c.metallbPools,
			_c.externalBackends,
			_c.serversTransports,
			_c.exposedServices,
			_c.githubRepositoryWebhooks,
			_c.gpuOperators,
			_c.verticalPodAutoscalers,
			_c.staticSites,
			_c.backupPolicies,
		])
	}
}

if _cluster != "" {
	manifests: list.Concat([
		_platformXRDs,
		_platformComps,
		_clusterComposites[_cluster],
	])
}
if _cluster == "" {
	// All clusters: platform resources + all cluster composites flattened
	let _allComposites = list.Concat([ for _name, _composites in _clusterComposites {_composites}])
	manifests: list.Concat([
		_platformXRDs,
		_platformComps,
		_allComposites,
	])
}
