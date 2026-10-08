# Flows & CI

An agent session is exploratory and costs tokens. A flow file is the same run,
replayed deterministically with no model in the loop. It costs nothing to run
again.

## The format

A `.flow` file is **one testa command per line**. There is no DSL and no YAML
schema; anything `testa help` lists works. The only extras are `#` comments and
three directives: `@name`, `@timeout <ms>` (default timeout for `wait` steps) and
`@require <bundle>`.

```text
# examples/native/smoke.flow
@name smoke
@timeout 8000
@require com.testa.showcase.native

launch com.testa.showcase.native
wait "#status"
tap "#tapButton"
assert "tap:" exists
clear "#textInput"
setvalue "#textInput" hello
assert #status label=typed:hello
appearance dark                       # app must survive the trait change
wait "typed:hello"
assert #status label=typed:hello
appearance light
dragdrop "#dragHandle" "#zoneB"
assert #dropResult "label=dropped on zoneB"
```

## Record instead of write

You rarely write flows by hand. Let the agent explore, then save what it did:

```bash
testa flow record start              # the agent drives the app normally from here
…                                    # tap, type, assert — whatever it takes
testa flow record save smoke.flow    # pure reads are filtered out; actions are kept
```

## Run

```bash
testa flow run smoke.flow --junit results.xml --artifacts artifacts/
testa matrix "iPhone 17 Pro,iPad Pro,iPhone SE (3rd generation)" -- flow run smoke.flow
```

`flow run` exits 0 only if every step passed. On failure it saves a bundle from
the moment it broke: `screenshot.png`, `ui-full.txt`, `see.txt`, `logs.txt`,
`crashes.txt` and `summary.txt`. `matrix` runs each device in parallel against
its own warm daemon and merges the JUnit output.

## GitHub Action

```yaml
# .github/workflows/e2e.yml
name: iOS E2E
on: [push, pull_request]

jobs:
  e2e:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - run: xcodebuild -scheme MyApp -sdk iphonesimulator -derivedDataPath dd build
      - uses: valewnrt/testa@v0.2.2
        with:
          flows: "e2e/**/*.flow"
          device: "iPhone 17 Pro"
```

| Input | Default | |
|---|---|---|
| `flows` | `**/*.flow` | glob or space-separated list of flow files |
| `device` | `iPhone 17 Pro` | simulator name or UDID |
| `install` | `brew` | `brew` (tap + install) or `source` (build from the checked-out repo) |
| `artifact-name` | `testa-artifacts` | name of the uploaded artifact |

The action installs testa, boots the device, runs the flows with
`--junit testa-results.xml --artifacts testa-artifacts`, and always uploads
both. See [`action.yml`](../action.yml).
