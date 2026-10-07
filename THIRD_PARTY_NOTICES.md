# Third-party notices

The native transfer bridge links libcurl (curl license). Its SFTP support uses libssh2 (BSD-3-Clause).
Development currently links the Homebrew curl distribution, which also includes TLS/compression dependencies.
Bundled binaries must include the license texts for their actual dependency closure before distribution.

- https://curl.se/docs/copyright.html
- https://libssh2.org/license.html
- The development bundle includes the Homebrew ca-certificates root bundle (Mozilla trust data). Its upstream notices and the complete binary license closure must accompany formal distribution.
- FTPS fixtures use pyOpenSSL (Apache-2.0), installed only in the ignored test virtualenv; it is not an application dependency.

No Transmit code, icons, or commercial assets are included.
