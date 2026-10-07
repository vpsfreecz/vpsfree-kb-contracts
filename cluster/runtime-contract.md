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
Private records are published by atomic rename. A reader validates both the
named file and its opened descriptor, including ownership, mode and size. If a
safe replacement changes the inode between those checks, it restarts the read,
up to three attempts. Other failures and continued replacement refuse access.
A successful read returns one complete validated snapshot; owner locks and
receipt identity checks still govern consistency across records.

Before creating machines or publishing its live tuple, the runner establishes
its own POSIX session without forking. Its recorded PID, executable and argument
vector stay the same. Session establishment failure refuses before machine
creation. The separate session protects the run from inherited terminal and
process-group signals; a containing cgroup, supervisor or host failure can still
end it. Complete ownership and exit evidence remain required for cleanup.

Readiness belongs to that exact run. The runner's boot marker confirms its test
shell. The engine separately waits for valid SSH host keys from every recorded
machine within one absolute readiness deadline. Empty or unavailable key
discovery may wait within that budget. Invalid or wrong-endpoint keys, runner
identity loss and retained-key mismatch refuse immediately. Initial trust is
written only after all machines succeed; retained trust is never replaced or
expanded to accept a changed key. Strict authentication and guest source/system
closure checks remain separate requirements.

The engine's read-only `ready?` predicate requires a ready phase, its validated
current launch, the matching schema-1 run-ready marker and the recorded live
runner. Missing readiness returns false; unsafe or foreign records refuse.
Status, connection export, initial update admission and capture use this same
predicate. Capture checks it again after guest attestation and throughout its
lease. Process liveness alone does not establish readiness. Shutdown withdraws
the marker even when requested directly through the runner's signal path.

Failed discovery attempts identify the machine, endpoint and private native
diagnostic path. An exhausted budget may refuse before a scan starts. Bounded
command output and status stay under the owned run, outside artifact exports. A failed verification leaves the run non-ready with its claims
and evidence. It does not replay lifecycle work or authorize orphan cleanup.
A stale PID or ready file cannot authorize cleanup. Status reports busy (exit 75)
when a lifecycle operation or capture owns the gate.

Public `start`, `resume`, `update`, `stop` and `reset` refuse gate or operation
contention with exit 75. Retry explicitly after the holder releases its lock;
these commands do not queue a mutation behind a capture. A fresh start may
create empty persistent lock infrastructure before admission, but initializes
no instance until both locks are held. Successful start, resume and update
output describes the verified run at operation completion. Use `status` for a
fresh guarded snapshot afterward.

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
After authenticating the owned paths and peer, the controller marks the run
`stopping` before sending the request. The runner withdraws readiness and issues
at most one graceful stop per started, running machine. Repeated authenticated
requests acknowledge the same shutdown and wait; they do not repeat poweroff.
Once a valid request starts shutdown, the runner continues even if its reply
cannot reach the caller. A missing reply does not prove that shutdown was
rejected; a later public stop can wait for the same drain.

The runner uses its configured machine operation budget, normally 900 seconds.
The CLI's `--timeout` bounds the controller's observation after acknowledgement;
it does not bound sequential machine waits or the whole update command. If a
machine wait or the caller expires, the same runner, tracker, control listener
and reapers remain alive while owned children remain. The run stays non-ready
and retains its claims and disks. A later public stop can wait for that same
shutdown. No timeout supplies force or restart authority.

The runner records newly discovered children throughout the drain. It publishes
complete exit only after machine reapers finish and every retained child is
proved gone. It then joins its control thread before closing the listener and
removing its own control socket. Unknown
socket-directory entries still prevent the engine from marking the run stopped.
An unresponsive or ambiguous orphan remains recorded with its paths and claims;
no PID search, process-group kill or force option substitutes for ownership.
Reset requires a stopped, proven instance and removes only its owned tree.
Old rooted closures remain until that owned reset.

Process discovery reads the child lists of every task in each reached process.
It retains observed process identities across exit and reparenting; task IDs
are not child-process records. Missing child data for a live task refuses the
observation. An observed task disappearance or changed task set makes that pass
inconclusive. The runner retains ownership and observes again through its normal
drain loop. It requires a successful quiesced observation before invoking machine
finalization or cleanup, and fresh proof afterward before publishing completion.
These procfs reads are not an atomic tree snapshot: machine reapers and retained
child identities still govern completion. Discovery cannot recover processes
that escaped before observation or repair incomplete old receipts.

During the same locked stop or update call, the engine may remove the
acknowledged runner's residual control socket. Before sending the request, it
pins the private directory and socket inode with open descriptors and proves
the recorded live runner and control peer. Removal requires the accepted stop
response, the same launch and runner identity, complete exit proof for every
recorded process, and an unchanged directory containing only that socket.
Changed paths, unsafe metadata and other entries refuse cleanup. If the runner
removed its socket, ordinary empty-directory cleanup applies.

This permission lasts only for that call. Interruption discards it; a later
call must authenticate a still-live runner or find a proven empty namespace.
A dead runner's residual socket cannot regain permission from receipt or inode
facts alone. Claim release precedes socket cleanup, so a cleanup refusal may
leave claims released while the phase remains non-stopped. An update cannot
boot its candidate until the existing shutdown and cleanup checks succeed.

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

Fast runtime, connection, artifact and verifier tests use isolated roots and
fake transports. They do not certify installed packages, live guests or captures.
The `runtime-verify` package provides `vpsfree-kb-verify` for real verification
on an ordinary Linux/Nix/KVM host. It drives the installed public launcher,
capture and validator from its own immutable source. It launches no outer VM
and needs no development workspace, session command or provider activation.
Other managed KB page suites retain their test-runner route.

Prepare the packages from a clean exact Git-flake revision after source checks
and independent review. Supply one private disk-backed campaign root, one
explicit configuration and a private capacity receipt. Run the required real
phase, then the optional capture phase against the same inputs:

```sh
vpsfree-kb-verify --root "$ROOT" --config "$CONFIG" \
  --capacity-receipt "$CAPACITY_RECEIPT" --phase runtime-smoke
vpsfree-kb-verify --root "$ROOT" --config "$CONFIG" \
  --capacity-receipt "$CAPACITY_RECEIPT" --phase bilingual-capture
```

`installed-layout` is an optional package/path check. It constructs no
predecessor package and is not a prerequisite for `runtime-smoke`. Campaign kind
`single-runtime-v1` binds the selected source and tools, raw configuration digest,
canonical root and capacity evidence. Old campaign roots and obsolete argument
combinations refuse; the verifier does not migrate or reinterpret their receipts.
A completed runtime receipt is required for capture. Each completed phase is
immutable. An incomplete or failed attempt retains its native stage evidence
and owned state and refuses replay. It supplies no cleanup authority.

The qualification uses one `single` cluster with a 2 GiB services guest and
2 GiB node1. Set `services.memoryMiB` and `nodes.node1.memoryMiB` to 2048,
`services.rootDiskMiB` to 8192 and `nodes.node1.tankDiskGiB` to 8. The services
image and its independent writable copy are each 8 GiB. The image-finalization
builder also uses `services.memoryMiB` and finishes before runtime guests start.
Configure explicit local loopback TCP forwarding and an integer multicast port,
disable dedicated DNS guests, use QEMU's `10.0.2.3` resolver and `example.test`
domains. Conflicts refuse rather than selecting other resources. These targets
must pass a real qualification; they are not measured sufficient minima for
all fixtures or workloads. The general runtime configuration remains separate
from this verifier profile.

Include disposable `test-admin` (level 99), `test-user1` and `test-user2`
(both level 1) accounts from the initial start. Give each a full name, a password
and an email of `LOGIN@example.test`. Each namespace has `blockCount: 8`;
set `blockStart` to 1 for `test-admin`, 9 for `test-user1` and 17 for `test-user2`.
The verifier rejects missing, duplicate or incompatible entries before lifecycle
work. Keep the initial configuration unchanged and compare the private
accounts-file digest without exposing credentials.

The runtime phase starts the final-source public package, obtains its attested
connection and verifies both guest identity records and actual system closures.
It checks real TLS/API current-user identity and member PHP access, public lease
contention, peer loss and reacquisition. Wrong-source refusal must precede SSH;
contended stop, update and reset must return 75 without queued mutation.
Dedicated services-root and node-ZFS sentinels are written through public SSH.
Ordinary public stop must establish complete exit. Same-source public resume
must retain the accepted artifact, all six credentials, accounts digest, disk
identities and sentinel contents, with a fresh run ID and no new image or build.
The final attestation checks source, closures, trust and readiness again.
Completion leaves that resumed instance available for optional captures.

This one-instance qualification does not establish two-live-cluster isolation,
historical resume/update, closure import or a vpsAdmin upgrade. Recorded source
and synthetic process/lock tests retain their scoped evidence; deferred real
upgrade campaigns are not counted as passing tests.

The public stop/resume observation budget is 900 seconds. It is separate from
the runner's per-machine operation budget and does not bound all sequential
machine work or grant force authority. A native build, readiness, capacity,
lease or lifecycle failure ends the finite qualification. Preserve the exact
failure and state; do not resize, upscale, substitute a configuration or launch
another instance automatically. Failed public commands retain native argv,
exit/signal and diagnostic output privately beneath the campaign root. Artifact
exports exclude this evidence.

Before start or resume, capacity admission includes the 4 GiB guest RAM and
shared-memory demand plus separately assessed positive overhead. For example,
2 GiB RAM and 1 GiB shared-memory margins require 6 GiB available RAM and 5 GiB
free shared memory. Initial start assesses construction and runtime/browser
phases separately and uses their peak. The builder finishes before guests start.

Live capture first attests the same resumed guests and their continuity. Its
fresh availability check requires only the additional runtime/browser margins,
2 GiB RAM and 1 GiB shared memory in this example. The running guests have
already reduced those available figures. Require working KVM; no emulation or
nested VM is part of this qualification.

The intrinsic eventual new disk output is one 8 GiB image, one 8 GiB writable
root and one 8 GiB sparse tank. The receipt reports this 24 GiB extent separately
from missing closures, construction staging/import overlap, assessed build
headroom and retained-host reserves. Deduct actual allocated blocks once per
file/inode/filesystem and retain sparse future growth. Resume creates no second
image. Previously allocated files already reduce measured free space; their
unallocated possible growth remains a separate protected host obligation.
Keep at least the existing 16 GiB base reserve plus assessed retained growth.
There is no universal free-disk floor for this test.

The required capacity receipt binds source/package identities, the configuration
digest, campaign root and actual state/store/builder filesystems. Record realized
paths, known missing construction, effective concurrency, exact kernel-cache
evidence and assessed headroom. The qualification uses one build job and one
core through normal Nix configuration. Builder scratch remains explicitly
unknown: NAR/download sizes and a client `TMPDIR` do not bound it or identify
the daemon build filesystem. Package preparation precedes verifier invocation
and needs its own assessment. Refresh actual RAM/shm/filesystem admission before
build/start and resume; the receipt does not reserve resources against other
host activity or certify monitoring.

Public runtime-plan and derivation projection can reject an oversized payload
and prove selected memory/image/kernel facts. Placeholder planning inputs are
not the eventual guest identity or full closure. The fixed-size image build
inside public start is the final exact payload-fit gate before runtime reserve
and spawn; there is no private preparation substitute or public post-build
launch pause. Keep assessed construction headroom and live reserve monitoring,
stop unexpected kernel compilation and investigate its cache prerequisite.
Do not reclaim foreign state/store or bypass ZFS/template/quota admission.

Once ready, record image/root lengths and allocated blocks, services free bytes
and inodes, node ZFS available space and memory pressure. Require 1 GiB services
free space before fixtures. Before capture, assess tank headroom for the selected
template, metadata and the real 4 GiB VPS quota. Boot success alone does not
qualify capture resources. If the reduced target is inadequate, stop advancing
and retain the measured failure. An optional capture failure does not erase a
separately completed lifecycle receipt, but it leaves media acceptance pending.

The bilingual phase selects only `networking/ip-address-list` and its
`ip-inventory` fixture. This uses one real 1 CPU, 1 GiB RAM, 4 GiB disk VPS,
its enabled assigned address, and a dedicated disabled documentation pool with
an owned detached address. Other capture concepts retain their full fixtures.
CS and EN use one explicit output root different from the invocation directory,
exercising both cluster and private connection selectors. An EN recapture from
the output directory also proves the packaged writable-CWD default. The results
contain exactly the two language/ID rows from one immutable generator source.

Installed validation first updates the candidate inventory and then strictly
checks the full inventory, without `--allow-missing`. Unchanged assets may come
from immutable source. Under the physical artifact lock, export only the two
`screenshots/{cs,en}/networking/ip-address-list.png` files, `captures.json`,
`tmp/capture-results.json` and `tmp/capture-source.json`, with checksums. Exclude
connections, credentials, accounts, CLI homes and raw transcripts. Validate and
review both images before carryback; preserve the generating revision when a
later commit records them. Native tooltip title/focus assertions do not establish
that a browser-native tooltip appears in a PNG.

The optional workspace integration is documented by its provider in
vpsfree-dev-workspace. Source publication does not install or activate it.
Default-branch integration, package activation, real cluster operations and wiki
publication are separate operator actions.
