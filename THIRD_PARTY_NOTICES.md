# Third-party notices

The native transfer bridge links libcurl (curl license). Its SFTP support uses libssh2 (BSD-3-Clause).
Development builds curl 8.22.0 from its verified official release archive with a narrow upstream SSH-passphrase fix backported from a7b42cc90cbcb09f4813253ac97ea96c10fd9e94. OpenSSL, libssh2 and zlib provide TLS/SSH/compression support. See docs/protocol-runtime.md for provenance; curl's COPYING is included in the development app.
Bundled binaries must include the license texts for their actual dependency closure before distribution.

- https://curl.se/docs/copyright.html
- https://libssh2.org/license.html
- The development bundle includes the Homebrew ca-certificates root bundle (Mozilla trust data). Its upstream notices and the complete binary license closure must accompany formal distribution.
- FTPS fixtures use pyOpenSSL (Apache-2.0), installed only in the ignored test virtualenv; it is not an application dependency.

No Transmit code, icons, or commercial assets are included.
