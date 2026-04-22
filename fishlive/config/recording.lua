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

--- Return the name of the active mic (default input source) if it is a real
-- microphone and currently unmuted. Monitor sources (speaker loopbacks) and
-- muted sources are treated as "no mic" so we silently fall back to capturing
-- only the system audio output.
local function active_mic()
	local p = io.popen("pactl get-default-source 2>/dev/null")
	if not p then return nil end
	local src = p:read("*l")
	p:close()
	if not src or src == "" or src:match("%.monitor$") then
		return nil
	end
	local m = io.popen("pactl get-source-mute '" .. src .. "' 2>/dev/null")
	if not m then return nil end
	local mute = m:read("*l")
	m:close()
	if mute and mute:match("Mute:%s*no") then
		return src
	end
	return nil
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
		local mic = active_mic()
		-- Merge system output and mic into a single audio track so every
		-- player plays back both without needing per-track selection. Pipe
		-- separator is the gpu-screen-recorder syntax for merged sources.
		local audio_source = mic and ("default_output|" .. mic) or "default_output"
		awful.spawn.with_shell(
			"gpu-screen-recorder"
			.. " -w " .. output
			.. " -f 144"
			.. " -k hevc"
			.. " -q very_high"
			.. " -bm vbr"
			.. " -ac opus"
			.. " -a '" .. audio_source .. "'"
			.. " -fm cfr"
			.. " -cursor yes"
			.. " -cr full"
			.. " -c mkv"
			.. " -o " .. outfile
			.. " & echo $! > " .. pid_file
		)
		local mic_msg = mic and (" + mic") or ""
		naughty.notification({
			title = "Recording",
			message = "Started (" .. output .. mic_msg .. "): " .. outfile,
			timeout = 3,
		})
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
