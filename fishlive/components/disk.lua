---------------------------------------------------------------------------
--- Disk wibar widget — used / total GB + percent for the primary mount.
--
-- Subscribes to broker signal `data::disk` (btrfs-aware producer). Shows only
-- the primary mount in the bar; full per-mount data is still available to
-- any consumer via broker.get_value("data::disk").
--
-- @module fishlive.components.disk
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

--- Create the disk widget for a screen.
-- @tparam screen screen The awful.screen the widget belongs to
-- @tparam ?table config Reserved (currently unused)
-- @treturn wibox.widget
function M.create(screen, config)
	local widget, update = wh.create_icon_text("widget_disk_color", "#e2b55a")

	broker.connect_signal("data::disk", function(data)
		update(data.icon, string.format("%s/%s GB %2d%%", data.used, data.total, data.percent))
	end)

	-- Left-click: open the storage detail panel pinned to this screen.
	local screen_name = screen and screen.name or ""
	widget:buttons(gears.table.join(awful.button({}, 1, function()
		awful.spawn({
			"qs", "ipc", "-c", "somewm", "call",
			"somewm-shell:panels", "toggleOnScreen",
			"storage-detail", screen_name,
		}, false)
	end)))

	return widget
end

return M
