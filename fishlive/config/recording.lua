---------------------------------------------------------------------------
--- Screen recording — gpu-screen-recorder start/stop/pause helpers.
--
-- Shared by keybindings (Super+Alt+R) and desktop menu.
-- Auto-detects focused output name. Output: ~/Videos/rec-YYYYMMDD-HHMMSS.mkv
--
-- @module fishlive.config.recording
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local awful = require("awful")
local naughty = require("naughty")

local M = {}

local pid_file = "/tmp/gpu-screen-recorder.pid"

--- Get the output name (e.g. "DP-3") of the currently focused screen.
local function focused_output()
	local s = awful.screen.focused()
	return s and s.output and s.output.name or "screen"
end

function M.is_running()
	local f = io.open(pid_file, "r")
	if not f then return false end
	local pid = f:read("*l")
	f:close()
	local check = io.open("/proc/" .. pid .. "/status", "r")
	if check then check:close(); return true end
	os.remove(pid_file)
	return false
end

function M.toggle()
	if M.is_running() then
		awful.spawn.with_shell("kill -INT $(cat " .. pid_file .. ") && rm -f " .. pid_file)
		naughty.notification({ title = "Recording", message = "Stopped & saved", timeout = 3 })
	else
		local output = focused_output()
		local outfile = os.getenv("HOME") .. "/Videos/rec-" .. os.date("%Y%m%d-%H%M%S") .. ".mkv"
		awful.spawn.with_shell(
			"gpu-screen-recorder"
			.. " -w " .. output
			.. " -f 144"
			.. " -k hevc"
			.. " -q very_high"
			.. " -bm vbr"
			.. " -ac opus"
			.. " -a default_output"
			.. " -fm cfr"
			.. " -cursor yes"
			.. " -cr full"
			.. " -c mkv"
			.. " -o " .. outfile
			.. " & echo $! > " .. pid_file
		)
		naughty.notification({ title = "Recording", message = "Started (" .. output .. "): " .. outfile, timeout = 3 })
	end
end

function M.pause_resume()
	if M.is_running() then
		awful.spawn.with_shell("kill -USR2 $(cat " .. pid_file .. ")")
		naughty.notification({ title = "Recording", message = "Pause/Resume toggled", timeout = 2 })
	else
		naughty.notification({ title = "Recording", message = "Not recording", timeout = 2 })
	end
end

return M
