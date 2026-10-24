---------------------------------------------------------------------------
--- Network wibar widget — rx / tx rates for the primary interface.
--
-- Subscribes to broker signal `data::network`. Renders two icon/value pairs
-- side by side as four single-font runs (widget_helper.create_runs).
--
-- @module fishlive.components.network
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

--- Create the network widget for a screen.
-- @tparam screen screen The awful.screen the widget belongs to
-- @tparam ?table config Reserved (currently unused)
-- @treturn wibox.widget
function M.create(screen, config)
	local widget, set = wh.create_runs(4)

	broker.connect_signal("data::network", function(data)
		local color = beautiful.widget_network_color or "#89b482"
		set(1, wh.icon_font, color, data.icon_down)
		set(2, wh.number_font, color, " " .. data.rx_formatted .. " ")
		set(3, wh.icon_font, color, data.icon_up)
		set(4, wh.number_font, color, " " .. data.tx_formatted)
	end)

	return widget
end

return M
