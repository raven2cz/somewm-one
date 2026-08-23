---------------------------------------------------------------------------
--- Spotify service — now-playing state via playerctl MPRIS.
--
-- Event-driven: `playerctl --follow` pushes a line on every track and status
-- change, which triggers a full metadata read. A slow backstop poll covers the
-- one transition the follow stream cannot be relied on for -- the player
-- disappearing -- so the widget hides itself even if no event arrives.
--
-- playerctl stays alive when Spotify is not running and emits as soon as it
-- starts, so there is nothing to restart or retry on that path.
--
-- Signal: data::spotify — { running, playing, artist, title, album, icon }
-- Interval: event-driven, with a 5s backstop.
--
-- @module fishlive.services.spotify
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local service = require("fishlive.service")
local broker = require("fishlive.broker")

local M = {}

-- Field separator for the playerctl template. Deliberately something no track
-- title carries; the parser also checks the field count, so a title that did
-- contain it degrades to "not running" rather than to garbled output.
local SEP = "@|@"

-- markup_escape is playerctl's own, so ampersands in titles arrive already
-- safe for Pango markup -- the original awesome widget had to gsub them by
-- hand and only handled '&'.
local FORMAT = table.concat({
	"{{status}}",
	"{{markup_escape(artist)}}",
	"{{markup_escape(title)}}",
	"{{markup_escape(album)}}",
}, SEP)

M.METADATA_CMD = "playerctl -p spotify metadata --format '" .. FORMAT .. "' 2>/dev/null"
M.FOLLOW_CMD = "playerctl -p spotify --follow --format '{{status}}' metadata"

local STOPPED = {
	running = false,
	playing = false,
	artist = "",
	title = "",
	album = "",
	icon = "",
}

--- Parse one playerctl metadata line.
-- @tparam ?string stdout Raw command output
-- @treturn table Never nil: a "not running" table is a real state that the
--   widget needs in order to hide itself, so it must be emitted like any other.
function M.parse(stdout)
	if not stdout or stdout:match("^%s*$") then
		return STOPPED
	end

	local line = stdout:match("^[^\n]*") or ""
	local fields = {}
	local pos = 1
	while true do
		local a, b = line:find(SEP, pos, true)
		if not a then
			fields[#fields + 1] = line:sub(pos)
			break
		end
		fields[#fields + 1] = line:sub(pos, a - 1)
		pos = b + 1
	end

	if #fields ~= 4 then
		return STOPPED
	end

	local status, artist, title, album = fields[1], fields[2], fields[3], fields[4]
	if status == "" or (artist == "" and title == "") then
		return STOPPED
	end

	local playing = status == "Playing"
	return {
		running = true,
		playing = playing,
		artist = artist,
		title = title,
		album = album,
		icon = playing and "󰐊" or "󰏤",
	}
end

local s = service.new {
	signal          = "data::spotify",
	command         = M.METADATA_CMD,
	parser          = M.parse,
	event_cmd       = M.FOLLOW_CMD,
	safety_interval = 5,
}

broker.register_producer("data::spotify", s)

M.service = s
return M
