# nexus-infra-vitess / terraform / envs / vitess / variables.tf

variable "template_root" {
  type    = string
  default = "H:\\VMS\\NexusPlatform\\_templates"
}

variable "vm_output_dir_root" {
  type    = string
  default = "H:\\VMS\\NexusPlatform"
}

variable "vmrun_path" {
  type    = string
  default = "C:/Program Files/VMware/VMware Workstation/vmrun.exe"
}

variable "vnet_primary" {
  type    = string
  default = "VMnet11"
}

variable "vnet_secondary" {
  type    = string
  default = "VMnet10"
}

# ─── Per-VM toggles ───────────────────────────────────────────────────────
variable "enable_vitess_etcd_1" {
  type    = bool
  default = true
}
variable "enable_vitess_etcd_2" {
  type    = bool
  default = true
}
variable "enable_vitess_etcd_3" {
  type    = bool
  default = true
}
variable "enable_vitess_control_1" {
  type    = bool
  default = true
}
variable "enable_vitess_vtgate_1" {
  type    = bool
  default = true
}
variable "enable_vitess_vtgate_2" {
  type    = bool
  default = true
}
variable "enable_vitess_shard1_tablet_1" {
  type    = bool
  default = true
}
variable "enable_vitess_shard1_tablet_2" {
  type    = bool
  default = true
}
variable "enable_vitess_shard1_tablet_3" {
  type    = bool
  default = true
}
variable "enable_vitess_shard2_tablet_1" {
  type    = bool
  default = true
}
variable "enable_vitess_shard2_tablet_2" {
  type    = bool
  default = true
}
variable "enable_vitess_shard2_tablet_3" {
  type    = bool
  default = true
}

# ─── Per-VM primary MACs (VMnet11) -- MUST match foundation mac_vitess_*_primary ─
variable "mac_vitess_etcd_1_primary" {
  type    = string
  default = "00:50:56:3F:00:CB"
}
variable "mac_vitess_etcd_2_primary" {
  type    = string
  default = "00:50:56:3F:00:CC"
}
variable "mac_vitess_etcd_3_primary" {
  type    = string
  default = "00:50:56:3F:00:CD"
}
variable "mac_vitess_control_1_primary" {
  type    = string
  default = "00:50:56:3F:00:CE"
}
variable "mac_vitess_vtgate_1_primary" {
  type    = string
  default = "00:50:56:3F:00:CF"
}
variable "mac_vitess_vtgate_2_primary" {
  type    = string
  default = "00:50:56:3F:00:D0"
}
variable "mac_vitess_shard1_tablet_1_primary" {
  type    = string
  default = "00:50:56:3F:00:D1"
}
variable "mac_vitess_shard1_tablet_2_primary" {
  type    = string
  default = "00:50:56:3F:00:D2"
}
variable "mac_vitess_shard1_tablet_3_primary" {
  type    = string
  default = "00:50:56:3F:00:D3"
}
variable "mac_vitess_shard2_tablet_1_primary" {
  type    = string
  default = "00:50:56:3F:00:D4"
}
variable "mac_vitess_shard2_tablet_2_primary" {
  type    = string
  default = "00:50:56:3F:00:D5"
}
variable "mac_vitess_shard2_tablet_3_primary" {
  type    = string
  default = "00:50:56:3F:00:D6"
}

# ─── Per-VM secondary MACs (VMnet10 backplane) :01:CB-:D6 ─────────────────
variable "mac_vitess_etcd_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:CB"
}
variable "mac_vitess_etcd_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:CC"
}
variable "mac_vitess_etcd_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:CD"
}
variable "mac_vitess_control_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:CE"
}
variable "mac_vitess_vtgate_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:CF"
}
variable "mac_vitess_vtgate_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:D0"
}
variable "mac_vitess_shard1_tablet_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:D1"
}
variable "mac_vitess_shard1_tablet_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:D2"
}
variable "mac_vitess_shard1_tablet_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:D3"
}
variable "mac_vitess_shard2_tablet_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:D4"
}
variable "mac_vitess_shard2_tablet_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:D5"
}
variable "mac_vitess_shard2_tablet_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:D6"
}

# ─── Per-overlay toggles (bring-up graph) ────────────────────────────────
variable "enable_nftables_backplane" {
  type    = bool
  default = true
}
variable "enable_vitess_vault_agents" {
  type    = bool
  default = true
}
variable "enable_vitess_tls" {
  type    = bool
  default = true
}
variable "enable_etcd_bootstrap" {
  type    = bool
  default = true
}
variable "enable_vitess_tablets" {
  type    = bool
  default = true
}
variable "enable_vitess_reparent" {
  type    = bool
  default = true
}
variable "enable_vitess_gate" {
  type    = bool
  default = true
}
variable "enable_vitess_schema" {
  type    = bool
  default = true
}

# ─── Cluster / Vitess identity ───────────────────────────────────────────
variable "vitess_cell" {
  type    = string
  default = "nexus"
}
variable "vitess_keyspace" {
  type    = string
  default = "commerce"
}
variable "vitess_mysql_server_version" {
  type        = string
  default     = "8.4.0-Percona-Server"
  description = "Version string vtgate/vttablet advertise (--mysql_server_version). Percona Server 8.4 LTS per ADR-0041."
}

# ─── Operator / cross-env vars ───────────────────────────────────────────
variable "vitess_node_user" {
  type    = string
  default = "nexusadmin"
}
variable "vault_agent_version" {
  type        = string
  default     = "1.18.5"
  description = "Vault Agent binary version installed on each Vitess-tier node (matches every prior tier)."
}
variable "vitess_cluster_timeout_minutes" {
  type    = number
  default = 20
}
variable "vault_addr" {
  type    = string
  default = "https://192.168.70.121:8200"
}
variable "vault_ca_bundle_path" {
  type    = string
  default = "~/.nexus/vault-ca-bundle.crt"
}
variable "vault_init_keys_path" {
  type    = string
  default = "~/.nexus/vault-init.json"
}
variable "vault_pki_vitess_role_name" {
  type    = string
  default = "vitess-server"
}
variable "vault_agent_vitess_creds_dir" {
  type    = string
  default = "~/.nexus"
}
