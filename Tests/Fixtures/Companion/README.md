# Companion fixtures

Read by the Swift suite (`Tests/CompleteScannerTests`, through the `CompanionFixtures` extension in
`CompanionLoopbackTests.swift`). The loopback companion server serves these identities, imported to
memory, because a CI runner's keychain refuses the keys a test would make (errSecMissingEntitlement).

| File | What it is |
|---|---|
| `tls-desktop-a.p12` | The desktop identity of `CompanionLoopbackTests` and `CompanionHostTests`: a self-signed P-256 certificate (CN "Test Desktop a CompleteScanner") **and its private key**. The SHA-256 of its SubjectPublicKeyInfo is `d0b8817381596dee250bb3b57b81b2fbbe172d3369226ecccd87eea543cd97a2` |
| `tls-desktop-b.p12` | The same for the identity after Reset pairing (CN "Test Desktop b CompleteScanner"), so the key changes. The SHA-256 of its SubjectPublicKeyInfo is `e648402792146a52071a9fd3c170c3793cfaffaaf3ba4c8d9078276483a6f7da` |

Test fixtures only: no app ships a key. Both files are PKCS #12 with 3DES and a SHA-1 MAC so every Apple
system imports them; the password is in `CompanionFixtures.loopbackPassword`, and
`CompanionLoopbackTests.testTheFixtureIdentitiesHaveTheirFingerprints` checks the two fingerprints.
They were made once with OpenSSL, for `a` and `b`:

```
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 7300 -sha256 \
    -subj "/CN=Test Desktop a CompleteScanner" -keyout key.pem -out cert.pem
openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -name desktop-a -inkey key.pem -in cert.pem -out tls-desktop-a.p12
```

The files are kept byte for byte (`../.gitattributes` turns off line-ending conversion).
