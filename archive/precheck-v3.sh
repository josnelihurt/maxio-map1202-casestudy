#!/bin/bash
# zfix3: decision-tree prechecks + SteamOS install on MAP1202
LOG=/tmp/zfix-install.log
exec >>$LOG 2>&1
nvme_err_count() { dmesg | grep -cE 'nvme nvme0: .*(timeout|reset controller|I/O error)'; }
fatal() { echo "FATAL: $*"; udevadm control --start-exec-queue 2>/dev/null; exit 1; }

echo "=== zfix3 start $(date) ==="
dmesg -w > /tmp/nvme-watch.log 2>&1 &

for i in $(seq 1 60); do [ -b /dev/nvme0n1 ] && break; sleep 1; done
sleep 5
[ -b /dev/nvme0n1 ] || fatal "nvme0n1 no aparece"

echo "--- cmdline: $(grep -o 'nvme[^ ]*' /proc/cmdline | tr '\n' ' ')"
grep -q 'nvme.max_host_mem_size_mb=0' /proc/cmdline || fatal "parametro HMB off no aplico"
echo 0 > /sys/block/nvme0n1/queue/discard_max_bytes
echo 0 > /sys/class/nvme/nvme0/power/pm_qos_latency_tolerance_us
echo "--- mitigaciones: discard=$(cat /sys/block/nvme0n1/queue/discard_max_bytes) pmqos=$(cat /sys/class/nvme/nvme0/power/pm_qos_latency_tolerance_us)"
dmesg | grep -i 'host memory buffer' && fatal "HMB sigue alocado"

dd if=/dev/nvme0n1 of=/dev/null bs=1M count=64 2>/dev/null || fatal "lectura de sanidad fallo"
echo "--- sanidad 64MB OK"

echo "--- TEST A: IO mixto concurrente (lector 4K aleatorio + escritor secuencial), 60s, $(date)"
( end=$((SECONDS+60)); n=0
  while [ $SECONDS -lt $end ]; do
    dd if=/dev/nvme0n1 of=/dev/null bs=4k count=64 skip=$(( (RANDOM * 32768 + RANDOM) % 488000000 )) iflag=direct 2>/dev/null || exit 9
    n=$((n+1))
  done
  echo "lector: $n lecturas aleatorias completadas" ) &
RPID=$!
wloops=0
while kill -0 $RPID 2>/dev/null; do
  dd if=/dev/zero of=/dev/nvme0n1 bs=1M count=2048 oflag=direct conv=fsync 2>/dev/null || { kill $RPID 2>/dev/null; fatal "TEST A: escritor fallo"; }
  wloops=$((wloops+1))
done
wait $RPID || fatal "TEST A: lector fallo"
[ "$(nvme_err_count)" -eq 0 ] || { dmesg | grep -E 'nvme nvme0: .*(timeout|reset)' | tail -5; fatal "TEST A: errores nvme durante IO mixto CONCURRENTE"; }
echo "TEST A PASADO ($wloops pasadas de escritura, 60s) $(date)"

echo "--- TEST B: acceso al final del disco (GPT backup), $(date)"
TOTAL_BLK=$(cat /sys/block/nvme0n1/size)
N1M=$(( TOTAL_BLK / 2048 ))
echo "total=${TOTAL_BLK} sectores, ${N1M} bloques de 1MiB"
dd if=/dev/zero of=/dev/nvme0n1 bs=1M count=32 seek=$((N1M-32)) oflag=direct 2>/dev/null || fatal "TEST B: escritura al final fallo"
dd if=/dev/nvme0n1 bs=512 count=34 skip=$((TOTAL_BLK-34)) of=/tmp/lastblk.bin 2>/dev/null || fatal "TEST B: lectura del ultimo LBA fallo"
dd if=/dev/zero of=/dev/nvme0n1 bs=512 count=33 seek=$((TOTAL_BLK-33)) oflag=direct 2>/dev/null || fatal "TEST B: escritura GPT backup fallo"
[ "$(nvme_err_count)" -eq 0 ] || fatal "TEST B: errores nvme en zona final"
echo "TEST B PASADO $(date)"

echo "--- TEST C: sfdisk + partx -a (sin BLKRRPART) + mkfs p6, udev congelado, $(date)"
udevadm control --stop-exec-queue
sfdisk --no-tell-kernel --no-reread /dev/nvme0n1 <<'SFD'
label: gpt
start=2048, size=524288, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"
start=526336, size=131072, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="efi-A"
start=657408, size=131072, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="efi-B"
start=788480, size=10485760, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="rootfs-A"
start=11274240, size=10485760, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="rootfs-B"
start=21760000, size=524288, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D, name="var-A"
start=22284288, size=524288, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D, name="var-B"
start=22808576, size=204800, type=933AC7E1-2EB4-4F13-B844-0E14E2AEF915, name="home"
SFD
sleep 2
partx -d /dev/nvme0n1 2>/dev/null
partx -a --nr 1-8 /dev/nvme0n1 2>/dev/null || partx -a /dev/nvme0n1 || fatal "TEST C: partx -a fallo"
sleep 3
[ -b /dev/nvme0n1p6 ] || fatal "TEST C: p6 no aparecio tras partx"
mkfs.ext4 -F -K -E nodiscard -L var /dev/nvme0n1p6 > /tmp/mkfs-c.log 2>&1; mrc=$?; tail -4 /tmp/mkfs-c.log; [ $mrc -eq 0 ] || fatal "TEST C: mkfs p6 fallo (rc=$mrc) incluso con udev congelado"
mkdir -p /mnt/p6t
mount /dev/nvme0n1p6 /mnt/p6t || fatal "TEST C: mount p6 fallo"
( echo zfix3 > /mnt/p6t/probe.txt; cat /mnt/p6t/probe.txt; sync ) || fatal "TEST C: rw en p6 monto fallo"
umount /mnt/p6t
[ "$(nvme_err_count)" -eq 0 ] || fatal "TEST C: errores nvme con udev congelado"
echo "TEST C PASADO $(date)"

echo "=== TODOS LOS PRECHECKS PASARON - lanzando instalador con udev congelado $(date) ==="
NOPROMPT=1 /bin/bash /home/deck/tools/repair_device_zfix.sh all
rc=$?
udevadm control --start-exec-queue
echo "=== instalacion terminada rc=$rc $(date) ==="
