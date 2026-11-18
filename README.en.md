# SimPilot

[中文](README.md) | **English**

A CLI and menu bar app for iOS Simulator automation.

Related: [duo-verify-skill](https://github.com/peter6601/duo-verify-skill), a Claude Code skill that uses SimPilot to check screens on iPhone Duo.

- Read on-screen elements: label, role, frame.
- Tap buttons by label.
- Switch iPhone Duo poses and read the current pose back.
- Output JSON that [duo-verify](https://github.com/peter6601/duo-verify-skill)'s `duo_check.py` reads directly.

## Why

Goal: let an AI agent (such as Claude Code) drive the simulator from the terminal and check screens on its own.

Problems it solves:

- To judge a layout, an agent needs each button's coordinates. Screenshots alone are not precise enough.
- Xcode's built-in UI snapshot has no coordinates.
- Existing accessibility tools don't run on Xcode 27.2.
- A normal XCUITest relaunches the app, so the screen and state you navigated to are lost.
- Starting XCUITest for every command is slow: over 10 seconds each time.

How SimPilot works around them:

- It attaches to the app that is already running. No relaunch; it reads whatever screen is showing.
- The runner stays alive, so later reads take under 1 second.
- It taps by label and reports whether the screen changed, and which elements appeared, disappeared or moved.
- No usage limits. Run the same check as often as you like.
- Everything runs locally, and every command prints JSON for agents and scripts.

## How it helps on iPhone Duo

iPhone Duo is a foldable: it has an outer display, an inner display and a fold. One screen has to work in several poses and orientations.

Why manual testing is painful:

- Each screen has 9 combinations: book and open in 4 orientations each, plus closed.
- Device Hub's pose buttons sometimes swallow clicks, so a switch may not land.
- The hinge has hysteresis: at the same angle, either display may be lit.
- A button under the status bar, home indicator or fold is hard to spot by eye.

What SimPilot does for you:

- `duo pose` switches to closed, book or open from the terminal, confirms which display is lit, and clicks again if it didn't land.
- `duo hinge` reports the current pose, the lit display and the orientation.
- `elements` coordinates follow the current display and orientation, so you can check buttons against the fold and system areas directly.
- With [duo-verify](https://github.com/peter6601/duo-verify-skill), an agent can run the whole 9-cell matrix and report the problems in each cell.

## How it works

```
simpilot (CLI) ──Unix socket──▶ SimPilot.app (menu bar, owns the daemon)
                                   │ starts the runner with xcodebuild test-without-building when needed
                                   ▼
                     Resident XCUITest server in the simulator (Runner/) ──HTTP 127.0.0.1──
                     Attaches with XCUIApplication(bundleIdentifier:), never calls launch()
```

- The runner attaches to the running app and never restarts it.
- The first runner start takes about 15 seconds.
- After that, `elements` takes about 0.3–0.6 s and `tap` about 2 s.
- While the runner is up, it holds an xcodebuild process.
- It shuts down after 3 idle minutes (configurable from the menu bar).
- To build something else right away, run `simpilot stop` first.
- If the daemon is killed, the runner exits on its own after the idle time plus 60 seconds.

## Requirements

- macOS 14 or later.
- Xcode with an iOS 17 or later simulator runtime.
- Tested on Xcode 27.2 and iOS 27.2.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- `duo pose` also needs Accessibility permission; see below.

## Install

```sh
git clone https://github.com/peter6601/SimPilot.git
cd SimPilot
scripts/make-app.sh                  # builds build/SimPilot.app and build/simpilot
build/simpilot runner build          # builds the runner for the simulator
ln -s "$PWD/build/simpilot" /usr/local/bin/simpilot   # optional: put it on PATH
```

- Keep the cloned folder. The CLI finds the app and the runner there.
- So symlink it onto PATH instead of copying the binary.
- Use any directory on your PATH, such as `~/bin` or `~/.local/bin`.
- You can also drag `build/SimPilot.app` into `/Applications`.
- After changing `Runner/`, run `simpilot runner build` again.

Uninstall:

1. Run `simpilot stop`.
2. Delete the cloned folder and the symlink on your PATH.
3. Delete `~/Library/Application Support/SimPilot/` and `~/Library/Logs/SimPilot/`.

## Usage

- Boot the simulator and open the app you want to test first.
- SimPilot does not launch the app for you.
- Find the UDID with `xcrun simctl list devices booted`.

```sh
simpilot elements --udid <UDID> > out.json          # read elements
simpilot interact tap --label Settings --udid <UDID> # tap by label
simpilot status                                      # list running runners
simpilot stop                                        # stop runners and free xcodebuild

# iPhone Duo simulator only
simpilot duo pose book --udid <UDID>                 # closed | book | open
simpilot duo hinge --udid <UDID>
```

- The first CLI call opens SimPilot.app in the background; an icon appears in the menu bar.
- From the menu bar you can see runner status, stop runners and change the idle time.
- If the app isn't found, the CLI starts `simpilot daemon` in the background instead.
- Without `--bundle`, it picks the app in the simulator's foreground.

Before using `duo pose`:

1. Open Device Hub in Xcode and select this Duo simulator.
2. In System Settings → Privacy & Security → Accessibility, turn on the terminal you use.

## Output

`elements`:

- Format: `{"ok": true, "data": {"canvasSize": [w, h], "elements": [...]}}`.
- Each element has `id`, `label`, `role`, `frame`, `stableKey`, `identifier`, `parentId` and `value`.
- canvasSize and frame are in points, in the current interface orientation.
- Only visible elements are listed. Anything under a sheet or fullScreenCover is left out.

`interact tap`:

- Only hittable elements are tapped. With duplicate labels, buttons win.
- `tapped`: the element that was tapped.
- `screen_changed`: whether the screen changed.
- `appeared` / `disappeared`: labels that were added or removed.
- `moved`: labels whose position changed, such as two cards swapping places.
- `value_changed`: labels whose value changed.

Errors:

- Exit code 0 means success, 1 means failure.
- On failure, check the `error` field.
- Common ones: `app_not_running`, `app_not_foreground`, `not_found`, `not_hittable`.
- Runner-related: `runner_not_built`, `runner_exited`, `runner_timeout`.
- `xcodebuild_busy`: someone else's xcodebuild is running; the PID and command are included.

## Duo poses

`duo pose`:

- Clicks Closed / Partially Open / Open in Device Hub.
- Only these three fixed poses; no arbitrary angles.
- After switching, it checks which display is lit with `devicectl`.
- Closed should light the outer display; book and open should light the inner one.
- If it doesn't match, it clicks again, up to 3 times.
- Book goes to Open first, then Partially Open: going straight from Closed stays on the outer display.
- If Device Hub shows a different simulator, it returns `devicehub_wrong_device` and clicks nothing.
- Both commands run in the CLI process, not the daemon.

`duo hinge`:

- Returns `hinge_state`, `active_display` and `display_orientation`.
- `hinge_state` is `closed`, `partiallyOpen` or `openFlat`.
- **The angle is always null.**
- **The state is inferred:**
  - Outer display lit means closed.
  - Inner display lit: book vs open comes from the last pose SimPilot set.
  - If it can't tell, it returns `unknown`.
- The `source` field says how it was inferred.

Why the angle can't be read:

- `devicectl` has no hinge command.
- Only the foreground app receives `UIHingeInteraction` updates, and the runner is in the background.
- Device Hub doesn't show the angle.
- A private CoreDevice framework can read it, but that needs reverse engineering and isn't done.

## Not yet supported

- Screenshots: use `xcrun simctl io <UDID> screenshot` for now.
- Actions other than tap: swipe, type, long press.

## xcodebuild

- By default it goes through `~/.claude/skills/duo-verify/scripts/safe-xcodebuild.sh`.
- That script refuses to run while someone else's xcodebuild is running.
- Without it, SimPilot uses `xcrun xcodebuild`.
- To use another wrapper, set `SIMPILOT_XCODEBUILD`.

## Files

- `Sources/SimPilotCore`: Unix socket, daemon, runner lifecycle.
- `Sources/simpilot`: CLI.
- `Sources/SimPilotMenuBar`: menu bar app.
- `Runner/`: XCUITest server inside the simulator (XcodeGen project).
- `spikes/`: prototypes from the technical validation; not part of the app.
  - `ax-bridge` and `simapp-ax` use Apple private frameworks and are kept for reference only.
- Logs: `~/Library/Logs/SimPilot/`.
- Socket and runner build: `~/Library/Application Support/SimPilot/`.

## License

MIT. See [LICENSE](LICENSE).
