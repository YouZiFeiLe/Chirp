# Contributing to Chirp

[简体中文](CONTRIBUTING.md) · English

## Report a problem or suggest a change

- **Bug reports.** Search existing issues first. Include the affected client, OS and server versions, the shortest steps that reproduce the problem, and what you expected and observed. Export the redacted `.chirplog` from Settings → Log Management, zip it and attach the `.zip` to the issue. Redact any additional screenshots and keep tokens and `.chirpkey` backups private. [GitHub Issues](https://github.com/YouZiFeiLe/Chirp/issues)
- **Feature requests.** Describe a situation where the change would help and what you want to do differently. For protocol changes that affect several clients, an issue is a good place to discuss compatibility. Small code fixes can go straight to a pull request.
- **Documentation.** Submit documentation corrections, additions and translations as pull requests in the documentation repository. [Chirp-Doc-Page](https://github.com/YouZiFeiLe/Chirp-Doc-Page)
- **Security vulnerabilities.** Privately tell the maintainer which versions are affected and under what conditions the problem occurs. [Report a vulnerability on GitHub](https://github.com/YouZiFeiLe/Chirp/security/advisories/new) · [Security policy](SECURITY.md#english)

## Get started

Fork the repository on GitHub, replace `YOUR-NAME` with your username, and create a branch from `main`. Run the remaining commands from the repository root.

```sh
git clone https://github.com/YOUR-NAME/Chirp.git
cd Chirp
git switch -c fix/room-reconnect origin/main
```

Install the tools for the component you plan to change. For the Go server, the entry point is in `cmd/chirp`. Room, identity and SQLite storage code lives under `internal/`. On macOS or Linux, use the project's Go version and a C compiler for the race detector. [Go version](go.mod)

```sh
sh scripts/go.sh run ./cmd/chirp version
sh scripts/test-sqlite.sh local
```

The first command builds the CLI and prints its version. The second runs the Go tests with race detection and temporary SQLite files, then runs `go vet`. To start the local API or test a Compose deployment, see the [server build and test guide](https://chirp.youzifeile.com/en/development/building).

## Test the components you changed

| Component | Command |
| --- | --- |
| Web admin console and passkey pages | `node --test internal/webui/*_test.mjs internal/passkeyhttp/*_test.mjs` |
| Rust crypto library shared by all four clients | `cargo test --locked --manifest-path Client/apple/MLS/native/Cargo.toml` |
| Shared macOS and iOS logic (Apple Silicon Mac) | Run `sh scripts/prepare-mls.sh` to build the XCFramework, then `swift test --package-path Client/apple` |
| Android client | `./Client/android/gradlew -p Client/android :app:testDebugUnitTest` |
| Windows x64 protocol and audio | `pwsh -NoProfile -File Client/windows/scripts/Build-Native.ps1 -Test` |
| Windows desktop behavior | `dotnet run --project Client/windows/tests/DesktopBehavior.csproj -c Release` |

For SDKs and native dependencies, see the [client build guide](https://chirp.youzifeile.com/en/development/clients). For microphone, device pairing or two-party call changes, check the behavior on real devices using the [manual QA checklist](https://chirp.youzifeile.com/en/development/testing).

## Open a pull request

Push your branch to your fork and open a pull request against `main` in `YouZiFeiLe/Chirp`.

- Keep the PR focused on one problem. Explain why the change is needed, describe the behavior it changes, and link the issue if one exists.
- Format changed Go files with `gofmt`. When fixing a bug, add a regression test that reproduces the original behavior where practical. List the checks you ran, their results and the platforms you tested. A redacted screenshot helps reviewers verify UI changes.
- For changes to identity, pairing or recovery file formats, check the affected implementations against the shared vectors and describe compatibility with earlier versions. [Cross-platform test vectors](internal/identity/testdata/)

Original work in Chirp is licensed under AGPL-3.0-only. When adding third-party code or assets, credit the source and retain its license and attribution notices. [Project license](LICENSE) · [Compliance statement](COMPLIANCE.md)
