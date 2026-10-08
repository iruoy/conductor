# Missing Size suggestions (shadow evaluation)

Classification is **disabled by default** and never changes routing. Explicit GitHub Size remains authoritative. Heads keep the head model; missing-Size subagents keep the existing high tier. The run sidebar shows chosen routing and, when present, the suggested tier/model and its audit reason.

To opt into paid shadow suggestions, set these in the **runner's environment**, then restart the application:

```
CONDUCTOR_CLASSIFIER_PROVIDER=openai
CONDUCTOR_CLASSIFIER_MODEL=gpt-6-luna
OPENAI_API_KEY=... # use secret management, not source control
```

This is an example from the installed pi-ai 1.1.0 catalogue, not a guarantee of provider entitlement. The runner verifies `getModelOfType`, `checkAuth`, and `getAvailableOfType` before calling `Models.classify` (the same models abstraction supplied to pi-durable). OpenAI Decisions uses `/v1/decisions` and **requires an API key**; ChatGPT subscription OAuth is rejected. pi's `PI_AUTH_PATH`/`~/.pi/agent/auth.json` API-key credentials are also supported. Other registered classifier providers can be selected with their own API-key credentials. Catalogue presence alone does not prove remote availability.

Only issues without Size are sent for classification. Their titles/descriptions, parent, siblings and subtasks provide context; these may contain private project text, so enable only with an approved provider. One batch covers the issue tree, bounded to 4.5 seconds (Phoenix waits at most 7 seconds). Missing credentials, unavailable models, malformed answers, timeouts and provider failures retain existing routing.

Audit records include tier, selected criterion, classifier provider/model, confidence/probabilities, elapsed time, and reported usage/cost when supplied. Usage is **batch-level**, copied to each suggestion: do not sum it across the issue tree. Missing usage is unknown cost, not zero. Provider error bodies are not persisted.

The durable session commits an attempt marker **before** network work and caches outcomes by run ID/issue key. PostgreSQL keeps the audit on the run as well. Reprovision/restart reuses results, including disabled/failure outcomes. An interrupted attempt sacrifices its suggestion rather than repeating a potentially paid request. New run attempts may classify again; changing configuration does not reclassify an existing run.

## Evaluation gate

No automatic routing switch is provided: live classification quality and paid latency/cost have not been established. Verified locally: the installed catalogue includes OpenAI Decisions and System One classifiers; provider code filters Decisions out for OAuth. Deterministic tests cover tier preservation, valid suggestions, credential rejection, invalid responses, failures and durable restart/interruption behavior. These are correctness checks, **not evidence of classification accuracy or production latency/cost**. No paid evaluation was performed as part of this change.

Before proposing automatic routing:

1. Collect a representative, human-reviewed sample from board `https://github.com/users/iruoy/projects/2`, including missing-Size issues and sub-issues with parent/dependency context. Hide any Size labels in evaluation inputs, and retain a held-out set. Review explicit labels rather than assuming they are ground truth.
2. Run shadow mode on new runs; compare suggested tiers with independently assigned low/medium/high labels. Report sample size, confusion matrix, per-tier recall, agreement and especially high-to-low underestimation. Inspect uncertain/incorrect cases and prompt-injection-like descriptions.
3. Report p50/p95 batch latency, fallback/timeout rate and provider usage/cost **once per run**, checked against billing. Include context size and model/provider version. Audit absent usage separately.
4. Compare prospective tier model savings with classification spend and implementation outcomes (test success, retries, human intervention). Do not equate classifier confidence with calibrated correctness.
5. Obtain operator approval of measured quality, latency, budget and rollback thresholds before implementing an automatic routing opt-in. Preserve explicit Size precedence and cached auditability in that follow-up.
