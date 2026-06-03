# nexus-infra-vitess / terraform / envs / vitess / outputs.tf

output "vitess_cluster_summary" {
  description = "Phase 0.O Vitess-sharded MySQL cluster topology + access points."
  value = {
    cell     = var.vitess_cell
    keyspace = var.vitess_keyspace
    shards   = ["-80", "80-"]
    nodes_active = {
      for h, s in local.vitess_nodes_active : h => {
        role    = s.role
        shard   = s.shard
        vmnet11 = s.vmnet11
        vmnet10 = s.vmnet10
      }
    }
    etcd_topo_endpoints = local.etcd_endpoints
    control_node        = local.vitess_control_ip
    vtgate_mysql        = [for h, s in local.vtgate_nodes : "${s.vmnet11}:15306"]
    vtgate_rr_dns       = "vtgate.nexus.lab:15306"
    web = {
      vtctld   = local.vitess_control_ip != "" ? "http://${local.vitess_control_ip}:15000" : ""
      vtorc    = local.vitess_control_ip != "" ? "http://${local.vitess_control_ip}:16000" : ""
      vtgate   = [for h, s in local.vtgate_nodes : "http://${s.vmnet11}:15001"]
      vttablet = [for h, s in local.tablet_nodes : "http://${s.vmnet11}:15101"]
    }
  }
}

output "vitess_tablet_aliases" {
  description = "Tablet alias (cell-uid) per shard."
  value = {
    for h, s in local.tablet_nodes : h => {
      alias = "${var.vitess_cell}-${s.tablet_uid}"
      shard = s.shard
    }
  }
}
