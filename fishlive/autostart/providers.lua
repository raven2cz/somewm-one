---------------------------------------------------------------------------
--- Readiness providers for fishlive.autostart.
--
-- Bridges compositor signals and D-Bus name ownership into the
-- `fishlive.broker` "ready::*" namespace so autostart entries can gate on
-- a single uniform mechanism.
--
-- Signals produced:
--   ready::somewm           — emitted when somewm.c reaches steady state
--   ready::xwayland         — emitted when xwayland.c finishes EWMH init
--   ready::dbus:<name>      — emitted when a D-Bus session bus name is
--                             owned (and `false` when it vanishes)
--   ready::tray             — alias for ready::dbus:org.kde.StatusNotifierWatcher
--   ready::portal           — alias for ready::dbus:org.freedesktop.portal.Desktop
--
-- Important: providers emit through `broker.emit_signal()` directly. They
-- do NOT call `broker.register_producer()` because the broker tears down
-- a registered producer when the last consumer disconnects -- that would
-- kill the D-Bus watchers as soon as all entries finished gating.
--
-- The single shared session bus connection is opened at module load time
-- via `Gio.bus_get` (async). All requested D-Bus name watches register
-- inside the bus-acquired callback so the broker's sticky cache always
-- has a real producer behind it once the bus comes up.
--
-- @module fishlive.autostart.providers
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local providers = {}

-- Aliases: short name → canonical D-Bus well-known name.
local DBUS_ALIASES = {
	tray   = "org.kde.StatusNotifierWatcher",
	portal = "org.freedesktop.portal.Desktop",
}

-- Reverse map: canonical name → list of alias broker keys to also emit on.
-- Built once at first request_dbus_name call.
local function alias_keys_for(name)
	local out = {}
	for alias, full in pairs(DBUS_ALIASES) do
		if full == name then out[#out + 1] = "ready::" .. alias end
	end
	return out
end

---------------------------------------------------------------------------
-- Module state
---------------------------------------------------------------------------

local state = {
	broker         = nil,           -- fishlive.broker (or fallback via require)
	bus_connection = nil,           -- Gio.DBusConnection or nil until bus_get fires
	watch_ids      = {},            -- name → watcher id
	pending_names  = {},            -- names requested before bus_connection ready
	compositor_bridged = false,     -- one-time guard for the awesome.connect_signal calls
	deps           = {},            -- injected for tests
}

-- Resolve the broker even if providers.setup() has not been called yet.
-- request_dbus_name() can be invoked from autostart.add() before start_all()
-- runs setup(), and a D-Bus name that is already owned will fire `appeared`
-- as soon as the watcher registers. Without a fallback the early emit gets
-- silently dropped and gates would only fire on the next ownership change.
local function resolve_broker()
	if state.broker then return state.broker end
	local ok, broker = pcall(require, "fishlive.broker")
	if ok then
		state.broker = broker
		return broker
	end
	return nil
end

local function broker_emit(name, value)
	local broker = resolve_broker()
	if not broker then return end
	broker.emit_signal(name, value)
end

---------------------------------------------------------------------------
-- D-Bus name watcher
---------------------------------------------------------------------------

local function emit_for_name(canonical, value)
	broker_emit("ready::dbus:" .. canonical, value)
	for _, alias_key in ipairs(alias_keys_for(canonical)) do
		broker_emit(alias_key, value)
	end
end

local function watch_name(canonical)
	if state.watch_ids[canonical] then return end  -- already watching

	local Gio = state.deps.Gio or require("lgi").Gio
	local GObject = state.deps.GObject or require("lgi").GObject

	local appeared = function(_conn, _name)
		emit_for_name(canonical, true)
	end
	local vanished = function(_conn, _name)
		emit_for_name(canonical, false)
	end

	local id = Gio.bus_watch_name_on_connection(
		state.bus_connection,
		canonical,
		Gio.BusNameWatcherFlags.NONE,
		GObject.Closure(appeared),
		GObject.Closure(vanished))
	state.watch_ids[canonical] = id
end

---------------------------------------------------------------------------
-- Compositor signal bridge
---------------------------------------------------------------------------

local function bridge_compositor()
	if state.compositor_bridged then return end
	state.compositor_bridged = true

	local awesome_caps = state.deps.awesome or _G.awesome
	if not awesome_caps then return end

	awesome_caps.connect_signal("somewm::ready", function()
		broker_emit("ready::somewm", true)
	end)
	awesome_caps.connect_signal("xwayland::ready", function()
		broker_emit("ready::xwayland", true)
	end)

	-- Replay cached values for the case where the C side already fired the
	-- signal before this module loaded (the C-side flag persists across hot
	-- reload; awesome.somewm_ready / awesome.xwayland_ready expose it).
	if awesome_caps.somewm_ready then
		broker_emit("ready::somewm", true)
	end
	if awesome_caps.xwayland_ready then
		broker_emit("ready::xwayland", true)
	end
end

---------------------------------------------------------------------------
-- Bus acquisition
---------------------------------------------------------------------------

local function on_bus_acquired(connection)
	state.bus_connection = connection
	-- Drain pending watches.
	local todo = state.pending_names
	state.pending_names = {}
	for canonical in pairs(todo) do
		watch_name(canonical)
	end
end

local function ensure_bus()
	if state.bus_connection then return end
	if state._bus_get_inflight then return end
	state._bus_get_inflight = true

	local Gio = state.deps.Gio or require("lgi").Gio
	-- Synchronous form is simpler and matches what awful.statusnotifierwatcher
	-- and awful.systray already do at module load time. Async would be nicer
	-- but `bus_get` requires a callback wired into the GLib main loop and
	-- gains us nothing here -- this runs once at autostart init.
	local conn, err = Gio.bus_get_sync(Gio.BusType.SESSION, nil)
	state._bus_get_inflight = false
	if not conn then
		io.stderr:write(string.format(
			"[autostart.providers] failed to acquire session bus: %s\n",
			tostring(err)))
		return
	end
	on_bus_acquired(conn)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Initialize providers with deps.
-- Call once from fishlive.autostart.init.setup().
--
-- @tparam table opts
--   broker (table)  fishlive.broker module (required)
--   deps   (table)  Optional: { Gio, GObject, awesome } overrides for tests
function providers.setup(opts)
	assert(opts and opts.broker, "providers.setup requires opts.broker")
	state.broker = opts.broker
	state.deps   = opts.deps or {}
	state.compositor_bridged = false  -- allow re-bridging after hot reload

	bridge_compositor()
end

--- Request a D-Bus name watcher.
-- Resolves short aliases ("tray", "portal") into their canonical names.
-- May be called before the bus is acquired -- the request will be queued
-- and registered once `Gio.bus_get_sync` completes.
--
-- @tparam string name "tray", "portal", or a fully-qualified well-known name.
function providers.request_dbus_name(name)
	assert(name, "request_dbus_name requires a name")
	local canonical = DBUS_ALIASES[name] or name

	if state.bus_connection then
		watch_name(canonical)
	else
		state.pending_names[canonical] = true
		ensure_bus()
		-- ensure_bus is synchronous on success; if it succeeded it already
		-- drained pending_names. If it failed (nil conn), the request stays
		-- queued and a future setup() call could retry.
	end
end

--- Translate a "ready::*" gate name into the underlying D-Bus name watch
-- requirement, if any. Used by autostart.add() to lazily start watchers
-- only for gates that are actually used.
--
-- Returns the canonical D-Bus name to watch, or nil if the gate is not
-- D-Bus backed (e.g. ready::somewm).
function providers.dbus_name_for_gate(gate)
	-- ready::tray, ready::portal → resolve via alias map
	local alias = gate:match("^ready::([^:]+)$")
	if alias and DBUS_ALIASES[alias] then
		return DBUS_ALIASES[alias]
	end
	-- ready::dbus:org.foo.bar → strip prefix
	local explicit = gate:match("^ready::dbus:(.+)$")
	if explicit then return explicit end
	return nil
end

--- Tear down all watchers + bus connection.
-- Called from awesome::exit and autostart.reload() to avoid leaking
-- closures across Lua VM rebuilds.
function providers.shutdown()
	local Gio = state.deps.Gio or require("lgi").Gio
	for name, id in pairs(state.watch_ids) do
		pcall(Gio.bus_unwatch_name, id)
		state.watch_ids[name] = nil
	end
	state.watch_ids = {}
	state.pending_names = {}
	state.bus_connection = nil
	state.compositor_bridged = false
end

-- Test hooks
providers._state = state
providers._DBUS_ALIASES = DBUS_ALIASES

return providers
