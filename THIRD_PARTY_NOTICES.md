# Third-party notices

The native transfer bridge links libcurl (curl license). Its SFTP support uses libssh2 (BSD-3-Clause).
Development currently links the Homebrew curl distribution, which also includes TLS/compression dependencies.
Bundled binaries must include the license texts for their actual dependency closure before distribution.

- https://curl.se/docs/copyright.html
- https://libssh2.org/license.html

No Transmit code, icons, or commercial assets are included.

The application bundles CA certificates derived from Mozilla's trust store via Homebrew ca-certificates (MPL-2.0). Source: https://curl.se/docs/caextract.html.
Every embedded Homebrew dylib has its installed license text and source formula included in Contents/Resources/Licenses. librtmp is LGPL-2.1-or-later (not the GPL command-line tools); its full LGPL text is included separately. Its source archive is https://deb.debian.org/debian/pool/main/r/rtmpdump/rtmpdump_2.4+20151223.gitfa8646d.1.orig.tar.gz (SHA-256 5c032f5c8cc2937eb55a81a94effdfed3b0a0304b6376147b86f951e225e3ab5); the included Homebrew formula records its OpenSSL patch and build instructions. The libraries remain dynamically linked and replaceable; no rtmpdump tools are distributed.

The dark connection-bridge icon was generated using OpenAI image generation and selected for AetherTransfer on 2026-11-04.
