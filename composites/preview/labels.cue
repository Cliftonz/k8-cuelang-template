package preview

// Feature Pipeline GitHub label names.
//
// Single source of truth — change any value here to rename globally.
// All Sensor filters, AgentConfig prompts, Job env vars, and docs
// reference these via `\(labels.X)` interpolation.
//
// Renaming workflow:
//   1. Edit a value here.
//   2. Run: make validate && make export-cluster CLUSTER=preview UNIFI=true
//   3. Apply: kubectl apply -R -f clusters/preview
//   4. Rename the label on GitHub (gh label edit OR recreate + migrate).
labels: {
	// Triggers branch creation + ideation loop on an issue.
	aiFeature: "ai-feature"

	// Triggers implementation Task when applied to an issue.
	// Prerequisite: issue must already have branchCreated label.
	aiImplement: "ready:ai-implement"

	// Applied by branch-create Job after a feature branch exists.
	// Gates the implementer Sensor (prevents firing before branch ready).
	branchCreated: "branch-created"

	// Applied to a PR by the implementer after marking ready-for-review.
	// Triggers the review panel (tier 1 + tier 2).
	pendingReview: "pending-review"

	// Applied by any agent when ambiguity blocks progress. Pauses the
	// pipeline for that issue/PR until removed by a human. Removal fires
	// feature-human-resume Sensor which posts an "unblocked" note.
	awaitingHuman: "awaiting-human"

	// Applied by orchestrator when all 7 reviewers APPROVE on HEAD SHA.
	// Signals the PR is ready for human merge.
	readyToMerge: "ready-to-merge"

	// Applied by orchestrator after 3 fix rounds exhausted with remaining
	// CHANGES_REQUESTED. Pipeline stops; human resolves.
	reviewFailed: "review-failed"
}
