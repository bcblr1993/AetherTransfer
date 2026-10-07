# Changelog

## Unreleased — 0.1.0

- Initial native macOS FTP/SFTP file transfer client under development.
- Explicit and implicit FTPS, verified TLS trust/hostname checks, encrypted RSA SSH-key authentication.
- Recursive transfers, bounded queue, cancellation, pause/resume, rate limits and conflict choices.
- Native reusable file table, background filtering/sorting, Liquid Glass tabs and compact activity panel.
- Server groups, editing and credential-free JSON import/export.
- Folder sync previews across local and connected remote roots, manual bidirectional conflict resolution, explicit mirror selection and stale-plan checks.
- Persistent single-file transfer checkpoints, verified FTP/FTPS/SFTP upload/download resume and HTTP/HTTPS ranged downloads; explicit restart for WebDAV uploads, recovery UI and owned-partial cleanup.
- File preparation shares bounded queue slots and preserves early pause/retain requests; local downloads use atomic commit with exclusive no-clobber behavior and POSIX permission preservation.
- Cancelled or failed initial editor loads remain read-only until a successful retry; unpublished editor sessions are cleaned independently of the cancelled reader.
- Current-file transfer speed and estimated remaining time use bounded recent samples; pause, retry and verification reset estimates without adding an idle polling timer.
