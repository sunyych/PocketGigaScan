# LumiaPocketGigaScan roadmap

This roadmap turns [PRD.md](PRD.md) into reviewable work. A source-level
binding is not evidence of a packaged native library or a hardware workflow.

| ID | Work | Depends on | Status | Owner | Evidence / handoff |
| --- | --- | --- | --- | --- | --- |
| PG-001 | Build the upstream fork unchanged | — | pending | platform | `just check` output and build artifact |
| PG-002 | Audit Pocket 2 BLE, SoftAP, DUML, preview, gimbal, shutter, photo, state | PG-001 | hardware blocked | camera shell | `protocol/pocket2.md`; needs redacted physical-device journal |
| PG-003 | Define `PocketCamera` and capability boundary in the shell | PG-002 | in progress | camera shell | `PocketCapabilities`; Android wire/profile tests |
| PG-004 | Pocket 2 connect, preview, gimbal, capture loop | PG-003 | pending | camera shell | Physical Pocket 2 acceptance evidence |
| PG-005 | Gimbal center/+10/center/-10/center repeatability test | PG-004 | pending | camera shell | Automated report plus physical cycles |
| PG-006 | Pin and integrate `lumia-gigascan-core` stable API | — | in progress | core integration | Core `af39e3e`; Swift/Kotlin/JNI bindings; mobile native artifacts pending |
| PG-007 | Custom 3×3 plan, capture, preserve nine originals, stitch | PG-005, PG-006 | pending | scan shell | Source manifest, Core report, seam review |
| PG-008 | Background sharpness/features/matching during capture | PG-007 | pending | core integration | Timing and cancellation evidence |
| PG-009 | Persist/resume `ScanJob` | PG-007 | pending | scan shell | Restart/resume automated test and device journal |
| PG-010 | NxM and panorama modes from one `ScanPlan` | PG-007 | pending | scan shell/core | Planner tests and visual seam acceptance |
| PG-011 | Pocket 4P adapter and capability qualification | PG-005 | pending | camera shell | Physical-device evidence |
| PG-012 | 60mm maximum-resolution capture and pyramid viewer | PG-011, PG-010 | pending | shell/core | Original files, pyramid manifest, visual review |
| PG-013 | GPU-first mobile renderer: Metal/Vulkan compute with explicit CPU fallback | PG-006, PG-007 | in progress | shell/core | Requests default to `gpuPreferred`; needs same-manifest GPU quality diff, time, peak memory, thermal journal |

## Collaboration handoff

Agents should update the row they own, preserve IDs, and attach paths or
command output as evidence. Hardware claims require a dated physical journal.
When blocked, record the exact blocker and a safe next action. Keep this ledger
and `AGENTS.md` as the shared coordination surface.
