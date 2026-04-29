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
busted spec/                              # unit tests for fishlive modules
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
