# somewm-one — Claude Code Project Guide

## What this repo is

User-facing AwesomeWM-style configuration for the [somewm](https://github.com/raven2cz/somewm)
Wayland compositor — a single `rc.lua`, themes, layout-machi plugin, and the
`fishlive/` config modules (rules, titlebars, client_fixes, shell_ipc).

This is the **release copy** — edit here, deploy to `~/.config/somewm/`.

## User & environment

- **User:** Antonín Fischer (raven2cz)
- **OS:** Arch Linux
- **Compositor:** somewm (raven2cz fork of `trip-zip/somewm`)
- **Shell:** [somewm-shell](https://github.com/raven2cz/somewm-shell) (Quickshell/QML)
- **Sibling fork checkout:** `~/git/github/somewm` (override with `SOMEWM_FORK_PATH`)

## Lines: v2 (main) and v1 (legacy/v1)

`main` targets **somewm 2.x** (the fork's v2 line, upstream 2.1 + thin delta,
since 2026-10-24). The config for the v1 compositor (SceneFX, wlroots 0.19,
`anim_client.lua`) is frozen on `legacy/v1` / tag `v1-legacy`. Deploy the
line that matches the installed compositor. What changed for 2.x and why:
`~/git/github/somewm/plans/v2/README.md`.

2.x uses wlroots 0.20.2, GLES2/pixman and Clay rendering. Client corners use
`client.shape`; shadows use upstream's nine-patch renderer through
`beautiful.shadow_*`. There is no blur.

2.x notes that bite: no `awesome.start_animation` (animations are theme keys,
see `fishlive/config/animations.lua`); a function
`bgimage` is not drawn; a markup with several fonts is drawn in its first
run's font (use `widget_helper.create_runs`).

Nested test sessions: `SOMEWM_NO_AUTOSTART=1` skips the session daemons,
`SOMEWM_NO_SHELL=1` keeps rc.lua from (re)launching Quickshell.

## Edit / deploy / reload cycle

```bash
# 1. Edit rc.lua / themes / fishlive modules in this repo
vim rc.lua

# 2. Deploy to active config (rsyncs to ~/.config/somewm)
./deploy.sh

# 3. Reload running compositor (no window loss)
somewm-client reload
```

`deploy.sh --dry-run` previews the rsync without writing.

**Rule:** Never hand-edit `~/.config/somewm/rc.lua` directly — `deploy.sh`
overwrites it.

## Path coupling

This repo is co-developed with the somewm fork and somewm-shell. Runtime
references to sibling repos use env-var overrides:

- `SOMEWM_FORK_PATH` — defaults to `$HOME/git/github/somewm` (used by `deploy.sh`
  for `somewm-snapshot.sh`)
- `SOMEWM_SHELL_PATH` — defaults to `$HOME/git/github/somewm-shell` (used by
  `rc.lua` for `theme-export.sh`)

If `theme-export.sh` is absent, `rc.lua` skips theme export and just relaunches
Quickshell — somewm-shell ships a baseline `theme.default.json`.

## Tests

```bash
# unit tests (busted for Lua 5.1 is not on PATH on Arch):
lua5.1 /usr/lib/luarocks/rocks-5.1/busted/2.3.0-1/bin/busted \
    --helper=spec/preload.lua --lpath='?.lua;?/init.lua' spec/
# header lint lives in the somewm fork (override path with SOMEWM_FORK_PATH):
bash "${SOMEWM_FORK_PATH:-$HOME/git/github/somewm}/plans/scripts/check-headers.sh"
```

## Commit style

Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`. Co-author
trailer for AI-assisted commits:

```
Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

## Communication

Komunikuj s uživatelem česky. Commity, kód, komentáře a docs zůstávají anglicky.
