---------------------------------------------------------------------------
--- Layoutbox component — layout icon with popup menu on click.
--
-- Left-click opens a popup menu listing all available layouts with icons
-- and names. The current layout is highlighted. Scroll to cycle layouts.
--
-- @module fishlive.components.layoutbox
---------------------------------------------------------------------------

local wibox     = require("wibox")
local awful     = require("awful")
local gears     = require("gears")
local beautiful = require("beautiful")
local dpi       = require("beautiful.xresources").apply_dpi
local menu      = require("fishlive.menu")

local M = {}

-- Nerd Font fallback icons for layouts without theme PNGs
local fallback_icons = {
	machi        = "󰕰",
	carousel     = "󰑂",
	["carousel.vertical"] = "󰁁",
}

function M.create(screen, config)
	local layout_menu = menu.new({
		items_source = function()
			local items = {}
			local current = awful.layout.get(screen)
			-- Recolor icons to match theme accent
			local fg = beautiful.border_color_active or beautiful.fg_normal or "#e2b55a"
			for _, l in ipairs(awful.layout.layouts) do
				local name = awful.layout.getname(l)
				local icon_raw = beautiful["layout_" .. name]
				local icon_image = nil
				local icon_text = nil

				if icon_raw then
					-- Recolor PNG/SVG icon to match theme foreground
					icon_image = gears.color.recolor_image(icon_raw, fg)
				else
					-- Use Nerd Font fallback
					icon_text = fallback_icons[name] or "󰕫"
				end

				items[#items + 1] = {
					icon_image = icon_image,
					icon = icon_text,
					label = name,
					checked = (l == current),
					on_activate = function()
						awful.layout.set(l, screen.selected_tag)
					end,
				}
			end
			return items
		end,
		close_on = "mouse_leave",
		placement = "under_mouse",
		width = dpi(200),
	})

	local layoutbox = awful.widget.layoutbox {
		screen = screen,
		buttons = {
			awful.button({}, 1, function()
				layout_menu:toggle()
			end),
			awful.button({}, 4, function() awful.layout.inc(-1) end),
			awful.button({}, 5, function() awful.layout.inc(1) end),
		},
	}

	return layoutbox
end

return M
