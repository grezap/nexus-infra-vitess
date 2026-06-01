/*
 * vitess-gate-node -- Packer template variables (Phase 0.O)
 * Serves the vtgate routers (.194/.195) + the vtctld/VTOrc control node (.193).
 */

variable "vm_name" {
  type        = string
  default     = "vitess-gate-node"
  description = "VM display name and output .vmx basename."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/vitess-gate-node"
  description = "Absolute directory for the built template (.vmx + disks)."
}

variable "iso_url" {
  type    = string
  default = "https://cdimage.debian.org/debian-cd/13.5.0/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a"
}

variable "vitess_version" {
  type        = string
  default     = "24.0.1"
  description = "Vitess release version (prebuilt tarball vitess-<version>-<build>.tar.gz). v24.0.1 GA (ADR-0041)."
}

variable "vitess_build" {
  type        = string
  default     = "61daa0a"
  description = "The git-SHA suffix in the Vitess release tarball name (vitess-24.0.1-61daa0a.tar.gz). Bump with var.vitess_version."
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory_mb" {
  type        = number
  default     = 1024
  description = "Build-time RAM (MB). Default 1 GB (vtgate/vtctld/vtorc are stateless + light, no mysqld); steady-state 2 GB per vms.yaml at clone time."
}

variable "disk_gb" {
  type        = number
  default     = 20
  description = "Disk size in GB. Default 20 GB; gate/control nodes hold no data (state lives in etcd topo)."
}

variable "ssh_username" {
  type    = string
  default = "nexusadmin"
}

variable "ssh_password" {
  type      = string
  default   = "nexus-packer-build-only"
  sensitive = true
}

variable "boot_wait" {
  type    = string
  default = "15s"
}

variable "ssh_timeout" {
  type    = string
  default = "30m"
}
