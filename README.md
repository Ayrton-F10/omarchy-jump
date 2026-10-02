# omarchy-jump

A keyboard-driven window switcher for [Omarchy](https://omarchy.org), with a
workspace chip that announces every switch.

Two independent surfaces in one plugin:

- **Panel** — summoned with a keybind. Lists every workspace, and under each one
  every window on it. One flat cursor: <kbd>↑</kbd>/<kbd>↓</kbd> (or `j`/`k`) move,
  <kbd>⏎</kbd> focuses or switches, <kbd>esc</kbd> dismisses, and typing filters.
- **Chip** — a transient label on every workspace change, so you always know
  which category you just landed in.

Both read the same Hyprland state, which is why they live in one file: splitting
them would load that state twice per keystroke.

## Requirements

- Omarchy with the Quickshell shell
- Hyprland

## Install

```sh
git clone https://github.com/Ayrton-F10/omarchy-jump.git \
  ~/.config/omarchy/plugins/local.jump
omarchy-restart-shell
```

The directory name **must** be `local.jump` — it has to match the `id` in
`manifest.json`, because that is what the summon IPC resolves.

### Keybind

The panel is summoned over IPC. Pick a combo that is free on your machine:

```sh
omarchy-shell shell summon local.jump
```

In Hyprland's `.conf` format:

```conf
bind = SUPER SHIFT J, exec, omarchy-shell shell summon local.jump
unbind = SUPER SHIFT J
```

Or in the `.lua` format recent Omarchy uses:

```lua
hl.unbind("SUPER + SHIFT + J")
o.bind("SUPER + SHIFT + J", "Jump to window", "omarchy-shell shell summon local.jump")
```

The `unbind` matters. Stock Omarchy binds <kbd>SUPER</kbd>+<kbd>J</kbd> to a
dwindle-only toggle-split that does nothing under other layouts, and <kbd>SHIFT</kbd>
combinators often collide, so check `hyprctl binds` before picking.

> **Modmask gotcha:** `hyprctl binds -j` reports `SUPER + SHIFT` as `65` and
> `SUPER + CTRL` as `68` — the opposite of the obvious guess. Worth verifying
> against Omarchy's own bindings before assuming yours took.

## Configuration

The chip's look is driven by a block of properties near the top of the chip
surface in `Jump.qml`. All of them are plain QML — change them and restart the
shell.

| Property | Default | Effect |
| --- | --- | --- |
| `chipFontSize` | `Style.font.display` | Type size. Tracks your shell's font scale. |
| `chipOpacity` | `0.5` | Plate alpha. `0` means no plate at all. |
| `chipShadow` | `true` | Drop shadow behind the text. |
| `chipWidth` | `Style.space(340)` | Fixed width. Set `0` to hug the content. |
| `chipTopMargin` | `48` | Distance from the top of the screen. |
| `chipBorderWidth` | `0` | `0` is borderless. |
| `chipBorderColor` | `root.accentColor` | Border colour; defaults to the theme accent. |
| `chipRadius` | `root.cornerRadius` | Corner rounding. Use `chipHeight / 2` for a pill. |

Chip dwell time is the `interval` on `chipTimer` (1400ms).

Two notes on the defaults:

- **The shadow matters while the plate is transparent.** Foreground-coloured text
  over an arbitrary window is not reliably readable without it.
- **The border follows your theme accent**, so the chip re-colours itself when you
  switch themes. On a monochrome theme (e.g. `vantablack`, whose accent is
  `#8d8d8d`) that reads as grey — point `chipBorderColor` at a literal if you want
  saturation regardless of theme.

## Editing the plugin

**Restart the shell after every change: `omarchy-restart-shell`.**

The shell does hot-reload local plugins on file change, but that does not work
for this one. `manifest.json` sets `keepLoaded: true` — the chip has to stay
mounted to observe workspace changes — and the shell's documented behaviour for
a kept instance is that *"the kept instance is not replaced, so code changes to a
`keepLoaded` service itself only take effect on a shell restart."* In practice a
hot reload constructs a second root without destroying the first: both react to
the same workspace switch, both chips render at identical coordinates, and the
stale one paints on top. You will be debugging a ghost.

## Design notes

A few things that are easy to get wrong and are deliberate here:

- **Window matching uses `toplevel.wayland.appId`**, not the Hyprland toplevel's
  own fields. Quickshell's `HyprlandToplevel` has no populated `class` and its
  `name` is declared but never set, so both read as undefined. `appId` is the
  same source Omarchy's own ActiveWindow widget uses, and it is what lets
  `chrome` match a browser no matter what page is open.
- **The filter is a real `TextField`**, not a string built from key events.
  `PanelKeyCatcher` has no `Qt.Key_Backspace` branch, so a string-based filter
  receives backspace as `U+0008` and appends it verbatim — one tofu box per
  press, with no way to erase. A real field gives you backspace, delete, word
  deletion, Home/End and selection for free.
- **The chip is its own layer-shell surface with no input region**, rather than a
  notification. That is what lets it appear regardless of the notification
  service and therefore regardless of DND.

## Licence

MIT — see [LICENSE](LICENSE).