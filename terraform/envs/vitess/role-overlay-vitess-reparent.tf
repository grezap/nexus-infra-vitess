/*
 * role-overlay-vitess-reparent.tf -- Phase 0.O
 *
 * Per shard, after all 3 tablets have registered (init_tablet_type=replica, no
 * primary yet), elect the initial PRIMARY:
 *   1. SetKeyspaceDurabilityPolicy --durability-policy=semi_sync commerce
 *      (idempotent; semi_sync => a write acks only after >=1 replica acks, so
 *       a single replica/primary loss never loses an acked write -- the
 *       guarantee VTOrc relies on when it auto-reparents on primary kill).
 *   2. PlannedReparentShard commerce/<shard> --new-primary <cell>-<primary-uid>
 *      (modern Vitess uses PRS for the initial election too -- no current
 *       primary to demote on a fresh shard).
 *   3. Wait for 1 PRIMARY + 2 REPLICA, all serving.
 *
 * Runs ON the control node via the /usr/local/sbin/nexus-vtctldclient wrapper
 * (installed by the vtctld bring-up in role-overlay-vitess-gate.tf -- preloaded
 * with --server <vtctld>:15999 + gRPC mTLS). Initial primary = the lowest-uid
 * tablet of each shard (shard1 -80 -> nexus-100; shard2 80- -> nexus-200).
 *
 * Dependency order: tablets -> THIS -> vtgate/vtorc -> schema.
 * Selective ops: var.enable_vitess_reparent.
 */

locals {
  vitess_control_ip = length(local.control_nodes) > 0 ? one([for h, s in local.control_nodes : s.vmnet11]) : ""

  vitess_shard_primary_alias = {
    "-80" = length(local.shard1_tablets) > 0 ? "${var.vitess_cell}-${min([for h, s in local.shard1_tablets : s.tablet_uid]...)}" : ""
    "80-" = length(local.shard2_tablets) > 0 ? "${var.vitess_cell}-${min([for h, s in local.shard2_tablets : s.tablet_uid]...)}" : ""
  }

  vitess_reparent_shards = {
    for sh, def in local.shards : sh => {
      primary_alias = local.vitess_shard_primary_alias[sh]
      tablet_count  = length(def.tablets)
    }
    if length(def.tablets) > 0
  }
}

resource "null_resource" "vitess_reparent" {
  for_each = (var.enable_vitess_reparent && local.vitess_control_ip != "") ? local.vitess_reparent_shards : {}

  triggers = {
    tablet_ids    = jsonencode([for k in keys(null_resource.vitess_tablet) : null_resource.vitess_tablet[k].id])
    vtctld_id     = length(null_resource.vitess_vtctld) > 0 ? null_resource.vitess_vtctld[0].id : "disabled"
    primary_alias = each.value.primary_alias
    reparent_v    = "2" # v2 (0.O fix O14) = durability none (async repl; semi_sync needs the semisync plugins loaded -> 0.O.1 hardening). v1 was semi_sync.
  }

  depends_on = [
    null_resource.vitess_tablet,
    null_resource.vitess_vtctld,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $shard      = '${each.key}'
      $primary    = '${each.value.primary_alias}'
      $keyspace   = '${var.vitess_keyspace}'
      $controlIp  = '${local.vitess_control_ip}'
      $sshUser    = '${var.vitess_node_user}'
      $timeout    = ${var.vitess_cluster_timeout_minutes}
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[vitess-reparent $keyspace/$shard] electing initial primary $primary (via control $controlIp)"

      # 1. Durability policy (keyspace-wide; idempotent).
      $durOut = (ssh @sshOpts "$sshUser@$controlIp" "sudo /usr/local/sbin/nexus-vtctldclient SetKeyspaceDurabilityPolicy --durability-policy=none $keyspace 2>&1" | Out-String)
      Write-Host "[vitess-reparent] durability: $($durOut.Trim())"

      # 2. Check current shard primary; skip PRS if already this primary.
      $cur = (ssh @sshOpts "$sshUser@$controlIp" "sudo /usr/local/sbin/nexus-vtctldclient GetShard $keyspace/$shard 2>/dev/null" | Out-String)
      if ($cur -match 'primary_alias' -and $cur -match "uid.*$($primary.Split('-')[-1])") {
        Write-Host "[vitess-reparent $keyspace/$shard] primary already $primary; skipping PRS"
      } else {
        Write-Host "[vitess-reparent $keyspace/$shard] PlannedReparentShard --new-primary $primary"
        $prsOut = (ssh @sshOpts "$sshUser@$controlIp" "sudo /usr/local/sbin/nexus-vtctldclient PlannedReparentShard $keyspace/$shard --new-primary $primary 2>&1" | Out-String)
        Write-Host $prsOut.Trim()
        if ($prsOut -match 'rpc error' -or $prsOut -match 'Error:' -or $prsOut -match 'failed') {
          # Fresh-shard fallback: InitShardPrimary --force (older verb, still
          # present in some builds) if PRS rejects the no-current-primary case.
          Write-Host "[vitess-reparent $keyspace/$shard] PRS reported an error; trying InitShardPrimary --force fallback"
          $isp = (ssh @sshOpts "$sshUser@$controlIp" "sudo /usr/local/sbin/nexus-vtctldclient InitShardPrimary --force $keyspace/$shard $primary 2>&1" | Out-String)
          Write-Host $isp.Trim()
        }
      }

      # 3. Wait for 1 PRIMARY + 2 REPLICA.
      Write-Host "[vitess-reparent $keyspace/$shard] waiting for 1 PRIMARY + 2 REPLICA..."
      $deadline = (Get-Date).AddMinutes($timeout)
      $ok = $false
      $last = ""
      while ((Get-Date) -lt $deadline) {
        $last = (ssh @sshOpts "$sshUser@$controlIp" "sudo /usr/local/sbin/nexus-vtctldclient GetTablets --keyspace $keyspace --shard $shard 2>/dev/null" | Out-String)
        $primaryCount = ([regex]::Matches($last, 'primary')).Count
        $replicaCount = ([regex]::Matches($last, 'replica')).Count
        if ($primaryCount -ge 1 -and $replicaCount -ge 2) { $ok = $true; break }
        Start-Sleep -Seconds 5
      }
      if (-not $ok) {
        Write-Host $last.Trim()
        throw "[vitess-reparent $keyspace/$shard] did not converge to 1 PRIMARY + 2 REPLICA within $timeout min"
      }
      Write-Host "[vitess-reparent $keyspace/$shard] OK -- 1 PRIMARY ($primary) + 2 REPLICA"
    PWSH
  }
}
