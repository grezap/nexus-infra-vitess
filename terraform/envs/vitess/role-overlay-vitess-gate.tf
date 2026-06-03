/*
 * role-overlay-vitess-gate.tf -- Phase 0.O -- the Vitess control + serving plane.
 *
 * THREE resources with deliberately different positions in the dependency graph
 * (Vitess bring-up is not linear by file -- terraform orders by depends_on):
 *
 *   null_resource.vitess_vtctld  (EARLY, after etcd) -- control node:
 *       renders vtctld.env, installs /usr/local/sbin/nexus-vtctldclient (the
 *       mTLS-preloaded wrapper every later overlay calls), starts nexus-vtctld,
 *       AddCellInfo `nexus`. MUST precede tablets (a tablet cannot register
 *       until the cell exists).
 *
 *   null_resource.vitess_vtgate  (LATE, after reparent) -- the 2 routers:
 *       renders vtgate.env + the MySQL-listener static-auth file, starts
 *       nexus-vtgate. :15306 = client MySQL front door (TLS); :15001 = web.
 *
 *   null_resource.vitess_vtorc   (LATE, after reparent) -- control node:
 *       renders vtorc.env, starts nexus-vtorc. Watches keyspace `commerce` +
 *       auto-reparents a shard when its PRIMARY dies (the HA demo).
 *
 * mTLS everywhere: every component carries --grpc_cert/-key/-ca (server side)
 * + the *_grpc client cert flags (no --*_server_name => Go verifies against the
 * dial-target IP, which every per-host cert covers via its vmnet10/vmnet11 IP
 * SANs -- the robust pattern for per-host certs). etcd topo via --topo_etcd_tls_*.
 *
 * Selective ops: var.enable_vitess_gate (master). vtctld also gated implicitly
 * (tablets depend on it); vtgate/vtorc gated by var.enable_vitess_gate.
 */

locals {
  vitess_control_vmnet10 = length(local.control_nodes) > 0 ? one([for h, s in local.control_nodes : s.vmnet10]) : ""
  vitess_control_host    = length(local.control_nodes) > 0 ? one(keys(local.control_nodes)) : ""
}

# ─── vtctld + cell (EARLY) ───────────────────────────────────────────────────
resource "null_resource" "vitess_vtctld" {
  count = (var.enable_vitess_gate && local.vitess_control_ip != "") ? 1 : 0

  triggers = {
    etcd_id  = length(null_resource.vitess_etcd_bootstrap) > 0 ? null_resource.vitess_etcd_bootstrap[0].id : "disabled"
    tls_id   = local.vitess_control_host != "" ? null_resource.vitess_tls[local.vitess_control_host].id : "none"
    vtctld_v = "2" # v2 (0.O fix O10) = + tablet-manager-grpc client certs so vtctld can mTLS-dial tablets for reparent. (v1 = base vtctld + cell + wrapper.)

    destroy_vm_ip    = local.vitess_control_ip
    destroy_ssh_user = var.vitess_node_user
  }

  depends_on = [
    null_resource.vitess_etcd_bootstrap,
    null_resource.vitess_tls,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip        = '${local.vitess_control_ip}'
      $vmnet10   = '${local.vitess_control_vmnet10}'
      $cell      = '${var.vitess_cell}'
      $etcd      = '${local.etcd_endpoints}'
      $sshUser   = '${var.vitess_node_user}'
      $timeout   = ${var.vitess_cluster_timeout_minutes}
      $sshOpts   = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[vitess-vtctld] bring-up on control $ip (cell=$cell, topo=$etcd)"

      $stage = @'
set -euo pipefail
CFG=/etc/nexus-vitess
TLS=$CFG/tls
ETCD="__ETCD__"
VMNET10="__VMNET10__"

# vtctld.env
sudo tee $CFG/vtctld.env > /dev/null <<VTCTLDENV
VTCTLD_FLAGS=--alsologtostderr \
  --topo-implementation etcd2 \
  --topo-global-server-address $ETCD \
  --topo-global-root /vitess/global \
  --topo-etcd-tls-ca $TLS/ca.pem \
  --topo-etcd-tls-cert $TLS/server-cert.pem \
  --topo-etcd-tls-key $TLS/server-key.pem \
  --port 15000 \
  --grpc-port 15999 \
  --service-map grpc-vtctl,grpc-vtctld \
  --grpc-cert $TLS/server-cert.pem --grpc-key $TLS/server-key.pem --grpc-ca $TLS/ca.pem \
  --tablet-manager-grpc-ca $TLS/ca.pem --tablet-manager-grpc-cert $TLS/server-cert.pem --tablet-manager-grpc-key $TLS/server-key.pem
VTCTLDENV
sudo chown root:vitess $CFG/vtctld.env
sudo chmod 0640 $CFG/vtctld.env

# nexus-vtctldclient wrapper -- mTLS-preloaded; dials vtctld on the backplane.
# No --server_name: verify against the IP (in the cert IP-SANs).
sudo tee /usr/local/sbin/nexus-vtctldclient > /dev/null <<'WRAP'
#!/bin/bash
exec /usr/local/bin/vtctldclient \
  --server VMNET10PLACEHOLDER:15999 \
  --vtctld-grpc-ca /etc/nexus-vitess/tls/ca.pem \
  --vtctld-grpc-cert /etc/nexus-vitess/tls/server-cert.pem \
  --vtctld-grpc-key /etc/nexus-vitess/tls/server-key.pem \
  --vtctld-grpc-server-name vitess-control-1.vitess.nexus.lab \
  "$@"
WRAP
sudo sed -i "s|VMNET10PLACEHOLDER|$VMNET10|g" /usr/local/sbin/nexus-vtctldclient
sudo chown root:root /usr/local/sbin/nexus-vtctldclient
sudo chmod 0755 /usr/local/sbin/nexus-vtctldclient

sudo systemctl daemon-reload
sudo systemctl enable nexus-vtctld.service
sudo systemctl restart nexus-vtctld.service
echo VTCTLD_STARTED
'@
      $stage = $stage.Replace('__ETCD__', $etcd).Replace('__VMNET10__', $vmnet10)
      $stageLf = $stage -replace "`r`n","`n"
      $out = ($stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String)
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'VTCTLD_STARTED') {
        Write-Host $out.Trim()
        throw "[vitess-vtctld] vtctld render/start failed (rc=$LASTEXITCODE)"
      }

      # Wait for vtctld gRPC (via the wrapper -- GetCellInfoNames answers once up).
      Write-Host "[vitess-vtctld] waiting for vtctld gRPC..."
      $deadline = (Get-Date).AddMinutes($timeout)
      $up = $false
      while ((Get-Date) -lt $deadline) {
        $probe = (ssh @sshOpts "$sshUser@$ip" "sudo /usr/local/sbin/nexus-vtctldclient GetCellInfoNames 2>&1" | Out-String)
        if ($LASTEXITCODE -eq 0 -and $probe -notmatch 'rpc error' -and $probe -notmatch 'connection refused') { $up = $true; break }
        Start-Sleep -Seconds 5
      }
      if (-not $up) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-vtctld.service --no-pager -n 40" 2>&1 | Out-String)
        Write-Host $journal
        throw "[vitess-vtctld] vtctld gRPC never answered within $timeout min"
      }
      Write-Host "[vitess-vtctld] vtctld up"

      # AddCellInfo nexus (idempotent -- catch already-exists).
      Write-Host "[vitess-vtctld] AddCellInfo $cell (root /vitess/$cell)"
      $cellOut = (ssh @sshOpts "$sshUser@$ip" "sudo /usr/local/sbin/nexus-vtctldclient AddCellInfo --root /vitess/$cell --server-address '$etcd' $cell 2>&1" | Out-String)
      if ($cellOut -match 'already exists' -or $cellOut -match 'node already exists') {
        Write-Host "[vitess-vtctld] cell $cell already exists (idempotent)"
      } elseif ($cellOut -match 'rpc error' -or $cellOut -match 'Error:') {
        Write-Host $cellOut.Trim()
        throw "[vitess-vtctld] AddCellInfo failed"
      } else {
        Write-Host "[vitess-vtctld] cell $cell created"
      }
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $vmIp    = '${self.triggers.destroy_vm_ip}'
      $sshUser = '${self.triggers.destroy_ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[vitess-vtctld destroy] stopping vtctld + removing wrapper/env"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now nexus-vtctld.service 2>/dev/null; sudo rm -f /etc/nexus-vitess/vtctld.env /usr/local/sbin/nexus-vtctldclient" 2>$null
      exit 0
    PWSH
  }
}

# ─── vtgate routers (LATE -- after reparent) ─────────────────────────────────
resource "null_resource" "vitess_vtgate" {
  for_each = var.enable_vitess_gate ? local.vtgate_nodes : {}

  triggers = {
    reparent_ids = jsonencode([for k in keys(null_resource.vitess_reparent) : null_resource.vitess_reparent[k].id])
    tls_id       = null_resource.vitess_tls[each.key].id
    vtgate_v     = "1" # v1 (0.O) = vtgate MySQL :15306 (TLS) + static-auth, tablet gRPC mTLS.

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.vitess_node_user
  }

  depends_on = [
    null_resource.vitess_reparent,
    null_resource.vitess_tls,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $vmnet10  = '${each.value.vmnet10}'
      $cell     = '${var.vitess_cell}'
      $etcd     = '${local.etcd_endpoints}'
      $mysqlVer = '${var.vitess_mysql_server_version}'
      $sshUser  = '${var.vitess_node_user}'
      $timeout  = ${var.vitess_cluster_timeout_minutes}
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[vitess-vtgate $hostName] bring-up on $ip (cell=$cell)"

      $stage = @'
set -euo pipefail
CFG=/etc/nexus-vitess
TLS=$CFG/tls
ETCD="__ETCD__"
CELL="__CELL__"
MYSQLVER="__MYSQLVER__"

if ! sudo test -s $CFG/mysql-app-password; then
  echo "[vitess-vtgate] ERROR: $CFG/mysql-app-password missing" >&2; exit 1
fi
APP_PWD=$(sudo cat $CFG/mysql-app-password)

# MySQL-listener static-auth file: client user `nexus` / app password.
sudo tee $CFG/vtgate_creds.json > /dev/null <<CREDS
{
  "nexus": [
    {
      "Password": "$${APP_PWD}",
      "UserData": "nexus"
    }
  ]
}
CREDS
sudo chown root:vitess $CFG/vtgate_creds.json
sudo chmod 0640 $CFG/vtgate_creds.json

sudo tee $CFG/vtgate.env > /dev/null <<VTGATEENV
VTGATE_FLAGS=--alsologtostderr \
  --cell $CELL \
  --cells-to-watch $CELL \
  --topo-implementation etcd2 \
  --topo-global-server-address $ETCD \
  --topo-global-root /vitess/global \
  --topo-etcd-tls-ca $TLS/ca.pem \
  --topo-etcd-tls-cert $TLS/server-cert.pem \
  --topo-etcd-tls-key $TLS/server-key.pem \
  --port 15001 \
  --grpc-port 15991 \
  --mysql-server-port 15306 \
  --mysql-server-bind-address 0.0.0.0 \
  --mysql-server-version $MYSQLVER \
  --mysql-auth-server-impl static \
  --mysql-auth-server-static-file $CFG/vtgate_creds.json \
  --mysql-server-ssl-cert $TLS/server-cert.pem \
  --mysql-server-ssl-key $TLS/server-key.pem \
  --mysql-server-ssl-ca $TLS/ca.pem \
  --service-map grpc-vtgateservice \
  --grpc-cert $TLS/server-cert.pem --grpc-key $TLS/server-key.pem --grpc-ca $TLS/ca.pem \
  --tablet-grpc-ca $TLS/ca.pem --tablet-grpc-cert $TLS/server-cert.pem --tablet-grpc-key $TLS/server-key.pem \
  --tablet-types-to-wait PRIMARY,REPLICA
VTGATEENV
sudo chown root:vitess $CFG/vtgate.env
sudo chmod 0640 $CFG/vtgate.env

sudo systemctl daemon-reload
sudo systemctl enable nexus-vtgate.service
sudo systemctl restart nexus-vtgate.service
echo VTGATE_STARTED
'@
      $stage = $stage.Replace('__ETCD__', $etcd).Replace('__CELL__', $cell).Replace('__MYSQLVER__', $mysqlVer)
      $stageLf = $stage -replace "`r`n","`n"
      $out = ($stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String)
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'VTGATE_STARTED') {
        Write-Host $out.Trim()
        throw "[vitess-vtgate $hostName] vtgate render/start failed (rc=$LASTEXITCODE)"
      }

      Write-Host "[vitess-vtgate $hostName] waiting for vtgate :15306 + :15001..."
      $deadline = (Get-Date).AddMinutes($timeout)
      $up = $false
      while ((Get-Date) -lt $deadline) {
        $probe = (ssh @sshOpts "$sshUser@$ip" "systemctl is-active nexus-vtgate.service 2>/dev/null; (echo > /dev/tcp/127.0.0.1/15306) 2>/dev/null && echo MYSQLPORT; curl -fsS http://127.0.0.1:15001/debug/vars 2>/dev/null | head -c 1" 2>&1 | Out-String)
        if ($probe -match '(?m)^active' -and $probe -match 'MYSQLPORT' -and $probe -match '\{') { $up = $true; break }
        Start-Sleep -Seconds 5
      }
      if (-not $up) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-vtgate.service --no-pager -n 40" 2>&1 | Out-String)
        Write-Host $journal
        throw "[vitess-vtgate $hostName] vtgate did not come up within $timeout min"
      }
      Write-Host "[vitess-vtgate $hostName] vtgate up (:15306 MySQL listener + :15001 web)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[vitess-vtgate destroy] $${hostName}: stopping vtgate + removing env/creds"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now nexus-vtgate.service 2>/dev/null; sudo rm -f /etc/nexus-vitess/vtgate.env /etc/nexus-vitess/vtgate_creds.json" 2>$null
      exit 0
    PWSH
  }
}

# ─── VTOrc (LATE -- after reparent) ──────────────────────────────────────────
resource "null_resource" "vitess_vtorc" {
  count = (var.enable_vitess_gate && local.vitess_control_ip != "") ? 1 : 0

  triggers = {
    reparent_ids = jsonencode([for k in keys(null_resource.vitess_reparent) : null_resource.vitess_reparent[k].id])
    vtctld_id    = length(null_resource.vitess_vtctld) > 0 ? null_resource.vitess_vtctld[0].id : "disabled"
    vtorc_v      = "1" # v1 (0.O) = VTOrc watch keyspace commerce, tablet-manager gRPC mTLS.

    destroy_vm_ip    = local.vitess_control_ip
    destroy_ssh_user = var.vitess_node_user
  }

  depends_on = [
    null_resource.vitess_reparent,
    null_resource.vitess_vtctld,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip       = '${local.vitess_control_ip}'
      $keyspace = '${var.vitess_keyspace}'
      $etcd     = '${local.etcd_endpoints}'
      $sshUser  = '${var.vitess_node_user}'
      $timeout  = ${var.vitess_cluster_timeout_minutes}
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[vitess-vtorc] bring-up on control $ip (watch keyspace=$keyspace)"

      $stage = @'
set -euo pipefail
CFG=/etc/nexus-vitess
TLS=$CFG/tls
ETCD="__ETCD__"
KEYSPACE="__KEYSPACE__"

sudo tee $CFG/vtorc.env > /dev/null <<VTORCENV
VTORC_FLAGS=--alsologtostderr \
  --topo-implementation etcd2 \
  --topo-global-server-address $ETCD \
  --topo-global-root /vitess/global \
  --topo-etcd-tls-ca $TLS/ca.pem \
  --topo-etcd-tls-cert $TLS/server-cert.pem \
  --topo-etcd-tls-key $TLS/server-key.pem \
  --port 16000 \
  --clusters-to-watch $KEYSPACE \
  --tablet-manager-grpc-ca $TLS/ca.pem --tablet-manager-grpc-cert $TLS/server-cert.pem --tablet-manager-grpc-key $TLS/server-key.pem
VTORCENV
sudo chown root:vitess $CFG/vtorc.env
sudo chmod 0640 $CFG/vtorc.env

sudo systemctl daemon-reload
sudo systemctl enable nexus-vtorc.service
sudo systemctl restart nexus-vtorc.service
echo VTORC_STARTED
'@
      $stage = $stage.Replace('__ETCD__', $etcd).Replace('__KEYSPACE__', $keyspace)
      $stageLf = $stage -replace "`r`n","`n"
      $out = ($stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String)
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'VTORC_STARTED') {
        Write-Host $out.Trim()
        throw "[vitess-vtorc] vtorc render/start failed (rc=$LASTEXITCODE)"
      }

      Write-Host "[vitess-vtorc] waiting for vtorc active + :16000..."
      $deadline = (Get-Date).AddMinutes($timeout)
      $up = $false
      while ((Get-Date) -lt $deadline) {
        $probe = (ssh @sshOpts "$sshUser@$ip" "systemctl is-active nexus-vtorc.service 2>/dev/null; curl -fsS http://127.0.0.1:16000/debug/health 2>/dev/null | head -c 3" 2>&1 | Out-String)
        if ($probe -match '(?m)^active') { $up = $true; break }
        Start-Sleep -Seconds 5
      }
      if (-not $up) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-vtorc.service --no-pager -n 40" 2>&1 | Out-String)
        Write-Host $journal
        throw "[vitess-vtorc] vtorc did not become active within $timeout min"
      }
      Write-Host "[vitess-vtorc] vtorc active (watching $keyspace)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $vmIp    = '${self.triggers.destroy_vm_ip}'
      $sshUser = '${self.triggers.destroy_ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[vitess-vtorc destroy] stopping vtorc + removing env"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now nexus-vtorc.service 2>/dev/null; sudo rm -f /etc/nexus-vitess/vtorc.env" 2>$null
      exit 0
    PWSH
  }
}
