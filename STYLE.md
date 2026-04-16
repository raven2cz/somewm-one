# Style Guide — somewm-one

Code conventions for the `somewm-one` reference configuration and the
`fishlive` framework. New files stay consistent by following this document.

## File headers (Lua)

Every file under `fishlive/` (except vendored `rubato/` and `layout-machi/`)
and every `themes/*/theme.lua` gets a full LDoc header:

```lua
---------------------------------------------------------------------------
--- <One-line purpose>.
--
-- <2–4 lines: what the module exposes, how it is consumed, any init
-- convention (auto-init-on-require vs .setup()).>
--
-- @module fishlive.<path>
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------
```

**Services** (`fishlive/services/*.lua`) additionally document the broker
signal they emit, the payload shape, and the poll interval (or
`event-driven`):

```
-- Signal: data::<name> — { field1, field2, ... }
-- Interval: Ns (or event-driven).
```

**Components** (`fishlive/components/*.lua`) document the single public
contract `M.create(screen, config) -> wibox.widget` with `@tparam` /
`@treturn` tags.

`rc.lua` is the only exception — it carries the project signature header
(raven ASCII + project tagline) instead of an LDoc block.

## Module init conventions

### Config (`fishlive/config/*.lua`)

All config modules export `M.setup(args)` and are called explicitly from
`rc.lua`. **No side effects at require time.** Each `setup()` is idempotent,
guarded by:

```lua
if M._initialized then return end
M._initialized = true
```

so `somewm-client reload` is safe.

**Load order is a property of `rc.lua`, not of `require` ordering.** The
critical invariant is:

```text
rc.lua execution flow:
  │
  ├─► rules.setup()        (Must run first: defines matching criteria)
  │
  ├─► titlebars.setup()    (Relies on rules being active for classification)
  ├─► client_fixes.setup() (Relies on rules being active for workarounds)
  │
  └─► (other modules)      (Order-independent)
```

`titlebars` and `client_fixes` attach `request::titlebars` /
`property::*` handlers that assume the rule set is already registered.
This invariant is covered by the test suite (`tests/test-all.sh` — section
"Config Module Init Convention").

Utility modules (e.g. `recording.lua`, `menu.lua`) are not signal-connecting
and just export a table of functions — no `setup()`.

### Services (`fishlive/services/*.lua`)

Services auto-register with `broker.register_producer()` on require.
Bootstrap by requiring the `fishlive.services` registry once at startup.
Services should never read or write to any global other than `broker`.

### Components (`fishlive/components/*.lua`)

Components **never run code at require time**. They expose exactly one
public function:

```lua
M.create(screen, config) -> wibox.widget
```

Configuration is passed in; nothing is read from global state. See
`fishlive/factory.lua` for the theme-aware widget resolver that wires
components to services.

## IPC conventions (Lua → Shell)

Every cross-boundary call goes through:

```
qs ipc -c somewm call somewm-shell:<module> <method> [args]
```

- `<module>` names are flat (no dashes in the module slot).
- Handlers live in a single QML owner file on the shell side.
- Payloads are small and typed — no multi-line eval, no dynamic code
  construction from user input.
- Globals the shell reads or writes are namespaced as `awesome._<name>`
  (never bare `_G.name`).

The authoritative catalogue of handlers and globals lives in the shell
project: [`../somewm-shell/IPC.md`](../somewm-shell/IPC.md).

## Verification

```
plans/scripts/check-headers.sh
```

Minimum-viable grep lint for header presence across Lua and QML. Re-run
after adding new files.
