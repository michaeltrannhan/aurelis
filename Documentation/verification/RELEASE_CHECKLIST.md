# Release verification

## Automated gates

Run `Scripts/run-verification.sh all`. It enforces complete Swift concurrency, the full Thread Sanitizer suite, sustained audio callback stress, generated Xcode Debug tests, production widget rendering, unsigned Debug/Release app/widget validation, and the product-verifier fault matrix.

For certificate-backed validation, run both configurations with the release team and identity:

```sh
DEVELOPMENT_TEAM=TEAMID SIGN_IDENTITY="Apple Development" Scripts/run-verification.sh signed
```

Use the generic `Apple Development` selector with Xcode automatic signing; set `TEAMID` to the certificate's organizational-unit/team identifier. Certificate-backed builds sign temporary app- and widget-entitled probes, resolve both against the live app-group container, and exchange a nonce across processes. The build fails if the app/widget bundle IDs, versions, architectures, package types, embedding, signatures, signing teams, entitlements, or shared app-group identifier diverge.

`Scripts/test-build-verifier.sh` validates a known-good product and proves that the verifier rejects deliberately injected build, plist, embedding, architecture, bundle-identifier, entitlement, and missing-notary-configuration faults. With `CODE_SIGNING_ALLOWED=YES`, it also rejects signature tampering and a non–Developer ID distribution package. Signed and unsigned Xcode logs use distinct names under `.build/logs` so both evidence sets survive the matrix.

## Distribution and notarization

Create a keychain profile with `xcrun notarytool store-credentials`, then package a Developer ID-signed Release build:

```sh
DEVELOPMENT_TEAM=TEAMID \
SIGN_IDENTITY="Developer ID Application" \
NOTARY_PROFILE=eqmacrep-notary \
Scripts/package-release.sh
```

The command requires notarization by default, waits for acceptance, staples and validates the ticket, reruns Gatekeeper assessment, and recreates the final ZIP. `REQUIRE_NOTARIZATION=NO` is only for an explicitly non-distributed local artifact.

Every package input, including `SKIP_BUILD=YES`, is rechecked through the product verifier and must use Developer ID Application signatures with hardened runtime on both bundles. The final ZIP is extracted and the contained app/widget are verified again; notarized archives also repeat stapler and Gatekeeper validation after extraction.

## External evidence

- Complete [HARDWARE_MATRIX.md](HARDWARE_MATRIX.md) for hardware-impacting releases.
- Review the requirement-level [Phase 8 audit](PHASE8_AUDIT.md) for the boundary between automated proof and hands-on evidence.
- Retain Xcode, TSan, stress, signing, notary, and Gatekeeper logs with the release.
