# Changelog — nexus-infra-vitess

All notable changes to this repo. Format loosely follows Keep a Changelog.

## [Unreleased] — Phase 0.O (Vitess-sharded MySQL)

### Added
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
