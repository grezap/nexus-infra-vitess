# nexus-infra-vitess

**Phase 0.O of NexusPlatform** — a Vitess-sharded MySQL cluster: the relational
**horizontal-sharding** tier of the OLTP story.

- **Engine:** Percona Server 8.4 LTS tablets, fronted by **Vitess v24.0.1**
  (`vtgate` MySQL-protocol routers, `vttablet` shard sidecars, `vtctld` control
  plane, **VTOrc** automated failover orchestrator).
- **Topology** (ADR-0041): 12 VMs, tier `07-vitess` —
  - 3× **etcd** 3.5 (global + local cell `nexus` topology service) — `.190`–`.192`
  - 1× **control** (vtctld + VTOrc) — `.193`
  - 2× **vtgate** routers (round-robin `vtgate.nexus.lab`, MySQL `:15306`) — `.194`/`.195`
  - 2 shards × 3 tablets — keyspace `commerce`, split `-80` (`.196`–`.198`) /
    `80-` (`.199`–`.201`), hash vindex on the sharding key.
- **Security:** full **Vault-PKI mTLS** on every gRPC channel
  (vtgate↔vttablet, vtctld↔vttablet, VTOrc↔vttablet, all↔etcd), the mysqld wire,
  and the vtgate MySQL listener. etcd uses client-cert-auth (mTLS is the access
  control). Per-host Vault Agent renders leaf certs + MySQL creds from Vault.
- **Networking:** VMnet11 service net (mgmt + vtgate `:15306` + web ports);
  VMnet10 backplane (etcd raft, all intra-cluster gRPC, MySQL replication).

## Status

**In ratification** (Phase 0.O). Per-engine Packer templates + per-cluster
Terraform state per `feedback_per_cluster_state_per_engine_template`.

## Layout

```
packer/vitess-{etcd,gate,tablet}-node/   # 3 per-engine templates (binaries + DISABLED units)
terraform/envs/vitess/                    # per-cluster state: 12 VMs + 7 bring-up overlays
terraform/modules/vm/                     # VMware clone module (shared)
scripts/vitess.ps1                        # operator wrapper (apply/destroy/cycle/smoke/plan/validate)
scripts/smoke-0.O.ps1                     # ~55-check exit gate (incl VTOrc reparent + sharding proof)
scripts/build-templates.ps1              # build the 3 templates
docs/handbook.md                          # from-zero replay guide (§0 prereqs … §3 runbooks)
```

## Quick start

```pwsh
# prereqs (other repo): foundation dhcp pins + vault PKI/sidecars
pwsh -File ..\nexus-infra-vmware\scripts\foundation.ps1 apply
pwsh -File ..\nexus-infra-vmware\scripts\security.ps1   apply
# this repo:
pwsh -File scripts\build-templates.ps1     # ~30-45 min
pwsh -File scripts\vitess.ps1 apply        # -parallelism=3 first apply
pwsh -File scripts\vitess.ps1 smoke
```

See [docs/handbook.md](docs/handbook.md) for the exact from-zero replay,
selective-ops examples, and the cold-rebuild canon.
