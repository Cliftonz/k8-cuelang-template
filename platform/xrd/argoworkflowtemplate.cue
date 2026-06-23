package xrd

// XArgoWorkflowTemplate defines the CompositeResourceDefinition for an
// Argo Workflows WorkflowTemplate. WorkflowTemplates are the reusable
// blueprint that the build Sensor instantiates as a Workflow on each PR
// event. The `config` field accepts the WorkflowTemplate spec verbatim
// (preserve-unknown-fields) so we don't have to mirror the upstream
// schema in CUE — the same approach taken for XArgoSensor.
#XArgoWorkflowTemplate: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xargoworkflowtemplates.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XArgoWorkflowTemplate"
			plural: "xargoworkflowtemplates"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request an Argo Workflows WorkflowTemplate."
				properties: spec: {
					type:        "object"
					description: "Desired WorkflowTemplate settings and placement metadata."
					properties: {
						name: {
							type:        "string"
							description: "WorkflowTemplate resource name."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the WorkflowTemplate will be created."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						tier: {
							type:        "string"
							description: "Deployment tier."
							enum: ["dev", "staging", "production"]
						}
						cluster: {
							type:        "string"
							description: "Target cluster name."
						}
						owner: {
							type:        "string"
							description: "Owning team or service."
						}
						config: {
							type:                                   "object"
							description:                            "WorkflowTemplate spec (entrypoint, templates, arguments, etc.)."
							"x-kubernetes-preserve-unknown-fields": true
						}
					}
					required: ["name", "namespace", "tier", "cluster", "owner", "config"]
				}
			}
		}]
	}
}

xArgoWorkflowTemplate: #XArgoWorkflowTemplate
