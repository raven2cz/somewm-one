---------------------------------------------------------------------------
--- Volume wibar widget — PipeWire sink level with mouse controls.
--
-- Subscribes to broker signal `data::volume`. Mouse buttons:
--   1 → pavucontrol, 2 → helvum, 3 → toggle mute,
--   4 (scroll up) → +5%, 5 (scroll down) → -5%.
--
-- @module fishlive.components.volume
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local wibox = require("wibox")
local awful = require("awful")
local gears = require("gears")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

--- Create the volume widget for a screen.
-- @tparam screen screen The awful.screen the widget belongs to
-- @tparam ?table config Reserved (currently unused)
-- @treturn wibox.widget
function M.create(screen, config)
	local widget, update = wh.create_icon_text("widget_volume_color", "#ea6962")

	broker.connect_signal("data::volume", function(data)
		update(data.icon, string.format("%3d%%", data.volume))
	end)

	widget:buttons(gears.table.join(
		awful.button({}, 1, function() awful.spawn("pavucontrol") end),
		awful.button({}, 2, function() awful.spawn("helvum") end),
		awful.button({}, 3, function()
			awful.spawn.with_shell("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle &")
		end),
		awful.button({}, 4, function()
			awful.spawn.with_shell("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ &")
		end),
		awful.button({}, 5, function()
			awful.spawn.with_shell("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- &")
		end)
	))

	return widget
end

return M
