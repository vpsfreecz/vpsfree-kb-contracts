# vpsFree KB contracts

This repository owns reproducible evidence for an explicit subset of the
vpsFree.cz knowledge bases. It contains canonical article sources and runtime
tests, the complete vpsAdmin screenshot inventory, a pinned development
cluster, deterministic fixtures, and Playwright capture scenarios for the
WebUI, remote console, and CLI. It is not the source repository for every KB
page.

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

`captures.json` contains 59 language-neutral screenshot concepts. Every
concept has Czech and English variants with independent legacy/source-page
bindings, canonical media ID, output, dimensions, SHA-256, review state, and
capture provenance. Topic, scenario/checkpoint, driver, fixtures, viewport,
and the pinned vpsAdmin commit are shared. A scenario can emit several related
screenshots, but every bitmap has an independently addressable semantic
checkpoint and language variant.

The `vpsadmin-kb-captures/schema-5` value in capture provenance is a stable
schema identifier retained across the repository rename. New repository links
and package metadata use `vpsfree-kb-contracts`; existing capture records do
not change identity merely because their repository was renamed.

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

Captures are intentionally operator-run and this repository contains no
DokuWiki uploader. GitHub Actions runs static contract checks on changes.
Registered article suites run as separate jobs on relevant pushes, manually,
and every week on a self-hosted runner with KVM.

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
`contract/kb-navigation-inventory.yml` represents an independent scan of the
complete final page corpus, not the curated path list. When a release changes
content, refresh the affected discoveries from the candidates; unchanged
candidates are identical to the fetched production pages. Every detected
candidate paragraph records its semantic path IDs or an explicit reason why it
is not bound. The inventory and guarded source index pin the complete
per-language page-ID sets, and the checker rejects duplicate IDs or files, so
an accidentally partial source fetch cannot pass validation by preserving only
the page count. Candidate construction and the release manifest separately
guard production content checksums and revisions.
Validate a locally prepared candidate set with:

```sh
ruby tools/check-kb-annotations.rb \
  --source-index /path/to/kb-sources/index.json \
  --candidate-index /path/to/kb-candidates/index.json
```

The checker rejects unknown IDs, malformed tags, count drift, partial page
sets, candidate paragraphs missed by the discovery heuristic, and newly
unclassified or stale independently discovered paragraphs.
Fetching, staging, and publishing DokuWiki pages remain outside this repository.

## Managed article contract

`contract/articles.yml` is the registry of source-controlled KB articles. Each
entry binds its Czech and English sources to a test suite, executable samples,
section claims and fingerprints, and screenshot references. The checker reads
the flake's `testsMeta` output, so adding an article does not require an
article-specific source parser or workflow edit.

Every test script has the common `kb-runtime` tag and a `kbArticle` label. The
KVM article currently provides these independently runnable scripts:

```text
kb/kvm#platform-defaults
kb/kvm#libvirt
kb/kvm#storage
kb/kvm#networking
kb/kvm#nfs-locking
```

The suite provisions the exact `Debian (latest)` template through vpsAdmin
without feature or ZFS-property overrides. It verifies the runtime devices,
system libvirt connection and direct KVM capabilities, a subdataset-backed
libvirt storage pool with inherited ZFS defaults, dual-stack libvirt NAT with
persistent port forwarding, a public IPv4 routed through a private VPS address,
a delegated IPv6 `/64` routed through the VPS's primary `/64`, and the
narrowly scoped read-only NFSv3 installer-ISO workaround. The networking script
boots deterministic Nix-built KVM guests and verifies their inbound and
outbound IPv4 and IPv6 paths from outside the VPS.

List or run the maintained tests from the repository root:

```sh
./test-runner.sh ls --filter 'tag=kb-runtime'
./test-runner.sh test --fresh 'kb/kvm#platform-defaults'
./test-runner.sh test --fresh --jobs 1 \
  --filter 'tag=kb-runtime && kbArticle=kvm'
```

Managed pages contain a visible note linking their canonical source and test.
Do not edit them directly in DokuWiki. Candidate construction compares the
fetched wiki page, an explicit Git base commit, and the working source. A
wiki-only edit or concurrent Git/wiki edits stop the release until the change
is explicitly adopted or merged into the repository and verified again.

The flake exports `tests`, `testsMeta`, `lib.testFramework`, and a named
`test-runner` app using the pinned vpsAdminOS external-test interface. The
existing default app remains the operator-run screenshot cluster runner.
