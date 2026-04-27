---------------------------------------------------------------------------
--- Tests for fishlive.autostart (state machine + scheduler + log + backoff)
---
--- Run: busted --helper='plans/project/somewm-one/spec/preload.lua' \
---             --lpath='plans/project/somewm-one/?.lua;plans/project/somewm-one/?/init.lua' \
---             plans/project/somewm-one/spec/autostart_spec.lua
---------------------------------------------------------------------------

package.path = "./plans/project/somewm-one/?.lua;./plans/project/somewm-one/?/init.lua;" .. package.path

---------------------------------------------------------------------------
-- Mock helpers (recreated per test in before_each)
---------------------------------------------------------------------------

local function fresh_broker()
	local b = { _values = {}, _subs = {} }
	function b.get_value(name) return b._values[name] end
	function b.emit_signal(name, value)
		b._values[name] = value
		for _, fn in ipairs(b._subs[name] or {}) do fn(value) end
	end
	function b.connect_signal(name, fn)
		b._subs[name] = b._subs[name] or {}
		table.insert(b._subs[name], fn)
		if b._values[name] ~= nil then fn(b._values[name]) end
		return function()
			for i, f in ipairs(b._subs[name] or {}) do
				if f == fn then table.remove(b._subs[name], i); break end
			end
		end
	end
	return b
end

local function fresh_timer()
	local t = { _pending = {} }
	function t.start_new(seconds, fn)
		local handle = {
			_delay = seconds,
			_fn = fn,
			stop = function(self) self._cancelled = true end,
		}
		table.insert(t._pending, handle)
		return handle
	end
	function t.fire_one()
		local h = table.remove(t._pending, 1)
		if h and not h._cancelled then h._fn() end
		return h
	end
	function t.fire_all()
		while #t._pending > 0 do t.fire_one() end
	end
	function t.pending_count()
		local n = 0
		for _, h in ipairs(t._pending) do
			if not h._cancelled then n = n + 1 end
		end
		return n
	end
	return t
end

local function fresh_spawn()
	local s = {
		_calls    = {},      -- argv tables
		_signals  = {},      -- "TERM:1234" etc.
		_next_pid = 1000,
		_alive    = {},      -- pid → bool
	}
	function s.backend_for() return s._backend end
	function s.send_signal(pid, sig)
		table.insert(s._signals, sig .. ":" .. tostring(pid))
		if sig == "KILL" or sig == "TERM" then s._alive[pid] = nil end
	end
	function s.is_alive(pid) return s._alive[pid] == true end
	function s._backend(opts)
		table.insert(s._calls, { cmd = opts.cmd, env = opts.env })
		if s._fail_next then
			s._fail_next = nil
			return nil, s._fail_msg or "spawn failed"
		end
		local pid = s._next_pid
		s._next_pid = s._next_pid + 1
		s._alive[pid] = true
		s._last_exit = opts.on_exit
		s._last_pid = pid
		return pid
	end
	return s
end

local function fresh_log()
	local l = { _events = {}, path = "/tmp/test.log" }
	function l:event(fields)
		table.insert(l._events, fields)
	end
	function l:stream(stream, line) end
	function l:note(text) end
	return l
end

local function load_module()
	package.loaded["fishlive.autostart.log"] = nil
	package.loaded["fishlive.autostart.entry"] = nil
	package.loaded["fishlive.autostart.spawn"] = nil
	package.loaded["fishlive.autostart.providers"] = nil
	package.loaded["fishlive.autostart"] = nil
	package.loaded["fishlive.broker"] = nil
end

---------------------------------------------------------------------------
-- log
---------------------------------------------------------------------------

describe("autostart.log", function()
	local log

	before_each(function()
		load_module()
		log = require("fishlive.autostart.log")
	end)

	it("formats microsecond timestamps as ISO-8601 with milliseconds", function()
		-- 1714152319418000 us = 2024-04-26 19:25:19.418 UTC
		local ts = log._format_ts(1714152319418000)
		assert.matches("^2024%-04%-26T%d%d:25:19%.418[%+%-]%d%d%d%d$", ts)
	end)

	it("renders fields in stable order", function()
		local s = log._format_fields({
			pid = 99, attempt = 2, state = "running", custom = "x",
			gates = { "ready::a", "ready::b" },
		})
		-- state then attempt then pid then gates then custom (alpha)
		assert.are.equal("state=running attempt=2 pid=99 gates=ready::a,ready::b custom=x", s)
	end)

	it("rotates the per-entry log when it exceeds 1 MiB", function()
		local renames, removes, opened = {}, {}, {}
		local writer = log.new{
			name = "rotateme",
			deps = {
				now_us      = function() return 0 end,
				mkdir_p     = function() end,
				file_size   = function() return log._ROTATE_BYTES + 1 end,
				rename      = function(a, b) table.insert(renames, a .. "→" .. b) end,
				remove      = function(p)    table.insert(removes, p) end,
				open_append = function(p)
					table.insert(opened, p)
					return { write = function() end, close = function() end }
				end,
			},
		}
		writer:event({ state = "starting" })
		-- Aggregate log gets rotated AFTER per-entry; both rotate the same way.
		assert.is_true(#renames >= 2)  -- one shift for per-entry, one for aggregate
		assert.is_true(#opened >= 2)
	end)
end)

---------------------------------------------------------------------------
-- spawn
---------------------------------------------------------------------------

describe("autostart.spawn", function()
	local spawn

	before_each(function()
		load_module()
		spawn = require("fishlive.autostart.spawn")
	end)

	it("normalizes string cmd to sh -c argv", function()
		local argv = spawn._to_argv("echo hi", nil)
		assert.are.same({ "sh", "-c", "echo hi" }, argv)
	end)

	it("passes table cmd through verbatim", function()
		local argv = spawn._to_argv({ "blueman-applet", "--debug" }, nil)
		assert.are.same({ "blueman-applet", "--debug" }, argv)
	end)

	it("merges env via env -i prefix", function()
		local argv = spawn._to_argv({ "x" }, { K = "v" })
		assert.are.equal("env", argv[1])
		assert.are.equal("K=v", argv[2])
		assert.are.equal("x", argv[3])
	end)

	it("returns nil + err string on spawn failure", function()
		local fake_aspawn = {
			with_line_callback = function() return "no such binary" end,
		}
		local pid, err = spawn.awful_backend{
			cmd = { "/nope" },
			deps = { spawn = fake_aspawn },
		}
		assert.is_nil(pid)
		assert.are.equal("no such binary", err)
	end)

	it("returns numeric pid + nil err on success", function()
		local fake_aspawn = {
			with_line_callback = function() return 4242 end,
		}
		local pid, err = spawn.awful_backend{
			cmd = { "ok" },
			deps = { spawn = fake_aspawn },
		}
		assert.are.equal(4242, pid)
		assert.is_nil(err)
	end)
end)

---------------------------------------------------------------------------
-- entry — state machine
---------------------------------------------------------------------------

describe("autostart.entry", function()
	local entry, broker, timer, spawn, log

	local function make_entry(spec)
		return entry.new{
			spec = spec,
			deps = {
				broker = broker, timer = timer, spawn = spawn, log = log,
				now    = function() return broker._now or 0 end,
			},
		}
	end

	before_each(function()
		load_module()
		broker = fresh_broker()
		timer  = fresh_timer()
		spawn  = fresh_spawn()
		log    = fresh_log()
		package.loaded["fishlive.autostart.spawn"] = spawn
		entry = require("fishlive.autostart.entry")
	end)

	it("transitions gated → starting → running when single gate already true", function()
		broker.emit_signal("ready::somewm", true)
		local e = make_entry{ name = "x", cmd = { "x" }, when = { "ready::somewm" }, delay = 0 }
		e:start()
		assert.are.equal("running", e:state())
		assert.are.equal(1000, e:pid())
		assert.are.equal(1, #spawn._calls)
	end)

	it("waits in gated until all gates fire (multi-gate)", function()
		broker.emit_signal("ready::a", true)
		local e = make_entry{ name = "y", cmd = { "y" }, when = { "ready::a", "ready::b" }, delay = 0 }
		e:start()
		assert.are.equal("gated", e:state())
		broker.emit_signal("ready::b", true)
		assert.are.equal("running", e:state())
	end)

	it("starts immediately if gate fires AFTER add (broker late-join)", function()
		local e = make_entry{ name = "z", cmd = { "z" }, when = { "ready::late" }, delay = 0 }
		e:start()
		assert.are.equal("gated", e:state())
		broker.emit_signal("ready::late", true)
		assert.are.equal("running", e:state())
	end)

	it("transitions to failed after gate timeout", function()
		local e = make_entry{ name = "to", cmd = { "to" }, when = { "ready::never" }, timeout = 5, delay = 0 }
		e:start()
		assert.are.equal("gated", e:state())
		timer.fire_all()
		assert.are.equal("failed", e:state())
	end)

	it("respawns after process exit (respawn mode, retries=-1)", function()
		broker.emit_signal("ready::somewm", true)
		local e = make_entry{ name = "r", cmd = { "r" }, mode = "respawn", retries = -1, delay = 0 }
		e:start()
		assert.are.equal("running", e:state())
		spawn._last_exit("exit", 0)
		assert.are.equal("restart_pending", e:state())
		assert.are.equal(1, timer.pending_count())
	end)

	it("transitions oneshot retries=1 to failed after spawn failure", function()
		broker.emit_signal("ready::somewm", true)
		spawn._fail_next = true
		spawn._fail_msg = "no such file"
		local e = make_entry{ name = "fb", cmd = { "/nope" }, mode = "oneshot", delay = 0 }
		e:start()
		assert.are.equal("failed", e:state())
	end)

	it("respawn schedules backoff matching min(base*2^(n-1), 60)", function()
		broker.emit_signal("ready::somewm", true)
		local e = make_entry{ name = "bo", cmd = { "x" }, mode = "respawn", retries = -1, delay = 2 }
		e:start()
		-- delay > 0 schedules a delay timer before the spawn; fire it.
		timer.fire_all()
		assert.are.equal("running", e:state())
		broker._now = 1
		spawn._last_exit("exit", 0)  -- attempt 1 → 2 * 2^0 = 2
		local h = timer._pending[1]
		assert.are.equal(2, h._delay)
	end)

	it("resets attempt counter after process stays alive >= 60 s", function()
		broker.emit_signal("ready::somewm", true)
		broker._now = 0
		local e = make_entry{ name = "lr", cmd = { "x" }, mode = "respawn", retries = -1, delay = 1 }
		e:start()
		timer.fire_all()  -- consume delay timer to reach running
		assert.are.equal(1, e._attempts)
		broker._now = 65
		spawn._last_exit("exit", 0)
		assert.are.equal(0, e._attempts)
	end)

	it("disabled entry stays in pending after start()", function()
		broker.emit_signal("ready::somewm", true)
		local e = make_entry{ name = "off", cmd = { "off" }, disabled = true }
		e:start()
		assert.are.equal("pending", e:state())
		assert.are.equal(0, #spawn._calls)
	end)

	it("ignores gate re-emission while running", function()
		broker.emit_signal("ready::somewm", true)
		local e = make_entry{ name = "f", cmd = { "x" }, when = { "ready::somewm" }, mode = "oneshot", delay = 0 }
		e:start()
		assert.are.equal("running", e:state())
		assert.are.equal(1, #spawn._calls)
		broker.emit_signal("ready::somewm", true)  -- flap
		assert.are.equal(1, #spawn._calls)         -- no relaunch
	end)

	it("stop() sigterms running entry and returns it to pending", function()
		broker.emit_signal("ready::somewm", true)
		local e = make_entry{ name = "s", cmd = { "x" }, mode = "respawn", delay = 0 }
		e:start()
		local pid = e:pid()
		e:stop()
		assert.are.equal("pending", e:state())
		assert.is_nil(e:pid())
		local found = false
		for _, sig in ipairs(spawn._signals) do
			if sig == "TERM:" .. tostring(pid) then found = true end
		end
		assert.is_true(found)
	end)

	it("oneshot exit=0 lands in done (launcher contract)", function()
		broker.emit_signal("ready::somewm", true)
		local e = make_entry{ name = "ok", cmd = { "x" }, mode = "oneshot", delay = 0 }
		e:start()
		assert.are.equal("running", e:state())
		spawn._last_exit("exit", 0)
		assert.are.equal("done", e:state())
		assert.are.equal(0, e._exit_code)
	end)

	it("oneshot exit!=0 still goes to failed (retries=1 default)", function()
		broker.emit_signal("ready::somewm", true)
		local e = make_entry{ name = "ko", cmd = { "x" }, mode = "oneshot", delay = 0 }
		e:start()
		spawn._last_exit("exit", 1)
		assert.are.equal("failed", e:state())
	end)

	it("respawn exit=0 is NOT terminal -- still walks retry path", function()
		broker.emit_signal("ready::somewm", true)
		local e = make_entry{ name = "rsp", cmd = { "x" }, mode = "respawn", retries = -1, delay = 0 }
		e:start()
		assert.are.equal("running", e:state())
		spawn._last_exit("exit", 0)
		assert.are.equal("restart_pending", e:state())
	end)

	it("restart() from done re-engages a oneshot launcher", function()
		broker.emit_signal("ready::somewm", true)
		local e = make_entry{ name = "redo", cmd = { "x" }, mode = "oneshot", delay = 0 }
		e:start()
		spawn._last_exit("exit", 0)
		assert.are.equal("done", e:state())
		assert.is_true(e:restart())
		assert.are.equal("running", e:state())
	end)

	it("restart() from failed resets attempts and re-enters gated", function()
		broker.emit_signal("ready::somewm", true)
		spawn._fail_next = true
		local e = make_entry{ name = "rs", cmd = { "x" }, mode = "oneshot", delay = 0 }
		e:start()
		assert.are.equal("failed", e:state())
		assert.are.equal(1, e._attempts)
		spawn._fail_next = nil
		assert.is_true(e:restart())
		-- Gate is already satisfied, so it transitions through → running
		assert.are.equal("running", e:state())
		assert.are.equal(1, e._attempts)  -- restart resets to 0, then start_starting bumps to 1
	end)
end)

---------------------------------------------------------------------------
-- providers
---------------------------------------------------------------------------

describe("autostart.providers", function()
	local providers

	before_each(function()
		load_module()
		providers = require("fishlive.autostart.providers")
	end)

	it("resolves alias names for known aliases", function()
		assert.are.equal("org.kde.StatusNotifierWatcher",
			providers.dbus_name_for_gate("ready::tray"))
		assert.are.equal("org.freedesktop.portal.Desktop",
			providers.dbus_name_for_gate("ready::portal"))
	end)

	it("resolves explicit ready::dbus:<name> form", function()
		assert.are.equal("org.foo.Bar",
			providers.dbus_name_for_gate("ready::dbus:org.foo.Bar"))
	end)

	it("returns nil for non-DBus gates", function()
		assert.is_nil(providers.dbus_name_for_gate("ready::somewm"))
		assert.is_nil(providers.dbus_name_for_gate("garbage"))
	end)

	it("bridges compositor signals through to broker", function()
		local broker = fresh_broker()
		local handlers = {}
		local fake_aw = {
			somewm_ready = false,
			xwayland_ready = false,
			connect_signal = function(name, fn) handlers[name] = fn end,
		}
		providers.setup{ broker = broker, deps = { awesome = fake_aw } }
		assert.is_function(handlers["somewm::ready"])
		handlers["somewm::ready"]()
		assert.is_true(broker.get_value("ready::somewm"))
	end)

	it("replays cached compositor flags on setup (hot-reload safety)", function()
		local broker = fresh_broker()
		local fake_aw = {
			somewm_ready = true, xwayland_ready = true,
			connect_signal = function() end,
		}
		providers.setup{ broker = broker, deps = { awesome = fake_aw } }
		assert.is_true(broker.get_value("ready::somewm"))
		assert.is_true(broker.get_value("ready::xwayland"))
	end)
end)

---------------------------------------------------------------------------
-- init (public API)
---------------------------------------------------------------------------

describe("autostart.init", function()
	local autostart, broker, timer, spawn

	before_each(function()
		load_module()
		broker = fresh_broker()
		timer  = fresh_timer()
		spawn  = fresh_spawn()
		package.loaded["fishlive.broker"] = broker
		package.loaded["gears.timer"] = timer
		package.loaded["fishlive.autostart.spawn"] = spawn
		package.loaded["fishlive.autostart.providers"] = {
			setup = function() end,
			request_dbus_name = function() end,
			dbus_name_for_gate = function() return nil end,
			shutdown = function() end,
		}
		package.loaded["fishlive.autostart.log"] = {
			new = function(opts)
				return setmetatable({ name = opts.name, path = "/tmp/" .. opts.name },
					{ __index = { event = function() end, stream = function() end, note = function() end } })
			end,
		}
		_G.awesome = { connect_signal = function() end, somewm_ready = true, xwayland_ready = true }
		autostart = require("fishlive.autostart")
	end)

	after_each(function() autostart._reset() end)

	it("registers entries in declaration order", function()
		autostart.add{ name = "first", cmd = { "x" } }
		autostart.add{ name = "second", cmd = { "x" } }
		assert.are.same({ "first", "second" }, autostart.list())
	end)

	it("rejects duplicate entry names", function()
		autostart.add{ name = "dup", cmd = { "x" } }
		assert.has_error(function()
			autostart.add{ name = "dup", cmd = { "x" } }
		end)
	end)

	it("requires name + cmd", function()
		assert.has_error(function() autostart.add{ cmd = { "x" } } end)
		assert.has_error(function() autostart.add{ name = "x" } end)
	end)

	it("status() returns generation, ready map and per-entry snapshots", function()
		broker.emit_signal("ready::somewm", true)
		autostart.add{ name = "z", cmd = { "x" }, when = { "ready::somewm" }, delay = 0 }
		autostart.start_all()
		local s = autostart.status()
		assert.are.equal(1, s.generation)
		assert.is_true(s.ready["ready::somewm"])
		assert.are.equal("running", s.entries["z"].state)
		assert.is_number(s.entries["z"].pid)
	end)

	it("schedules late-added entries when start_all already ran", function()
		broker.emit_signal("ready::somewm", true)
		autostart.start_all()
		autostart.add{ name = "late", cmd = { "x" }, when = { "ready::somewm" }, delay = 0 }
		assert.are.equal("running", autostart.status().entries["late"].state)
	end)

	it("stop() returns true for known entries, false otherwise", function()
		autostart.add{ name = "ok", cmd = { "x" } }
		assert.is_true(autostart.stop("ok"))
		local ok = autostart.stop("nope")
		assert.is_false(ok)
	end)
end)
