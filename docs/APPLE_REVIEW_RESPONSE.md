# Apple App Store Review Response Template

## Context

This response was drafted January 2025 after Apple rejected the Mac build while approving the identical iOS build. The rejection asked about game content rights.

---

## Response to App Review Questions

Thank you for your review. I'm happy to clarify these points. Note that this same build was approved for iOS, so I believe this is simply a matter of providing additional context.

**1) Are the games available directly in the app or do users have to download them separately?**

The app does not contain any game disk images. It contains no disk images at all, and no ROM either: what is in the bundle is the emulator and its interface. The app is a CP/M emulator that runs the open-source RomWBW system software. Users access optional content through the Settings page, which presents a curated list of disk images. These are downloaded on-demand, when the user selects them, from my own GitHub repository at https://github.com/avwohl/romwbw_disks, where I build and publish them.

The RomWBW ROM the emulator boots is downloaded from that same repository, in the same way, and is checked against the SHA-256 that repository publishes for it before the app will run it. A first launch therefore needs a network connection, for the ROM and for a disk alike. The ROM Attestation document covers the ROMs in detail.

**2) How do users obtain the games and does the app include instructions?**

The Settings page provides a simple interface where users can browse and select from the curated disk library. Each disk has a description. When selected, the disk image is automatically downloaded and mounted. No external steps are required—the entire process happens within the app. The Help section explains how to use the emulator and access disk content.

**3) Do you have the rights to the files for the games listed?**

Yes. All disk images in the curated library are either:

a) **Original works I created** - such as the sample programs and demonstrations

b) **RomWBW project content** - sourced from https://github.com/wwarthen/RomWBW which is licensed under GPLv3 (see: https://github.com/wwarthen/RomWBW/blob/master/LICENSE). This explicitly grants rights to use and distribute. I build the disk images the app offers from that content myself and publish them at https://github.com/avwohl/romwbw_disks, which is the only place the app downloads disk images and ROMs from.

The specific text adventures mentioned (Zork, Adventure, Hitchhiker's Guide) are freely distributable versions that have been included in the RomWBW project's distribution for years. These are well-known public domain or freely distributable versions from the CP/M era that the retro-computing community has preserved and shared.

**Previous Attestation Reference**

I previously submitted a ROM Attestation document during review which affirms my rights to this content. It has been updated for this build: the app no longer includes a ROM in its bundle, so the attestation now covers the ROMs the app downloads and verifies. The RomWBW system software (GPLv3) and all disk content are either my original work or properly licensed open-source material.

I'm the same developer for both the iOS and Mac versions. The iOS version using identical content was approved. I'm happy to provide any additional documentation needed.

---

## Key Links for Future Reference

- RomWBW License: https://github.com/wwarthen/RomWBW/blob/master/LICENSE
- RomWBW Project: https://github.com/wwarthen/RomWBW
- ROMs and disk images the app downloads, and their source: https://github.com/avwohl/romwbw_disks
- ROM Attestation: See `docs/ROM_ATTESTATION.md` in this repo

## Notes

- Character count of the response section: 3,102, measured 2026-09-08 over the
  text from "Thank you for your review" to the end of the last paragraph before
  the Key Links rule, Markdown included (Apple limit is 4000)
- iOS was approved with same content, Mac was rejected - inconsistent review
