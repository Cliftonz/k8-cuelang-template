package render

// Sentinel docs for resource types that have no clean kubectl-applyable
// equivalent in raw-fallback mode. The export pipeline pulls these out
// of the apply stream via ci/scripts/strip-skipped.sh and writes them
// to clusters/<name>-raw/_skipped.md so the operator sees what's missing
// and how to replicate it manually.

#ObjectPatchInput: {
	name: string
	targetRef: {
		apiVersion: string
		kind:       string
		name:       string
		namespace?: string
	}
	annotations?: {[string]: string}
	labels?: {[string]: string}
	tier:    string
	cluster: string
	owner:   string
}

#RenderObjectPatch: {
	in: #ObjectPatchInput
	out: {
		apiVersion: "k8-infra/raw-fallback/v1alpha1"
		kind:       "RawExportSkipped"
		metadata: name: in.name
		spec: {
			originalKind: "XObjectPatch"
			reason:       "server-side-apply patch on a resource owned by another controller — no equivalent in raw mode"
			replacement:  """
				After applying the rest of the bundle, run:

				  kubectl annotate \(in.targetRef.kind)/\(in.targetRef.name) \\
				    \(*("-n "+in.targetRef.namespace+" ") | "")\\
				    <key>=<value> --overwrite

				…for each entry in spec.details.annotations / spec.details.labels.
				"""
			details: {
				targetRef: in.targetRef
				if in.annotations != _|_ {annotations: in.annotations}
				if in.labels != _|_ {labels: in.labels}
			}
		}
	}
}

#NodeTaintInput: {
	name:     string
	cluster:  string
	owner:    string
	nodeName: string
	taints: [...{...}]
}

#RenderNodeTaint: {
	in: #NodeTaintInput
	out: {
		apiVersion: "k8-infra/raw-fallback/v1alpha1"
		kind:       "RawExportSkipped"
		metadata: name: in.name
		spec: {
			originalKind: "XNodeTaint"
			reason:       "Node taints mutate existing Node objects — no kubectl-applyable equivalent"
			replacement:  """
				Apply taints with kubectl:

				  kubectl taint nodes \(in.nodeName) <key>=<value>:<effect>

				One invocation per entry in spec.details.taints.
				"""
			details: {
				nodeName: in.nodeName
				taints:   in.taints
			}
		}
	}
}

// GPU Operator — wraps a Helm release and depends on Talos system extensions
// at the node level. Raw mode could expand to a HelmRenderRequest, but the
// chart's `node-feature-discovery` + `gpu-operator-validator` daemonsets
// require runtime knowledge of the kernel module that only exists once the
// Talos node has booted with the right schematic. Skip in raw mode and
// document the manual install path.
#GpuOperatorInput: {
	name:           string
	namespace:      string
	chartVersion:   string
	driverVariant?: string
	tier:           string
	cluster:        string
	owner:          string
}

#RenderGpuOperatorSkipped: {
	in: #GpuOperatorInput
	out: {
		apiVersion: "k8-infra/raw-fallback/v1alpha1"
		kind:       "RawExportSkipped"
		metadata: name: in.name
		spec: {
			originalKind: "XGpuOperator"
			reason:       "wraps Helm release + requires Talos node-level system extensions; raw fallback cannot install kmod via kubectl apply"
			replacement:  """
				1. Re-image the GPU node(s) with a Talos schematic containing
				   siderolabs/nonfree-kmod-nvidia-\(*in.driverVariant | "lts") +
				   siderolabs/nvidia-container-toolkit-\(*in.driverVariant | "lts").
				2. helm install \(in.name) gpu-operator \\
				     --repo https://helm.ngc.nvidia.com/nvidia \\
				     --namespace \(in.namespace) --create-namespace \\
				     --version \(in.chartVersion) \\
				     --set driver.enabled=false \\
				     --set toolkit.enabled=false \\
				     --set operator.runtimeClass=nvidia
				"""
			details: {
				namespace:    in.namespace
				chartVersion: in.chartVersion
				if in.driverVariant != _|_ {driverVariant: in.driverVariant}
			}
		}
	}
}

// Harbor (and other external-API providers) — these never produce a
// kubectl-applyable manifest. Use the provider's native API/UI/CLI.
#HarborSkippedInput: {
	name: string
	kind: string
}

#RenderHarborSkipped: {
	in: #HarborSkippedInput
	out: {
		apiVersion: "k8-infra/raw-fallback/v1alpha1"
		kind:       "RawExportSkipped"
		metadata: name: in.name
		spec: {
			originalKind: in.kind
			reason:       "external-api provider (Harbor) — has no in-cluster equivalent"
			replacement: """
				Manage via the Harbor UI or `harbor-cli` against the target registry.
				This resource type only exists to wire Harbor objects into the GitOps
				surface; with no Crossplane there is no in-cluster reconciler.
				"""
		}
	}
}

// GitHub repository webhook — external-API resource on github.com,
// provisioned by Crossplane provider-github. No in-cluster equivalent.
#GithubRepositoryWebhookSkippedInput: {
	name:       string
	repository: string
	url:        string
}

#RenderGithubRepositoryWebhookSkipped: {
	in: #GithubRepositoryWebhookSkippedInput
	out: {
		apiVersion: "k8-infra/raw-fallback/v1alpha1"
		kind:       "RawExportSkipped"
		metadata: name: in.name
		spec: {
			originalKind: "XGithubRepositoryWebhook"
			reason:       "external-api provider (GitHub) — webhooks live in GitHub, not in-cluster"
			replacement: """
				Configure manually in GitHub:
				  Repo \(in.repository) → Settings → Webhooks → Add webhook
				  Payload URL: \(in.url)
				  Content type: application/json
				  Events: choose the events your sensor expects
				"""
			details: {
				repository: in.repository
				url:        in.url
			}
		}
	}
}

// XBackupPolicy — wraps a velero.io/v1 Schedule CR. The durable
// answer is to apply Velero (and its Schedules) directly on the CP
// via CUE rather than behind an Argo CD Application — recovery-
// critical operators can't sit on the path that depends on Argo
// being healthy. Until that refactor lands, emit a skipped
// placeholder so raw-coverage CI passes.
#BackupPolicySkippedInput: {
	name:     string
	schedule: string
	tier:     string
	cluster:  string
	owner:    string
}

#RenderBackupPolicySkipped: {
	in: #BackupPolicySkippedInput
	out: {
		apiVersion: "k8-infra/raw-fallback/v1alpha1"
		kind:       "RawExportSkipped"
		metadata: name: in.name
		spec: {
			originalKind: "XBackupPolicy"
			reason:       "raw renderer not yet wired — durable answer is to apply Velero + its Schedule CRs directly via CUE on the CP, not via Argo. Placeholder unblocks raw-coverage CI until the refactor lands."
			replacement:  """
				Apply the velero.io/v1 Schedule manifest manually until
				the raw renderer (or the Velero-direct-from-CUE refactor)
				lands:

				  kubectl apply -n velero -f schedule-\(in.name).yaml

				…where the YAML is the velero.io/v1 Schedule body derived
				from composites/<cluster>/backuppolicies.cue's spec
				(schedule=\(in.schedule)).
				"""
			details: {
				name:     in.name
				schedule: in.schedule
			}
		}
	}
}

// XArgoWorkflowTemplate — preserve-unknown-fields config that the
// Crossplane composition unwraps into an argoproj.io WorkflowTemplate.
// A real raw renderer would just emit the WorkflowTemplate body directly
// (mirror #RenderArgoSensor). This placeholder unblocks CI's dispatcher
// coverage check until that renderer lands.
#ArgoWorkflowTemplateSkippedInput: {
	name:      string
	namespace: string
	tier:      string
	cluster:   string
	owner:     string
}

#RenderArgoWorkflowTemplateSkipped: {
	in: #ArgoWorkflowTemplateSkippedInput
	out: {
		apiVersion: "k8-infra/raw-fallback/v1alpha1"
		kind:       "RawExportSkipped"
		metadata: name: in.name
		spec: {
			originalKind: "XArgoWorkflowTemplate"
			reason:       "raw renderer not yet wired — WorkflowTemplate XR uses preserve-unknown-fields config that needs a dedicated #RenderArgoWorkflowTemplate (mirror #RenderArgoSensor)"
			replacement:  """
				Apply the upstream WorkflowTemplate manifest manually until
				the raw renderer lands:

				  kubectl apply -n \(in.namespace) -f workflowtemplate-\(in.name).yaml

				…where the YAML is the unwrapped argoproj.io/v1alpha1
				WorkflowTemplate body from composites/<cluster>/argoworkflows.cue's
				`config` field.
				"""
			details: {
				name:      in.name
				namespace: in.namespace
			}
		}
	}
}
