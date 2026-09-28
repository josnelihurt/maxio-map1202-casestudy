set -e
printf '%s\n' 'ACTION=="add|change", KERNEL=="nvme*n1", ATTR{queue/discard_max_bytes}="0"' > /etc/udev/rules.d/99-nvme-nodiscard.rules
cat /etc/udev/rules.d/99-nvme-nodiscard.rules
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>&1 | head -4
