# Portable capture runtime

The KB repository owns one engine. `bin/devcluster` runs it from a checkout;
`vpsfree-kb-devcluster` runs the same code from the `kb-runtime` flake package.
It does not inspect development sessions or require dev-workspace. The optional
workspace provider adds session and package-generation guards outside the engine.

The checkout defaults to its own `.devcluster/v2`, regardless of the caller's
working directory. The package defaults to `.devcluster/v2` beneath the caller's
working directory. Pass `--state-root DIR` to select another owned private root.
An explicit configuration is required before start. Bridge configuration must
name dedicated addresses, the bridge and gateway. Local configuration must name
all forwarding ports and an integer `local.multicastPort` in 1..65535. The default
config declares 10000; concurrent instances need disjoint explicit UDP ports.
Conflicts fail; the engine does not change ports, select another subnet or clean
foreign resources.

## State and ownership

State schema 2 stores `clusters/SLUG/identity.json`. The identity binds a random
instance UUID, owner UID, canonical root, slug and creation time. Moving or copying
it does not transfer ownership. Private directories use mode 0700 and private
files use 0600. Symlinks and unsupported schemas fail before mutations.
Persistent gate/operation/runner locks live outside the removable cluster tree.
Read-only status does not initialize missing state.

Each runner start records a fresh run UUID and immutable reservation and launch
receipts. They bind a prepared artifact UUID and receipt digest to configuration
bytes, socket paths, requested resources, source, runner and expected system
closures. The runner records its boot ID, PID, Linux start ticks, executable and
exact argument vector, plus owned child identities.
Readiness belongs to that exact run. A stale PID or ready file cannot authorize
cleanup. Status reports busy (exit 75) when a lifecycle operation or capture owns
the gate.

The per-user resource registry claims the complete requested set under one short
lock. Its durable records remain after controller loss. Only positive process
exit proof permits release. The registry coordinates KB instances; a host bind
failure or responding foreign bridge address also refuses start. Dedicated
bridge allocation remains the operator's responsibility.

Local socket networks use the configured integer at multicast address
`230.0.0.1`. Instance/run labels identify provenance, not the actual UDP resource.
Claims conservatively exclude the same UDP port across KB instances, regardless
of root or multicast group; TCP and UDP are separate resources. A no-reuse UDP
bind probe precedes launch and closes before QEMU binds. The durable claim spans
that handoff, but cannot reserve the port against unrelated host software.

Stop requests shutdown through the recorded runner's validated control socket.
The runner gracefully shuts down and reaps its machines. An unresponsive or
ambiguous orphan remains recorded with its paths and claims; no PID search,
process-group kill or force option substitutes for ownership. Reset requires a
stopped, proven instance and removes only its owned tree. Old rooted closures
remain until that owned reset.

Legacy `.devcluster/clusters` and old slug-only global socket directories are
outside schema 2. The launcher neither adopts nor deletes them. Create a fresh
v2 instance with disjoint resources. Cleaning legacy resources requires its own
ownership investigation and explicit operation.

## Source proof

Start builds from a committed immutable KB flake snapshot. A dirty checkout cannot
produce final capture evidence. The source receipt binds the KB revision and
store source, lock digest, locked revisions/narHashes and fixture digest. Nested
follows paths resolve through their complete remaining suffix. Inherited source
overrides are cleared before Nix receives explicit configuration and credential
inputs. The extension's ordinary vpsAdmin/vpsAdminOS inputs do not select this
source.

The build places `/etc/vpsfree-kb-capture.json` in every guest. This binds the
instance, prepared artifact, exact source and configuration input digest. It has
no live run UUID; starting the same artifact again does not rebuild the guests.
Before login or fixture changes, capture checks that identity over the instance's
SSH trust and
compares `/run/current-system` with every expected system closure. The live
vpsAdmin pin must match the source lock and inventory. The host descriptor alone
does not prove source identity. A failed or partial transition is not ready for
capture, and original launch receipts remain available for diagnosis.

## Stop, resume and update

`start` creates a fresh instance and refuses retained state. After an owned stop,
`resume SLUG` uses the latest accepted artifact with a fresh live run UUID and new
resource/socket reservations. Resume takes no replacement configuration, topology
or network and rebuilds nothing. The selected committed source, recorded
configuration, disk identities, credentials and preparation evidence must match.
Missing roots fail rather than being recreated. An unresolved update refuses
resume and cannot fall back to an older artifact.

`update` prevalidates the replacement configuration, disk layout and TLS names
under one held operation, then attests the old live runner and guests. Updates
require the same resolved SSH hosts and ports because retained host-key trust is
not rebound. The engine journals the candidate and becomes non-ready before
building its rooted closures. Build
failure preserves the old processes, claims and disks. Retrying requires the same
selected source and requested configuration.

The private candidate journal retains the requested configuration for that retry.
The immutable artifact identifies it by its input digest and recorded path;
exported provenance does not embed seed accounts or passwords.

Each retained NixOS guest receives the exact recursive candidate closure through
the old run's explicit SSH endpoint, port, key and known-hosts file. Preparation
requires working guest Nix/store tools and writable store access. It checks the
missing closure's NAR bytes and filesystem entry count, plus a 256 MiB and 10,000
inode reserve. This conservative check does not guarantee that a later import
cannot exhaust the filesystem. There is no automatic GC, resizing, activation or
host-store mount. Host and guest path identities, references and contents must
agree, and the guest receives an exact per-instance/artifact GC root. The old
running metadata and system closure must remain unchanged throughout preparation.

A partial copy, unavailable store, content mismatch or failed guest GC root
leaves the old processes and disks intact, with a non-ready update journal.
Retry rechecks the same candidate and retains valid imported paths. An offline
update requires complete recorded preparation; it cannot invent a bootable
candidate from an unprepared retained root.

Only complete preparation permits graceful shutdown and the candidate's direct
boot. K's NixOS driver preserves the owned compatible root image and other disks;
it copies the initial root once, not during resume or update. New kernel, initrd,
init and toplevel paths come from the candidate. OS nodes use its read-only
squashfs and retained data disks. Live attestation is mandatory before accepting
the candidate. Every old result root, artifact, configuration and preparation
receipt remains until an owned reset. These retained receipts are evidence, not
an application-data downgrade guarantee.

Each runner attempt is recorded before spawn. Recovery must prove an earlier
attempt gone before starting another. It never automatically boots the previous
artifact, replaces a root image or activates a guest profile as a fallback.

## Connection and lease

`connection SLUG` exports private connection schema 1, bounded to 2 MiB. It names
the instance/run/artifact, owner, topology, fixture capabilities, logical HTTPS
service URLs with exact
connect endpoints, SSH machines, CA/account references, launch provenance and an
explicit controller argument vector. Credentials are file references. The
connection file and referenced credentials must be private owned ordinary files.

`bin/capture --cluster SLUG` obtains that descriptor from the local engine.
`--connection FILE` uses an explicit dedicated external capture environment.
The selectors are mutually exclusive and use the same validation and source
proof. Neither selector grants permission to reset an external environment.
Unknown service destinations are not routed through the capture proxy.

Capture starts the owning controller with expected instance/run/artifact IDs,
the artifact receipt digest and exact descriptor digest. Lease protocol 1 sends
one bounded readiness JSON only after
acquiring the capture gate and verifying live source. Its stdin/stdout pipes remain
open for the whole operation. Controller loss cancels browser and SSH activity.
Normal shutdown closes browser/SSH resources before EOF releases the gate.
Failed readiness supervises and reaps only its own controller child. A descriptor
without lease, SSH or required fixture capabilities fails before fixture changes.

Protocol stdout EOF or error fails a pending handshake or cancels an acquired
lease immediately, even if the controller process is still running. No later
fixture or SSH request may pass the live-lease check. Closing diagnostic stderr
alone does not end the lease. Intentional normal shutdown releases the lease
after capture resources close. Cancellation cannot undo a remote request already
accepted before peer loss.

## Source and artifacts

The capture package includes `vpsfree-kb-capture` and `vpsfree-kb-validate` from
one fixed immutable source. They default output to the invocation directory;
checkout `bin/capture` and `bin/validate` default output to the owning checkout.
`--output-root DIR` changes artifacts only. Code, lock, scenarios, fixtures and
original inventory always come from the selected source. A store or unwritable
output root fails before connection or fixture work.

An artifact lock serializes captures and validation for each output root. It is
acquired before reading retained results or acquiring the cluster lease. Capture
keeps the locked file descriptor in the writing process and passes the same open
file description only to its artifact-lock helper. Both processes close their
copies without explicitly unlocking. If the helper dies during synchronous
publication, the writer still holds the lock until browser, SSH and controller
cleanup finishes. Observed helper loss cancels capture and prevents further
publication. Validation's writing child also retains its lock if the wrapper dies.

Each invocation uses a private directory under
`outputRoot/tmp` for CLI authentication, fixture metadata, transcripts and staged
PNGs. Canonical screenshots remain under `screenshots/{cs,en}/TOPIC/VIEW.png`.
No source or credential path is derived from an artifact directory.

Successful publication atomically merges results by language and semantic ID.
Czech then English capture retains both results. The source receipt binds the
original inventory and normalized immutable capture contract; generated hashes,
dimensions and provenance do not change that binding. Every retained result must
match its PNG hash and verified instance/run/artifact source. Duplicate, mixed-source or
stale results fail. An interrupted PNG/result publication cannot certify output.
Reviewed or uploaded source/candidate assets remain protected even with an empty
alternate output directory.

`validate --update` writes only the output root's candidate `captures.json`.
Immutable candidate fields must match the source contract. Changed entries need
their artifact and matching verified result. Unchanged entries may use original
source PNGs. Strict validation covers the full inventory. `bin/check --output-root
DIR` forwards that root only to final artifact validation; source-contract checks
continue to read the owning source. Capture scratch, CLI homes, credentials and
raw transcripts are not part of a generated evidence carryback.

## Verification and limits

Fast runtime/connection/artifact tests use isolated roots and fake VM transports;
they do not certify live KVM or workspace activation. The `runtime/standalone`
external-test suite installs the named KB packages in a disposable NixOS machine,
without a workspace registry, package or session variables.

Use an exact clean Git-flake revision to build `standalone-test-config`. This
immutable profile carries the original source receipt and matching runtime and
capture packages through the test runner's path-based source evaluation. The
test framework validates the profile's source, revision, lock and metadata before
using its packages. A standalone run without a valid profile refuses before VM
startup; the other KB suites keep their existing invocation route.

```sh
PROFILE=$(nix build --no-link --print-out-paths "$K_REF#standalone-test-config")
nix run "$K_REF#test-runner" -- test --jobs 1 --state-dir "$TEST_STATE" \
  --test-config "$PROFILE" 'runtime/standalone#installed-layout'
```

Set `K_REF` to the exact committed Git-flake reference and `TEST_STATE` to fresh
test-owned runner state. Run `two-instances`, `resume-update` and
`bilingual-capture` separately, replacing the final selector and state path for
each invocation. Keep the same source profile throughout.

The outer VM needs functioning nested KVM, 32 GiB RAM, eight CPUs, a 128 GiB root
disk and 24 GiB shared memory. Its nested cases check available RAM, shared
memory and at least 96 GiB free disk space before building their clusters. With
the runner's default 8 GiB reserves, host admission needs at least 40 GiB
available RAM and 40 GiB free shared memory. Plan for at least 272 GiB host disk
space for the built root image, writable copy and 16 GiB reserve, plus uncached
closures and build working space. Measure each filesystem; sparse-image savings
do not establish capacity. Insufficient capacity refuses the run.

The isolated fixtures use explicit local ports, QEMU's `10.0.2.3` DNS endpoint
and `example.test` domains. The builder uses the pinned OS cache and key, but
that configuration alone does not prove the expected kernel is available.
An unexpected local kernel build requires investigation; resource overrides,
weaker assertions and CPU-emulation fallbacks do not supply runtime proof.

The bilingual case captures CS and EN into one explicit output root different
from CWD, then updates and strictly validates that inventory. Before VM cleanup,
the test exports only the two PNGs, candidate inventory, merged results and
source receipt to `state_dir/artifacts`. Inspect and validate that bundle before
carrying approved artifacts back to a checkout. The resume/update case checks
all six credential identities, retained root/data sentinels and disk identities,
fresh live run identity and the actual changed system closures.

The optional workspace integration is documented by its provider in
vpsfree-dev-workspace. Source publication does not install or activate it.
Default-branch integration, package activation, real cluster operations and wiki
publication are separate operator actions.
