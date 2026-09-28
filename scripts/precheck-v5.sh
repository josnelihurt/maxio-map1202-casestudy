#!/bin/bash
# zfix5: SIN tocar la tabla de particiones (el rescan runtime mata el MAP1202)
LOG=/tmp/zfix-install.log
exec >>$LOG 2>&1
nvme_err_count() { dmesg | grep -cE 'nvme nvme0: .*(timeout|reset controller|I/O error)'; }
fatal() { echo "FATAL: $*"; udevadm control --start-exec-queue 2>/dev/null; exit 1; }

echo "=== zfix5 start $(date) ==="
dmesg -w > /tmp/nvme-watch.log 2>&1 &
for i in $(seq 1 60); do [ -b /dev/nvme0n1 ] && break; sleep 1; done
sleep 5
[ -b /dev/nvme0n1 ] || fatal "nvme0n1 no aparece"
echo "--- cmdline: $(grep -o 'nvme[^ ]*' /proc/cmdline | tr '\n' ' ')"
grep -q 'nvme.max_host_mem_size_mb=0' /proc/cmdline || fatal "parametro HMB off no aplico"
echo 0 > /sys/block/nvme0n1/queue/discard_max_bytes
echo 0 > /sys/class/nvme/nvme0/power/pm_qos_latency_tolerance_us
echo "--- mitigaciones: discard=$(cat /sys/block/nvme0n1/queue/discard_max_bytes) pmqos=$(cat /sys/class/nvme/nvme0/power/pm_qos_latency_tolerance_us)"
dd if=/dev/nvme0n1 of=/dev/null bs=1M count=64 2>/dev/null || fatal "lectura de sanidad fallo"

echo "--- particiones existentes (GPT ya en disco, escaneada en boot):"
lsblk -bno NAME,SIZE,TYPE /dev/nvme0n1 | head -12
for p in 1 2 3 4 5 6 7 8; do [ -b /dev/nvme0n1p$p ] || fatal "falta /dev/nvme0n1p$p"; done

echo "--- TEST E: mkfs p6 con -b 4096 (cero operaciones de tabla), udev congelado, $(date)"
udevadm control --stop-exec-queue
mkfs.ext4 -F -K -E nodiscard -b 4096 -L var /dev/nvme0n1p6 > /tmp/mkfs-c.log 2>&1; mrc=$?; tail -3 /tmp/mkfs-c.log; [ $mrc -eq 0 ] || fatal "TEST E: mkfs p6 -b 4096 fallo (rc=$mrc)"
mkdir -p /mnt/p6t
mount /dev/nvme0n1p6 /mnt/p6t || fatal "TEST E: mount p6 fallo"
( echo zfix5 > /mnt/p6t/probe.txt; cat /mnt/p6t/probe.txt; sync ) || fatal "TEST E: rw p6 fallo"
umount /mnt/p6t
[ "$(nvme_err_count)" -eq 0 ] || fatal "TEST E: errores nvme"
echo "TEST E PASADO (bloques 4K) $(date)"

echo "--- formateando resto de particiones (udev congelado, todo -b 4096) $(date)"
mkfs.ext4 -F -K -E nodiscard -b 4096 -L var /dev/nvme0n1p7 >/dev/null 2>&1 || fatal "mkfs p7"
mkfs.vfat -n esp /dev/nvme0n1p1 >/dev/null 2>&1 || fatal "mkfs p1"
mkfs.vfat -n efi /dev/nvme0n1p2 >/dev/null 2>&1 || fatal "mkfs p2"
mkfs.vfat -n efi /dev/nvme0n1p3 >/dev/null 2>&1 || fatal "mkfs p3"
mkfs.ext4 -F -K -E nodiscard -b 4096 -O casefold -T huge -L home /dev/nvme0n1p8 >/dev/null 2>&1 || fatal "mkfs p8"
tune2fs -m 0 /dev/nvme0n1p8 >/dev/null 2>&1 || fatal "tune2fs p8"
[ "$(nvme_err_count)" -eq 0 ] || fatal "errores nvme tras formateos"
echo "--- verificacion blkid:"
for spec in "p1 vfat" "p2 vfat" "p3 vfat" "p6 ext4" "p7 ext4" "p8 ext4"; do set -- $spec; t=$(blkid -o value -s TYPE /dev/nvme0n1$1); echo "$1 -> $t"; [ "$t" = "$2" ] || fatal "blkid $1: $t != $2"; done
echo "FORMATEOS OK $(date)"

udevadm control --start-exec-queue
sleep 3
echo "=== TODO PASADO - lanzando instalador modo system (sin tocar tabla) $(date) ==="
DOPARTVERIFY=0 NOPROMPT=1 /bin/bash /home/deck/tools/repair_device_zfix.sh system
rc=$?
echo "=== instalacion terminada rc=$rc $(date) ==="
