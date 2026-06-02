# nexus-infra-vitess / terraform / envs / vitess / main.tf
#
# Phase 0.O -- Vitess-sharded MySQL cluster (ADR-0041). 12 VMs:
#   3 etcd topo (vitess-etcd-1/2/3)            -> .190/.191/.192  (vitess-etcd-node)
#   1 control vtctld+VTOrc (vitess-control-1)  -> .193            (vitess-gate-node)
#   2 vtgate routers (vitess-vtgate-1/2)       -> .194/.195       (vitess-gate-node)
#   2x3 tablets vttablet+Percona 8.4           -> .196-.201       (vitess-tablet-node)
#     shard -80: vitess-shard1-tablet-1/2/3    -> .196/.197/.198
#     shard 80-: vitess-shard2-tablet-1/2/3    -> .199/.200/.201
#
# Keyspace `commerce`, 2 shards, hash vindex. Full Vault-PKI mTLS on every gRPC
# channel + the mysqld wire + the vtgate MySQL listener. etcd is the global+local
# (cell `nexus`) topo server. Per-cluster state + per-engine templates per
# feedback_per_cluster_state_per_engine_template.md.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── etcd topo nodes ──────────────────────────────────────────────────────
module "vitess_etcd_1" {
  source            = "../../modules/vm"
  count             = var.enable_vitess_etcd_1 ? 1 : 0
  vm_name           = "vitess-etcd-1"
  template_vmx_path = "${var.template_root}/vitess-etcd-node/vitess-etcd-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/07-vitess/vitess-etcd-1"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_vitess_etcd_1_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_vitess_etcd_1_secondary
}
module "vitess_etcd_2" {
  source            = "../../modules/vm"
  count             = var.enable_vitess_etcd_2 ? 1 : 0
  vm_name           = "vitess-etcd-2"
  template_vmx_path = "${var.template_root}/vitess-etcd-node/vitess-etcd-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/07-vitess/vitess-etcd-2"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_vitess_etcd_2_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_vitess_etcd_2_secondary
}
module "vitess_etcd_3" {
  source            = "../../modules/vm"
  count             = var.enable_vitess_etcd_3 ? 1 : 0
  vm_name           = "vitess-etcd-3"
  template_vmx_path = "${var.template_root}/vitess-etcd-node/vitess-etcd-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/07-vitess/vitess-etcd-3"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_vitess_etcd_3_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_vitess_etcd_3_secondary
}

# ─── control plane (vtctld + VTOrc) ───────────────────────────────────────
module "vitess_control_1" {
  source            = "../../modules/vm"
  count             = var.enable_vitess_control_1 ? 1 : 0
  vm_name           = "vitess-control-1"
  template_vmx_path = "${var.template_root}/vitess-gate-node/vitess-gate-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/07-vitess/vitess-control-1"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_vitess_control_1_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_vitess_control_1_secondary
}

# ─── vtgate routers ───────────────────────────────────────────────────────
module "vitess_vtgate_1" {
  source            = "../../modules/vm"
  count             = var.enable_vitess_vtgate_1 ? 1 : 0
  vm_name           = "vitess-vtgate-1"
  template_vmx_path = "${var.template_root}/vitess-gate-node/vitess-gate-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/07-vitess/vitess-vtgate-1"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_vitess_vtgate_1_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_vitess_vtgate_1_secondary
}
module "vitess_vtgate_2" {
  source            = "../../modules/vm"
  count             = var.enable_vitess_vtgate_2 ? 1 : 0
  vm_name           = "vitess-vtgate-2"
  template_vmx_path = "${var.template_root}/vitess-gate-node/vitess-gate-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/07-vitess/vitess-vtgate-2"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_vitess_vtgate_2_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_vitess_vtgate_2_secondary
}

# ─── shard-1 (-80) tablets ────────────────────────────────────────────────
module "vitess_shard1_tablet_1" {
  source            = "../../modules/vm"
  count             = var.enable_vitess_shard1_tablet_1 ? 1 : 0
  vm_name           = "vitess-shard1-tablet-1"
  template_vmx_path = "${var.template_root}/vitess-tablet-node/vitess-tablet-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/07-vitess/vitess-shard1-tablet-1"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_vitess_shard1_tablet_1_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_vitess_shard1_tablet_1_secondary
}
module "vitess_shard1_tablet_2" {
  source            = "../../modules/vm"
  count             = var.enable_vitess_shard1_tablet_2 ? 1 : 0
  vm_name           = "vitess-shard1-tablet-2"
  template_vmx_path = "${var.template_root}/vitess-tablet-node/vitess-tablet-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/07-vitess/vitess-shard1-tablet-2"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_vitess_shard1_tablet_2_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_vitess_shard1_tablet_2_secondary
}
module "vitess_shard1_tablet_3" {
  source            = "../../modules/vm"
  count             = var.enable_vitess_shard1_tablet_3 ? 1 : 0
  vm_name           = "vitess-shard1-tablet-3"
  template_vmx_path = "${var.template_root}/vitess-tablet-node/vitess-tablet-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/07-vitess/vitess-shard1-tablet-3"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_vitess_shard1_tablet_3_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_vitess_shard1_tablet_3_secondary
}

# ─── shard-2 (80-) tablets ────────────────────────────────────────────────
module "vitess_shard2_tablet_1" {
  source            = "../../modules/vm"
  count             = var.enable_vitess_shard2_tablet_1 ? 1 : 0
  vm_name           = "vitess-shard2-tablet-1"
  template_vmx_path = "${var.template_root}/vitess-tablet-node/vitess-tablet-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/07-vitess/vitess-shard2-tablet-1"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_vitess_shard2_tablet_1_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_vitess_shard2_tablet_1_secondary
}
module "vitess_shard2_tablet_2" {
  source            = "../../modules/vm"
  count             = var.enable_vitess_shard2_tablet_2 ? 1 : 0
  vm_name           = "vitess-shard2-tablet-2"
  template_vmx_path = "${var.template_root}/vitess-tablet-node/vitess-tablet-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/07-vitess/vitess-shard2-tablet-2"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_vitess_shard2_tablet_2_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_vitess_shard2_tablet_2_secondary
}
module "vitess_shard2_tablet_3" {
  source            = "../../modules/vm"
  count             = var.enable_vitess_shard2_tablet_3 ? 1 : 0
  vm_name           = "vitess-shard2-tablet-3"
  template_vmx_path = "${var.template_root}/vitess-tablet-node/vitess-tablet-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/07-vitess/vitess-shard2-tablet-3"
  vmrun_path        = var.vmrun_path
  vnet              = var.vnet_primary
  mac_address       = var.mac_vitess_shard2_tablet_3_primary
  vnet_secondary    = var.vnet_secondary
  mac_secondary     = var.mac_vitess_shard2_tablet_3_secondary
}

# ─── Cluster topology metadata (used by overlays) ─────────────────────────
locals {
  cell = "nexus"

  # All 12 nodes: hostname -> {role, vmnet11, vmnet10, shard, tablet_uid}.
  # role: "etcd" | "control" | "vtgate" | "tablet"
  # shard: "-80" | "80-" | "" (non-tablet)
  # tablet_uid: globally-unique uint for the tablet alias (cell-uid). 0 for non-tablets.
  vitess_nodes = {
    "vitess-etcd-1"          = { role = "etcd", vmnet11 = "192.168.70.190", vmnet10 = "192.168.10.190", shard = "", tablet_uid = 0 }
    "vitess-etcd-2"          = { role = "etcd", vmnet11 = "192.168.70.191", vmnet10 = "192.168.10.191", shard = "", tablet_uid = 0 }
    "vitess-etcd-3"          = { role = "etcd", vmnet11 = "192.168.70.192", vmnet10 = "192.168.10.192", shard = "", tablet_uid = 0 }
    "vitess-control-1"       = { role = "control", vmnet11 = "192.168.70.193", vmnet10 = "192.168.10.193", shard = "", tablet_uid = 0 }
    "vitess-vtgate-1"        = { role = "vtgate", vmnet11 = "192.168.70.194", vmnet10 = "192.168.10.194", shard = "", tablet_uid = 0 }
    "vitess-vtgate-2"        = { role = "vtgate", vmnet11 = "192.168.70.195", vmnet10 = "192.168.10.195", shard = "", tablet_uid = 0 }
    "vitess-shard1-tablet-1" = { role = "tablet", vmnet11 = "192.168.70.196", vmnet10 = "192.168.10.196", shard = "-80", tablet_uid = 100 }
    "vitess-shard1-tablet-2" = { role = "tablet", vmnet11 = "192.168.70.197", vmnet10 = "192.168.10.197", shard = "-80", tablet_uid = 101 }
    "vitess-shard1-tablet-3" = { role = "tablet", vmnet11 = "192.168.70.198", vmnet10 = "192.168.10.198", shard = "-80", tablet_uid = 102 }
    "vitess-shard2-tablet-1" = { role = "tablet", vmnet11 = "192.168.70.199", vmnet10 = "192.168.10.199", shard = "80-", tablet_uid = 200 }
    "vitess-shard2-tablet-2" = { role = "tablet", vmnet11 = "192.168.70.200", vmnet10 = "192.168.10.200", shard = "80-", tablet_uid = 201 }
    "vitess-shard2-tablet-3" = { role = "tablet", vmnet11 = "192.168.70.201", vmnet10 = "192.168.10.201", shard = "80-", tablet_uid = 202 }
  }

  # Per-host enabled gate (mirrors the 12 module.* count gates).
  vitess_host_enabled = {
    "vitess-etcd-1"          = var.enable_vitess_etcd_1
    "vitess-etcd-2"          = var.enable_vitess_etcd_2
    "vitess-etcd-3"          = var.enable_vitess_etcd_3
    "vitess-control-1"       = var.enable_vitess_control_1
    "vitess-vtgate-1"        = var.enable_vitess_vtgate_1
    "vitess-vtgate-2"        = var.enable_vitess_vtgate_2
    "vitess-shard1-tablet-1" = var.enable_vitess_shard1_tablet_1
    "vitess-shard1-tablet-2" = var.enable_vitess_shard1_tablet_2
    "vitess-shard1-tablet-3" = var.enable_vitess_shard1_tablet_3
    "vitess-shard2-tablet-1" = var.enable_vitess_shard2_tablet_1
    "vitess-shard2-tablet-2" = var.enable_vitess_shard2_tablet_2
    "vitess-shard2-tablet-3" = var.enable_vitess_shard2_tablet_3
  }

  vitess_nodes_active = {
    for host, spec in local.vitess_nodes : host => spec
    if local.vitess_host_enabled[host]
  }

  # Filtered views per role/shard for the overlays.
  etcd_nodes     = { for h, s in local.vitess_nodes_active : h => s if s.role == "etcd" }
  control_nodes  = { for h, s in local.vitess_nodes_active : h => s if s.role == "control" }
  vtgate_nodes   = { for h, s in local.vitess_nodes_active : h => s if s.role == "vtgate" }
  tablet_nodes   = { for h, s in local.vitess_nodes_active : h => s if s.role == "tablet" }
  shard1_tablets = { for h, s in local.vitess_nodes_active : h => s if s.shard == "-80" }
  shard2_tablets = { for h, s in local.vitess_nodes_active : h => s if s.shard == "80-" }

  # etcd client endpoints (VMnet10 backplane, mTLS https) for --topo_global_server_address.
  etcd_endpoints = join(",", [for h, s in local.etcd_nodes : "https://${s.vmnet10}:2379"])

  # The two shards keyed by range, with their tablet IP lists.
  shards = {
    "-80" = { tablets = local.shard1_tablets }
    "80-" = { tablets = local.shard2_tablets }
  }
}
