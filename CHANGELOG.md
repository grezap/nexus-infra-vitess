# Changelog — nexus-infra-vitess

All notable changes to this repo. Format loosely follows Keep a Changelog.

## [Unreleased] — Phase 0.O (Vitess-sharded MySQL)

### Changed — Platform CA rollover: the full vitess tier cold-rebuilt to the new Vault PKI root (2026-06-29)

- **The 12-VM vitess tier (etcd ×3 · control ×1 · vtgate ×2 · shard1 tablets ×3 [-80] · shard2 tablets ×3
  [80-]) cold-rebuilt onto the v0.8.1-greenfield Vault root** as the fourth tier of the paced platform CA
  rollover. No source `.tf` changed — env + module + clone_vm-state `vmrun_path` were already non-x86.
  Vitess is **KV-cred** (mysql user passwords in Vault KV mount `nexus`, field `content`), but a cold
  rebuild reads the CURRENT KV for both user creation and config render → consistent by construction (the
  citus in-place cred-drift hazard does not apply). Pre-flight: all **12 per-node AppRole sidecars**
  login-verified against the current root + all 5 KV creds (`vitess/{mysql-app,mysql-allprivs,mysql-root,
  mysql-repl,vtorc-topo}-password`) confirmed present.
- **Operation:** `vitess.ps1 destroy` (86 destroyed, clean) → `apply` with `TF_CLI_ARGS_apply=-parallelism=3`
  (86 added, **zero transients**) → **`smoke-0.O` ALL PASSED** (etcd topo + vtctld/VTOrc + 2 shards 1P+2R
  each + vtgate routing + hash-vindex sharding + full mTLS from the **new-root** `vitess-server` PKI +
  the VTOrc auto-reparent HA drill: kill `-80` primary → VTOrc promotes → killed tablet rejoins).
- **CA-rollover proof — `nexus cert-rotate vitess` GREEN** (all 12 nodes — etcd/control/vtgate/tablets,
  fresh leaf serials, 0 errors): x509-fails on old-root, succeeds only post-rebuild. Verb matrix re-run
  GREEN: `status` (2 shards, primaries drift-read from topo) / `health` (vtctld+VTOrc healthy, both shards
  1P+2R, operator-auth mTLS round-trip, sharding proof) / `topology` (keyranges) / `backup take` (per-shard
  logical `mysqldump` from each shard primary — engine-native Backup remains the 0.O.1 enhancement) /
  `acl list` (the `nexus` vtgate static-auth user).
- **3 per-engine Packer templates** (`vitess-etcd-node`, `vitess-gate-node`,
  `vitess-tablet-node`) — etcd 3.5.16; Percona Server 8.4 LTS + Vitess v24.0.1
  tablet binaries; Vitess v24.0.1 gate/control binaries. All systemd units
  delivered DISABLED (TF overlays render per-host config + enable).
- **`vitess_firstboot` role** — 12-node IP→role map, dual-NIC discovery, VMnet10
  backplane, `/etc/nexus-vitess/node-identity.env`.
- **`terraform/envs/vitess/`** per-cluster state: `main.tf` (12 VMs + topology
  locals), `variables.tf`, `outputs.tf`, and 7 bring-up overlays —
  nftables-backplane · vault-agents · tls · etcd-bootstrap · tablets · reparent ·
  gate (vtctld+vtgate+VTOrc) · schema. **Full Vault-PKI mTLS** on every gRPC
  channel + mysqld wire + vtgate MySQL listener.
- **`scripts/vitess.ps1`** operator wrapper + **`scripts/smoke-0.O.ps1`**
  (~55-check exit gate incl. VTOrc auto-reparent-on-primary-kill + sharded-insert-
  across-both-shards + mTLS verify) + **`scripts/build-templates.ps1`**.
- **`docs/handbook.md`** — from-zero replay guide (§0 prereqs … §3 runbooks +
  transient table).

### Cross-repo (provisioned in nexus-infra-vmware)
- foundation: `role-overlay-gateway-vitess-reservations.tf` (12 dhcp pins
  `.190`–`.201`, MACs `:CB`–`:D6`).
- security: `vitess-server` PKI role + 5 KV cluster creds + 12 narrow policies +
  12 AppRoles + per-host sidecars.
