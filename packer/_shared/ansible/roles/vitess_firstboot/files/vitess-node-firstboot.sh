#!/bin/bash
# vitess-node-firstboot.sh -- runs once at first boot per vitess-node clone.
#
# Linear descendant of the OLTP tier's oltp-node-firstboot.sh, scoped to the
# Phase 0.O Vitess tier (07-vitess). Same NIC discrimination by MAC OUI byte 5
# (0x00 primary VMnet11, 0x01 secondary VMnet10), same /etc/hosts pattern, same
# hostname renaming, same VMnet10 backplane .link MAC-match.
#
# The IP-to-role map covers all 12 Vitess-tier nodes (ADR-0041):
#   etcd     .190/.191/.192          (topo server)
#   control  .193                    (vtctld + VTOrc)
#   vtgate   .194/.195               (query routers)
#   tablet   .196/.197/.198 (shard -80) + .199/.200/.201 (shard 80-)
# A clone landing on an unmapped IP fails fast with a clear error.
#
# Like the OLTP firstboot: this script does NOT enable any Vitess/etcd/mysqld
# service. The Terraform role-overlays render per-host config (which needs
# Terraform-time per-host data -- topo addresses, shard/alias, cert SANs) and
# bring up exactly the right component per node.
#
# Idempotent: marker at /var/lib/vitess-node-firstboot-done short-circuits
# re-runs. Removing the marker forces re-run on next boot.

set -euo pipefail

MARKER=/var/lib/vitess-node-firstboot-done
LOG_PREFIX="[vitess-node-firstboot]"
# IDENTITY_DIR is /etc/nexus-vitess for every role (group vitess). Initialised
# empty; set after the IP->role map (step 4).
IDENTITY_DIR=""
IDENTITY_FILE=""

if [ -f "$MARKER" ]; then
  echo "$LOG_PREFIX already done, skipping (remove $MARKER to force re-run)"
  exit 0
fi

# --- 1. Discover both NICs by MAC OUI pattern ------------------------------
PRIMARY_IF=""
PRIMARY_MAC=""
SECONDARY_IF=""
SECONDARY_MAC=""
for ifdir in /sys/class/net/*; do
  ifname=$(basename "$ifdir")
  [ "$ifname" = "lo" ] && continue
  [ -e "$ifdir/device" ] || continue
  ifmac=$(cat "$ifdir/address" 2>/dev/null || true)
  case "$ifmac" in
    00:50:56:*:00:*) PRIMARY_IF=$ifname; PRIMARY_MAC=$ifmac ;;
    00:50:56:*:01:*) SECONDARY_IF=$ifname; SECONDARY_MAC=$ifmac ;;
  esac
done

if [ -z "$PRIMARY_IF" ]; then
  echo "$LOG_PREFIX ERROR: no primary NIC (MAC pattern 00:50:56:*:00:*) found" >&2
  ip -br link >&2
  exit 1
fi
echo "$LOG_PREFIX detected primary NIC: $PRIMARY_IF (MAC $PRIMARY_MAC)"
if [ -n "$SECONDARY_IF" ]; then
  echo "$LOG_PREFIX detected secondary NIC: $SECONDARY_IF (MAC $SECONDARY_MAC)"
else
  echo "$LOG_PREFIX ERROR: no secondary NIC (MAC pattern 00:50:56:*:01:*) found -- vitess tier requires the VMnet10 backplane" >&2
  ip -br link >&2
  exit 1
fi

# --- 2. Ensure nic0 == primary, nic1 == secondary --------------------------
NEED_NETWORKD_RESTART=0

if [ "$PRIMARY_IF" != "nic0" ]; then
  echo "$LOG_PREFIX nic0 swap needed: $PRIMARY_IF should be nic0"
  if [ -e /sys/class/net/nic0 ]; then
    CURRENT_NIC0_MAC=$(cat /sys/class/net/nic0/address 2>/dev/null || true)
    echo "$LOG_PREFIX moving current nic0 (MAC $CURRENT_NIC0_MAC) aside as nic-old"
    ip link set nic0 down 2>/dev/null || true
    ip link set nic0 name nic-old
    if [ "$CURRENT_NIC0_MAC" = "$SECONDARY_MAC" ]; then
      SECONDARY_IF="nic-old"
    fi
  fi
  ip link set "$PRIMARY_IF" down 2>/dev/null || true
  ip link set "$PRIMARY_IF" name nic0
  ip link set nic0 up
  PRIMARY_IF="nic0"
  NEED_NETWORKD_RESTART=1
  echo "$LOG_PREFIX nic0 now has primary MAC $PRIMARY_MAC"
fi

if [ "$SECONDARY_IF" != "nic1" ]; then
  echo "$LOG_PREFIX renaming secondary $SECONDARY_IF -> nic1"
  ip link set "$SECONDARY_IF" down 2>/dev/null || true
  ip link set "$SECONDARY_IF" name nic1
  SECONDARY_IF="nic1"
  NEED_NETWORKD_RESTART=1
fi

if [ "$NEED_NETWORKD_RESTART" = "1" ]; then
  echo "$LOG_PREFIX restarting systemd-networkd after NIC rename(s)"
  systemctl restart systemd-networkd
  sleep 3
fi

# --- 3. Wait for nic0 DHCP --------------------------------------------------
VMNET11_IP=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  VMNET11_IP=$(ip -4 -o addr show nic0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$VMNET11_IP" ] && break
  echo "$LOG_PREFIX waiting for nic0 IPv4 (attempt $i/10)..."
  sleep 5
done

if [ -z "$VMNET11_IP" ]; then
  echo "$LOG_PREFIX ERROR: nic0 has no IPv4 address after 50s -- DHCP failed?" >&2
  ip -br addr show nic0 >&2 || true
  systemctl status systemd-networkd --no-pager >&2 || true
  exit 1
fi
echo "$LOG_PREFIX nic0 (VMnet11) IP: $VMNET11_IP"

# --- 4. Map IP -> hostname + VMnet10 IP + role + cluster -------------------
# Canon: nexus-platform-plan/docs/infra/vms.yaml (cluster: vitess) + ADR-0041.
# Convention: VMnet10 third octet = 10; fourth octet matches VMnet11.
HOSTNAME=""; VMNET10_IP=""; ROLE=""; CLUSTER=""; SHARD=""
case "$VMNET11_IP" in
  # --- etcd topo server (global + local cell `nexus`) ---
  192.168.70.190) HOSTNAME=vitess-etcd-1; VMNET10_IP=192.168.10.190; ROLE=etcd; CLUSTER=vitess ;;
  192.168.70.191) HOSTNAME=vitess-etcd-2; VMNET10_IP=192.168.10.191; ROLE=etcd; CLUSTER=vitess ;;
  192.168.70.192) HOSTNAME=vitess-etcd-3; VMNET10_IP=192.168.10.192; ROLE=etcd; CLUSTER=vitess ;;

  # --- control plane: vtctld + VTOrc ---
  192.168.70.193) HOSTNAME=vitess-control-1; VMNET10_IP=192.168.10.193; ROLE=control; CLUSTER=vitess ;;

  # --- vtgate query routers (round-robin DNS vtgate.nexus.lab) ---
  192.168.70.194) HOSTNAME=vitess-vtgate-1; VMNET10_IP=192.168.10.194; ROLE=vtgate; CLUSTER=vitess ;;
  192.168.70.195) HOSTNAME=vitess-vtgate-2; VMNET10_IP=192.168.10.195; ROLE=vtgate; CLUSTER=vitess ;;

  # --- shard -80 tablets (vttablet + Percona Server 8.0) ---
  192.168.70.196) HOSTNAME=vitess-shard1-tablet-1; VMNET10_IP=192.168.10.196; ROLE=tablet; CLUSTER=vitess; SHARD="-80" ;;
  192.168.70.197) HOSTNAME=vitess-shard1-tablet-2; VMNET10_IP=192.168.10.197; ROLE=tablet; CLUSTER=vitess; SHARD="-80" ;;
  192.168.70.198) HOSTNAME=vitess-shard1-tablet-3; VMNET10_IP=192.168.10.198; ROLE=tablet; CLUSTER=vitess; SHARD="-80" ;;

  # --- shard 80- tablets ---
  192.168.70.199) HOSTNAME=vitess-shard2-tablet-1; VMNET10_IP=192.168.10.199; ROLE=tablet; CLUSTER=vitess; SHARD="80-" ;;
  192.168.70.200) HOSTNAME=vitess-shard2-tablet-2; VMNET10_IP=192.168.10.200; ROLE=tablet; CLUSTER=vitess; SHARD="80-" ;;
  192.168.70.201) HOSTNAME=vitess-shard2-tablet-3; VMNET10_IP=192.168.10.201; ROLE=tablet; CLUSTER=vitess; SHARD="80-" ;;

  *)
    echo "$LOG_PREFIX ERROR: unknown VMnet11 IP '$VMNET11_IP' -- not a 0.O Vitess tier IP" >&2
    echo "$LOG_PREFIX recognised IPs: etcd .190/.191/.192; control .193; vtgate .194/.195; shard-80 tablets .196/.197/.198; shard 80- tablets .199/.200/.201" >&2
    exit 1
    ;;
esac
echo "$LOG_PREFIX mapped: hostname=$HOSTNAME role=$ROLE cluster=$CLUSTER shard='${SHARD:-n/a}' VMnet10=$VMNET10_IP/24"

# Every Vitess-tier node uses /etc/nexus-vitess (group vitess) for its
# node-identity env. The vitess system user/group is created at template bake.
IDENTITY_DIR=/etc/nexus-vitess
IDENTITY_GROUP=vitess
IDENTITY_FILE="$IDENTITY_DIR/node-identity.env"

# --- 5. Hostname + /etc/hosts ----------------------------------------------
CURRENT_HOSTNAME=$(cat /etc/hostname 2>/dev/null || echo '')
if [ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]; then
  echo "$LOG_PREFIX renaming hostname: '$CURRENT_HOSTNAME' -> '$HOSTNAME'"
  hostnamectl set-hostname "$HOSTNAME"
fi

# Per memory/feedback_smoke_gate_probe_robustness.md: every Linux first-boot
# must write /etc/hosts entry for the new hostname or sudo emits "unable to
# resolve host" stderr noise on every invocation.
HOSTS_LINE="127.0.1.1 $HOSTNAME.nexus.lab $HOSTNAME"
sed -i '/^127\.0\.1\.1\s/d' /etc/hosts
echo "$HOSTS_LINE" >> /etc/hosts
echo "$LOG_PREFIX wrote /etc/hosts entry: $HOSTS_LINE"

# --- 6. VMnet10 backplane config (.link MAC-match + .network static) -------
echo "$LOG_PREFIX configuring nic1 (VMnet10 backplane)"
cat > /etc/systemd/network/20-nic1.link <<EOF
[Match]
MACAddress=$SECONDARY_MAC

[Link]
Name=nic1
EOF
cat > /etc/systemd/network/20-nic1.network <<EOF
[Match]
Name=nic1

[Network]
Address=$VMNET10_IP/24
LinkLocalAddressing=no
DHCP=no
IPv6AcceptRA=no
EOF

# Per memory/feedback_systemd_link_precedence_multi_nic.md -- rewrite the
# baseline 10-nic0.link to MAC-match the primary NIC instead of the greedy
# OriginalName=en* match. Without this, on every reboot AFTER firstboot the
# udev lex-order match leaves nic1 on its kernel-default name, the static
# .network never applies, the backplane has no IP.
if [ -f /etc/systemd/network/10-nic0.link ] && ! grep -q "^MACAddress=$PRIMARY_MAC" /etc/systemd/network/10-nic0.link; then
  echo "$LOG_PREFIX rewriting 10-nic0.link to MAC-match primary"
  cat > /etc/systemd/network/10-nic0.link <<EOF
[Match]
MACAddress=$PRIMARY_MAC

[Link]
Name=nic0
EOF
  udevadm control --reload 2>/dev/null || true
fi

ip link set nic1 up 2>/dev/null || true
if ! ip -4 -o addr show nic1 2>/dev/null | grep -q "$VMNET10_IP"; then
  ip addr add "$VMNET10_IP/24" dev nic1 || true
fi
systemctl restart systemd-networkd
sleep 3

# --- 7. Write the node-identity env file for the Terraform role-overlays ----
mkdir -p "$IDENTITY_DIR"
cat > "$IDENTITY_FILE" <<EOF
# Generated by vitess-node-firstboot.sh -- do not edit by hand.
NEXUS_HOSTNAME=$HOSTNAME
NEXUS_ROLE=$ROLE
NEXUS_CLUSTER=$CLUSTER
NEXUS_SHARD=$SHARD
NEXUS_VMNET11_IP=$VMNET11_IP
NEXUS_VMNET10_IP=$VMNET10_IP
EOF
chown "root:$IDENTITY_GROUP" "$IDENTITY_FILE"
chmod 640 "$IDENTITY_FILE"
echo "$LOG_PREFIX wrote $IDENTITY_FILE (group=$IDENTITY_GROUP)"

# --- 8. Mark complete ------------------------------------------------------
# No Vitess/etcd/mysqld service is enabled here -- the Terraform role-overlays
# render per-host config (topo addresses, tablet alias, cert SANs) then bring
# up exactly the right component per node.
touch "$MARKER"
echo "$LOG_PREFIX done -- $HOSTNAME ready ($ROLE role in $CLUSTER cluster on VMnet11 $VMNET11_IP / VMnet10 $VMNET10_IP)"
