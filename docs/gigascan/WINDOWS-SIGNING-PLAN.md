# Windows signing rollout plan

## Scope

If accepted, SignPath Foundation signing will apply to the product-owned `PocketGigaScan.exe` and `lumia_gigascan_core.dll`. Third-party executables and libraries in the ZIP stay byte-for-byte unchanged, including any vendor signatures already present. The signed release ZIP, manifest and SHA-256 file are rebuilt after signing, then published to `latest` only for a successful default-branch push.

## Workflow

1. Run the existing Windows dependency checks, native tests, Flutter analysis/tests and Release build on the hosted Windows runner.
2. On every ref, use the builder's `-PrepareSigning` mode and upload its unsigned signing-input ZIP. Pull requests, fork builds and other non-candidate events upload the input as a clearly named, short-retention non-release artifact. A push in `sunyych/PocketGigaScan` or a manual dispatch there uploads the exact `PocketGigaScan-Windows-signing-input.zip` artifact for SignPath. Those jobs never expose signing environment values or secrets to pull requests or forks.
3. In the protected `windows-signing` environment, require maintainer approval. Fail the signing job if any SignPath setting or API token is absent. Submit the uploaded artifact to the official SignPath GitHub action, pinned at immutable v3.0.0 commit `f6d04783b4569d051e0c80105fe66e82819d0092`; wait for approval and completion, then collect the signed ZIP from its output directory.
4. Run `scripts/complete-dwarf-stitch-windows-signing.ps1` with unsigned and signed input ZIP paths and the expected signer thumbprint. Reject unexpected archive members, signer identity or PE payload changes outside the Authenticode checksum, security-directory and certificate-table fields. Regenerate the final manifest, release ZIP and adjacent SHA-256.
5. Upload the verified result as a run artifact. Publish or refresh the `latest` prerelease only from a default-branch push after finalization succeeds. A dispatch can produce a verified run artifact without changing the public release.

## Configuration and onboarding gates

The SignPath Foundation application was submitted on 2026-10-08 and is awaiting review. The organization, project, signing policy, artifact configuration, GitHub API token, signer thumbprint and protected environment reviewer settings have not been provisioned. No signed release can be produced until acceptance and configuration are complete.

The `windows-signing` environment must define `SIGNPATH_ORGANIZATION_ID`, `SIGNPATH_PROJECT_SLUG`, `SIGNPATH_SIGNING_POLICY_SLUG`, `SIGNPATH_ARTIFACT_CONFIGURATION_SLUG` and `SIGNPATH_SIGNER_THUMBPRINT` as variables and `SIGNPATH_API_TOKEN` as a secret. Configure required maintainer reviewers there; naming an environment in YAML does not itself create a required approval gate.

SignPath Foundation terms require the project to sign its own binaries and allow unsigned upstream libraries inside packages. Its artifact configuration must select only the product-owned EXE and core DLL. The Windows MSVC build now gives both product binaries product/version metadata from the application version. Verify those values against SignPath's artifact metadata restrictions during onboarding before claiming that enforcement is active.

SignPath Foundation's terms require human approval for every release signing request and defined author, reviewer and approver roles. The project policy and current role assignments are recorded in [the Windows code signing policy](../WINDOWS-SIGNING.md). Foundation terms: https://signpath.org/terms. Official GitHub action reference: https://docs.signpath.io/trusted-build-systems/github.

## Handoff status

Workflow and documentation scaffolding are prepared by the Luna workflow/docs coder. The Windows builder's `-PrepareSigning` contract and the finalizer are owned by the coordinator's separate implementation lane. The coordinator reviews the complete integration. Until SignPath Foundation accepts the project and the repository settings are configured, CI cannot produce or publish a signed release.
