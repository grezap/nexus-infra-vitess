# Phase 0.O per-host nftables. Vitess intra-cluster traffic (etcd raft/client,
# vttablet/vtgate/vtctld/vtorc gRPC, mysqld replication) all rides the VMnet10
# backplane (trusted whole-segment). On VMnet11 (nic0) only SSH + node_exporter
# are open everywhere; the vtgate nodes additionally expose the client MySQL
# port 15306 (the round-robin `vtgate.nexus.lab` front door). Component web
# status ports (vtctld 15000, vttablet 15101, vtgate 15001) are reachable from
# VMnet11 too for operator/Prometheus scraping.

locals {
  # Per-role extra VMnet11 dports (beyond 22 + 9100 which every node opens).
  vitess_nftables_extra_ports = {
    etcd    = []             # etcd 2379/2380 ride VMnet10 only
    control = [15000, 16000] # vtctld web + vtorc web (operator/scrape)
    vtgate  = [15306, 15001] # MySQL client front door + vtgate web
    tablet  = [15101]        # vttablet web (operator/scrape); 16101 gRPC + 3306 ride VMnet10
  }

  vitess_nftables = {
    for host, spec in local.vitess_nodes_active : host => <<-NFT
      #!/usr/sbin/nft -f
      # Managed by nexus-infra-vitess/terraform/envs/vitess/role-overlay-vitess-nftables-backplane.tf
      # role=${spec.role} shard=${spec.shard}
      flush ruleset

      table inet filter {
        chain input {
          type filter hook input priority filter; policy drop;
          ct state established,related accept
          ct state invalid drop
          iif "lo" accept
          meta l4proto icmp accept
          meta l4proto ipv6-icmp accept

          iifname "nic0" tcp dport 22 accept
          iifname "nic0" tcp dport 9100 accept
%{for p in local.vitess_nftables_extra_ports[spec.role]~}
          iifname "nic0" tcp dport ${p} accept
%{endfor~}

          iifname "nic1" ip saddr 192.168.10.0/24 accept
          counter drop
        }
        chain forward { type filter hook forward priority filter; policy drop; }
        chain output  { type filter hook output  priority filter; policy accept; }
      }
    NFT
  }
}

resource "null_resource" "vitess_nftables" {
  for_each = var.enable_nftables_backplane ? local.vitess_nodes_active : {}

  triggers = {
    vmnet11     = each.value.vmnet11
    role        = each.value.role
    ruleset_sha = sha256(local.vitess_nftables[each.key])
    overlay_v   = "1"

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.vitess_node_user
  }

  depends_on = [
    module.vitess_etcd_1, module.vitess_etcd_2, module.vitess_etcd_3,
    module.vitess_control_1, module.vitess_vtgate_1, module.vitess_vtgate_2,
    module.vitess_shard1_tablet_1, module.vitess_shard1_tablet_2, module.vitess_shard1_tablet_3,
    module.vitess_shard2_tablet_1, module.vitess_shard2_tablet_2, module.vitess_shard2_tablet_3,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $user     = '${var.vitess_node_user}'
      $timeout  = ${var.vitess_cluster_timeout_minutes}
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $ruleset = @'
${local.vitess_nftables[each.key]}
'@
      $ruleset = $ruleset -replace "`r`n","`n"

      Write-Host "[nftables $hostName] waiting for SSH + firstboot marker..."
      $deadline = (Get-Date).AddMinutes($timeout)
      $ready = $false
      while ((Get-Date) -lt $deadline) {
        $probe = (ssh @sshOpts "$user@$ip" "test -f /var/lib/vitess-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
        if ($probe -match 'READY') { $ready = $true; break }
        Start-Sleep -Seconds 15
      }
      if (-not $ready) { throw "[nftables $hostName] SSH + firstboot marker never ready after $timeout min" }

      Write-Host "[nftables $hostName] pushing ruleset (role=${each.value.role}) + nft -f"
      $remote = "tr -d '\r' | sudo tee /etc/nftables.conf > /dev/null && sudo nft -f /etc/nftables.conf && sudo systemctl enable nftables --now && echo NFT_OK"
      $out = ($ruleset | ssh @sshOpts "$user@$ip" $remote 2>&1 | Out-String)
      if ($out -notmatch 'NFT_OK') { throw "[nftables $hostName] ruleset push failed -- $out" }
      Write-Host "[nftables $hostName] applied"
    PWSH
  }
}
