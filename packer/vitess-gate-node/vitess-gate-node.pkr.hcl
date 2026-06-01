/*
 * vitess-gate-node -- Vitess control-plane + router node template (Phase 0.O).
 * Per-engine refactor per memory/feedback_per_cluster_state_per_engine_template.md.
 * 3 clones: vitess-vtgate-1/2 (.194/.195, run vtgate) + vitess-control-1 (.193,
 * runs vtctld + VTOrc). All three use the same Vitess v24.0.1 binaries + the
 * `vitess` system user, no mysqld -- the terraform/envs/vitess role-overlays
 * enable the right unit(s) per node by its firstboot role (vtgate vs control).
 *
 *   - OS: Debian 13 (same ISO + preseed pattern as siblings)
 *   - Default RAM: 1 GB at bake; steady-state 2 GB per vms.yaml at clone time.
 *   - Dual-NIC at clone time: ethernet0 = VMnet11 (vtgate MySQL :15306 +
 *     service); ethernet1 = VMnet10 (gRPC to tablets + etcd topo backplane).
 *
 * Build-time vs clone-time vs first-boot:
 *   - Build-time (this template): single NAT NIC. Vitess v24.0.1 binaries
 *     (vtgate, vtctld, vtorc, vtctldclient) from the upstream prebuilt tarball.
 *     The nexus-vtgate / nexus-vtctld / nexus-vtorc units are DISABLED.
 *   - Clone-time (terraform/modules/vm): writes ethernet0 + ethernet1 MAC.
 *   - First-boot (vitess-node-firstboot.service): role=vtgate for .194/.195,
 *     role=control for .193; writes /etc/nexus-vitess/node-identity.env.
 *   - Cluster bring-up (terraform/envs/vitess/role-overlay-*.tf): control node
 *     gets vtctld + VTOrc (render env + start); vtgate nodes get vtgate. vtctld
 *     is needed early (ApplySchema/InitShardPrimary); vtgate + VTOrc after the
 *     tablets register in topo.
 *
 * Build:   cd packer/vitess-gate-node; packer init .; packer build .
 * See:     docs/handbook.md
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware = {
      version = ">= 1.0.11"
      source  = "github.com/hashicorp/vmware"
    }
    ansible = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

source "vmware-iso" "vitess-gate-node" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  guest_os_type = "debian12-64"
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0

  network_adapter_type = "vmxnet3"
  network              = "nat"

  version = "20"

  http_directory = "http"
  boot_wait      = var.boot_wait
  boot_command = [
    "<esc><wait>",
    "auto ",
    "url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
    "language=en country=US locale=en_US.UTF-8 keymap=us ",
    "hostname=${var.vm_name} domain=nexus.local ",
    "priority=critical ",
    "interface=auto ",
    "<enter>"
  ]

  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = var.ssh_timeout
  ssh_handshake_attempts = 200

  shutdown_command = "echo '${var.ssh_password}' | sudo -S -E shutdown -P now"
  shutdown_timeout = "5m"

  headless        = true
  skip_compaction = false

  vmx_remove_ethernet_interfaces = true

  vmx_data = {
    "annotation"           = "vitess-gate-node template (Phase 0.O) -- built by Packer; Vitess ${var.vitess_version} vtgate + vtctld + vtorc (no mysqld)"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "vitess-gate-node"
  sources = ["source.vmware-iso.vitess-gate-node"]

  provisioner "file" {
    source      = "files/nftables.conf"
    destination = "/tmp/nftables.conf"
  }
  provisioner "file" {
    source      = "files/chrony.conf"
    destination = "/tmp/chrony.conf"
  }

  provisioner "shell" {
    inline = [
      "echo 'Waiting for systemd to settle...'",
      "sudo systemctl is-system-running --wait || true",
      "echo 'Installing Ansible + prerequisites...'",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible curl ca-certificates gnupg openssl jq unzip"
    ]
  }

  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths = [
      "../_shared/ansible/roles/nexus_identity",
      "../_shared/ansible/roles/nexus_network",
      "../_shared/ansible/roles/nexus_firewall",
      "../_shared/ansible/roles/nexus_observability",
      "../_shared/ansible/roles/vitess_firstboot",
      "ansible/roles/vitess_gate",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "vitess_gate_vitess_version=${var.vitess_version}",
      "--extra-vars", "vitess_gate_vitess_build=${var.vitess_build}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- vitess-gate-node post-install checks ---'",
      "test -x /usr/local/bin/vtgate",
      "test -x /usr/local/bin/vtctld",
      "test -x /usr/local/bin/vtorc",
      "test -x /usr/local/bin/vtctldclient",
      "/usr/local/bin/vtgate --version",
      "systemctl cat nexus-vtgate.service > /dev/null",
      "systemctl cat nexus-vtctld.service > /dev/null",
      "systemctl cat nexus-vtorc.service > /dev/null",
      "systemctl cat vitess-node-firstboot.service > /dev/null",
      "systemctl is-enabled vitess-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "id vitess",
      "echo '--- cleanup ---'",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -f /var/lib/systemd/random-seed",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "history -c || true",
      "sudo rm -f /home/${var.ssh_username}/.bash_history || true"
    ]
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
