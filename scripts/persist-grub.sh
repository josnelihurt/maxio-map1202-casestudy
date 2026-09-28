set -e
F=/etc/default/grub
grep -q nvme_core.default_ps_max_latency_us $F || sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvme_core.default_ps_max_latency_us=0 nvme.max_host_mem_size_mb=0 pcie_aspm=off"/' $F
echo "== linea resultante:"
grep -n '^GRUB_CMDLINE_LINUX_DEFAULT' $F
update-grub 2>&1 | tail -2
