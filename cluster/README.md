# Screenshot development cluster

This directory contains the complete NixOS/vpsAdminOS cluster definition and
seed configuration used by `bin/devcluster`. The flake lock pins its upstream
software revisions.

The capture topology contains a services VM, Production machine `node1`,
Playground machine `node2`, and Praha storage machine `backuper1`. Their
vpsAdmin identities are `node1.prg`, `node1.pgnd`, and `backuper1.prg`. The
declarative seed in `fixtures/production-shape.json` reproduces the public
environment, location, cluster-resource, and package labels needed by the
screenshots while using documentation-safe environment domains, local IDs,
and documentation address ranges.
VM memory and CPU sizes are deliberately modest and independent of the public
resource catalog so the complete topology can run alongside normal developer
workloads.
Screenshot scenarios then add their labeled, idempotent VPS, dataset, mount,
NAS, snapshot, account, console, and traffic fixtures through the WebUI.

All mutable cluster state is outside this directory in the ignored `.devcluster/v2/`
tree. Do not place credentials, generated certificates, SSH keys, or VM state
in Git.

The [portable runtime contract](runtime-contract.md) defines standalone state,
connection leases, immutable source, capture output and recovery. The optional
workspace provider calls this same engine and adds its own session and generation
guards; the engine itself has no workspace dependency.
