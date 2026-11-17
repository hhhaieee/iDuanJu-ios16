# Current player signer

`current*.go` ports the locally verified 7.2.1.33 arithmetic into the production
Go player. On 2026-11-16 its envelope was also accepted for a real 7.4.5.32
playback request and, independently, freshly registered anonymous Go requests.
It does not load APK/ELF files or reuse a phone identity, SDK token or captured
protobuf at runtime. Category requests retain their separate 551 signer.

The KS/custom transform candidate originated in OpenHongguo, commit
`05aa580a2fa914becabc5ae4be5b05539c66bda6`, under Apache-2.0. A copy of the license
is included in `LICENSE.current.txt`. The implementation was modified and
checked against local native evidence: current four-branch tables, initialization,
bit-lane envelope, prefix, checksum, license profile and explicit request binding.
The factor compression implements six independently verified selectors; the
request builder searches a bounded ticket range and signs the exact final bytes.

Constant provenance: `libmetasec_ml.so` SHA-256
`712384bd0e310fded0ae9b6441c2a264dd356dfaf1ef42d2ebc3c790fdd9269c`;
APK SHA-256 `0ed1bf1550ddd8bccfd78377c2222b3fd4c4646f167189ee91bc7cffc19c1984`.
Test fixtures contain synthetic native vectors and output digests only, with no
captured device credentials. This notice grants no license to third-party APKs
or services and does not guarantee future server acceptance.
