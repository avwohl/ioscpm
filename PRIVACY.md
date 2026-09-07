# Privacy Policy

**Z80CPM** is an open source CP/M emulator for iOS and macOS.

## Data Collection

This app does **not** collect, store, or transmit any personal data.

## Network Usage

The app connects to GitHub and to nothing else. Everything it fetches is a
public release asset, requested from `github.com` and served, after GitHub's
own redirect, from `release-assets.githubusercontent.com`. There are five
kinds of request:

- **The release index**, `index-v0.json`, from
  `github.com/avwohl/romwbw_disks`. It lists the RomWBW releases on offer.
- **The catalog of the release you have selected**, from the same repository.
  It names every ROM and disk image that release publishes, with a size and a
  SHA-256 for each.
- **That release's ROM.** The app bundles no ROM, so the machine you boot is
  one of the published ones and it is downloaded like anything else.
- **The disk images you choose to download**, again from that release.
- **The in-app help index and the help articles you open**, from
  `github.com/avwohl/ioscpm`.

Nothing else is fetched. These are plain HTTPS GETs of public release assets -
no account, no identifier and no user data is sent, beyond the request itself
and whatever your network stack normally includes (your IP address and the URL
being requested).

Builds older than this one - including the one currently on the App Store -
fetch the same kinds of thing from an older place: a catalog named `disks.xml`
and the disk images beside it, published on a release of
`github.com/avwohl/ioscpm` rather than of `romwbw_disks`, and no ROM at all,
because those builds carry one inside the app. Different files on the same
host, requested the same way, carrying nothing about you either.

## Local Storage

Everything the app downloads or remembers (the ROM, disk images, the release
index and catalogs, cached help articles, settings and preferences) is stored
locally on your device in the app's private container. This data is not
accessible to other apps and is not transmitted anywhere.

## Analytics

This app does not include any analytics, tracking, or advertising frameworks.

## Third-Party Services

This app does not use any third-party services that collect user data.

## Contact

If you have questions about this privacy policy, please open an issue at:
https://github.com/avwohl/ioscpm/issues

## Changes

This privacy policy may be updated occasionally. Changes will be posted to this repository.

*Last updated: September 2026*
