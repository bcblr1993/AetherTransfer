# Contributing

Use `feat/*` or `fix/*` branches and Conventional Commits. Keep changes focused.
Run `scripts/test_core.sh` and `scripts/build_app.sh`, which clean the previous build before each gate. Protocol changes require `scripts/test_protocols.sh`; S3 changes also require `scripts/test_s3.sh` (Go 1.24+). Run gates serially and remove generated intermediate artifacts after retaining small acceptance evidence.
Describe the user-visible behavior and validation in the PR. Do not commit secrets or private test fixtures.
