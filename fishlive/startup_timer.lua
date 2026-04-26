---------------------------------------------------------------------------
--- Startup phase timer — write phase + elapsed-ms to a dedicated log so we
--- can see WHICH part of rc.lua / fishlive boot blocks the main thread.
---
--- Usage:
---   local ST = require("fishlive.startup_timer")
---   ST.mark("rc:require:awful")    -- elapsed since first mark()
---   ST.mark("rc:after:beautiful")
---   ST.flush()                      -- final entry, write summary
---
--- Output: ~/.local/log/somewm-startup.log
---   absolute_ms  delta_ms  phase
---   0           0         rc:start
---   42          42        rc:after:awful
---   ...
---
--- The file is overwritten on first mark() each session so a clean restart
--- gives a clean log. socket.gettime() gives microseconds without GLib
--- dependency. Falls back to os.time() (1 s precision) when luasocket missing.
---
-- @module fishlive.startup_timer
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local M = {}

local LOG_PATH = (os.getenv("HOME") or "/tmp") .. "/.local/log/somewm-startup.log"

-- High-resolution monotonic clock. lgi is already a hard dep of awesome on
-- somewm (used by gears.surface, etc.) and GLib.get_monotonic_time returns
-- microseconds since process start as an int64. Fallback chain:
--   1. lgi GLib.get_monotonic_time() — µs precision, no syscall
--   2. luasocket socket.gettime()    — sub-µs but extra dep
--   3. os.time()                     — 1 s precision, last resort
local _now_us
local _ok_lgi, lgi = pcall(require, "lgi")
if _ok_lgi and lgi.GLib and lgi.GLib.get_monotonic_time then
	local glib_mono = lgi.GLib.get_monotonic_time
	_now_us = function() return tonumber(glib_mono()) end
else
	local _ok_sock, socket = pcall(require, "socket")
	if _ok_sock and socket and socket.gettime then
		_now_us = function() return math.floor(socket.gettime() * 1e6) end
	else
		_now_us = function() return os.time() * 1000000 end
	end
end

local _t0 = nil
local _last = nil
local _file = nil

local function _open()
	if _file then return _file end
	-- Truncate on first open of this session.
	_file = io.open(LOG_PATH, "w")
	if _file then
		_file:write("# somewm startup timing — abs_ms  delta_ms  phase\n")
		_file:flush()
	end
	return _file
end

--- Record a phase boundary. First call also opens (truncates) the log file.
--- @tparam string phase Short label, e.g. "rc:after:require:awful"
function M.mark(phase)
	local now = _now_us()
	if not _t0 then
		_t0 = now
		_last = now
	end
	local abs_ms = math.floor((now - _t0) / 1000 + 0.5)
	local delta_ms = math.floor((now - _last) / 1000 + 0.5)
	_last = now

	local f = _open()
	if f then
		f:write(string.format("%6d  %6d  %s\n", abs_ms, delta_ms, phase or "?"))
		f:flush()
	end
end

--- Final marker. Call once at end of rc.lua so the file always closes cleanly.
function M.flush()
	M.mark("rc:end")
	if _file then _file:close(); _file = nil end
end

return M
