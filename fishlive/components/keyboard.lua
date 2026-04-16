---------------------------------------------------------------------------
--- Keyboard layout wibar widget — shows active xkb group, click cycles.
--
-- Subscribes to broker signal `data::keyboard`. Left-click advances the xkb
-- group modulo the number of configured layouts. Prefixed with an extra
-- leading space because this widget sits flush against the taglist.
--
-- @module fishlive.components.keyboard
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

--- Create the keyboard-layout widget for a screen.
-- @tparam screen screen The awful.screen the widget belongs to
-- @tparam ?table config Reserved (currently unused)
-- @treturn wibox.widget
function M.create(screen, config)
	local widget, _update = wh.create_icon_text("widget_keyboard_color", "#7daea3")

	broker.connect_signal("data::keyboard", function(data)
		local color = beautiful.widget_keyboard_color or "#7daea3"
		-- Extra leading space: keyboard is first widget, needs gap from taglist colors
		widget.markup = string.format(
			'<span> </span><span font="%s" foreground="%s">%s</span>' ..
			'<span font="%s" foreground="%s"> %s</span>',
			wh.icon_font, color, data.icon,
			wh.number_font, color, string.upper(data.layout))
	end)

	widget:buttons(gears.table.join(
		awful.button({}, 1, function()
			local data = broker.get_value("data::keyboard")
			if data and data.layouts then
				local count = #data.layouts
				if count > 0 then
					awesome.xkb_set_layout_group(
						(awesome.xkb_get_layout_group() + 1) % count)
				end
			end
		end)
	))

	return widget
end

return M
