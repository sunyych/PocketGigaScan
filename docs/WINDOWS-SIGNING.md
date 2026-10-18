# Windows code signing policy

**Planned provider:** Free code signing provided by SignPath.io, certificate by SignPath Foundation; the application was submitted on 2026-10-08 and is pending review. If accepted, SignPath Foundation will be the publisher shown by the certificate. The project intends to sign only its own `PocketGigaScan.exe` and `lumia_gigascan_core.dll` binaries, built from this repository. Bundled Flutter, Microsoft, OpenCV, JPEG XL and other third-party DLL bytes remain unchanged, including any vendor signatures already present; the signing workflow will neither add signatures to third-party code nor strip existing signatures. SignPath Foundation currently permits unsigned upstream libraries in a signed package ([conditions](https://signpath.org/terms)).

## Team roles

- Authors and reviewers: repository maintainer [sunyych](https://github.com/sunyych), who owns and maintains [PocketGigaScan](https://github.com/sunyych/PocketGigaScan). Changes proposed by other contributors require maintainer review.
- Signing approver: repository maintainer [sunyych](https://github.com/sunyych), through the protected GitHub `windows-signing` environment and SignPath's per-release approval.

All maintainers and signing approvers must use multi-factor authentication for GitHub and SignPath. SignPath Foundation must accept the project before the signing service is used.

## Privacy

Known application network activity includes operator-initiated connections to a selected camera/device for requesting and transferring photographs. The signing workflow sends the source-built signing input to SignPath only for eligible repository events after the protected-environment gate. This describes the reviewed product and workflow paths; a dependency-wide network and telemetry audit has not been completed, so it is not a blanket declaration about every bundled component.

## Current status

The SignPath Foundation application was submitted on 2026-10-08 and is awaiting review. The organization/project/policy/artifact configuration, signer thumbprint, API token, and protected GitHub environment reviewers have not been provisioned. Until acceptance and repository configuration are complete and a maintainer approves a release, no signed package is produced or published. Existing Windows downloads remain unsigned.

The workflow runs the full Windows source build and tests before making the signing input artifact. Pull requests and fork builds never access the signing environment or its secrets. A push in the canonical repository or a manual dispatch there can request signing after entering the protected `windows-signing` environment, which must require maintainer approval. Missing configuration fails the signing gate. The `latest` prerelease is refreshed only after final verification on a default-branch push.

The builder will create `PocketGigaScan-Windows-signing-input.zip`. The pinned SignPath GitHub action submits that uploaded artifact and returns the signed ZIP under the same filename. The completion script compares unsigned and signed PE payloads, checks the expected signer identity, and regenerates the release manifest, final ZIP and checksum. The artifact configuration must select only the product-owned EXE and core DLL for signing. The Windows MSVC build now gives both product binaries product/version metadata from the application version. Verify those values against the SignPath artifact metadata restrictions during onboarding before claiming that enforcement is active.

## Repository configuration

After SignPath Foundation accepts the application, configure these values in the GitHub `windows-signing` environment:

| Type | Name |
| --- | --- |
| Variable | `SIGNPATH_ORGANIZATION_ID` |
| Variable | `SIGNPATH_PROJECT_SLUG` |
| Variable | `SIGNPATH_SIGNING_POLICY_SLUG` |
| Variable | `SIGNPATH_ARTIFACT_CONFIGURATION_SLUG` |
| Variable | `SIGNPATH_SIGNER_THUMBPRINT` |
| Secret | `SIGNPATH_API_TOKEN` |

Require one or more maintainers to approve deployments to this environment. The signing action is pinned to the immutable v3.0.0 commit [`f6d04783b4569d051e0c80105fe66e82819d0092`](https://github.com/SignPath/github-action-submit-signing-request/commit/f6d04783b4569d051e0c80105fe66e82819d0092). Its documented GitHub artifact ID, wait-for-completion and output-directory inputs are used as described in the [official GitHub integration guide](https://docs.signpath.io/trusted-build-systems/github).
