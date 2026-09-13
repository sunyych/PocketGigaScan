---
title: Pocket 2 audit
description: What is known, what remains unverified, and how to capture Pocket 2 protocol evidence safely.
---

Pocket 2 support is an evidence-gathering profile, not a verified camera profile.
The repository does not yet contain a physical-device capture of its BLE model
id, new-format product type, live-view codec, DUML replies, or media storage
layout. Do not substitute Pocket 3 or Pocket 4 constants for those unknowns.

## Known without a protocol capture

- The camera is a Pocket-family body with a three-axis gimbal.
- Wireless operation requires the Do-It-All Handle.
- The camera has a built-in 3×3 panorama mode. This does not establish an app
  command for selecting or driving that mode.
- A name containing `Pocket2` resolves to the explicit
  `pocket2-unverified` profile. It is not marked hardware-verified.

The profile keeps codec and command capabilities `unknown`. Until captures say
otherwise, the app hides speculative tap-focus and focus-mode controls, offers
only 1× in the zoom cycle, and does not advertise HDR or log color choices.

## Physical audit checklist

Use a physical iPhone or Android phone and a Pocket 2 with the Do-It-All Handle.
Record firmware versions and test one operation at a time:

1. Save the raw BLE manufacturer payload and decoded classic model id or
   new-format product type.
2. Pair through `fff0` / `fff4` / `fff5`; record only status bytes from
   `07/45`, `07/07`, and `07/0e`.
3. Join the returned SoftAP and confirm the phone has a `192.168.2.x` address.
4. Open TCP `:7001`, then UDP `:9004`; record handshake/register/subscription
   replies.
5. Send the existing Pocket live preparation and one enable. Record the
   receiver, status, first NAL types, and whether the codec detector reports AVC
   or HEVC. Do not add a repeated enable loop.
6. Separately test gimbal recenter, one bounded stick movement, shutter, photo
   listing, and one download. Stop after any unsupported/bad-parameter reply.

Run the static checks before and after the audit. Physical proof must include a
dated redacted journal and a moving-picture observation.

## Redaction

Never commit camera Wi-Fi passwords, personal SSIDs, Bluetooth addresses,
captured media, or unredacted logs. Keep captures outside the repository.
Manufacturer payloads may identify hardware; redact device-specific bytes while
preserving the model/product-type positions needed for decoding.

## Exit criteria

Pocket 2 can become a verified profile only after the physical audit establishes
the advert identity, connection spine, live codec/enable sequence, gimbal
feedback and control, shutter result, and media list/download behavior.
Simulator and unit tests do not satisfy this requirement.
