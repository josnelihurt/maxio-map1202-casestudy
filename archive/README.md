# Archive

| File | What it was |
|---|---|
| `precheck-v3.sh` | Historical decision-tree version (kept for the record). Its battery: **TEST A** — 60 s of concurrent randomized 4 KiB direct readers vs. sequential direct writers (rejected the "concurrent mixed I/O" hypothesis); **TEST B** — sector-exact end-of-disk writes/reads including the last 34 LBAs (rejected "bad GPT-backup zone"; note: its first draft had the off-by-end harness bug described in [docs/09-postmortem.md](../docs/09-postmortem.md) M3); **TEST C** — sfdisk + kernel rescan (`blockdev --rereadpt`) + mkfs with the udev exec-queue frozen, which isolated the runtime partition-rescan trigger. It was later taught `partx -d/-a`, and finally replaced by `scripts/precheck-v5.sh` (zero partition-table operations + `-b 4096`). |
