# eSCL fixtures

Read by both test suites: `Tests/LazyScanTests` (Swift, through `EsclFixtures.swift`) and
`windows/LazyScan.Core.Tests` (C#, through `EsclFixtures.cs`, which the project copies next to
its assembly). Changing a file here changes the expectations on both platforms at once.

| File | What it is |
|---|---|
| `capabilities-platen-duplex-adf.xml` | An all-in-one's ScannerCapabilities: platen and a two-sided feeder, discrete resolutions, `scan:`/`pwg:` prefixes |
| `capabilities-feeder-only.xml` | A sheet-fed scanner: feeder only, a resolution range, long paper, a default namespace |
| `capabilities-bare-platen.xml` | A flatbed listing no sizes, modes or formats |
| `capabilities-duplex-option.xml` | Two-sided feeding announced only as an `AdfOption` |
| `request-platen-color.xml` | The ScanSettings document of a full-platen color scan of the all-in-one (compared byte for byte) |
| `request-feeder-two-sided.xml` | The ScanSettings document of a two-sided color feeder scan of the all-in-one |
| `txt-hp.txt` | A DNS-SD TXT record as HP all-in-ones advertise it, one `key=value` entry per line |
| `certificate-rsa2048.pem`, `certificate-p256.pem`, `certificate-p384.pem` | Self-signed scanner certificates made once with OpenSSL (no private keys kept). The SHA-256 of their SubjectPublicKeyInfo is `4ad3ab48…e4e9`, `61010433…7d6c` and `ef13555c…e199` (in full in both `EsclFixtures` files) |
| `tls-scanner-a.p12`, `tls-scanner-b.p12` | Two self-signed RSA-2048 identities, certificate **and private key** (PKCS #12, 3DES and SHA-1 MAC so every Apple system imports them; password in both `EsclFixtures` files), made once with OpenSSL for the Swift suite's loopback HTTPS scanner (`EsclLoopbackTests`). Test fixtures only: no app ships a key. The SHA-256 of their SubjectPublicKeyInfo is `68046922…83eb` and `db3aaa68…a5dd`, checked on both sides (C#'s `EsclTrustTests.TheLoopbackIdentitiesHaveTheirFingerprints`, Swift's `EsclLoopbackTests.testTheLoopbackIdentitiesHaveTheirFingerprints`) |
| `escl-trust-windows.json`, `escl-trust-apple.json` | The same two pins as each platform writes `escl-trust.json`; each platform must load both |

The files are kept byte for byte (`../.gitattributes` turns off line-ending conversion).
