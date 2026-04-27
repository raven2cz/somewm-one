---------------------------------------------------------------------------
--- Autostart logger — per-entry file logger with rotation + aggregate log.
--
-- Each entry gets its own `~/.local/log/somewm-autostart/<name>.log` file
-- containing state transitions and captured stdout/stderr lines. A shared
-- `~/.local/log/somewm-autostart.log` aggregates state transitions only
-- (no stdio noise) so a single tail can show "what happened last session".
--
-- Rotation: when the per-entry log exceeds 1 MiB, rotate
-- `.log` -> `.log.1` -> `.log.2`, deleting the oldest. Checked on each
-- write (cheap stat).
--
-- All filesystem and time access is dependency-injectable through opts.deps
-- so tests can drive this synchronously without touching the disk.
--
-- @module fishlive.autostart.log
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local log_module = {}

local DEFAULT_DIR = os.getenv("HOME") .. "/.local/log/somewm-autostart"
local DEFAULT_AGGREGATE = os.getenv("HOME") .. "/.local/log/somewm-autostart.log"
local ROTATE_BYTES = 1024 * 1024  -- 1 MiB
local ROTATE_KEEP = 2             -- keep .log.1 and .log.2

---------------------------------------------------------------------------
-- Default deps (real GLib + io)
---------------------------------------------------------------------------

local function default_now_us()
	local lgi = require("lgi")
	return lgi.GLib.get_real_time()  -- microseconds since epoch
end

local function default_mkdir_p(path)
	-- mkdir -p semantics; io-only fallback shells out via os.execute
	os.execute(string.format("mkdir -p %q", path))
end

local function default_file_size(path)
	local fh = io.open(path, "rb")
	if not fh then return 0 end
	local size = fh:seek("end") or 0
	fh:close()
	return size
end

local function default_rename(from, to)
	os.rename(from, to)
end

local function default_remove(path)
	os.remove(path)
end

local function default_open_append(path)
	return io.open(path, "ab")
end

---------------------------------------------------------------------------
-- Timestamp helpers
---------------------------------------------------------------------------

--- Format a microsecond timestamp as ISO-8601 with millisecond + tz offset.
-- e.g. "2026-04-26T21:25:19.418+0200"
local function format_ts(us)
	local s = math.floor(us / 1000000)
	local ms = math.floor((us % 1000000) / 1000)
	return string.format("%s.%03d%s",
		os.date("%Y-%m-%dT%H:%M:%S", s),
		ms,
		os.date("%z", s))
end

---------------------------------------------------------------------------
-- Rotation
---------------------------------------------------------------------------

local function maybe_rotate(deps, path)
	local size = deps.file_size(path)
	if size <= ROTATE_BYTES then return end

	-- Drop the oldest, then shift each .log.N -> .log.N+1, finally .log -> .log.1.
	deps.remove(path .. "." .. ROTATE_KEEP)
	for n = ROTATE_KEEP - 1, 1, -1 do
		deps.rename(path .. "." .. n, path .. "." .. (n + 1))
	end
	deps.rename(path, path .. ".1")
end

---------------------------------------------------------------------------
-- Field formatting
---------------------------------------------------------------------------

local function format_value(v)
	if type(v) == "table" then
		return table.concat(v, ",")
	end
	return tostring(v)
end

--- Render an event field map into a stable "k=v k=v" string.
-- Keys are emitted in a fixed order so log lines are diffable across runs.
local FIELD_ORDER = {
	"state", "attempt", "pid", "exit", "reason",
	"runtime", "gates", "waiting_for", "backoff", "error",
}

local function format_fields(fields)
	local parts = {}
	local seen = {}
	for _, k in ipairs(FIELD_ORDER) do
		local v = fields[k]
		if v ~= nil then
			parts[#parts + 1] = k .. "=" .. format_value(v)
			seen[k] = true
		end
	end
	-- Append any unknown keys in alphabetical order so unspecced fields still log.
	local extra = {}
	for k in pairs(fields) do
		if not seen[k] then extra[#extra + 1] = k end
	end
	table.sort(extra)
	for _, k in ipairs(extra) do
		parts[#parts + 1] = k .. "=" .. format_value(fields[k])
	end
	return table.concat(parts, " ")
end

---------------------------------------------------------------------------
-- Writer object
---------------------------------------------------------------------------

local Writer = {}
Writer.__index = Writer

local function append_line(deps, path, line)
	maybe_rotate(deps, path)
	local fh = deps.open_append(path)
	if not fh then return false end
	fh:write(line, "\n")
	fh:close()
	return true
end

--- Log a state transition.
-- Written to both the per-entry log and the aggregate log.
--
-- @tparam table fields Field map (state, attempt, pid, ...)
function Writer:event(fields)
	local ts = format_ts(self._deps.now_us())
	local body = format_fields(fields)
	local line = string.format("%s [autostart entry=%s %s]", ts, self.name, body)
	append_line(self._deps, self.path, line)
	append_line(self._deps, self.aggregate_path, line)
end

--- Log a captured stdout/stderr line from the supervised process.
-- Per-entry log only — aggregate log stays free of stdio noise.
--
-- @tparam string stream "stdout" or "stderr"
-- @tparam string text Single line, no trailing newline
function Writer:stream(stream, text)
	local ts = format_ts(self._deps.now_us())
	local line = string.format("%s [%s] %s", ts, stream, text)
	append_line(self._deps, self.path, line)
end

--- Log a freeform supervisor diagnostic (pre-spawn errors, gate timeouts).
-- Routed to the per-entry log only; transitions still go through `event`.
--
-- @tparam string text Diagnostic message
function Writer:note(text)
	local ts = format_ts(self._deps.now_us())
	append_line(self._deps, self.path, string.format("%s [note] %s", ts, text))
end

---------------------------------------------------------------------------
-- Constructor
---------------------------------------------------------------------------

--- Create a writer for an autostart entry.
--
-- @tparam table opts
--   name           (string)  Entry name; required.
--   path           (string)  Override per-entry log path; defaults to
--                            <DEFAULT_DIR>/<name>.log.
--   aggregate_path (string)  Override aggregate path.
--   deps           (table)   Test hooks: now_us, mkdir_p, file_size, rename,
--                            remove, open_append.
-- @treturn Writer
function log_module.new(opts)
	assert(opts and opts.name, "log.new requires opts.name")

	local deps = {
		now_us       = (opts.deps and opts.deps.now_us) or default_now_us,
		mkdir_p      = (opts.deps and opts.deps.mkdir_p) or default_mkdir_p,
		file_size    = (opts.deps and opts.deps.file_size) or default_file_size,
		rename       = (opts.deps and opts.deps.rename) or default_rename,
		remove       = (opts.deps and opts.deps.remove) or default_remove,
		open_append  = (opts.deps and opts.deps.open_append) or default_open_append,
	}

	local path = opts.path or (DEFAULT_DIR .. "/" .. opts.name .. ".log")
	local aggregate_path = opts.aggregate_path or DEFAULT_AGGREGATE

	-- Ensure parent dirs exist on construction so first write does not race.
	local function dirname(p)
		return p:match("^(.*)/[^/]+$") or "."
	end
	deps.mkdir_p(dirname(path))
	deps.mkdir_p(dirname(aggregate_path))

	return setmetatable({
		name           = opts.name,
		path           = path,
		aggregate_path = aggregate_path,
		_deps          = deps,
	}, Writer)
end

-- Expose for tests + spec.
log_module._format_ts = format_ts
log_module._format_fields = format_fields
log_module._ROTATE_BYTES = ROTATE_BYTES
log_module._ROTATE_KEEP = ROTATE_KEEP
log_module._DEFAULT_DIR = DEFAULT_DIR
log_module._DEFAULT_AGGREGATE = DEFAULT_AGGREGATE

return log_module
