---------------------------------------------------------------------------
--- Widget helper — fonts, separators, markup helpers.
--
-- Design rules:
-- 1. Icon font: Symbols Nerd Font Mono (fixed width, no half-cut)
-- 2. Number font: CommitMono Nerd Font Propo (monospace digits)
-- 3. One textbox per font: somewm 2.x draws a markup with several runs in
--    the first run's font (colours survive, fonts do not), so icon and text
--    sit in adjacent textboxes of a zero-spacing fixed layout
-- 4. Fixed-width number formatting via string.format width specifiers
--
-- @module fishlive.widget_helper
---------------------------------------------------------------------------

local wibox = require("wibox")
local beautiful = require("beautiful")
local gears_string = require("gears.string")

local M = {}

M.icon_font = "Symbols Nerd Font Mono 12"
M.number_font = "CommitMono Nerd Font Propo 10"

--- Shadow params memo (for iterative tuning)
-- CURRENT:  radius=30, opacity=0.65, offset_y=5
-- TEST:     radius=40, opacity=0.85, offset_y=7
M.shadow_memo = {
	current = { radius = 30, opacity = 0.65, offset_x = 5, offset_y = 5 },
	test    = { radius = 40, opacity = 0.85, offset_x = 5, offset_y = 7 },
}

--- Create a row of adjacent single-run textboxes.
-- @tparam number n Number of runs
-- @treturn wibox.widget The row (a zero-spacing fixed.horizontal layout)
-- @treturn function set(i, font, color, text) updates run i
function M.create_runs(n)
	local row = wibox.layout.fixed.horizontal()
	local boxes = {}
	for i = 1, n do
		boxes[i] = wibox.widget.textbox()
		row:add(boxes[i])
	end
	return row, function(i, font, color, text)
		local tb = boxes[i]
		tb.font = font
		tb.markup = string.format('<span foreground="%s">%s</span>',
			color, gears_string.xml_escape(tostring(text)))
	end
end

--- Create a widget with an icon and a text, each in its own font.
-- Color is read dynamically from beautiful on every update,
-- so theme switches take effect immediately.
-- @param color_key string: beautiful key name (e.g. "widget_cpu_color")
-- @param fallback string: fallback color if beautiful key is nil
function M.create_icon_text(color_key, fallback)
	local row, set = M.create_runs(2)
	return row, function(icon, text)
		local color = beautiful[color_key] or fallback
		set(1, M.icon_font, color, icon)
		set(2, M.number_font, color, " " .. text)
	end
end

--- Create a separator widget between components.
-- Re-reads color from beautiful on data::theme signal.
function M.separator()
	local sep = wibox.widget.textbox()
	local function refresh()
		sep.markup = string.format('<span color="%s"> │ </span>',
			beautiful.fg_minimize or "#555555")
		sep.font = beautiful.font or "Geist 10"
	end
	refresh()
	local broker = require("fishlive.broker")
	broker.connect_signal("data::theme", refresh)
	return sep
end

return M
