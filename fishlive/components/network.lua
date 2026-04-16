---------------------------------------------------------------------------
--- Network wibar widget — rx / tx rates for the primary interface.
--
-- Subscribes to broker signal `data::network`. Renders a custom markup with
-- icon-font + number-font spans (does not use `create_icon_text` because it
-- shows two icon/value pairs side by side).
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
	local widget = wibox.widget.textbox()

	broker.connect_signal("data::network", function(data)
		local color = beautiful.widget_network_color or "#89b482"
		widget.markup = string.format(
			'<span font="%s" foreground="%s">%s</span>' ..
			'<span font="%s" foreground="%s"> %s </span>' ..
			'<span font="%s" foreground="%s">%s</span>' ..
			'<span font="%s" foreground="%s"> %s</span>',
			wh.icon_font, color, data.icon_down,
			wh.number_font, color, data.rx_formatted,
			wh.icon_font, color, data.icon_up,
			wh.number_font, color, data.tx_formatted)
	end)

	return widget
end

return M
