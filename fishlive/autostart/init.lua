---------------------------------------------------------------------------
--- fishlive.autostart — Wayland-native autostart for somewm.
--
-- Replaces the broken XDG-autostart pipeline with a declarative, gated,
-- supervised autostart system. Knows about Wayland/somewm-specific
-- session readiness (XWayland, tray, portal) so apps can wait for the
-- right surface to come up instead of racing the compositor.
--
-- Typical rc.lua usage:
--
--   local autostart = require("fishlive.autostart")
--   autostart.add{ name="nm-applet",  cmd={"nm-applet"},
--                  when={"ready::tray"} }
--   autostart.add{ name="blueman",    cmd={"blueman-applet"},
--                  when={"ready::tray","ready::portal"}, mode="respawn" }
--   autostart.add{ name="synology",   cmd={"synology-drive"},
--                  when={"ready::xwayland"}, retries=3 }
--   autostart.start_all()
--
-- IPC inspection from a separate terminal:
--
--   somewm-client eval 'local s = require("fishlive.autostart").status()
--      for n,e in pairs(s.entries) do print(n, e.state, e.pid or "-") end'
--
-- See plans/fishlive-autostart/plan.md for design + state machine.
--
-- @module fishlive.autostart
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local autostart = {}

local broker_mod    = require("fishlive.broker")
local entry_mod     = require("fishlive.autostart.entry")
local providers_mod = require("fishlive.autostart.providers")
local log_mod       = require("fishlive.autostart.log")

---------------------------------------------------------------------------
-- Module state
---------------------------------------------------------------------------

local state = {
	entries     = {},   -- name → Entry instance
	order       = {},   -- ordered list of names (registration order)
	started     = false,
	generation  = 0,
	deps        = {},
}

---------------------------------------------------------------------------
-- Hot-reload carryover for oneshot "done" state.
--
-- Without this, awesome.restart() rebuilds the Lua VM and the new
-- rc.lua's start_all() respawns every oneshot launcher even though the
-- detached child it forked is still alive in the OS. Apps with GTK
-- single-instance dedupe survive this; everything else gets duplicated
-- (synology-drive, anything that exec()s a separate daemon).
--
-- The set is persisted to a file in XDG_RUNTIME_DIR at compositor exit
-- and read back by start_all(), guarded by awesome._restart so a real
-- cold boot (or full process restart) still spawns oneshots normally.
-- A stale file from a crashed compositor is harmless: cold boot ignores
-- it, and the next exit overwrites it.
---------------------------------------------------------------------------

local DONE_LIST_FILENAME = "somewm-autostart-done.list"

local function done_list_path()
	local dir = os.getenv("XDG_RUNTIME_DIR")
	if not dir or dir == "" then return nil end
	return dir .. "/" .. DONE_LIST_FILENAME
end

local function default_load_done_set()
	local path = done_list_path()
	if not path then return {} end
	local f = io.open(path, "r")
	if not f then return {} end
	local out = {}
	for line in f:lines() do
		if line ~= "" then out[line] = true end
	end
	f:close()
	return out
end

local function default_save_done_set(names)
	local path = done_list_path()
	if not path then return end
	local f = io.open(path, "w")
	if not f then return end
	for n in pairs(names) do f:write(n, "\n") end
	f:close()
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function build_deps_for(spec)
	-- log.new throws on missing name; spec validation guarantees it.
	local writer
	if spec.log == false then
		writer = nil
	elseif type(spec.log) == "string" then
		writer = log_mod.new{ name = spec.name, path = spec.log }
	else
		writer = log_mod.new{ name = spec.name }
	end

	-- Real timer module; tests inject through autostart._set_deps.
	local timer = state.deps.timer or require("gears.timer")

	return {
		broker = state.deps.broker or broker_mod,
		timer  = timer,
		spawn  = state.deps.spawn or require("fishlive.autostart.spawn"),
		log    = writer,
		now    = state.deps.now,
	}
end

local function validate(spec)
	assert(spec, "autostart.add requires a spec table")
	assert(type(spec.name) == "string" and spec.name ~= "", "spec.name required")
	assert(spec.cmd ~= nil, "spec.cmd required")
	if state.entries[spec.name] then
		error(string.format("autostart: duplicate entry name %q", spec.name), 2)
	end
	if spec.mode and spec.mode ~= "oneshot" and spec.mode ~= "respawn" then
		error(string.format("autostart: invalid mode %q", spec.mode), 2)
	end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Register an entry. Does NOT start it -- call autostart.start_all() once.
--
-- @tparam table spec See plan.md §5 for the full field list. Required:
--   name (string), cmd (string|table). Optional: when, mode, retries,
--   delay, timeout, log, env, replace, disabled, backend.
function autostart.add(spec)
	validate(spec)
	local e = entry_mod.new{
		spec = spec,
		deps = build_deps_for(spec),
	}
	state.entries[spec.name] = e
	state.order[#state.order + 1] = spec.name

	-- Pre-warm D-Bus watchers for any gate that needs one. This way watchers
	-- come up at registration time, not when start_all() runs -- matches the
	-- broker sticky-cache promise.
	for _, gate in ipairs(spec.when or {}) do
		local dbus_name = providers_mod.dbus_name_for_gate(gate)
		if dbus_name then providers_mod.request_dbus_name(dbus_name) end
	end

	-- If start_all() already ran (entry registered late), schedule it now.
	if state.started then e:start() end
end

--- Start the scheduler. Call once at the end of rc.lua.
-- Idempotent: subsequent calls are no-ops.
function autostart.start_all()
	if state.started then return end
	state.started = true
	state.generation = state.generation + 1

	-- Setup providers if a host has not done it (idempotent inside).
	local awesome_caps = state.deps.awesome or _G.awesome
	providers_mod.setup{
		broker = state.deps.broker or broker_mod,
		deps = { awesome = awesome_caps },
	}

	-- Hot-reload carryover: skip oneshot entries that already completed
	-- in the previous Lua VM. Cold boot has awesome._restart == nil so
	-- the file is ignored and oneshots run as expected.
	local done_set = {}
	if awesome_caps and awesome_caps._restart then
		local load_fn = (state.deps.persist and state.deps.persist.load_done_set)
			or default_load_done_set
		local ok, set = pcall(load_fn)
		if ok and type(set) == "table" then done_set = set end
	end

	for _, name in ipairs(state.order) do
		local e = state.entries[name]
		if e then
			if done_set[name] and e.spec.mode == "oneshot" then
				e._state = "done"
				if e._deps.log then
					pcall(function()
						e._deps.log:event{
							state = "done",
							attempt = 0,
							reason = "hot_reload_carryover",
						}
					end)
				end
			else
				e:start()
			end
		end
	end

	-- Hook compositor exit to gracefully stop respawn-mode entries.
	if awesome_caps and awesome_caps.connect_signal then
		awesome_caps.connect_signal("exit", function()
			autostart._on_exit()
		end)
	end
end

--- Restart an entry. Only valid for entries in the failed state -- for
-- everything else use stop() + start_all().
--
-- @tparam string name
-- @treturn boolean true if the entry was restarted, false otherwise
-- @treturn[2] string error message
function autostart.restart(name)
	local e = state.entries[name]
	if not e then return false, "no such entry: " .. tostring(name) end
	return e:restart()
end

--- Stop an entry: SIGTERM the process (if running), discard gates,
-- and transition back to pending. Re-running start_all() (or calling
-- restart_pending entries' restart) re-engages it.
function autostart.stop(name)
	local e = state.entries[name]
	if not e then return false, "no such entry: " .. tostring(name) end
	e:stop()
	return true
end

--- Take a status snapshot of all registered entries.
-- See plan.md §5.1 for the return shape.
function autostart.status()
	local broker = state.deps.broker or broker_mod
	local out = {
		generation = state.generation,
		ready = {
			["ready::somewm"]   = broker.get_value("ready::somewm")   == true,
			["ready::xwayland"] = broker.get_value("ready::xwayland") == true,
			["ready::tray"]     = broker.get_value("ready::tray")     == true,
			["ready::portal"]   = broker.get_value("ready::portal")   == true,
		},
		entries = {},
	}
	for name, e in pairs(state.entries) do
		out.entries[name] = e:snapshot()
	end
	return out
end

--- Return the registration list in declaration order.
-- Useful for IPC pretty-printers that want a stable iteration order.
function autostart.list()
	local out = {}
	for i, name in ipairs(state.order) do out[i] = name end
	return out
end

---------------------------------------------------------------------------
-- Internal hooks
---------------------------------------------------------------------------

-- Batched shutdown grace, in seconds. Runs once for the whole respawn
-- set instead of once per entry, so a fork with N respawn entries does
-- not multiply the compositor exit latency by N.
local SHUTDOWN_GRACE_SECONDS = 2

function autostart._on_exit()
	-- Persist done-oneshot names so the next Lua VM's start_all() can
	-- skip them on hot reload (see start_all comment). Best-effort: a
	-- failed write just means the new VM will respawn the launcher,
	-- which is the same as without this feature.
	local done_names = {}
	for name, e in pairs(state.entries) do
		if e.spec.mode == "oneshot" and e._state == "done" then
			done_names[name] = true
		end
	end
	local save_fn = (state.deps.persist and state.deps.persist.save_done_set)
		or default_save_done_set
	pcall(save_fn, done_names)

	-- Phase 1: synchronous SIGTERM to every respawn entry. Collect the
	-- PIDs we still need to verify so we can poll them in a single grace
	-- loop instead of blocking serially per entry.
	local pending = {}
	for _, e in pairs(state.entries) do
		if e.spec.mode == "respawn" then
			local ok, pid = pcall(e.shutdown_term, e)
			if ok and pid then
				pending[#pending + 1] = { entry = e, pid = pid }
			end
		end
	end

	-- Phase 2: single shared grace poll. Bail out early if everyone
	-- exited cleanly under SIGTERM.
	if #pending > 0 then
		local spawn_mod = state.deps.spawn or require("fishlive.autostart.spawn")
		local deadline = os.time() + SHUTDOWN_GRACE_SECONDS
		while os.time() < deadline do
			local alive = false
			for _, p in ipairs(pending) do
				if spawn_mod.is_alive(p.pid) then alive = true; break end
			end
			if not alive then break end
			os.execute("sleep 0.1")
		end

		-- Phase 3: SIGKILL stragglers. shutdown_kill performs the
		-- ownership check (entry still owns the same PID) so a child
		-- that exited cleanly during grace cannot be confused with a
		-- recycled PID.
		for _, p in ipairs(pending) do
			pcall(p.entry.shutdown_kill, p.entry, p.pid)
		end
	end

	pcall(providers_mod.shutdown)
end

--- Test override: inject deps before any add()/start_all() calls.
-- Cleared by autostart._reset().
function autostart._set_deps(deps) state.deps = deps or {} end

--- Test reset: nuke all entries + state. Does NOT reset the broker;
-- the spec is responsible for that.
function autostart._reset()
	state.entries    = {}
	state.order      = {}
	state.started    = false
	state.generation = 0
	state.deps       = {}
	pcall(providers_mod.shutdown)
end

return autostart
