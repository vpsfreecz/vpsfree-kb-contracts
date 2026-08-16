# vpsFree KB Contract Repository

This repository owns canonical sources, runtime tests, and reproducible
screenshots for an explicit subset of the vpsFree.cz knowledge bases. It does
not own every KB page. Screenshots are generated artifacts. Never edit them by
hand.

Every concept in `captures.json` must map to exactly one scenario and
checkpoint and provide both Czech and English variants. A scenario may produce
several related screenshots, but every checkpoint and language variant must be
independently addressable and have deterministic fixture requirements, locale,
viewport, masking rules, and source-page references.

Use the pinned Nix development shell. Run captures through `bin/capture` and
validation through `bin/validate`. Test IP addresses must come from
documentation ranges and test identities must use `example.test`. Never
capture passwords, tokens, TOTP secrets, QR codes, recovery codes, real member
data, or production infrastructure identifiers.

Capture scripts may modify only their dedicated development cluster. They must
be safe to rerun and must not stop, reset, or reuse another initiative's
cluster. Wiki uploads are deliberately outside the capture command and require
an explicit, separately reviewed DokuWiki publication workflow.

Every source-controlled article must be registered in
`contract/articles.yml`, provide reciprocal Czech/English pages, and bind every
claim, executable sample, screenshot, and `kb-runtime` test script. Article
tests must expose the registry key through the `kbArticle` metadata label.
Managed pages must retain the invisible `<kb-managed>` source/test marker
immediately after their language mapping and must be reconciled against direct
wiki edits before candidate construction.

Every instruction that tells the reader to perform an action in the vpsAdmin
WebUI must be wrapped in a paired `<vpsadmin-nav>` tag with a semantic path from
`contract/navigation.yml`. This includes action-oriented prose that does not
explicitly name a menu, form, or navigation path. Treat independent discovery
as a safety net, not as proof that every instruction is annotated.

When authoring or translating Czech KB articles, address the reader using
informal singular forms (`tykání`), for example `můžeš`, `potřebuješ`,
`nainstaluj`, and `použij`. Do not use formal `vy` or plural imperatives as a
polite form; use plural only when genuinely addressing multiple people.

Before writing or editing user-facing prose, read and apply the workspace skill
at `../../../skills/vpsfree-user-facing-writing/SKILL.md` from this initiative
worktree. The standard workspace layout defined by the top-level `AGENTS.md`
makes that the canonical copy; if it is unavailable, stop and report the
missing workspace dependency instead of silently skipping it. Apply the skill
directly after technical facts are settled and before committing. Do not hand
the main rewrite to a context-poor subagent; use a fresh agent only to review
the finished result. In Czech pages, translate human-readable comments in
scripts and configuration examples while preserving executable lines,
directives, identifiers, and values.

Write KB articles as documentation of the current supported state. Do not
mention obsolete distributions, former defaults, superseded commands, or
historical workarounds unless readers of a still-supported installation need
that history to migrate or recover. Record removal rationale in commit
messages, DokuWiki revision summaries, or initiative notes instead of article
prose.

When a vpsAdmin feature changes anything visible in the WebUI, follow
`docs/webui-change-workflow.md`. It is the canonical cross-repository procedure
for pinning the feature revision, interpreting contract drift, regenerating
screenshots, preparing KB candidates, staging, and approval-gated publication.

Use stable, semantic screenshot IDs and filenames under
`screenshots/<language>/<topic>/<view>.png`. DokuWiki IDs use
`<language>:screenshots:vpsadmin:<topic>:<view>.png`. Do not encode display order
or revision counters in them; Git and DokuWiki retain revision history. Never
reuse or overwrite a legacy production media ID during the initial migration.
After publication, a refreshed capture updates the same canonical media ID so
existing pages do not require reference-only edits.
