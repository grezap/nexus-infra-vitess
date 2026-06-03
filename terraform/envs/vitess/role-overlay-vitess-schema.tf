/*
 * role-overlay-vitess-schema.tf -- Phase 0.O -- the exit gate / sharding proof.
 *
 * 1. ApplySchema  -- CREATE TABLE customer(...) on keyspace `commerce` (lands
 *    on BOTH shards' mysqld via vtctld).
 * 2. ApplyVSchema -- mark `commerce` sharded + a hash vindex on customer_id.
 * 3. Seed + verify -- from a tablet node (it has the Percona mysql client),
 *    connect to a vtgate :15306 over TLS as user `nexus`, INSERT a spread of
 *    customer_id values, then count rows per shard (USE `commerce/-80` /
 *    `commerce/80-`) -- BOTH shards must be non-empty. That is the sharding
 *    proof: a single logical INSERT stream physically split across 2 shards by
 *    the hash vindex.
 *
 * ApplySchema/ApplyVSchema run on the control node via nexus-vtctldclient.
 * Seed + verify run on shard1-tablet-1 (mysql client present) against vtgate.
 *
 * Dependency order: vtgate (+ reparent) -> THIS.
 * Selective ops: var.enable_vitess_schema.
 */

locals {
  vitess_seed_tablet_host = length(local.shard1_tablets) > 0 ? one([for h, s in local.shard1_tablets : h if s.tablet_uid == min([for hh, ss in local.shard1_tablets : ss.tablet_uid]...)]) : ""
  vitess_seed_tablet_ip   = local.vitess_seed_tablet_host != "" ? local.shard1_tablets[local.vitess_seed_tablet_host].vmnet11 : ""
  vitess_vtgate_seed_ip   = length(local.vtgate_nodes) > 0 ? values(local.vtgate_nodes)[0].vmnet11 : ""
}

resource "null_resource" "vitess_schema" {
  count = (
    var.enable_vitess_schema
    && local.vitess_control_ip != ""
    && local.vitess_seed_tablet_ip != ""
    && local.vitess_vtgate_seed_ip != ""
  ) ? 1 : 0

  triggers = {
    vtgate_ids = jsonencode([for k in keys(null_resource.vitess_vtgate) : null_resource.vitess_vtgate[k].id])
    schema_v   = "1" # v1 (0.O) = customer table + hash vindex on customer_id + 100-row sharded seed.
  }

  depends_on = [null_resource.vitess_vtgate]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $controlIp = '${local.vitess_control_ip}'
      $tabletIp  = '${local.vitess_seed_tablet_ip}'
      $vtgateIp  = '${local.vitess_vtgate_seed_ip}'
      $keyspace  = '${var.vitess_keyspace}'
      $sshUser   = '${var.vitess_node_user}'
      $timeout   = ${var.vitess_cluster_timeout_minutes}
      $sshOpts   = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[vitess-schema] ApplySchema + ApplyVSchema on $keyspace (control $controlIp), seed via vtgate $vtgateIp from tablet $tabletIp"

      # ─── 1+2. ApplySchema + ApplyVSchema on the control node ──────────────
      $ddlStage = @'
set -euo pipefail
cat > /tmp/vitess-customer.sql <<'SQL'
CREATE TABLE IF NOT EXISTS customer (
  customer_id BIGINT NOT NULL,
  email VARCHAR(128),
  PRIMARY KEY (customer_id)
) ENGINE=InnoDB;
SQL
cat > /tmp/vitess-vschema.json <<'JSON'
{
  "sharded": true,
  "vindexes": { "hash": { "type": "hash" } },
  "tables": {
    "customer": {
      "column_vindexes": [ { "column": "customer_id", "name": "hash" } ]
    }
  }
}
JSON
echo "[schema] ApplySchema customer ..."
sudo /usr/local/sbin/nexus-vtctldclient ApplySchema --sql-file /tmp/vitess-customer.sql __KEYSPACE__ 2>&1 || true
echo "[schema] ApplyVSchema (hash vindex on customer_id) ..."
sudo /usr/local/sbin/nexus-vtctldclient ApplyVSchema --vschema-file /tmp/vitess-vschema.json __KEYSPACE__ 2>&1
rm -f /tmp/vitess-customer.sql /tmp/vitess-vschema.json
echo DDL_OK
'@
      $ddlStage = $ddlStage.Replace('__KEYSPACE__', $keyspace)
      $ddlOut = (($ddlStage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$controlIp" "tr -d '\r' | bash -s" 2>&1 | Out-String)
      Write-Host $ddlOut.Trim()
      if ($ddlOut -notmatch 'DDL_OK') {
        throw "[vitess-schema] ApplySchema/ApplyVSchema failed"
      }

      # Give vtgate a moment to pick up the new vschema.
      Start-Sleep -Seconds 8

      # ─── 3. Seed + per-shard verify from the tablet node (mysql client) ───
      # Connect to vtgate :15306 over TLS as user `nexus`. INSERT 100 rows with
      # spread customer_id; the hash vindex distributes them across both shards.
      $seedStage = @'
set -euo pipefail
CFG=/etc/nexus-vitess
TLS=$CFG/tls
APP_PWD=$(sudo cat $CFG/mysql-app-password)
VTGATE="__VTGATE__"
KS="__KEYSPACE__"

# vtgate's MySQL listener requires mTLS (client cert). Present the node's leaf
# cert + key (sudo: the key is 0640 root:vitess). (O13.)
MYSQL="sudo mysql --host=$VTGATE --port=15306 --user=nexus --password=$${APP_PWD} --ssl-mode=REQUIRED --ssl-cert=$TLS/server-cert.pem --ssl-key=$TLS/server-key.pem --ssl-ca=$TLS/ca.pem --batch --skip-column-names"

# Insert 100 rows (customer_id 1..100). Idempotent via INSERT IGNORE.
ROWS=$(for i in $(seq 1 100); do echo "INSERT IGNORE INTO customer(customer_id,email) VALUES($i,'user$${i}@nexus.lab');"; done)
echo "$ROWS" | $MYSQL "$KS"

# Count per shard via shard-targeted keyspace.
C1=$($MYSQL "$${KS}/-80" -e "SELECT COUNT(*) FROM customer" | tr -d '[:space:]')
C2=$($MYSQL "$${KS}/80-" -e "SELECT COUNT(*) FROM customer" | tr -d '[:space:]')
TOTAL=$($MYSQL "$KS" -e "SELECT COUNT(*) FROM customer" | tr -d '[:space:]')
echo "SHARD_80_LEFT=$C1"
echo "SHARD_80_RIGHT=$C2"
echo "TOTAL=$TOTAL"
'@
      $seedStage = $seedStage.Replace('__VTGATE__', $vtgateIp).Replace('__KEYSPACE__', $keyspace)
      $seedOut = (($seedStage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$tabletIp" "tr -d '\r' | bash -s" 2>&1 | Out-String)
      Write-Host $seedOut.Trim()

      $c1 = if ($seedOut -match '(?m)^SHARD_80_LEFT=(\d+)')  { [int]$Matches[1] } else { -1 }
      $c2 = if ($seedOut -match '(?m)^SHARD_80_RIGHT=(\d+)') { [int]$Matches[1] } else { -1 }
      $tot = if ($seedOut -match '(?m)^TOTAL=(\d+)')         { [int]$Matches[1] } else { -1 }

      if ($c1 -le 0 -or $c2 -le 0) {
        throw "[vitess-schema] sharding proof FAILED -- shard -80=$c1, shard 80-=$c2 (both must be > 0). total=$tot"
      }
      Write-Host ""
      Write-Host "[vitess-schema] SHARDING PROOF OK -- shard -80 has $c1 rows, shard 80- has $c2 rows (total $tot via vtgate); single INSERT stream split across both shards by the hash vindex."
    PWSH
  }
}
