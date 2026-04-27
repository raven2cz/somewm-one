---------------------------------------------------------------------------
--- Autostart spawn backends.
--
-- Two backends:
--   awful           default; wraps awful.spawn.with_line_callback. Stdout
--                   and stderr lines are appended to the per-entry log via
--                   the supplied writer.
--   start_process   legacy; wraps the user's ~/bin/start_process script.
--                   Internal PID tracking still tracks the wrapper, not
--                   the child process. Use only for entries that opt in
--                   via spec.backend = "start_process".
--
-- All spawns return either a numeric PID (success) or `nil, err_string`
-- (failure -- binary missing, fork failed, etc.). entry.lua treats the
-- failure case as a normal "died" transition so the backoff path covers
-- it without special casing.
--
-- Dependency injection through opts.deps lets the unit spec drive a
-- fully fake awful.spawn.
--
-- @module fishlive.autostart.spawn
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local spawn_module = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Build an `env -i`-style argv prefix from a key/value table.
-- Returns a list ready to be prepended to the user's cmd argv.
-- Empty/nil env returns an empty list.
local function env_prefix(env)
	if not env or not next(env) then return {} end
	local out = { "env" }
	for k, v in pairs(env) do
		out[#out + 1] = tostring(k) .. "=" .. tostring(v)
	end
	return out
end

--- Normalize cmd to an argv table.
-- If the user passed a string, route it through `sh -c` so shell features
-- (globbing, pipes) keep working. Table cmds are exec'd directly.
local function to_argv(cmd, env)
	local prefix = env_prefix(env)
	if type(cmd) == "string" then
		-- env -i KEY=val ... sh -c "cmd"
		local out = {}
		for _, p in ipairs(prefix) do out[#out + 1] = p end
		out[#out + 1] = "sh"
		out[#out + 1] = "-c"
		out[#out + 1] = cmd
		return out
	end
	assert(type(cmd) == "table", "cmd must be string or table")
	local out = {}
	for _, p in ipairs(prefix) do out[#out + 1] = p end
	for _, p in ipairs(cmd) do out[#out + 1] = p end
	return out
end

---------------------------------------------------------------------------
-- Backend: awful
---------------------------------------------------------------------------

--- Spawn via `awful.spawn.with_line_callback`.
--
-- @tparam table opts
--   cmd        (string|table)  Required.
--   env        (table)         Optional KEY=VALUE map merged into env.
--   writer     (Writer)        Optional per-entry log writer; receives
--                              stdout/stderr lines via writer:stream().
--   on_exit    (function)      Optional; called as on_exit(reason, code)
--                              when the child exits (reason: "exit" or "signal").
--   deps       (table)         Test override: { spawn = mock_awful_spawn }.
-- @treturn[1] integer pid
-- @treturn[2] nil, string  Error path -- caller should treat as "died".
function spawn_module.awful_backend(opts)
	assert(opts and opts.cmd, "spawn.awful_backend requires opts.cmd")

	local awful_spawn = (opts.deps and opts.deps.spawn) or require("awful.spawn")
	local writer = opts.writer
	local on_exit = opts.on_exit

	local argv = to_argv(opts.cmd, opts.env)

	local callbacks = {}
	if writer then
		callbacks.stdout = function(line) writer:stream("stdout", line) end
		callbacks.stderr = function(line) writer:stream("stderr", line) end
	end
	if on_exit then
		callbacks.exit = function(reason, code) on_exit(reason, code) end
	end

	local pid = awful_spawn.with_line_callback(argv, callbacks)
	if type(pid) == "string" then
		return nil, pid
	end
	if type(pid) ~= "number" then
		return nil, "spawn returned unexpected type: " .. type(pid)
	end
	return pid
end

---------------------------------------------------------------------------
-- Backend: start_process (legacy wrapper)
---------------------------------------------------------------------------

local START_PROCESS_PATH = os.getenv("HOME") .. "/bin/start_process"

--- Spawn through `~/bin/start_process` legacy supervisor.
-- The wrapper takes the cmd as its tail argv. We track the wrapper PID,
-- not the child the wrapper itself spawns -- this is consistent with how
-- start_process was used historically.
function spawn_module.start_process_backend(opts)
	assert(opts and opts.cmd, "spawn.start_process_backend requires opts.cmd")

	local awful_spawn = (opts.deps and opts.deps.spawn) or require("awful.spawn")
	local writer = opts.writer
	local on_exit = opts.on_exit

	local prefix = env_prefix(opts.env)
	local argv = {}
	for _, p in ipairs(prefix) do argv[#argv + 1] = p end
	argv[#argv + 1] = START_PROCESS_PATH

	if type(opts.cmd) == "string" then
		argv[#argv + 1] = "sh"
		argv[#argv + 1] = "-c"
		argv[#argv + 1] = opts.cmd
	else
		for _, p in ipairs(opts.cmd) do argv[#argv + 1] = p end
	end

	local callbacks = {}
	if writer then
		callbacks.stdout = function(line) writer:stream("stdout", line) end
		callbacks.stderr = function(line) writer:stream("stderr", line) end
	end
	if on_exit then
		callbacks.exit = function(reason, code) on_exit(reason, code) end
	end

	local pid = awful_spawn.with_line_callback(argv, callbacks)
	if type(pid) == "string" then
		return nil, pid
	end
	if type(pid) ~= "number" then
		return nil, "spawn returned unexpected type: " .. type(pid)
	end
	return pid
end

---------------------------------------------------------------------------
-- Termination helpers
---------------------------------------------------------------------------

--- Send a signal to a PID.
-- Uses /bin/kill via awful.spawn so we don't need an extra ffi binding.
-- @tparam integer pid
-- @tparam string sig POSIX name without "SIG", e.g. "TERM" or "KILL".
function spawn_module.send_signal(pid, sig, deps)
	if not pid then return end
	local awful_spawn = (deps and deps.spawn) or require("awful.spawn")
	awful_spawn.easy_async({ "kill", "-" .. sig, tostring(pid) }, function() end)
end

--- Check whether a PID is still alive (kill -0).
-- Synchronous via os.execute -- only used during entry shutdown to avoid
-- racing the SIGKILL path with a recycled PID.
function spawn_module.is_alive(pid)
	if not pid then return false end
	-- Redirect both fd to suppress shell noise.
	local rc = os.execute("kill -0 " .. tostring(pid) .. " 2>/dev/null")
	-- Lua 5.1 returns 0 on success, Lua 5.2+ returns true.
	return rc == 0 or rc == true
end

---------------------------------------------------------------------------
-- Backend lookup
---------------------------------------------------------------------------

local BACKENDS = {
	awful         = spawn_module.awful_backend,
	start_process = spawn_module.start_process_backend,
}

--- Resolve a backend name to its callable.
-- @tparam string|nil name "awful" (default) or "start_process".
-- @treturn function backend(opts) -> pid | nil, err
function spawn_module.backend_for(name)
	local b = BACKENDS[name or "awful"]
	assert(b, "unknown spawn backend: " .. tostring(name))
	return b
end

-- Expose for tests.
spawn_module._to_argv = to_argv
spawn_module._env_prefix = env_prefix
spawn_module._START_PROCESS_PATH = START_PROCESS_PATH

return spawn_module
