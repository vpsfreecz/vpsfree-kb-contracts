# vpsAdmin KB captures

This repository makes vpsAdmin documentation screenshots reproducible. It
contains the complete asset inventory, its own pinned vpsAdmin development
cluster, deterministic screenshot fixtures, and Playwright capture scenarios
for the WebUI, remote console, and CLI.

It is self-contained at runtime. The Nix lock file pins upstream vpsAdmin,
vpsAdminOS, and supporting sources; no external checkout layout or helper
repository is required.

## Quick start

Enter the pinned shell, start an isolated cluster, and run the captures:

```sh
nix develop
bin/devcluster start kb-captures --topology screenshots
bin/capture --cluster kb-captures --language en
bin/validate --update
bin/validate
bin/devcluster stop kb-captures
```

Bridge networking is the default. Use `--network local` when another bridge
cluster is active or bridge privileges are unavailable. Runtime state,
certificates, SSH keys, logs, and generated cluster configuration are stored in
the ignored `.devcluster/` directory.

The capture command reads the cluster's generated test accounts, verifies the
pinned vpsAdmin revision, creates or reuses only fixtures owned by this
repository, selects the requested locale and the exact `Debian (latest)` VPS
template, and writes PNG files under
`screenshots/<language>/<topic>/`. Fixtures can create the two documentation
VPSes (`vps` and `playground-vps`), a mounted `data` subdataset, a `nas`
dataset on `backuper1`, a labeled snapshot, a public key, an unconfirmed TOTP
device, console generation metadata, and network traffic. Never point the
tooling at a shared or production cluster.

The committed fixture shape mirrors the public production labels and resource
values needed by the documentation: Production, Playground, Praha storage,
Staging, their five locations, and the public package catalog. It deliberately
uses stable local IDs, documentation-safe environment domains, and the
production location domains `prg`, `brq`, `pgnd`, and `stg`. Large resource
values remain decimal strings so IPv6 quantities are not rounded by JSON
implementations.
The nodes use sparse 320 GiB tank images so the production-sized fixture
packages pass pool-capacity checks without allocating that space up front.

Use `--scenario NAME` to recapture a functional group or
`--checkpoint TOPIC/VIEW` for one asset. Run `bin/devcluster --help` for cluster
lifecycle and inspection commands.

## Naming and inventory

Screenshots use stable semantic paths, for example:

```text
screenshots/cs/console/web-console.png
screenshots/cs/datasets/create-dataset-form.png
```

The corresponding DokuWiki media IDs put the language namespace first, for
example `cs:screenshots:vpsadmin:console:web-console.png`. Display-order
prefixes and revision suffixes are deliberately absent: scenario code defines
capture order, while Git and DokuWiki provide revision history.

`captures.json` contains 85 language-neutral screenshot concepts. Every
concept has Czech and English variants with independent legacy/source-page
bindings, canonical media ID, output, dimensions, SHA-256, review state, and
capture provenance. Topic, scenario/checkpoint, driver, fixtures, viewport,
and the pinned vpsAdmin commit are shared. A scenario can emit several related
screenshots, but every bitmap has an independently addressable semantic
checkpoint and language variant.

`bin/validate --update` accepts capture results only when their ID, checkpoint,
driver, output path, and SHA-256 agree with the manifest and generated file.
Review the image and manifest diffs, then run strict `bin/validate`.
`bin/contact-sheet [TOPIC_OR_SCENARIO] [cs|en]` writes an ignored visual review
sheet under `tmp/`. The language defaults to Czech.

Capture bounds are derived from visible text, controls, complete table and
fieldset boxes, images, terminal surfaces, and other meaningful content inside
each selected region. Headings retain their full line height. An eight-pixel
margin is added after the bounds are combined, keeping complete table borders
without restoring unused block width. Scenarios still select the semantic
region; the crop helper only tightens its bounds.

The Nix shell provides a pinned Fontconfig setup with Liberation Mono. This is
used explicitly by synthetic terminals and satisfies the Courier fallback used
by the WebUI console, so terminal cell measurements do not depend on fonts
installed on the capture host.

Captures are intentionally operator-run. This repository contains no GitHub
Actions workflow and no DokuWiki uploader.

## Documentation contract

For the complete cross-repository procedure triggered by a vpsAdmin WebUI
change, see [`docs/webui-change-workflow.md`](docs/webui-change-workflow.md).

`contract/navigation.yml` assigns stable semantic IDs to documented WebUI
controls and navigation paths. It binds current English/Czech gettext labels,
coupled source fingerprints, affected KB pages, and screenshot concepts.
`bin/check` compares the contract with the pinned vpsAdmin source and capture
inventory. A label, route, landmark, or semantic-selector change reports every
affected ID together with its Czech/English pages and capture concepts.
Fingerprints cover the normalized production declaration around each landmark;
test files cannot satisfy them. DokuWiki annotation inventory will use the path
IDs without making this repository responsible for publishing pages.

`contract/kb-annotations.yml` records expected tags for every affected path.
`contract/kb-navigation-inventory.yml` is produced from an independent scan of
all accessible production pages, not from the curated path list. Every detected
source paragraph records its semantic path IDs or an explicit reason why it is
not bound. The inventory pins the complete per-language page-ID sets, and the
checker rejects duplicate IDs or files, so an accidentally partial source fetch
cannot pass validation by preserving only the page count.
Validate a locally prepared candidate set with:

```sh
ruby tools/check-kb-annotations.rb \
  --source-index /path/to/kb-sources/index.json \
  --candidate-index /path/to/kb-candidates/index.json
```

The checker rejects unknown IDs, malformed tags, count drift, partial page
sets, source paragraphs missed by the discovery heuristic, and newly
unclassified or stale independently discovered paragraphs.
Fetching, staging, and publishing DokuWiki pages remain outside this repository.
