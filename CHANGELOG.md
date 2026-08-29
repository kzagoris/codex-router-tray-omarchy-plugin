# Changelog

All notable changes to **Codex Router Tray** (`kzagoris.codex-router-tray`).

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning is `0.major.minor` while the plugin is pre-1.0; payload shapes are
verified against the codex-router version noted in each entry.

## [Unreleased]

The Router reader workflow deepened (`scratch/009`). No manifest schema
change; payload shapes unchanged.

- **One reader, one definition of refresh.** The Panel declares that a reader
  is present and which view is active; RouterService maps that demand to
  router commands, stages reads across health and capability recovery,
  coalesces overlapping demand, and publishes two stable projections
  (`routerSummary`, `activeViewProjection`). Views no longer compose their own
  timers or reads.
- **The 174 KB Snapshot is read for a reason.** Status, Providers and Models
  share one cached Snapshot that answers view entry without a read; it is
  re-read on explicit Refresh, after a relevant mutation, and once after the
  Router returns from offline. The open-panel 30-second Snapshot poll is gone;
  the only timed Snapshot read left is a visible `checking` Proof in Models.
- **Usage reads what Usage needs.** Entering Usage reads Provider setup and
  Provider usage; only Provider usage repeats on the data interval while
  Usage is visible. ChatGPT account usage runs on entry and explicit Refresh
  only, with loading, failure and freshness of its own, so a slow quota call
  cannot hold the rest of the view hostage.
- **Errors and freshness are per view.** A failed read appears only in the
  view that required the fact; a view keeps its last complete facts, and its
  Updated caption advances only when every required fact succeeded. After the
  Router was offline, Snapshot-backed views show their retained facts as
  stale until one fresh Snapshot commits.
- **Refresh means every Panel fact** — from the button or over IPC, with the
  panel open or closed; account usage included when enabled.
- **The legacy RouterService surface is gone** (raw fact properties, generic
  `invoke`, the broad data refresh, refresh deferral, read rounds). The
  capability secret still never reaches a projection, an error string or a
  log.

## [0.3.0] — 2026-08-28

Router 0.5.0 follow-ups. No manifest schema change. Payloads verified against
`codex-router 0.5.0` (was `0.4.0-beta.4`).

- **Router 0.5.0 alignment — proof lifecycle and degraded names**
  (`scratch/003`, `scratch/006`).
  Proof badges follow the new lifecycle: `candidate` → "Probe passed —
  awaiting certification", `verified` → "Certified on this machine", plus
  legacy `experimental`/`proven` labels. Local proofs no longer claim
  registry `v2`. Degraded health names render as "Kimi OAuth forwarder ·
  Grok OAuth forwarder · API forwarder · Gateway" behind a "Degraded:"
  prefix — not "providers". Unknown ids pass through the bounded plain-text
  clamp. Map lives in `Model.js`; `CONTEXT.md` Proof entry updated.

- **Subagent modes are live and honest** (`scratch/004`).
  The mode toggle now reads "Every catalog model as a subagent" and writes
  `all`, with a description that names the risk (exposes routes that have
  never been shown to work). Turning it off writes `selected` when a
  selection exists, otherwise `proven`. `isSubagentOn` in `logic/Catalog.js`
  mirrors `applyMultiAgentSettings` clause-for-clause (hidden/disabled →
  registry v2 → mode) so the panel and the Codex spawn agree.

- **Repository-certified v1 cannot be a native v2 subagent**
  (`scratch/005`).
  A model with `subagentCertification === "v1"` shows a disabled Subagents
  toggle and a badge that names the registry verdict. Picker visibility stays
  live. When a row is both hidden and v1, the picker interlock takes
  precedence. `CatalogRow.qml` shows the router-aligned explanation in its
  tooltip and does not navigate to Picker for this case.

- **Status view surfaces more 0.5 snapshot facts** (`scratch/007`).
  A dim caption shows `chatgptSession` (sharing, session usability,
  `expiresInHours` → `~10d` / `30+ days`) and another shows the router
  default catalog model (`routerDefaultModel` / `routerDefaultManaged`).
  Picker rows carry a caption for synthesized native context variants
  (`nativeClientManaged: false` → "Router-managed context variant") and
  free routes (`isFree` → "Free"). Captions never touch membership, counts,
  badges, or the interlock. `catalog.knownModels` is deliberately not listed
  — discovery belongs to Providers.

- **Usage view shows what funds the next request** (`scratch/008`).
  Generic quota windows (e.g. opencode Go "Rolling limit") keep the router's
  sanitized, clamped label and draw a LIMITS card through the existing
  Repeater. `kind: "balance"` metrics render as a new **FUNDING** section —
  value-only `PROVIDER · LABEL` rows, meter only with a genuine
  `usedPercent`, "Unavailable" when `available: false`, `detail` as a dim
  caption. `account.plan` and `account.message` render as a bounded
  **ACCOUNT NOTES** section (`PROVIDER · PLAN` heading + urgent caution).
  FUNDING and NOTES read `provider_usage` + `provider_setup` and show
  without the slow `account_usage` call; LIMITS (all quota windows) stays
  behind `accountUsage: On`.

## [0.2.0] — 2026-08-22

- **The Models view.** Shows each model in the catalog that an enabled
  provider gives, in groups by provider. A sub-switcher selects the picker
  visibility or the subagent eligibility. The view has proof badges, the
  interlock between the two settings, and the bulk commands.

- **The panel became a switcher over four views.** Status, Usage, Providers,
  and Models share one hero line, one status box, and one footer. The shell
  keeps the selected view for the session.

- **Optimistic toggles.** A click changes the toggle immediately. Repeated
  clicks on one model become one command. A failure puts the toggle back with
  the message from the router. The view then reconciles against one read.

- **Correct release of the automatic refresh.** Each exit from the mutation
  runner releases it, and this includes the abort when the router is off. A
  toggle whose read is still in transit stays when you leave the view.

- **The compaction of old tool results** moved into the modes in the Status
  view, where a routing mode belongs.

- The control CLI wrapper accepts a slug with a provider, for example
  `opencode-free/big-pickle`.

## [0.1.0] — 2026-08-21

The first public release. It has the bar pill with the live health dot. Its
panel has the modes, the activity, the usage, and the provider controls. The
panel also has the maintenance commands and the link to the web panel.

[Unreleased]: https://github.com/kzagoris/codex-router-tray-omarchy-plugin/compare/0.3.0...HEAD
[0.3.0]: https://github.com/kzagoris/codex-router-tray-omarchy-plugin/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/kzagoris/codex-router-tray-omarchy-plugin/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/kzagoris/codex-router-tray-omarchy-plugin/releases/tag/0.1.0
