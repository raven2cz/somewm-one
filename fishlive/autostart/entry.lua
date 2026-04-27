---------------------------------------------------------------------------
--- Per-entry state machine for fishlive.autostart.
--
-- Lifecycle:
--   pending → gated → starting → running → died → restart_pending → starting
--                                       ↓                                  ↓
--                                     failed (terminal until restart) ←────┘
--
-- Each transition increments an internal generation counter. All timers,
-- gate subscriptions and spawn-exit callbacks check the generation before
-- acting, so stale callbacks from previous attempts (or after a stop) are
-- harmless.
--
-- Backoff: `min(max(spec.delay, 1) * 2^(attempt-1), 60)` seconds.
-- Backoff reset: a process that stayed alive ≥ 60 s before dying resets
-- the attempt counter so the next death starts at the base delay.
--
-- All compositor-side dependencies (broker, timer, spawn, log writer)
-- are dependency-injected through opts.deps so the busted spec drives
-- the state machine entirely without touching wlroots.
--
-- @module fishlive.autostart.entry
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local entry_module = {}

local Entry = {}
Entry.__index = Entry

local DEFAULT_GATES = { "ready::somewm" }
local DEFAULT_TIMEOUT = 30
local BACKOFF_RESET_SECONDS = 60
local BACKOFF_CAP_SECONDS = 60

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function default_now() return os.time() end

local function shallow_copy(t)
	if not t then return {} end
	local c = {}
	for k, v in pairs(t) do c[k] = v end
	return c
end

local function copy_list(t)
	local c = {}
	for i, v in ipairs(t or {}) do c[i] = v end
	return c
end

--- Compute backoff delay for attempt N (1-based).
local function backoff_seconds(base, attempt)
	local d = math.max(base, 1) * (2 ^ (attempt - 1))
	if d > BACKOFF_CAP_SECONDS then d = BACKOFF_CAP_SECONDS end
	return d
end

---------------------------------------------------------------------------
-- Constructor
---------------------------------------------------------------------------

--- Create an entry from a spec.
--
-- @tparam table opts
--   spec    (table)  Validated spec from autostart.add (see init.lua).
--   deps    (table)  { broker, timer, spawn, log, now }.
function entry_module.new(opts)
	assert(opts and opts.spec, "entry.new requires opts.spec")
	local spec = opts.spec
	local deps = opts.deps or {}

	-- Defaults applied here so the spec table coming in from init.lua can
	-- stay sparse.
	local mode = spec.mode or "oneshot"
	local retries = spec.retries
	if retries == nil then
		retries = (mode == "respawn") and -1 or 1
	end

	local self = setmetatable({
		spec = {
			name      = spec.name,
			cmd       = spec.cmd,
			when      = (spec.when and #spec.when > 0) and copy_list(spec.when) or copy_list(DEFAULT_GATES),
			mode      = mode,
			retries   = retries,
			delay     = spec.delay or 0,
			timeout   = spec.timeout or DEFAULT_TIMEOUT,
			env       = shallow_copy(spec.env),
			replace   = spec.replace and true or false,
			disabled  = spec.disabled and true or false,
			backend   = spec.backend or "awful",
		},

		-- Runtime state
		_state           = "pending",
		_attempts        = 0,
		_pid             = nil,
		_started_at      = nil,
		_died_at         = nil,
		_exit_code       = nil,
		_exit_reason     = nil,
		_waiting_for     = nil,
		_generation      = 0,
		_gate_disconnects = {},
		_active_timers   = {},

		-- Deps (resolve at call time so test mocks can swap them late).
		_deps = {
			broker = deps.broker,
			timer  = deps.timer,
			spawn  = deps.spawn,
			log    = deps.log,
			now    = deps.now or default_now,
		},
	}, Entry)
	return self
end

---------------------------------------------------------------------------
-- Snapshot / introspection
---------------------------------------------------------------------------

--- Return a status snapshot for `autostart.status()`.
function Entry:snapshot()
	return {
		state       = self._state,
		mode        = self.spec.mode,
		attempts    = self._attempts,
		pid         = self._pid,
		started_at  = self._started_at,
		died_at     = self._died_at,
		exit_code   = self._exit_code,
		exit_reason = self._exit_reason,
		log_path    = self._deps.log and self._deps.log.path or nil,
		waiting_for = self._waiting_for and copy_list(self._waiting_for) or nil,
	}
end

function Entry:state() return self._state end
function Entry:pid() return self._pid end

---------------------------------------------------------------------------
-- Internal: timers + generation
---------------------------------------------------------------------------

local function bump_generation(self)
	self._generation = self._generation + 1
	-- Cancel all pending timers from previous gen.
	for t in pairs(self._active_timers) do
		if t.stop then pcall(t.stop, t) end
	end
	self._active_timers = {}
end

local function track_timer(self, timer)
	self._active_timers[timer] = true
end

local function untrack_timer(self, timer)
	self._active_timers[timer] = nil
end

--- Schedule a one-shot callback.
-- Wraps gears.timer.start_new with generation guard + tracking.
local function schedule(self, seconds, fn)
	local gen = self._generation
	local timer
	local function tick()
		untrack_timer(self, timer)
		if self._generation ~= gen then return end
		fn()
		return false  -- one-shot
	end
	timer = self._deps.timer.start_new(seconds, tick)
	if timer then track_timer(self, timer) end
	return timer
end

local function disconnect_gates(self)
	for _, fn in ipairs(self._gate_disconnects) do
		pcall(fn)
	end
	self._gate_disconnects = {}
end

local function emit_event(self, fields)
	if not self._deps.log then return end
	pcall(self._deps.log.event, self._deps.log, fields)
end

---------------------------------------------------------------------------
-- Internal: state transitions
---------------------------------------------------------------------------

local enter_state  -- forward decl

local function set_state(self, new, fields)
	self._state = new
	local payload = shallow_copy(fields or {})
	payload.state = new
	payload.attempt = self._attempts
	payload.pid = self._pid
	emit_event(self, payload)
end

---------------------------------------------------------------------------
-- gated
---------------------------------------------------------------------------

local function gates_satisfied(self)
	local broker = self._deps.broker
	for _, name in ipairs(self.spec.when) do
		if not broker.get_value(name) then return false end
	end
	return true
end

local function recompute_waiting(self)
	local broker = self._deps.broker
	local missing = {}
	for _, name in ipairs(self.spec.when) do
		if not broker.get_value(name) then
			missing[#missing + 1] = name
		end
	end
	self._waiting_for = missing
end

local function start_starting(self)
	disconnect_gates(self)
	self._waiting_for = nil
	bump_generation(self)
	self._attempts = self._attempts + 1
	set_state(self, "starting", {
		gates = self.spec.when,
	})

	local backend = require("fishlive.autostart.spawn").backend_for(self.spec.backend)
	local gen = self._generation

	local pid, err = backend({
		cmd = self.spec.cmd,
		env = self.spec.env,
		writer = self._deps.log,
		on_exit = function(reason, code)
			-- Stale callback guard
			if self._generation ~= gen then return end
			self:_on_exit(reason, code)
		end,
		deps = self._deps.spawn_deps,  -- forwarded to backend for tests
	})

	if not pid then
		-- spawn failure: count as one death, route through died.
		self._died_at = self._deps.now()
		self._exit_reason = "spawn_failed"
		self._exit_code = nil
		emit_event(self, { state = "died", attempt = self._attempts, error = err or "spawn returned nil" })
		self._state = "died"
		self:_after_death()
		return
	end

	self._pid = pid
	self._started_at = self._deps.now()
	enter_state(self, "running")
end

local function fire_gate_check(self)
	if self._state ~= "gated" then return end
	if not gates_satisfied(self) then
		recompute_waiting(self)
		return
	end
	-- All gates green: schedule delay (if any), then transition to starting.
	disconnect_gates(self)
	self._waiting_for = nil
	if self.spec.delay > 0 then
		schedule(self, self.spec.delay, function() start_starting(self) end)
	else
		start_starting(self)
	end
end

local function start_gated(self)
	bump_generation(self)
	self._state = "gated"
	recompute_waiting(self)

	-- Subscribe to all gate signals; broker fires synchronously with cached
	-- value if any (late join), so a fully-satisfied entry transitions
	-- immediately on the first connect.
	local broker = self._deps.broker
	for _, name in ipairs(self.spec.when) do
		local d = broker.connect_signal(name, function()
			fire_gate_check(self)
		end)
		self._gate_disconnects[#self._gate_disconnects + 1] = d
	end

	-- Emit event AFTER subscriptions but BEFORE the timeout: we may have
	-- already transitioned out via the late-join replay.
	if self._state ~= "gated" then return end

	emit_event(self, {
		state = "gated",
		attempt = self._attempts,
		waiting_for = self._waiting_for,
	})

	-- Timeout: if still in gated after `timeout` s, escalate to failed.
	if self.spec.timeout and self.spec.timeout > 0 then
		schedule(self, self.spec.timeout, function()
			if self._state ~= "gated" then return end
			disconnect_gates(self)
			self._state = "failed"
			emit_event(self, {
				state = "failed",
				attempt = self._attempts,
				reason = "gate_timeout",
				waiting_for = self._waiting_for,
			})
		end)
	end
end

---------------------------------------------------------------------------
-- running / died / restart_pending
---------------------------------------------------------------------------

function Entry:_after_death()
	-- Reset attempt counter if process stayed alive long enough.
	if self._started_at and self._died_at and (self._died_at - self._started_at) >= BACKOFF_RESET_SECONDS then
		self._attempts = 0
	end

	local retries = self.spec.retries
	local exhausted = (retries >= 0) and (self._attempts >= retries)

	if exhausted then
		self._state = "failed"
		emit_event(self, {
			state = "failed",
			attempt = self._attempts,
			reason = "retries_exhausted",
			exit = self._exit_code,
		})
		return
	end

	self._state = "restart_pending"
	local delay = backoff_seconds(self.spec.delay, self._attempts)
	emit_event(self, {
		state = "restart_pending",
		attempt = self._attempts,
		backoff = delay,
	})
	bump_generation(self)
	schedule(self, delay, function() start_starting(self) end)
end

function Entry:_on_exit(reason, code)
	if self._state ~= "running" then return end
	self._died_at = self._deps.now()
	self._exit_reason = reason
	self._exit_code = code
	local runtime = self._started_at and (self._died_at - self._started_at) or nil
	emit_event(self, {
		state = "died",
		attempt = self._attempts,
		exit = code,
		reason = reason,
		runtime = runtime,
	})
	self._state = "died"
	local prior_pid = self._pid
	self._pid = nil
	-- Clear started_at AFTER the runtime computation so backoff reset works.
	self:_after_death()
	-- Cosmetic: prior_pid retained only in event payload.
	_ = prior_pid
end

function enter_state(self, new)
	if new == "running" then
		self._state = "running"
		self._died_at = nil
		self._exit_code = nil
		self._exit_reason = nil
		emit_event(self, {
			state = "running",
			attempt = self._attempts,
			pid = self._pid,
		})
	end
end

---------------------------------------------------------------------------
-- Public actions
---------------------------------------------------------------------------

--- Begin autostart for this entry.
-- Transition pending → gated. Caller should only invoke once per entry
-- per autostart.start_all() cycle.
function Entry:start()
	if self.spec.disabled then return end

	-- replace=true: kill any existing managed PID before re-gating.
	if self.spec.replace and self._pid then
		local spawn_mod = require("fishlive.autostart.spawn")
		spawn_mod.send_signal(self._pid, "TERM", self._deps.spawn_deps)
		self._pid = nil
	end

	if self._state == "running" then
		-- Already running; nothing to do.
		return
	end
	if self._state == "starting" or self._state == "gated" or self._state == "restart_pending" then
		-- Already in flight; idempotent.
		return
	end

	self._attempts = 0
	start_gated(self)
end

--- Manually stop this entry.
-- Cancels gates / backoff timers and sigterms the running process.
-- The entry transitions to `pending` so the next start_all() picks it
-- back up.
function Entry:stop()
	disconnect_gates(self)
	bump_generation(self)
	if self._pid then
		local spawn_mod = require("fishlive.autostart.spawn")
		spawn_mod.send_signal(self._pid, "TERM", self._deps.spawn_deps)
	end
	self._waiting_for = nil
	self._state = "pending"
	self._pid = nil
	emit_event(self, { state = "pending", attempt = self._attempts, reason = "stopped" })
end

--- Manually restart this entry from `failed`.
-- Resets attempts and re-enters the gated state.
-- For other states this is a no-op (use stop()+start() if you really
-- want to restart a running entry).
function Entry:restart()
	if self._state ~= "failed" and self._state ~= "died" then
		return false
	end
	self._attempts = 0
	self._exit_code = nil
	self._exit_reason = nil
	self._died_at = nil
	start_gated(self)
	return true
end

--- Send SIGTERM with optional follow-up SIGKILL after a grace period.
-- Used during compositor shutdown. The grace timer is scheduled through
-- the injected timer so tests run synchronously.
function Entry:shutdown(grace_seconds)
	if not self._pid then return end
	local spawn_mod = require("fishlive.autostart.spawn")
	local pid = self._pid
	spawn_mod.send_signal(pid, "TERM", self._deps.spawn_deps)
	if grace_seconds and grace_seconds > 0 then
		self._deps.timer.start_new(grace_seconds, function()
			if spawn_mod.is_alive(pid) then
				spawn_mod.send_signal(pid, "KILL", self._deps.spawn_deps)
			end
			return false
		end)
	end
end

-- Test hooks
entry_module._backoff_seconds = backoff_seconds
entry_module._BACKOFF_RESET_SECONDS = BACKOFF_RESET_SECONDS
entry_module._BACKOFF_CAP_SECONDS = BACKOFF_CAP_SECONDS

return entry_module
