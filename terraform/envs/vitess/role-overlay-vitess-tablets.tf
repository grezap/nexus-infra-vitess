/*
 * role-overlay-vitess-tablets.tf -- Phase 0.O
 *
 * Brings up the 6 tablet nodes (2 shards x 3). Per tablet, an on-node bash
 * script (secrets never transit the build host) reads the 5 KV password files
 * rendered by the TLS overlay and writes:
 *   - /etc/nexus-vitess/init_db.sql  -- the Vitess user set with KV passwords
 *   - /etc/nexus-vitess/ssl.cnf      -- mysqld wire TLS (EXTRA_MY_CNF)
 *   - /etc/nexus-vitess/mysqlctld.env -- VTDATAROOT + mysqlctld flags
 *   - /etc/nexus-vitess/vttablet.env  -- tablet alias / keyspace / shard / topo
 *                                        / full gRPC mTLS / db creds + db TLS
 * then starts nexus-mysqlctld (mysqld up) + nexus-vttablet (registers the
 * tablet in the cell topo, initially NOT_SERVING until the reparent overlay
 * elects a PRIMARY).
 *
 * Dependency order (Vitess-correct, by depends_on -- not file name):
 *   etcd-bootstrap (topo) -> vtctld + AddCellInfo (cell `nexus` must exist
 *   before a tablet can register) -> THIS -> reparent -> vtgate/vtorc -> schema.
 *
 * Tablet alias = <cell>-<uid> (e.g. nexus-100). mysqlctld lays the datadir at
 * $VTDATAROOT/vt_<010d uid>/ with mysql.sock there; vttablet dials its mysqld
 * over that socket with TLS (--db_ssl_* + --db_flags=2048).
 *
 * Selective ops: var.enable_vitess_tablets. Pre-req: vitess_tls + etcd +
 * vtctld(cell).
 */

locals {
  # vttablet/mysqlctld common topo + TLS flag fragments (rendered into the env
  # files on-node). etcd_endpoints + cell + keyspace come from main.tf locals.
  vitess_tablet_specs = {
    for host, s in local.tablet_nodes : host => {
      vmnet11    = s.vmnet11
      vmnet10    = s.vmnet10
      shard      = s.shard
      tablet_uid = s.tablet_uid
      uid_padded = format("%010d", s.tablet_uid)
    }
  }
}

resource "null_resource" "vitess_tablet" {
  for_each = var.enable_vitess_tablets ? local.vitess_tablet_specs : {}

  triggers = {
    tls_id     = null_resource.vitess_tls[each.key].id
    etcd_id    = length(null_resource.vitess_etcd_bootstrap) > 0 ? null_resource.vitess_etcd_bootstrap[0].id : "disabled"
    vtctld_id  = length(null_resource.vitess_vtctld) > 0 ? null_resource.vitess_vtctld[0].id : "disabled"
    shard      = each.value.shard
    tablet_uid = each.value.tablet_uid
    tablet_v   = "4" # v4 (0.O fix T12) = mysqlctld gets --db-dba-user/-password so it can health-check mysqld across restarts (else vt_dba-no-password retry loop -> spurious mysqld instability). v3 = drop --db-host; v2 = super_read_only + mysql_native_password.

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.vitess_node_user
  }

  depends_on = [
    null_resource.vitess_tls,
    null_resource.vitess_etcd_bootstrap,
    null_resource.vitess_vtctld,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName   = '${each.key}'
      $ip         = '${each.value.vmnet11}'
      $vmnet10    = '${each.value.vmnet10}'
      $shard      = '${each.value.shard}'
      $uid        = ${each.value.tablet_uid}
      $uidPadded  = '${each.value.uid_padded}'
      $cell       = '${var.vitess_cell}'
      $keyspace   = '${var.vitess_keyspace}'
      $etcd       = '${local.etcd_endpoints}'
      $mysqlVer   = '${var.vitess_mysql_server_version}'
      $sshUser    = '${var.vitess_node_user}'
      $timeout    = ${var.vitess_cluster_timeout_minutes}
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[vitess-tablet $hostName] alias=$${cell}-$uid keyspace=$keyspace shard=$shard"

      # On-node render script: reads KV password files, writes init_db.sql +
      # ssl.cnf + the two env files, then starts mysqlctld + vttablet. All
      # secrets stay on the node.
      $stage = @'
set -euo pipefail

CFG=/etc/nexus-vitess
TLS=$CFG/tls
DATAROOT=/var/lib/nexus-vitess

for f in mysql-root mysql-app mysql-allprivs mysql-repl vtorc-topo; do
  if ! sudo test -s "$CFG/$f-password"; then
    echo "[vitess-tablet] ERROR: $CFG/$f-password missing (TLS/KV render?)" >&2
    exit 1
  fi
done
ROOT_PWD=$(sudo cat $CFG/mysql-root-password)
APP_PWD=$(sudo cat $CFG/mysql-app-password)
ALLPRIVS_PWD=$(sudo cat $CFG/mysql-allprivs-password)
REPL_PWD=$(sudo cat $CFG/mysql-repl-password)
VTORC_PWD=$(sudo cat $CFG/vtorc-topo-password)

# ── init_db.sql -- the Vitess user set, parameterised with KV passwords ──
sudo tee $CFG/init_db.sql > /dev/null <<INITSQL
# Nexus Vitess init_db.sql (Phase 0.O) -- rendered on-node, KV passwords.
SET sql_log_bin = 0;
# Vitess's generated my.cnf starts mysqld super-read-only (tablets are RO until
# promoted); disable it so the user DDL below can run (else errno 1290). (O11.)
SET GLOBAL super_read_only = 'OFF';
SET GLOBAL read_only = 'OFF';
DROP USER IF EXISTS 'root'@'%';
DELETE FROM mysql.user WHERE User = '';

# root (admin, localhost + 127.0.0.1)
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$${ROOT_PWD}';
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '$${ROOT_PWD}';
GRANT ALL ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
GRANT PROXY ON ''@'' TO 'root'@'127.0.0.1' WITH GRANT OPTION;

# vt_dba -- Vitess admin (mysqlctld + reparent + schema)
CREATE USER IF NOT EXISTS 'vt_dba'@'localhost' IDENTIFIED WITH mysql_native_password BY '$${ALLPRIVS_PWD}';
GRANT ALL ON *.* TO 'vt_dba'@'localhost' WITH GRANT OPTION;
GRANT GRANT OPTION ON *.* TO 'vt_dba'@'localhost';

# vt_app -- application query path (vttablet/vtgate)
CREATE USER IF NOT EXISTS 'vt_app'@'localhost' IDENTIFIED WITH mysql_native_password BY '$${APP_PWD}';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, REFERENCES, INDEX, ALTER, SHOW DATABASES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, EVENT, TRIGGER, REPLICATION CLIENT ON *.* TO 'vt_app'@'localhost';

# vt_appdebug -- read-only debug
CREATE USER IF NOT EXISTS 'vt_appdebug'@'localhost' IDENTIFIED WITH mysql_native_password BY '$${APP_PWD}';
GRANT SELECT, SHOW DATABASES, PROCESS ON *.* TO 'vt_appdebug'@'localhost';

# vt_allprivs -- vtorc/vreplication-adjacent admin
CREATE USER IF NOT EXISTS 'vt_allprivs'@'localhost' IDENTIFIED WITH mysql_native_password BY '$${ALLPRIVS_PWD}';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, RELOAD, PROCESS, REFERENCES, INDEX, ALTER, SHOW DATABASES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, REPLICATION SLAVE, REPLICATION CLIENT, CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, CREATE USER, EVENT, TRIGGER ON *.* TO 'vt_allprivs'@'localhost';

# vt_repl -- intra-shard replication (connects from peer tablets over TCP)
CREATE USER IF NOT EXISTS 'vt_repl'@'%' IDENTIFIED WITH mysql_native_password BY '$${REPL_PWD}';
GRANT REPLICATION SLAVE ON *.* TO 'vt_repl'@'%';

# vt_filtered -- vreplication/filtered replication
CREATE USER IF NOT EXISTS 'vt_filtered'@'localhost' IDENTIFIED WITH mysql_native_password BY '$${ALLPRIVS_PWD}';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, RELOAD, PROCESS, REFERENCES, INDEX, ALTER, SHOW DATABASES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, REPLICATION SLAVE, REPLICATION CLIENT, CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, CREATE USER, EVENT, TRIGGER ON *.* TO 'vt_filtered'@'localhost';

# vt_orc -- VTOrc topology probe + reparent SQL
CREATE USER IF NOT EXISTS 'vt_orc'@'%' IDENTIFIED WITH mysql_native_password BY '$${VTORC_PWD}';
GRANT SUPER, PROCESS, REPLICATION SLAVE, REPLICATION CLIENT, RELOAD, SELECT ON *.* TO 'vt_orc'@'%';

FLUSH PRIVILEGES;
RESET BINARY LOGS AND GTIDS;
INITSQL
sudo chown root:vitess $CFG/init_db.sql
sudo chmod 0640 $CFG/init_db.sql

# ── ssl.cnf -- mysqld wire TLS (added via EXTRA_MY_CNF) ──
sudo tee $CFG/ssl.cnf > /dev/null <<SSLCNF
[mysqld]
ssl-ca=$TLS/ca.pem
ssl-cert=$TLS/server-cert.pem
ssl-key=$TLS/server-key.pem
# Re-enable mysql_native_password (8.4 disables it by default) so the vt_* users
# (created IDENTIFIED WITH mysql_native_password) work -- avoids caching_sha2
# RSA failures on the vt_repl '%' TCP replication path. (O11.)
mysql_native_password=ON
SSLCNF
sudo chown root:vitess $CFG/ssl.cnf
sudo chmod 0640 $CFG/ssl.cnf

# ── mysqlctld.env ──
sudo tee $CFG/mysqlctld.env > /dev/null <<MYSQLCTLDENV
VTDATAROOT=$DATAROOT
EXTRA_MY_CNF=$CFG/ssl.cnf
MYSQLCTLD_FLAGS=--alsologtostderr --tablet-uid=__UID__ --mysql-port=3306 --db-charset=utf8mb4 --init-db-sql-file=$CFG/init_db.sql --socket-file=$DATAROOT/mysqlctl.sock --db-dba-user vt_dba --db-dba-password $${ALLPRIVS_PWD}
MYSQLCTLDENV
sudo chown root:vitess $CFG/mysqlctld.env
sudo chmod 0640 $CFG/mysqlctld.env

# ── vttablet.env -- alias / keyspace / shard / topo mTLS / gRPC mTLS / db creds + db TLS ──
sudo tee $CFG/vttablet.env > /dev/null <<VTTABLETENV
VTDATAROOT=$DATAROOT
VTTABLET_FLAGS=--alsologtostderr \
  --tablet-path __CELL__-__UID__ \
  --init-keyspace __KEYSPACE__ \
  --init-shard __SHARD__ \
  --init-tablet-type replica \
  --tablet-hostname __VMNET10__ \
  --topo-implementation etcd2 \
  --topo-global-server-address __ETCD__ \
  --topo-global-root /vitess/global \
  --topo-etcd-tls-ca $TLS/ca.pem \
  --topo-etcd-tls-cert $TLS/server-cert.pem \
  --topo-etcd-tls-key $TLS/server-key.pem \
  --port 15101 \
  --grpc-port 16101 \
  --service-map grpc-queryservice,grpc-tabletmanager,grpc-updatestream \
  --db-socket $DATAROOT/vt___UIDPAD__/mysql.sock \
  --db-app-user vt_app --db-app-password $${APP_PWD} \
  --db-dba-user vt_dba --db-dba-password $${ALLPRIVS_PWD} \
  --db-allprivs-user vt_allprivs --db-allprivs-password $${ALLPRIVS_PWD} \
  --db-repl-user vt_repl --db-repl-password $${REPL_PWD} \
  --db-filtered-user vt_filtered --db-filtered-password $${ALLPRIVS_PWD} \
  --db-ssl-ca $TLS/ca.pem --db-ssl-cert $TLS/server-cert.pem --db-ssl-key $TLS/server-key.pem \
  --grpc-cert $TLS/server-cert.pem --grpc-key $TLS/server-key.pem --grpc-ca $TLS/ca.pem \
  --tablet-manager-grpc-ca $TLS/ca.pem --tablet-manager-grpc-cert $TLS/server-cert.pem --tablet-manager-grpc-key $TLS/server-key.pem \
  --restore-from-backup=false
VTTABLETENV
sudo chown root:vitess $CFG/vttablet.env
sudo chmod 0640 $CFG/vttablet.env

# Substitute placeholders (avoids heredoc dollar-collision with KV passwords).
sudo sed -i "s|__UID__|__UIDVAL__|g; s|__CELL__|__CELLVAL__|g; s|__KEYSPACE__|__KSVAL__|g; s|__SHARD__|__SHARDVAL__|g; s|__VMNET10__|__VMNET10VAL__|g; s|__ETCD__|__ETCDVAL__|g; s|__UIDPAD__|__UIDPADVAL__|g" $CFG/mysqlctld.env $CFG/vttablet.env

sudo mkdir -p $DATAROOT
sudo chown vitess:vitess $DATAROOT

sudo systemctl daemon-reload
sudo systemctl enable nexus-mysqlctld.service nexus-vttablet.service
sudo systemctl restart nexus-mysqlctld.service
echo MYSQLCTLD_STARTED
'@

      # Inject per-host values (placeholders avoid shell here-doc interpolation
      # clobbering the KV passwords, which also contain no $; placeholders keep
      # the secrets out of the PS layer entirely).
      $stage = $stage.Replace('__UIDVAL__', "$uid").Replace('__CELLVAL__', $cell).Replace('__KSVAL__', $keyspace).Replace('__SHARDVAL__', $shard).Replace('__VMNET10VAL__', $vmnet10).Replace('__ETCDVAL__', $etcd).Replace('__UIDPADVAL__', $uidPadded)

      $stageLf  = $stage -replace "`r`n", "`n"
      $stageOut = $stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'MYSQLCTLD_STARTED') {
        Write-Host $stageOut.Trim()
        throw "[vitess-tablet $hostName] render + mysqlctld start failed (rc=$LASTEXITCODE)"
      }

      # Wait for mysqld to accept connections (via mysqlctld-managed socket).
      Write-Host "[vitess-tablet $hostName] waiting for mysqld (mysqlctld) to come up..."
      $deadline = (Get-Date).AddMinutes($timeout)
      $mysqlUp = $false
      while ((Get-Date) -lt $deadline) {
        # "mysqld is alive" (pre-init_db, root passwordless) OR "Access denied"
        # (post-init_db, root has a password) BOTH mean the server is up +
        # responding -- only connection-refused means it's still down. (O12.)
        $probe = (ssh @sshOpts "$sshUser@$ip" "sudo mysqladmin --socket=/var/lib/nexus-vitess/vt_$uidPadded/mysql.sock ping 2>&1" 2>&1 | Out-String)
        if ($probe -match 'mysqld is alive' -or $probe -match 'Access denied') { $mysqlUp = $true; break }
        Start-Sleep -Seconds 5
      }
      if (-not $mysqlUp) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-mysqlctld.service --no-pager -n 40" 2>&1 | Out-String)
        Write-Host $journal
        throw "[vitess-tablet $hostName] mysqld did not come up within $timeout min"
      }
      Write-Host "[vitess-tablet $hostName] mysqld up; starting vttablet"

      # Start vttablet -> it registers the tablet record in the cell topo.
      $startOut = (ssh @sshOpts "$sshUser@$ip" "sudo systemctl restart nexus-vttablet.service && echo VTTABLET_STARTED" 2>&1 | Out-String)
      if ($startOut -notmatch 'VTTABLET_STARTED') {
        Write-Host $startOut.Trim()
        throw "[vitess-tablet $hostName] vttablet start failed"
      }

      # Wait for the vttablet process to be active + its status port to answer.
      Write-Host "[vitess-tablet $hostName] waiting for vttablet active + :15101 status..."
      $deadline = (Get-Date).AddMinutes($timeout)
      $tabletUp = $false
      while ((Get-Date) -lt $deadline) {
        $st = (ssh @sshOpts "$sshUser@$ip" "systemctl is-active nexus-vttablet.service 2>/dev/null; curl -fsS http://127.0.0.1:15101/debug/vars 2>/dev/null | head -c 1" 2>&1 | Out-String)
        if ($st -match '(?m)^active' -and $st -match '\{') { $tabletUp = $true; break }
        Start-Sleep -Seconds 5
      }
      if (-not $tabletUp) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-vttablet.service --no-pager -n 40" 2>&1 | Out-String)
        Write-Host $journal
        throw "[vitess-tablet $hostName] vttablet did not become active within $timeout min"
      }
      Write-Host "[vitess-tablet $hostName] vttablet active + status port answering (alias $${cell}-$uid registered in topo)"
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
      Write-Host "[vitess-tablet destroy] $${hostName}: stopping vttablet + mysqlctld, wiping datadir + env files"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now nexus-vttablet.service nexus-mysqlctld.service 2>/dev/null; sudo rm -f /etc/nexus-vitess/vttablet.env /etc/nexus-vitess/mysqlctld.env /etc/nexus-vitess/init_db.sql /etc/nexus-vitess/ssl.cnf; sudo rm -rf /var/lib/nexus-vitess/vt_* /var/lib/nexus-vitess/mysqlctl.sock" 2>$null
      exit 0
    PWSH
  }
}
