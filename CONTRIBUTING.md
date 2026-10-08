# Contributing to Testa

Thanks for helping. Bug reports, Xcode-compatibility reports, docs fixes and
pull requests are all welcome.

- **Found a bug?** [Open an issue](https://github.com/valewnrt/testa/issues/new/choose)
  with `testa version`, your Xcode version and the output of `testa layout`.
- **Have a question or an idea?** Use [Discussions](https://github.com/valewnrt/testa/discussions).
- **Security issue?** See [SECURITY.md](SECURITY.md); please don't file it publicly.
- **Looking for something to work on?** Check
  [good first issues](https://github.com/valewnrt/testa/labels/good%20first%20issue).

For anything larger than a small fix, open an issue first so we can agree on
the approach before you spend time on it.

## Dev setup

You need macOS with Xcode 26 and a booted iOS 26 simulator.

```bash
git clone https://github.com/valewnrt/testa && cd testa
make build      # debug build
make test       # unit tests (swift test)
make showcase   # build + launch the SwiftUI showcase on the booted sim
make e2e        # gesture regression suite against the showcase
```

Drive the simulator with the debug build: `./.build/debug/testa ui`.

Source layout and architecture are described in
[docs/architecture.md](docs/architecture.md).

## Pull requests

- `make test` passes.
- `make e2e` passes against the native showcase (needs a booted simulator).
- **Zero third-party runtime dependencies.** Only Apple frameworks that ship
  with Xcode, plus `xcrun simctl`.
- New commands get a line in `testa help`, [docs/commands.md](docs/commands.md)
  and, if agents should use them, the skill at `skills/testa/SKILL.md`.
- User-visible changes get an entry under `Unreleased` in
  [CHANGELOG.md](CHANGELOG.md).
- Match the surrounding style; comments explain *why*, not *what*.

By contributing you agree that your work is licensed under the
[MIT License](LICENSE). Everyone taking part is expected to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Releasing (maintainers)

1. Update `CHANGELOG.md`, then `git tag -a vX.Y.Z && git push --tags`.
2. `./release.sh` builds the universal, signed and notarized zip; attach it to
   the GitHub release.
3. Update `url` and `sha256` in `Formula/testa.rb` (see the checklist at the top
   of that file), here and in the `homebrew-testa` tap.
4. Bump the version in `npm/package.json`, `server.json` and
   `.claude-plugin/plugin.json`, publish npm and the MCP registry entry.
