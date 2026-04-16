---------------------------------------------------------------------------
--- Updates wibar widget — pending Arch package updates count.
--
-- Subscribes to broker signal `data::updates` (official + AUR). Left-click
-- opens `paru` in the configured terminal for interactive upgrade.
--
-- @module fishlive.components.updates
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

--- Create the updates widget for a screen.
-- @tparam screen screen The awful.screen the widget belongs to
-- @tparam ?table config Reserved (currently unused)
-- @treturn wibox.widget
function M.create(screen, config)
	local widget, update = wh.create_icon_text("widget_updates_color", "#d8a657")

	broker.connect_signal("data::updates", function(data)
		update(data.icon, tostring(data.total))
	end)

	widget:buttons(gears.table.join(
		awful.button({}, 1, function()
			awful.spawn(string.format("%s -e paru",
				beautiful.terminal or "ghostty"))
		end)
	))

	return widget
end

return M
