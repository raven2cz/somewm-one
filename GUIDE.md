# somewm-one Developer Guide

## What is somewm-one?

A reference configuration and widget framework for the [somewm](https://github.com/raven2cz/somewm)
Wayland compositor. It is not a personal dotfile — it is a curated starting
point that ships the same Lua contracts the upstream AwesomeWM user knows
(`client`, `tag`, `screen`, signals, `rc.lua`) plus a small opinionated
framework called **fishlive** for building themed, reactive widgets.

If you already write AwesomeWM configs, you are already 90% home: signals
fire the same way, `awful.*` is the same API, themes are `theme.lua`.
somewm-one adds:

- A 210-line `rc.lua` that is pure orchestration (no 1500-line tangle).
  All real work lives under `fishlive.config.*`.
- The **fishlive framework**: a broker/service/component pattern that makes
  widgets reactive without writing polling loops in every widget.
- First-class integration with [somewm-shell](../somewm-shell/), the
  Quickshell-based overlay shell (dashboard, dock, OSD, hot edges).

## Architecture

```
rc.lua (entry point, orchestration only)
│
├── awful / gears / wibox / naughty / beautiful   (upstream AwesomeWM API)
├── theme load
│
└── fishlive.config.*                             (all logic lives here)
    ├── keybindings.setup(args)    ─ explicit setup, takes args
    ├── menus.setup(args)          ─ explicit setup
    ├── screen.setup(args)         ─ per-screen wibar + wallpaper
    ├── rules.setup()              ─ ruled.client rules            ◄── runs first
    ├── titlebars.setup()          ─ request::titlebars handler    ◄── depends on rules
    ├── client_fixes.setup()       ─ per-client workarounds        ◄── depends on rules
    ├── shell_ipc.setup()          ─ pushes compositor state to somewm-shell
    ├── notifications              ─ naughty config (auto-init)
    └── recording                  ─ utility, no setup

fishlive framework
│
├── broker.lua         ─ pub/sub signal bus (data::cpu, data::volume, …)
├── services/*.lua     ─ producers; auto-register with broker on require
├── components/*.lua   ─ consumers; expose M.create(screen, config) → widget
├── factory.lua        ─ theme-aware widget resolver (theme → standard fallback)
├── service.lua        ─ base helpers for services
└── widget_helper.lua  ─ layout helpers for components
```

### Why a broker?

Widgets used to poll `/proc/stat` each on their own timer, which meant
every new CPU meter added a subprocess. The broker reverses the flow:

```text
[ Service (Producer) ] ──(reads /proc/stat on a single timer)
          │
          ▼
 broker.emit("data::cpu", { usage = 12 })
          │
          ├─► [ Consumer A (Wibar Widget) ]
          ├─► [ Consumer B (Dashboard Widget) ]
          └─► [ Consumer C (Notification) ]
```

One service feeds N widgets. Adding a second CPU meter costs zero extra
timers.

### Load-order invariant

`rc.lua` calls config modules in a deterministic order. The critical
invariant is:

```
rules.setup()  ──►  titlebars.setup()  &  client_fixes.setup()
```

`request::titlebars` fires **after** the rule engine has classified a new
client — so `titlebars` and `client_fixes` must be loaded after `rules`.
Everything else is order-independent. The test suite enforces this.

## The fishlive framework

### broker.lua — the signal bus

```lua
local broker = require("fishlive.broker")

-- emit
broker.emit("data::cpu", { usage = 42, temp = 58 })

-- subscribe
broker.subscribe("data::cpu", function(payload)
    update_widget(payload.usage)
end)

-- a producer registers itself once
broker.register_producer("data::cpu", function()
    -- return initial snapshot or nil
end)
```

Signals are best-effort and synchronous. Payloads are plain Lua tables.

### services (producers)

A service is a tiny module that polls or subscribes to *something* and
emits broker signals. Location: `fishlive/services/<name>.lua`.

```lua
-- fishlive/services/cpu.lua (skeleton)
local broker = require("fishlive.broker")
local timer = require("gears.timer")

local M = {}

local function snapshot() return { usage = read_proc_stat() } end

broker.register_producer("data::cpu", snapshot)

timer {
    timeout = 2,
    autostart = true,
    call_now = true,
    callback = function() broker.emit("data::cpu", snapshot()) end,
}

return M
```

Bootstrap: require `fishlive.services` once at startup — it loads the
registry which in turn requires every service module.

### components (consumers)

A component is a reusable widget with a single public contract:

```lua
M.create(screen, config) -> wibox.widget
```

- Reads nothing from globals.
- Subscribes to broker signals during `create`.
- Returns the widget; caller places it in the wibar.

Location: `fishlive/components/<name>.lua`. See `components/cpu.lua` for
a reference implementation.

### factory.lua — theme-aware resolver

When a wibar asks for "the CPU widget", `factory` looks first in the
current theme (`themes/<name>/widgets/cpu.lua`) and falls back to the
standard component (`fishlive/components/cpu.lua`). This lets themes
override individual widgets without forking the whole stack.

## Shell integration (somewm-shell)

### Shell → Lua (read state)

The shell pulls compositor state over `somewm-client eval`:

```qml
process.command = ["somewm-client", "eval",
  "return require('naughty').active[1] and 'yes' or 'no'"]
```

All such globals are namespaced:

```
awesome._shell_overlay         -- block tag-scroll while overlay is open
awesome._notif_history         -- persistent notification history
```

Never `_G.anything`. Defaults are set defensively in Lua
(`awesome._X = awesome._X or {}`) so a crashed shell that restarts does
not wedge the compositor.

### Lua → Shell (push events)

`shell_ipc.setup()` subscribes to `client::manage`, `tag::selected`,
`screen::focus` and forwards them to the shell:

```lua
awful.spawn({"qs", "ipc", "-c", "somewm", "call",
             "somewm-shell:compositor", "invalidate"})
```

The shell debounces and re-queries. This is a **push-to-invalidate**
pattern: compositor never sends the payload, just the event.

Full catalogue of handlers and globals:
[../somewm-shell/IPC.md](../somewm-shell/IPC.md)

## Themes

Themes live under `themes/<name>/`:

```
themes/default/
├── theme.lua                  # colours, fonts, icon sizes, widget params
├── background.jpg             # default wallpaper
├── icons/                     # theme-specific icons
├── widgets/                   # optional per-theme widget overrides
└── user-wallpapers/           # per-user wallpapers (git-ignored)
```

`theme.lua` is a plain Lua table. The compositor loads it via
`beautiful.init(path)`.

### Bridging to the shell

The shell reads the same theme via a JSON export:

```
theme.lua   ──  theme-export.sh  ──►  ~/.config/somewm/themes/<name>/theme.json
                                      │
                        watched by Core.Theme (Quickshell FileView)
                                      │
                                   all QML bindings auto-update
```

Run `theme-export.sh` whenever `theme.lua` changes. (The shell's
"Apply Theme" toggle calls it automatically after wallpaper changes.)

## Development workflow

### Edit → deploy → reload

```bash
# Edit source in the repo
vim plans/project/somewm-one/rc.lua

# Sync to ~/.config/somewm (preserves user-wallpapers/)
plans/project/somewm-one/deploy.sh

# Reload the live compositor (no window loss)
somewm-client reload
```

**Rule:** always edit in `plans/project/somewm-one/`. Never hand-edit
`~/.config/somewm/rc.lua` directly — `deploy.sh` overwrites it.

Dry-run to preview the sync:

```bash
plans/project/somewm-one/deploy.sh --dry-run
```

### Tests

```bash
# Unit tests (busted)
busted spec/

# Compositor-side integration tests (somewm repo)
make test
```

The shell's test suite (`../somewm-shell/tests/test-all.sh`) also exercises
the Lua ↔ Shell contract and the `.setup()` convention — run it after
changes that cross the boundary.

### Adding a new service

1. Create `fishlive/services/mysignal.lua`.
2. `broker.register_producer("data::mysignal", snapshot_fn)`.
3. Start a timer (or subscribe to an event source) that calls
   `broker.emit("data::mysignal", payload)`.
4. Register it by adding `require("fishlive.services.mysignal")` to
   `fishlive/services/init.lua`.
5. Add a full LDoc header per [STYLE.md](STYLE.md).

### Adding a new component

1. Create `fishlive/components/mywidget.lua`.
2. Implement `M.create(screen, config) -> wibox.widget`.
3. Subscribe to broker signals inside the `create` function to keep the widget reactive.
4. Use it from `fishlive/config/screen.lua` via `factory.create("mywidget", ...)`.
5. Add a full LDoc header per [STYLE.md](STYLE.md) outlining its public properties.

### Adding a keybinding

`fishlive/config/keybindings.lua` exposes `M.setup(args)`. Add your
binding there — do not put `awful.key` calls in `rc.lua`.

## Directory structure

```
plans/project/somewm-one/
├── rc.lua                  # 210-line entry point (orchestration only)
├── deploy.sh               # rsync → ~/.config/somewm
├── STYLE.md                # code conventions
├── GUIDE.md                # this file
├── anim_client.lua         # client animation glue (required early in rc.lua)
│
├── fishlive/               # framework
│   ├── init.lua            # optional re-export module
│   ├── broker.lua          # pub/sub signal bus
│   ├── factory.lua         # theme-aware widget resolver
│   ├── service.lua         # service base helpers
│   ├── widget_helper.lua   # widget/layout helpers
│   ├── menu.lua            # menu builder
│   ├── exit_screen.lua     # logout/shutdown overlay
│   │
│   ├── config/             # everything rc.lua calls .setup() on
│   │   ├── keybindings.lua
│   │   ├── menus.lua
│   │   ├── screen.lua
│   │   ├── rules.lua
│   │   ├── titlebars.lua
│   │   ├── client_fixes.lua
│   │   ├── shell_ipc.lua
│   │   ├── notifications.lua
│   │   └── recording.lua
│   │
│   ├── services/           # producers (broker signals)
│   │   ├── init.lua        # registry — requires each service
│   │   ├── cpu.lua         # data::cpu
│   │   ├── memory.lua      # data::memory
│   │   ├── gpu.lua         # data::gpu
│   │   ├── disk.lua        # data::disk
│   │   ├── network.lua     # data::network
│   │   ├── volume.lua      # data::volume (pipewire/wpctl)
│   │   ├── updates.lua     # data::updates (pacman)
│   │   ├── keyboard.lua    # data::keyboard (layout)
│   │   └── ...
│   │
│   ├── components/         # consumers (widget factories)
│   │   ├── cpu.lua
│   │   ├── memory.lua
│   │   ├── volume.lua
│   │   ├── layoutbox.lua
│   │   ├── notifications.lua
│   │   ├── clock.lua
│   │   └── ...
│   │
│   └── rubato/             # vendored animation library (unchanged)
│
├── layout-machi/           # vendored layout engine
│
├── themes/
│   └── default/            # reference theme (Gruvbox Material)
│
└── spec/                   # busted unit tests
```

## Quick reference

```bash
# Deploy
plans/project/somewm-one/deploy.sh

# Reload (from a running somewm session)
somewm-client reload

# Run unit tests
busted spec/

# Inspect live compositor state
somewm-client eval 'return #client.get()'
somewm-client eval 'return client.focus and client.focus.name or "none"'

# Check header lint
plans/scripts/check-headers.sh

# Theme export (Lua → JSON for somewm-shell)
bash ../somewm-shell/theme-export.sh
```

## Further reading

- [STYLE.md](STYLE.md) — file headers, module init, IPC naming
- [../somewm-shell/IPC.md](../somewm-shell/IPC.md) — Lua ↔ Shell contract
- [../somewm-shell/GUIDE.md](../somewm-shell/GUIDE.md) — the shell side
- Upstream AwesomeWM docs still apply for anything framework-level
  (`awful.*`, `gears.*`, `wibox.*`, `naughty.*`).
