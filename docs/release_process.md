# Release Process

This page documents how firmware releases are built, what artifacts are
produced, and the tag + CI procedure. It is the human-facing counterpart of the
"Output Firmware" notes in `CLAUDE.md`.

## Versioning

- The app version lives in **`applications/clip/VERSION`** (Zephyr
  `VERSION`-file format: `VERSION_MAJOR/MINOR/PATCHLEVEL/TWEAK`). Zephyr's
  build turns it into `APP_VERSION_STRING` (surfaced in
  `build-clip/clip/zephyr/include/generated/zephyr/app_version.h`); there is no
  `git describe` involvement and no repo-root `VERSION` file.
- The release workflow (`.github/workflows/release.yml`) derives the release
  version from the **tag name** (`GITHUB_REF_NAME`, e.g. `v0.1.0` → `0.1.0`),
  not from the VERSION file. **Bump `applications/clip/VERSION` to match the
  tag before tagging** so the firmware-embedded version and the release agree.

## Build variants

Two images per release, both sysbuilds (MCUboot + app core + ipc-radio):

| Variant | Build dir | Console | Purpose |
|---------|-----------|---------|---------|
| Debug | `build-clip` | UART console + SD log (`/SD:/LOG`, INF) | Development, field debugging |
| Production | `build-clip-prod` | Console off (low idle power, ~170µA) | Battery/production builds |

```sh
# Debug
west build --build-dir build-clip --pristine --board clip/nrf5340/cpuapp applications/clip

# Production (app-dir snippets are auto-discovered under NCS v3.3.0;
# CI additionally passes -DSNIPPET_ROOT="$(pwd)/applications/clip")
west build --build-dir build-clip-prod --pristine --board clip/nrf5340/cpuapp applications/clip \
  -- -DSNIPPET=production
```

(`SNIPPET_ROOT` must be an absolute path.)

## Artifacts (8 per release)

| Artifact | Source | Purpose / who uses it |
|----------|--------|----------------------|
| `clip-$V-debug-merged.hex` | `build-clip/merged.hex` | J-Link flash of everything (MCUboot + app + netcore) for a debug unit |
| `clip-$V-debug-merged_CPUNET.hex` | `build-clip/merged_CPUNET.hex` | Network-core image (rarely flashed alone) |
| `clip-$V-debug-ota.zip` | `build-clip/dfu_application.zip` | MCUboot OTA/mcumgr DFU package (BLE OTA / USB serial DFU), debug variant |
| `clip-$V-debug-signed.bin` | `build-clip/clip/zephyr/zephyr.signed.bin` | Signed app binary, debug variant (manual slot-1 staging) |
| `clip-$V-production-merged.hex` | `build-clip-prod/merged.hex` | Production full-image J-Link flash |
| `clip-$V-production-merged_CPUNET.hex` | `build-clip-prod/merged_CPUNET.hex` | Production network-core image |
| `clip-$V-production-ota.zip` | `build-clip-prod/dfu_application.zip` | Production OTA package |
| `clip-$V-production-signed.bin` | `build-clip-prod/clip/zephyr/zephyr.signed.bin` | Production signed app binary |

## Publishing a release

1. Bump `applications/clip/VERSION` to the new `X.Y.Z` and commit.
2. **Create `docs/release_notes/vX.Y.Z.md`** — CI fails the release if this
   file does not exist at tag time.
3. Commit, then tag and push:

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

CI (`.github/workflows/release.yml`) then automatically:
- builds both variants (debug + production),
- exports the 8 artifacts above,
- creates the GitHub Release with the release notes file as the body.

### Fixing a botched release

If a release comes out wrong (bad artifact, missing fix), do **not** stack a
fix-up release. Immediately: delete the tag and the GitHub Release, correct the
commit, then re-tag from the corrected commit and force-push the tag. The
release workflow rebuilds everything from the tag, so this produces a clean
replacement release:

```sh
git push origin :refs/tags/vX.Y.Z        # delete remote tag
gh release delete vX.Y.Z --yes           # delete the release
# ... fix the commit(s), including applications/clip/VERSION if needed
git tag -f vX.Y.Z <corrected-commit>
git push origin vX.Y.Z
```

## Manual local export (local-dev equivalent of CI)

```sh
VERSION=$(grep APP_VERSION_STRING build-clip/clip/zephyr/include/generated/zephyr/app_version.h | cut -d'"' -f2)
mkdir -p output/$VERSION

# Debug
cp build-clip/merged.hex            output/$VERSION/clip-$VERSION-debug-merged.hex
cp build-clip/merged_CPUNET.hex     output/$VERSION/clip-$VERSION-debug-merged_CPUNET.hex
cp build-clip/dfu_application.zip   output/$VERSION/clip-$VERSION-debug-ota.zip
cp build-clip/clip/zephyr/zephyr.signed.bin output/$VERSION/clip-$VERSION-debug-signed.bin
# Production
cp build-clip-prod/merged.hex            output/$VERSION/clip-$VERSION-production-merged.hex
cp build-clip-prod/merged_CPUNET.hex     output/$VERSION/clip-$VERSION-production-merged_CPUNET.hex
cp build-clip-prod/dfu_application.zip   output/$VERSION/clip-$VERSION-production-ota.zip
cp build-clip-prod/clip/zephyr/zephyr.signed.bin output/$VERSION/clip-$VERSION-production-signed.bin
```

## Appendix: CI internals

`.github/workflows/firmware.yml` builds the clip app on every push/PR to
`main`. It installs the **Zephyr SDK 0.17.0** toolchain + **NCS v3.3.0 (Zephyr
v4.3)** source via `west` (the `nrfutil toolchain-manager` subcommand was
deprecated and removed, and the standalone pc-nrfutil binary has no toolchain
install — the old CI failed on `nrfutil self-upgrade`/`install` for exactly
this reason). It installs both `zephyr/scripts/requirements-base.txt` and
`nrf/scripts/requirements.txt` (the nrf one is required for image-signing deps
like `cryptography`; the *base* zephyr file is used instead of the full
`requirements.txt` because the full one pulls `requirements-extras.txt` →
`spsdk`, whose git `#egg=` deps make pip backtrack through every
`setuptools_scm` version and hang), applies the MCUboot patches
(idempotent `git apply --check` loop), and `west build`s the sysbuild.
Compilation check only; verified locally in a clean `ubuntu:22.04` container.
