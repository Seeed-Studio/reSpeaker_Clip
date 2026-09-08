# Contributing

Thanks for contributing to the reSpeaker Clip firmware.

## Build

Code must compile with **zero warnings**. Verify both variants before
submitting (NCS v3.3.0 workspace required — see the README
[Installing the toolchain](README.md#installing-the-toolchain) section):

```sh
# Debug build (console + SD log)
west build --build-dir build-clip --pristine --board clip/nrf5340/cpuapp applications/clip

# Production build (low-power, console off)
west build --build-dir build-clip-prod --pristine --board clip/nrf5340/cpuapp applications/clip \
  -- -DSNIPPET_ROOT=$(pwd)/applications/clip -DSNIPPET=production
```

## Commits

- Do **not** add `Co-Authored-By` trailers to commit messages.
- Keep commits focused; fix all compiler warnings before committing.

## Documentation

Update docs together with the code they describe. [docs/README.md](docs/README.md)
is the documentation map — add new docs there and check the "single source of
truth" table: update the owning file for a fact class, not just the summary.

## Testing

- Python suite: `cd applications/clip/tests && pytest`
  (see [applications/clip/tests/docs/testing.md](applications/clip/tests/docs/testing.md))
- Hardware test firmware: build and flash `tests/clip` per
  [tests/clip/README.md](tests/clip/README.md)

## Mobile

Changes under `mobile/` follow [mobile/CONTRIBUTING.md](mobile/CONTRIBUTING.md).

## Releases

Releasing is tag-driven — see [docs/release_process.md](docs/release_process.md).
The release notes file must exist before tagging.
