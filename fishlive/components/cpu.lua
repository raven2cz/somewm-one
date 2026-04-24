---------------------------------------------------------------------------
--- CPU wibar widget — usage percent and temperature.
--
-- Subscribes to broker signal `data::cpu` and renders icon + "NN% NN°C"
-- via fishlive.widget_helper.create_icon_text. Temperature is omitted when
-- no hwmon/thermal_zone sensor is available.
--
-- @module fishlive.components.cpu
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

--- Create the CPU widget for a screen.
-- @tparam screen screen The awful.screen the widget belongs to
-- @tparam ?table config Reserved (currently unused)
-- @treturn wibox.widget
function M.create(screen, config)
	local widget, update = wh.create_icon_text("widget_cpu_color", "#7daea3")

	broker.connect_signal("data::cpu", function(data)
		if data.temp then
			update(data.icon, string.format("%3d%% %2d°C", data.usage, data.temp))
		else
			update(data.icon, string.format("%3d%%", data.usage))
		end
	end)

	-- Left-click: open the CPU detail panel on this screen (captured
	-- closure — the per-screen widget is per-screen so `screen` is fixed).
	-- Same toggleOnScreen pattern as memory/storage widgets so a wibar
	-- click on a non-focused output opens the panel on that output.
	local screen_name = screen and screen.name or ""
	widget:buttons(gears.table.join(awful.button({}, 1, function()
		awful.spawn({
			"qs", "ipc", "-c", "somewm", "call",
			"somewm-shell:panels", "toggleOnScreen",
			"cpu-detail", screen_name,
		}, false)
	end)))

	return widget
end

return M
