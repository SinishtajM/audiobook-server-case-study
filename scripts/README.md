# Public-Safe Operational Script Examples

These scripts are sanitized examples derived from the verified production workflow described in the repository root README.

## Included Scripts

- `server-health.example.sh` — validates required commands, application services, the SMB workspace, VPN state, auto-m4b settings, workflow directories, disk utilization, and endpoint availability.
- `backup-audiobooks-local.example.sh` — performs a guarded Audiobooks-only rsync mirror with mount-first preflight checks, dry-run support, recovery history, locking, stable-source validation, post-run verification, retention, and successful-run state tracking.
- `backup-health.example.sh` — validates required commands, the active cron schedule, mounts, filesystem separation, capacity, mirror parity, timestamp plausibility, the last-successful-backup state, and retained run logs.

## Safety Notes

These are examples, not drop-in installers. Before using them:

1. Review every configurable path, hostname, port, threshold, and retention value.
2. Test the backup script with `--dry-run` before the first real synchronization.
3. Confirm the source and destination are separate physical filesystems.
4. Confirm the minimum source-file threshold is appropriate for the library.
5. Test restoration from both the current mirror and recovery-history directories.
6. Keep private configuration, credentials, and environment files outside the repository.
7. Re-run `bash -n` and ShellCheck after adapting an example.

The examples intentionally use generalized hosts, paths, and sample values. Verification is based on paths, file sizes, file counts, and total bytes; it is not a cryptographic content-integrity check.
