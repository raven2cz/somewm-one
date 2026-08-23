# somewm-one Developer Guide

## What is somewm-one?

A reference configuration and widget framework for the [somewm](https://github.com/raven2cz/somewm)
Wayland compositor. It is not a personal dotfile - it is a curated starting
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
client, so `titlebars` and `client_fixes` must be loaded after `rules`.
Everything else is order-independent. The test suite enforces this.

## The fishlive framework

### broker.lua: the signal bus

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

Bootstrap: require `fishlive.services` once at startup - it loads the
registry which in turn requires every service module.

### Event-driven services

Polling is the wrong shape when the thing you are watching can tell you it
changed. `fishlive.service` takes an `event_cmd`: a long-running process whose
every stdout line is a change notification.

```lua
service.new {
    signal          = "data::spotify",
    event_cmd       = { "stdbuf", "-oL", "playerctl", "--follow", ... },
    event_parser    = parse,   -- the line already carries the payload
    command         = METADATA_CMD,  -- initial state, and the backstop
    parser          = parse,
    safety_interval = 5,
}
```

Two options shape what happens per event:

- **`event_parser`** parses the event line straight into data. Use it when the
  stream already carries everything; it saves spawning `command` on every
  change. Without it, each event re-runs `command` instead (what
  `services/volume.lua` does with `pactl subscribe`, since the subscribe
  stream only says *that* something changed).
- **`safety_interval`** adds a slow backstop poll alongside the events, for
  transitions the stream cannot be relied on to report. Spotify uses it for
  the player disappearing.

Three traps, all of which cost real debugging time and are worth knowing
before you write the next one:

1. **Buffering.** A program writing to a pipe rather than a terminal usually
   switches to block buffering, so the first line arrives and everything after
   it sits in a 4 KB buffer until it fills. Symptom: the widget updates once
   and then only ever via the backstop poll. Run the command under
   `stdbuf -oL`.
2. **Deduplicating sources.** `playerctl --follow` prints only when its
   *formatted output changes*. A `{{status}}` template therefore says nothing
   when one playing track follows another. Make the template carry enough to
   differ on every change you care about - which usually means carrying the
   whole payload, at which point `event_parser` is free.
3. **Teardown.** The child process must be killed when the Lua state is torn
   down, or every reload leaks one. `broker.stop_all()` runs from the
   compositor's `exit` signal and `service:stop()` uses `awesome.kill`, a
   direct syscall - an async `kill` never gets its turn of the event loop
   during teardown.

When something is slow or erratic, measure the stages rather than guessing:
time the underlying tool on its own, then log when event lines arrive versus
when data is emitted. Spotify's own MPRIS latency is ~60 ms; anything much
above that was ours.

### components (consumers)

A component is a reusable widget with a single public contract:

```lua
M.create(screen, config) -> wibox.widget
```

- Reads nothing from globals.
- Subscribes to broker signals during `create`.
- Returns the widget; caller places it in the wibar.

Location: `fishlive/components/<name>.lua`. See `components/cpu.lua` for
a reference implementation, and `components/spotify.lua` for one that hides
itself when it has nothing to show, scrolls text that does not fit, and takes
mouse input.

A component that hides itself just sets `widget.visible`. `factory.widget_bar`
mirrors that onto the separator drawn after it, so a hidden widget does not
leave a stray `│` on an empty stretch of bar. If the widget runs an animation,
pause it while hidden - `spotify.lua` pauses its scroll container - or an
invisible widget keeps a timer alive for nothing.

### factory.lua: theme-aware resolver

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
vim rc.lua

# Sync to ~/.config/somewm (preserves user-wallpapers/)
./deploy.sh

# Reload the live compositor (no window loss)
somewm-client reload
```

**Rule:** always edit in this repo. Never hand-edit
`~/.config/somewm/rc.lua` directly - `deploy.sh` overwrites it.

Dry-run to preview the sync:

```bash
./deploy.sh --dry-run
```

### Tests

```bash
# Unit tests (busted)
busted spec/

# Compositor-side integration tests (somewm repo)
make test
```

The shell's test suite (`../somewm-shell/tests/test-all.sh`) also exercises
the Lua ↔ Shell contract and the `.setup()` convention - run it after
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
binding there - do not put `awful.key` calls in `rc.lua`.

### Adding an autostart entry

`fishlive.autostart` replaces the broken `xdg-desktop-autostart.target`
pipeline (and naive `awful.spawn.once`) with a Wayland-aware scheduler:
gates on `ready::*` broker signals, retry+backoff supervision, per-entry
logs, IPC status, and hot-reload carryover for oneshot launchers.

In `rc.lua`:

```lua
local autostart = require("fishlive.autostart")

autostart.add{
    name = "nm-applet",
    cmd  = { "nm-applet" },
    mode = "respawn",
}

autostart.add{
    name = "blueman-applet",
    cmd  = { "blueman-applet" },
    when = { "ready::tray" },          -- wait for tray protocol
    mode = "respawn",
}

autostart.add{
    name = "synology-drive",
    cmd  = { "synology-drive" },
    when = { "ready::xwayland" },      -- wait for XWayland to be live
    mode = "oneshot",                  -- launcher forks daemons, exits 0
}

-- Wake lazy XWayland once before start_all() so ready::xwayland fires.
awful.spawn.easy_async({ "xprop", "-root", "_NET_SUPPORTED" }, function() end)

autostart.start_all()
```

Decision tree for new entries:

- **`mode`**: does the program stay alive (`"respawn"`) or fork+exit
  (`"oneshot"`, default)?
- **`when`**: `"ready::tray"` for system tray icons, `"ready::xwayland"`
  for X11 clients, `"ready::portal"` for portal-dependent apps,
  `"ready::somewm"` for anything touching the compositor protocol.
- **`delay`**: seconds to wait after gates pass; useful for staggering.
- **`retries`**: overrides default (oneshot 1, respawn -1/infinite).

Inspect at runtime:

```bash
somewm-client eval '
  local s = require("fishlive.autostart").status()
  for n, e in pairs(s.entries) do
      print(n, e.state, e.pid or "-", "attempts=" .. e.attempts)
  end'

somewm-client eval 'return require("fishlive.autostart").restart("nm-applet")'
somewm-client eval 'return require("fishlive.autostart").stop("nm-applet")'
```

Logs land in `$XDG_STATE_HOME/somewm/autostart/<name>.log` (rotated at
1 MiB).

Full reference (state machine, gate evaluation, hot-reload protocol,
shutdown phases, provider bridge): [../../docs/fishlive-autostart.md](../../docs/fishlive-autostart.md).

## Directory structure

```

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
│   ├── autostart/          # Wayland-native autostart (replaces XDG)
│   │   ├── init.lua        # public API + scheduler + hot-reload
│   │   ├── entry.lua       # per-entry state machine
│   │   ├── providers.lua   # ready::* signal bridge (compositor + D-Bus)
│   │   ├── spawn.lua       # spawn backends
│   │   └── log.lua         # per-entry log file with rotation
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
./deploy.sh

# Reload (from a running somewm session)
somewm-client reload

# Run unit tests
busted spec/

# Inspect live compositor state
somewm-client eval 'return #client.get()'
somewm-client eval 'return client.focus and client.focus.name or "none"'

# Check header lint (script lives in the somewm fork)
bash "${SOMEWM_FORK_PATH:-$HOME/git/github/somewm}/plans/scripts/check-headers.sh"

# Theme export (Lua → JSON for somewm-shell)
bash "${SOMEWM_SHELL_PATH:-$HOME/git/github/somewm-shell}/theme-export.sh"
```

## Further reading

- [STYLE.md](STYLE.md) - file headers, module init, IPC naming
- [../somewm-shell/IPC.md](../somewm-shell/IPC.md) - Lua ↔ Shell contract
- [../somewm-shell/GUIDE.md](../somewm-shell/GUIDE.md) - the shell side
- Upstream AwesomeWM docs still apply for anything framework-level
  (`awful.*`, `gears.*`, `wibox.*`, `naughty.*`).
