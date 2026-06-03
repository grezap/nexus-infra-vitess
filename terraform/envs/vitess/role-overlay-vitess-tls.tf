/*
 * role-overlay-vitess-tls.tf -- Phase 0.O -- per-host PKI leaf + KV cred renders
 * for all 12 Vitess-tier nodes. Descendant of role-overlay-patroni-tls.tf.
 *
 * Drops Vault Agent template files on each host. Every node uses the same
 * config_dir (/etc/nexus-vitess) + owner_group (vitess), so the structure is
 * simpler than patroni's 3-role split -- only the KV secret set differs by role.
 *
 * 70-template-vitess-tls.hcl issues a per-host leaf from pki_int/issue/
 * vitess-server:
 *   - CN:   <host>.vitess.nexus.lab
 *   - DNS:  <host>, <host>.nexus.lab, <host>.vitess.nexus.lab, localhost
 *           (+ vtgate.nexus.lab on the 2 vtgate nodes -- the RR-DNS client
 *            front door, so a client TLS handshake against either vtgate
 *            validates regardless of which the round-robin picks)
 *   - IP:   <vmnet10>, <vmnet11>, 127.0.0.1
 * The split script writes 3 files: server-cert.pem, server-key.pem (PKCS#8),
 * ca.pem (intermediate + root). These feed every Vitess gRPC channel
 * (--grpc_cert/-key/-ca + the *_grpc client cert flags), the etcd topo client
 * (--topo_etcd_tls_*), the mysqld wire (EXTRA_MY_CNF ssl-ca/cert/key), and the
 * vtgate MySQL listener (--mysql_server_ssl_*).
 *
 * KV secret set per role (KV-v2 read path nexus/data/vitess/<name>-password ->
 * .Data.data.content; CLI write path nexus/vitess/<name>-password):
 *   tablet (6):  mysql-root, mysql-app, mysql-allprivs, mysql-repl, vtorc-topo
 *   control(1):  vtorc-topo, mysql-app
 *   vtgate (2):  mysql-app
 *   etcd   (3):  none (PKI only)
 *
 * Reachability invariant: this overlay does not touch the network.
 * Selective ops: var.enable_vitess_tls AND var.enable_vitess_vault_agents.
 */

locals {
  # Per-role TLS destination. etcd nodes use /etc/nexus-etcd (its config dir +
  # nexus-etcdctl wrapper + nexus-etcd.service all reference /etc/nexus-etcd/tls,
  # and etcd runs as user `etcd`); every other role uses /etc/nexus-vitess (group
  # vitess; mysqld/vttablet/vtgate/vtctld/vtorc run as vitess). (0.O fix O8.)
  vitess_tls_dirs = {
    etcd    = { config_dir = "/etc/nexus-etcd", owner_group = "etcd" }
    control = { config_dir = "/etc/nexus-vitess", owner_group = "vitess" }
    vtgate  = { config_dir = "/etc/nexus-vitess", owner_group = "vitess" }
    tablet  = { config_dir = "/etc/nexus-vitess", owner_group = "vitess" }
  }
  vitess_tls_config_dir  = "/etc/nexus-vitess"
  vitess_tls_owner_group = "vitess"

  # KV creds each role's Vault Agent renders. Names map to nexus/vitess/<name>.
  vitess_tls_kv_by_role = {
    tablet  = ["mysql-root", "mysql-app", "mysql-allprivs", "mysql-repl", "vtorc-topo"]
    control = ["vtorc-topo", "mysql-app"]
    vtgate  = ["mysql-app"]
    etcd    = []
  }

  vitess_tls_active = {
    for host, spec in local.vitess_nodes_active : host => spec
    if(
      var.enable_vitess_tls && var.enable_vitess_vault_agents
      && lookup(local.vitess_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "vitess_tls" {
  for_each = local.vitess_tls_active

  triggers = {
    va_id         = null_resource.vitess_vault_agent[each.key].id
    pki_role_name = var.vault_pki_vitess_role_name
    vmnet10       = each.value.vmnet10
    vmnet11       = each.value.vmnet11
    role          = each.value.role
    config_dir    = local.vitess_tls_dirs[each.value.role].config_dir
    owner_group   = local.vitess_tls_dirs[each.value.role].owner_group
    kv_set        = join(",", local.vitess_tls_kv_by_role[each.value.role])
    vitess_tls_v  = "2" # v2 (0.O fix O8) = role-aware dirs: etcd -> /etc/nexus-etcd/tls (group etcd); others -> /etc/nexus-vitess/tls (group vitess).

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.vitess_node_user
  }

  depends_on = [null_resource.vitess_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName   = '${each.key}'
      $ip         = '${each.value.vmnet11}'
      $vmnet10    = '${each.value.vmnet10}'
      $role       = '${each.value.role}'
      $configDir  = '${local.vitess_tls_dirs[each.value.role].config_dir}'
      $ownerGroup = '${local.vitess_tls_dirs[each.value.role].owner_group}'
      $pkiRole    = '${var.vault_pki_vitess_role_name}'
      $sshUser    = '${var.vitess_node_user}'
      $cn         = "$hostName.vitess.nexus.lab"
      # vtgate nodes additionally cover vtgate.nexus.lab (the RR-DNS front door).
      $altNames   = if ($role -eq 'vtgate') { "$hostName,$hostName.nexus.lab,$hostName.vitess.nexus.lab,vtgate.nexus.lab,localhost" } else { "$hostName,$hostName.nexus.lab,$hostName.vitess.nexus.lab,localhost" }
      $ipSans     = "$vmnet10,$ip,127.0.0.1"
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[vitess-tls $hostName] cert render + KV cred renders via Vault Agent templates (role=$role, ipSans=$ipSans)"

      # ─── Split script (single-quoted literal) ────────────────────────────
      $splitScript = @'
#!/bin/bash
set -euo pipefail
DEST="$${1:?usage: nexus-vitess-tls-split.sh <dest-dir> <owner-group>}"
OWNER_GROUP="$${2:?usage: nexus-vitess-tls-split.sh <dest-dir> <owner-group>}"
BUNDLE="$DEST/bundle.pem"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

awk -v tmp="$TMP" '
  /-----BEGIN/ { n++; file=tmp"/block-"n }
  { if (n>0) print > file }
' "$BUNDLE"

LEAF=""
KEY=""
CA=""
for f in "$TMP"/block-*; do
  hdr=$(head -1 "$f")
  case "$hdr" in
    *"PRIVATE KEY"*)
      KEY=$f
      ;;
    *"BEGIN CERTIFICATE"*)
      if [ -z "$LEAF" ]; then LEAF=$f; else CA=$f; fi
      ;;
  esac
done

if [ -z "$LEAF" ] || [ -z "$KEY" ] || [ -z "$CA" ]; then
  echo "[vitess-tls-split] ERROR: bundle missing one of leaf/key/ca" >&2
  ls -la "$TMP" >&2
  exit 1
fi

openssl pkcs8 -topk8 -nocrypt -in "$KEY" -out "$TMP/key-pkcs8.pem"

cat "$LEAF" > "$TMP/server-cert.pem"
cat "$TMP/key-pkcs8.pem" > "$TMP/server-key.pem"

ROOT_BUNDLE=/etc/vault-agent/ca-bundle.crt
if [ ! -s "$ROOT_BUNDLE" ]; then
  echo "[vitess-tls-split] ERROR: $ROOT_BUNDLE missing -- Vault Agent must be installed first" >&2
  exit 1
fi
cat "$CA" "$ROOT_BUNDLE" > "$TMP/ca.pem"

install -m 0640 -o root -g "$OWNER_GROUP" "$TMP/server-cert.pem" "$DEST/server-cert.pem"
install -m 0640 -o root -g "$OWNER_GROUP" "$TMP/server-key.pem"  "$DEST/server-key.pem"
install -m 0640 -o root -g "$OWNER_GROUP" "$TMP/ca.pem"          "$DEST/ca.pem"

install -m 0644 -o root -g root "$TMP/ca.pem" /etc/ssl/certs/vitess-ca.pem

echo "[vitess-tls-split] $(date -u +%FT%TZ) bundle split into $DEST (owner=$OWNER_GROUP)"
'@

      $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($splitScript -replace "`r`n","`n")))

      # ─── 70-template-vitess-tls.hcl ─── per-host PKI leaf ─────────────────
      $vaultTlsTemplate = @"
# 70-template-vitess-tls.hcl -- Phase 0.O (rendered for $hostName, role=$role).

template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT

  destination     = "$configDir/tls/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "$ownerGroup"
  command         = "/usr/local/sbin/nexus-vitess-tls-split.sh $configDir/tls $ownerGroup"
  command_timeout = "30s"
}
"@
      $vaTlsB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultTlsTemplate -replace "`r`n","`n")))

      # ─── KV template builder ─────────────────────────────────────────────
      function New-KvTemplate {
        param([string]$Path, [string]$Dest, [string]$OwnerGroup)
        @"
template {
  contents = <<EOT
{{- with secret `"$Path`" }}{{ .Data.data.content }}{{- end }}
EOT

  destination = "$Dest"
  perms       = "0400"
  user        = "root"
  group       = "$OwnerGroup"
}
"@
      }

      # KV secret set per role. File index starts at 71.
      $kvNames = switch ($role) {
        'tablet'  { @('mysql-root','mysql-app','mysql-allprivs','mysql-repl','vtorc-topo') }
        'control' { @('vtorc-topo','mysql-app') }
        'vtgate'  { @('mysql-app') }
        default   { @() }
      }
      $kvTemplates = @()
      $idx = 71
      foreach ($name in $kvNames) {
        $dest = "$configDir/$name-password"
        $file = "$idx-template-$name.hcl"
        $body = (New-KvTemplate "nexus/data/vitess/$name-password" $dest $ownerGroup)
        $kvTemplates += @{ File = $file; Body = $body; Dest = $dest }
        $idx++
      }

      $kvDropLines = @()
      $kvWaitLines = @()
      $kvErrLines  = @()
      foreach ($t in $kvTemplates) {
        $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($t.Body -replace "`r`n","`n")))
        $kvDropLines += "echo '$b64' | base64 -d | sudo tee /etc/vault-agent/$($t.File) > /dev/null"
        $kvDropLines += "sudo chown root:root /etc/vault-agent/$($t.File)"
        $kvDropLines += "sudo chmod 0644 /etc/vault-agent/$($t.File)"
        # Single space join (NOT bash line-continuation) -- PS `\\ renders TWO
        # backslashes which bash reads as literal "\". Lesson from 0.G.4 #5.
        $kvWaitLines += "&& sudo test -s $($t.Dest)"
        $kvErrLines  += "if ! sudo test -s $($t.Dest); then echo '[vitess-tls stage] ERROR: $($t.Dest) not rendered within 20s' >&2; sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2; exit 1; fi"
      }
      $kvDropBody = ($kvDropLines -join "`n")
      $kvWaitBody = ($kvWaitLines -join " ")
      $kvErrBody  = ($kvErrLines  -join "`n")

      $stage = @"
set -euo pipefail

# vitess user/group is created at template bake; defensive create here too.
if ! getent group vitess >/dev/null; then sudo groupadd --system vitess; fi
if ! getent passwd vitess >/dev/null; then sudo useradd --system --gid vitess --no-create-home --shell /usr/sbin/nologin vitess; fi

sudo mkdir -p $configDir/tls
sudo chown root:$ownerGroup $configDir $configDir/tls
sudo chmod 0750 $configDir $configDir/tls

echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/nexus-vitess-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/nexus-vitess-tls-split.sh
sudo chmod 0755 /usr/local/sbin/nexus-vitess-tls-split.sh

echo '$vaTlsB64' | base64 -d | sudo tee /etc/vault-agent/70-template-vitess-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/70-template-vitess-tls.hcl
sudo chmod 0644 /etc/vault-agent/70-template-vitess-tls.hcl

$kvDropBody

sudo systemctl restart nexus-vault-agent.service

# Wait for the cert render target (+ any KV targets), then invoke split.
for i in 1 2 3 4 5 6 7 8 9 10; do
  if sudo test -s $configDir/tls/bundle.pem $kvWaitBody; then break; fi
  sleep 2
done
if ! sudo test -s $configDir/tls/bundle.pem; then
  echo "[vitess-tls stage] ERROR: bundle.pem not rendered within 20s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
$kvErrBody
sudo /usr/local/sbin/nexus-vitess-tls-split.sh $configDir/tls $ownerGroup
echo STAGE_OK
"@
      $stageLf  = $stage -replace "`r`n", "`n"
      $stageOut = $stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') {
        Write-Host $stageOut.Trim()
        throw "[vitess-tls $hostName] cert + KV creds render stage failed (rc=$LASTEXITCODE)"
      }

      # Verify 3 split TLS files + KV secrets + CN.
      $kvCheckArgs = if ($kvTemplates.Count -gt 0) { (($kvTemplates | ForEach-Object { "sudo test -s $($_.Dest)" }) -join " && ") + " && " } else { "" }
      $verifyDeadline = (Get-Date).AddSeconds(60)
      $rendered = $false
      while ((Get-Date) -lt $verifyDeadline) {
        $check = (ssh @sshOpts "$sshUser@$ip" "sudo test -s $configDir/tls/server-cert.pem && sudo test -s $configDir/tls/server-key.pem && sudo test -s $configDir/tls/ca.pem && $kvCheckArgs sudo openssl x509 -in $configDir/tls/server-cert.pem -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -match 'OK') { $rendered = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $rendered) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 40" 2>&1 | Out-String)
        Write-Host $journal
        throw "[vitess-tls $hostName] cert + KV secrets not rendered (CN=$cn) within 60s"
      }
      Write-Host "[vitess-tls $hostName] rendered: server-cert.pem (CN=$cn) + server-key.pem (PKCS#8) + ca.pem (intermediate+root) + $($kvTemplates.Count) KV secrets"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName  = '${each.key}'
      $vmIp      = '${self.triggers.destroy_vm_ip}'
      $configDir = '${lookup(self.triggers, "config_dir", "/etc/nexus-vitess")}'
      $sshUser   = '${self.triggers.destroy_ssh_user}'
      $sshOpts   = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[vitess-tls destroy] $${hostName}: removing 70-7x templates + cert/keys + KV secret files + restarting vault-agent"
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/70-template-vitess-tls.hcl /etc/vault-agent/7[1-9]-template-*.hcl $configDir/tls/bundle.pem $configDir/tls/server-cert.pem $configDir/tls/server-key.pem $configDir/tls/ca.pem $configDir/mysql-root-password $configDir/mysql-app-password $configDir/mysql-allprivs-password $configDir/mysql-repl-password $configDir/vtorc-topo-password /etc/ssl/certs/vitess-ca.pem; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}
