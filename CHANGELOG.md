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
- Directory transfers scan bounded manifests and report overall bytes, processed items and skips; each file is verified and committed, and cancellation cleans its active partial.
- Incremental Dock progress aggregates tasks across tabs, retains completed work until the active batch ends and clears at idle; system Dock visual acceptance remains pending.
- Preserve an explicit zero-byte SFTP stat size in the bundled curl runtime so safe version checks support empty files.
- Native Quick Look for local files and verified remote snapshots up to 128 MiB, with cancellable preparation and owned temporary-file cleanup.
- Native file information inspector follows the focused pane and selection; folder totals and metadata editing remain pending.
- Startup recovery of abandoned preview caches uses locked ownership records, bounded cancellable cleanup and descriptor-relative deletion; active previews and unrecognized data are preserved.
- Native reusable icon browsing with independent pane/tab modes, preserved selection and keyboard focus, sorting and shared list/icon context menus. Drag-and-drop acceptance remains pending.
- Shared native file URL drop receiver for list/icon panes, copy-only local sources, loading/disabled guards and empty-state input passthrough. URL uploads capture the connection and destination before reading local metadata. Diagnostic-build internal drags transferred verified bytes; final-build and Finder drag acceptance remains pending.
- Independent S3 transport core with CryptoKit SigV4, byte-exact object keys, paginated listings, verified conditional downloads/uploads, bounded multipart source slices, pause/cancellation and owned multipart abort records. Test-only HTTPS MinIO fixture is built from pinned source and cleaned after testing; full app workflows and real AWS/R2 acceptance remain pending.
- Native S3 profiles with separate Keychain credential IDs, byte-exact prefix browsing and cached selection identity, shared queue file transfers and conflict policies, conditional empty-prefix markers, explicit object deletion and persisted owned-abort cleanup. Profile writes are serialized off the main actor; staged credentials preserve the old endpoint after a failed profile write. Recursive S3 transfers, editing, preview, sync and restart recovery remain pending.
- Connection forms use bordered native input fields with a fixed minimum width, leading text and visible prompts. Mouse typing, text-field Tab navigation, secure input and the longer S3 form were checked in the running app.
