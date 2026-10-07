# WebUI change documentation workflow

Use this workflow whenever a vpsAdmin change can alter something a member sees
in the WebUI: a label, menu or sidebar entry, form title, route, action,
rendered value, layout, or screenshot. The workflow detects impact and prepares
review material. It never rewrites or publishes production documentation by
itself.

## Repositories and ownership

- `vpsadmin` owns WebUI behavior, gettext labels, routes, and rendered
  `data-vpsadmin-doc-id` landmarks.
- `vpsfree-kb-contracts` owns semantic controls and paths, source fingerprints,
  page bindings, screenshot scenarios, deterministic fixtures, and PNGs.
- `dokuwiki-plugin-vpsadmindoc` renders `<vpsadmin-nav>` annotations. It does
  not fetch labels or write documentation.
- The vpsFree.cz coordination workspace owns production KB access, all-page
  source fetching, candidate construction, staging, and approval-gated release.

The operator must invoke this workflow. There is intentionally no cross-repo
GitHub workflow or automatic production publisher.

## 1. Develop the vpsAdmin change

Keep a semantic documentation ID when the user intent is unchanged, even if its
label, route, or layout changes. Add a new ID when the action has a different
meaning. When an action is removed, retire its path explicitly and update every
reported page and capture; do not silently reuse the ID for another purpose.

Documented controls pass their IDs to the existing WebUI rendering helpers. The
rendered control must expose the same ID through `data-vpsadmin-doc-id`. Keep the
ID beside the production label and route declaration so its source fingerprint
couples all three facts.

## 2. Pin the feature revision

In a dedicated `vpsfree-kb-contracts` feature branch, update the exact vpsAdmin
revision in:

- `flake.nix` and `flake.lock`;
- `captures.json` (`vpsadmin_commit`);
- `contract/navigation.yml` (`vpsadmin_revision`);
- `contract/pages.yml` (`revisions.vpsadmin`).

Update the flake input with:

```sh
nix flake update vpsadmin
```

Do not point the contract at a mutable branch name. Push the vpsAdmin commit
first so Nix can fetch the exact revision.

## 3. Run and interpret the contract

```sh
nix develop -c bin/check
```

The contract couples each documented control to its bilingual labels, route,
landmark source, affected KB pages, and screenshot concepts. A drift report is
an impact list, not an instruction to accept a new fingerprint blindly.

For every reported control:

1. confirm whether its user intent is unchanged, changed, or removed;
2. update the landmark, semantic ID, label, route, and source fingerprint as
   appropriate;
3. review every reported Czech and English page;
4. review or regenerate every reported screenshot concept;
5. add regression coverage for new landmarks or contract behavior.

A visual-only CSS or layout change may not alter a control fingerprint. Use the
capture bindings and feature scope to select screenshots for regeneration even
when the semantic contract remains green.

## 4. Regenerate affected screenshots

Every bitmap must remain reproducible from its scenario and checkpoint. Use the
repository-owned development cluster and fixtures; never depend on another
workspace at runtime. Configure explicit dedicated resources using the
[portable runtime contract](../cluster/runtime-contract.md). Packaged capture and
validation may write to an explicit artifact root without modifying their source.

Use the same committed source snapshot for the cluster, capture and validation
commands. Capture verifies the current instance, prepared source and running
system closures before changing fixtures. Updating a lockfile alone does not
establish the running revision. Keep both language results in one output root,
then update and strictly validate its candidate inventory.

```sh
nix develop
bin/devcluster start FEATURE-SLUG --topology screenshots --config /path/to/dedicated-config.json
bin/capture --cluster FEATURE-SLUG --language cs --scenario SCENARIO
bin/capture --cluster FEATURE-SLUG --language en --scenario SCENARIO
bin/validate --update
bin/validate
bin/check
bin/devcluster stop FEATURE-SLUG
```

For only `networking/ip-address-list`, use an explicit `single` configuration
with the `ip-inventory` capability and matching committed runtime, capture and
validation packages. This fixture needs services and node1; it does not require
the full storage/traffic fixture. Keep both languages in one private output
directory. Include explicit disposable `test-admin` (level 99), `test-user1`
and `test-user2` (both level 1) entries in `seed.users`. Give each a full name,
a password and an email of `LOGIN@example.test`. Each namespace has
`blockCount: 8`; set `blockStart` to 1 for `test-admin`, 9 for `test-user1` and
17 for `test-user2`. The fixture proves the recorded administrator and
`test-user1` API identities, uses the administrator only for inventory
provisioning, and keeps the browser in `test-user1`'s session throughout VPS
creation and capture:

```sh
vpsfree-kb-devcluster start FEATURE-SLUG --topology single --config /path/to/dedicated-config.json --state-root /path/to/private-state
vpsfree-kb-capture --cluster FEATURE-SLUG --state-root /path/to/private-state --language cs --checkpoint networking/ip-address-list --output-root /path/to/capture-output
vpsfree-kb-capture --cluster FEATURE-SLUG --state-root /path/to/private-state --language en --checkpoint networking/ip-address-list --output-root /path/to/capture-output
vpsfree-kb-validate --update --output-root /path/to/capture-output
vpsfree-kb-validate --output-root /path/to/capture-output
```

The committed generator source must already pin the affected vpsAdmin revision.
The [direct verifier](../cluster/runtime-contract.md#verification-and-limits)
also exercises the private connection selector and writable-CWD output default.
Its reduced real-runtime route qualifies one final-source `single`/local
instance: services and node1 each use 2048 MiB RAM, the services image and root
copy each use 8192 MiB, and the tank is 8 GiB. The builder also follows the
services RAM setting. These are unqualified targets until measured preparation
and public start succeed. The required `runtime-smoke` phase checks attested
connection/lease and ordinary stop/resume; `bilingual-capture` reuses that
resumed instance. Historical upgrade and two-root tests are separate deferred
coverage. Capacity admission accounts closures, temporary build costs and
retained-host obligations separately from the 24 GiB new disk extent. Its
capacity and owned-state failure requirements apply before real work.
Review the gray disabled row and enabled assigned row in both images; native
title/focus assertions accompany the images without claiming a native tooltip
popup was captured. Other screenshot concepts keep their existing fixtures.

Inspect changed images, crops, fonts, fixture data, and the contact sheet. Keep
the existing semantic filename for the same screenshot concept. Introduce a new
concept only when the documented intent changes. Screenshot generation never
uploads media.

Hosted `Check` runs on pushes and pull requests use `--allow-missing` while
media is being prepared. After committing and publishing the accepted media,
run that workflow manually with `strict` enabled against the exact feature
revision. It then runs `nix develop --command bin/check` over the full committed
inventory. Confirm the run's checkout SHA and strict step; a permissive source
check does not replace this result. Strict exported-output validation and visual
review remain separate requirements.

## 5. Prepare KB candidates

From the vpsFree.cz coordination workspace, fetch every accessible production
page into a new initiative directory:

```sh
bin/kb-contract-fetch --output work/SLUG/kb-sources
```

Prepare an exact YAML replacement plan and apply it:

```sh
bin/kb-contract-build \
  --source work/SLUG/kb-sources \
  --plan work/SLUG/kb-annotation-plan.yml \
  --output work/SLUG/kb-candidates
```

The plan must name the language, page, semantic path, expected old text, visible
candidate body, and exact occurrence count. Use an explicit final replacement
only when the semantic tag must cover less text than the matched source. Every
affected path/page pair must be a binding or a truthful exception.

```yaml
schema: 1
replacements:
  - language: en
    page: manuals:vps:management
    path: member.public-keys.add
    before: Edit profile → Public keys → Add public key
    count: 1
exceptions: []
```

`body` may override the visible text inside the generated tag. `replacement`
may override the complete replacement, including the tag, when surrounding
prose must remain outside its semantic span.

Validate the immutable source inventory against the candidates:

```sh
ruby /path/to/vpsfree-kb-contracts/tools/check-kb-annotations.rb \
  --source-index work/SLUG/kb-sources/index.json \
  --candidate-index work/SLUG/kb-candidates/index.json
```

Review `kb-candidates/review.md`. The checker rejects malformed or unknown
tags, count drift, partial or duplicated page inventories, newly unclassified
candidate paragraphs, and navigation tags missed by independent discovery.
Discovery is deliberately heuristic. Manually enumerate every instruction that
tells the reader to perform a vpsAdmin WebUI action, including prose that does
not name a menu or form, and verify that each instruction has a semantic
`<vpsadmin-nav>` binding.
The source index still has to contain exactly the same complete page-ID set;
candidate construction and the release manifest separately guard the fetched
production checksums and revisions.

For pages registered in `contract/pages.yml`, use replacement-plan schema 5
and name the page key under `managed_pages`. Pass the contract repository and
the explicit pre-change Git base to the builder:

```sh
bin/kb-contract-build \
  --source work/SLUG/kb-sources \
  --plan work/SLUG/kb-annotation-plan.yml \
  --code-root /path/to/vpsfree-kb-contracts \
  --code-base FULL-BASE-COMMIT-OID \
  --output work/SLUG/kb-candidates
```

Use the full 40-character commit OID so the reconciliation base cannot move
after a fetch. The candidate index and generated release manifest record that
base, the contract HEAD, the registry digest, and the canonical page digests.
The HEAD must be committed. Push it before staging so source links can use that
exact revision. The builder compares the base source, committed source, and
fetched wiki page. A wiki-only or concurrent edit stops candidate construction.
Inspect it with `bin/kb-contract-reconcile`; import a wiki-only edit only with
an explicit `--adopt --yes`, then commit it, update its contract evidence, and
rerun the tests.

Each managed page marker contains repository-relative identifiers rather than
a branch URL. Both values must match `contract/pages.yml` exactly:

```text
<kb-managed
  source="contract/pages/navody-server-firewall.txt"
  test="kb/firewall#*"
/>
```

The `#*` selector covers every script reported for the suite by `testsMeta`.
The candidate index records one test entry per registered page key under
`managed_contract.tests`:

```json
{
  "page_key": "firewall",
  "pattern": "kb/firewall#*",
  "source": "tests/suite/kb/firewall.nix",
  "sha256": "<SHA-256 of the source at managed_contract.head_commit>"
}
```

The release generator copies the entries needed by changed managed pages to
`contract.tests`. It keeps the existing `contract.pages` provenance alongside
them.

## 6. Build and stage guarded releases

List every page write and deletion in one bilingual changes file. Each entry
needs its own informative summary. Czech summaries are descriptive noun
phrases; English summaries describe the resulting change in one line.

```yaml
schema: 1
changes:
  - language: cs
    id: navody:vps:sprava
    action: write
    summary: Aktualizace správy VPS a doplnění konzole
  - language: en
    id: manuals:vps:management
    action: write
    summary: Update VPS management and add console recovery
  - language: cs
    id: navody:server:zastarametoda
    action: delete
    summary: Odstranění zastaralého serverového návodu
```

The generator requires exactly one `write` entry for every changed candidate
page. A `delete` entry must name an unchanged page from the fetched production
inventory. The generated manifest records its source revision and checksum.
This prevents a concurrent page edit from being deleted.

Create one schema-4 manifest per language from the same changes file:

```sh
bin/kb-contract-manifest \
  --source work/SLUG/kb-sources \
  --candidate work/SLUG/kb-candidates \
  --language cs --changes work/SLUG/release-changes.yml \
  --output work/SLUG/kb-release-cs.yml

bin/kb-contract-manifest \
  --source work/SLUG/kb-sources \
  --candidate work/SLUG/kb-candidates \
  --language en --changes work/SLUG/release-changes.yml \
  --output work/SLUG/kb-release-en.yml
```

Claim the global on-demand staging container. Reset it only when the current
session owns it and a clean production mirror is required:

```sh
bin/kb-stage start
bin/kb-stage reset --yes
bin/kb-release stage --manifest work/SLUG/kb-release-cs.yml --yes
bin/kb-release verify --manifest work/SLUG/kb-release-cs.yml
bin/kb-release stage --manifest work/SLUG/kb-release-en.yml --yes
bin/kb-release verify --manifest work/SLUG/kb-release-en.yml
```

Review both sites through their staging hostnames. Verify normal page IDs,
screenshots, rendered navigation markers, and bidirectional language links.
Staging resolves managed source and test links at the manifest's immutable
contract commit. `kb-release stage` updates the mounted staging revision file;
later feature-branch commits require restaging, not a host redeployment or a
container restart. `kb-release verify` checks the active revision and resolved
managed links.
The verify command also prints every page action, its exact summary, and a
clickable staging revision-history URL. Open those links and review the
summaries before approving publication. If candidate content is already staged
with another summary, reset staging and stage the manifest again; DokuWiki
cannot replace a revision summary with an unchanged page save.

Page deletions follow the same staging and promotion path as writes. The release
tool checks the recorded source, delete permission, resulting absence, and
latest revision summary. Do not remove release pages with separate `kb-page`
commands.

Only one manifest can be the pending promotion at a time; staging the second
language intentionally replaces the first pending record. Both page sets remain
available for review.

## 7. Publish only after explicit approval

Production plugin/configuration deployment and KB content promotion are
separate operator decisions. The plugin must be deployed before annotated
pages. Never treat a green check, staging review, merge approval, or a general
“continue” as production-write approval.

After direct approval, stage, verify, and immediately promote each exact
manifest separately. Restaging here recreates its pending digest; it must not
change the already reviewed candidate files.

Promotion verifies that remote `master` contains the recorded managed page and
test files with their exact checksums. This check must pass before any
production page write.

```sh
bin/kb-release stage --manifest work/SLUG/kb-release-cs.yml --yes
bin/kb-release verify --manifest work/SLUG/kb-release-cs.yml
bin/kb-release promote --manifest work/SLUG/kb-release-cs.yml \
  --yes --approved-production

bin/kb-release stage --manifest work/SLUG/kb-release-en.yml --yes
bin/kb-release verify --manifest work/SLUG/kb-release-en.yml
bin/kb-release promote --manifest work/SLUG/kb-release-en.yml \
  --yes --approved-production

bin/kb-stage release --yes
```

Verify production after promotion. Roll back pages before removing the plugin;
do not remove the plugin while published pages still contain its syntax unless
fallback rendering has been proven. If review is abandoned while a manifest is
pending, `bin/kb-stage release --yes` refuses to discard it; use
`--discard-pending` only as an explicit abandonment decision.

## Completion checklist

- Exact vpsAdmin revision pinned and contract checks pass.
- Semantic-ID decisions are explicit; fingerprints were reviewed, not merely
  refreshed.
- All reported pages and captures were reviewed.
- Affected screenshots were regenerated in both languages where needed.
- Complete production page identities and candidates validate.
- Czech and English staging releases render and interlink correctly; every page
  summary and revision-history link has been reviewed.
- Production remains untouched until the user approves exact promotion.
