# WebUI change documentation workflow

Use this workflow whenever a vpsAdmin change can alter something a member sees
in the WebUI: a label, menu or sidebar entry, form title, route, action,
rendered value, layout, or screenshot. The workflow detects impact and prepares
review material. It never rewrites or publishes production documentation by
itself.

## Repositories and ownership

- `vpsadmin` owns WebUI behavior, gettext labels, routes, and rendered
  `data-vpsadmin-doc-id` landmarks.
- `vpsadmin-kb-captures` owns semantic controls and paths, source fingerprints,
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

In a dedicated `vpsadmin-kb-captures` feature branch, update the exact vpsAdmin
revision in:

- `flake.nix` and `flake.lock`;
- `captures.json` (`vpsadmin_commit`);
- `contract/navigation.yml` (`vpsadmin_revision`).

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
workspace at runtime.

```sh
nix develop
bin/devcluster start FEATURE-SLUG --topology screenshots
bin/capture --cluster FEATURE-SLUG --language cs --scenario SCENARIO
bin/validate --update
bin/capture --cluster FEATURE-SLUG --language en --scenario SCENARIO
bin/validate --update
bin/check
bin/devcluster stop FEATURE-SLUG
```

Inspect changed images, crops, fonts, fixture data, and the contact sheet. Keep
the existing semantic filename for the same screenshot concept. Introduce a new
concept only when the documented intent changes. Screenshot generation never
uploads media.

## 5. Prepare KB candidates

From the vpsFree.cz coordination workspace, fetch every accessible production
page into a new initiative directory:

```sh
bin/kb-contract-fetch --output work/SLUG/kb-sources \
  --expect-new cs:navody:NEW-PAGE \
  --expect-new en:manuals:NEW-PAGE
```

Prepare an exact YAML replacement plan and apply it:

```sh
bin/kb-contract-build \
  --source work/SLUG/kb-sources \
  --plan work/SLUG/kb-annotation-plan.yml \
  --captures worktrees/SLUG/vpsadmin-kb-captures \
  --output work/SLUG/kb-candidates
```

The plan must name the language, page, semantic path, expected old text, visible
candidate body, and exact occurrence count. Use an explicit final replacement
only when the semantic tag must cover less text than the matched source. Every
affected path/page pair must be a binding or a truthful exception.

```yaml
schema: 2
new_pages:
  - language: en
    page: manuals:NEW-PAGE
    body: |
      ====== New page ======
      Open the relevant WebUI section here.
replacements:
  - language: en
    page: manuals:vps:management
    path: member.public-keys.add
    before: Edit profile → Public keys → Add public key
    count: 1
media:
  - language: en
    capture: ssh-keys/add-public-key
exceptions: []
```

`body` may override the visible text inside the generated tag. `replacement`
may override the complete replacement, including the tag, when surrounding
prose must remain outside its semantic span.

Schema 2 can add guarded pages and select capture media. Every `new_pages`
entry must have an exact `--expect-new` source guard; candidate construction
fails if production has created the page in the meantime or if a guarded page
is omitted from the plan. Capture IDs select the language-specific media ID,
PNG, and recorded checksum from `captures.json`. Use schema 1 and omit
`--captures` when no pages or media are being added.

Validate the immutable source inventory against the candidates:

```sh
ruby /path/to/vpsadmin-kb-captures/tools/check-kb-annotations.rb \
  --source-index work/SLUG/kb-sources/index.json \
  --candidate-index work/SLUG/kb-candidates/index.json
```

Review `kb-candidates/review.md`. The checker rejects malformed or unknown
tags, count drift, partial or duplicated page inventories, newly unclassified
source paragraphs, and navigation tags missed by independent discovery.
For a guarded new page, independent discovery scans the candidate because the
guarded source is intentionally empty.

## 6. Build and stage guarded releases

Create one manifest per language with an informative, localized production
summary:

```sh
bin/kb-contract-manifest \
  --source work/SLUG/kb-sources \
  --candidate work/SLUG/kb-candidates \
  --language cs --summary 'Český jednořádkový souhrn změny' \
  --output work/SLUG/kb-release-cs.yml

bin/kb-contract-manifest \
  --source work/SLUG/kb-sources \
  --candidate work/SLUG/kb-candidates \
  --language en --summary 'English one-line summary of the change' \
  --output work/SLUG/kb-release-en.yml
```

Claim the global on-demand staging container. Reset it only when the current
session owns it and a clean production mirror is required:

```sh
bin/kb-stage start
bin/kb-stage reset --yes
bin/kb-release stage --manifest work/SLUG/kb-release-cs.yml --yes
bin/kb-release stage --manifest work/SLUG/kb-release-en.yml --yes
bin/kb-release verify --manifest work/SLUG/kb-release-cs.yml
bin/kb-release verify --manifest work/SLUG/kb-release-en.yml
```

Review both sites through their staging hostnames. Verify normal page IDs,
screenshots, rendered navigation markers, and bidirectional language links.
When both manifests create counterpart pages, stage both languages before the
strict verification commands so each counterpart exists when links are
checked. Staging still verifies page and media bytes immediately; it defers
language-link checks for a manifest containing a create-only page.
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
- Czech and English staging releases render and interlink correctly.
- Production remains untouched until the user approves exact promotion.
