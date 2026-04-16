---------------------------------------------------------------------------
--- Clock component — dimmed date + accent time, calendar popup on click.
--
-- Preserves the original somewm-one clock style:
--   "Thu 02 Apr" in muted gray + "20:09" in warm amber
--
-- Colors update dynamically on theme switch via data::theme signal.
--
-- @module fishlive.components.clock
---------------------------------------------------------------------------

local wibox = require("wibox")
local awful = require("awful")
local gears = require("gears")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")

local M = {}

function M.create(screen, config)
	local date_color = config.date_color or "#b0b0b0"
	local icon_font = require("fishlive.widget_helper").icon_font

	local function get_time_color()
		return config.time_color or beautiful.widget_clock_color or "#e2b55a"
	end

	local function get_date_font()
		return config.date_font or beautiful.font or "Geist 10"
	end

	local function get_time_font()
		return config.time_font or beautiful.font_large or "Geist SemiBold 11"
	end

	local function make_format()
		local tc = get_time_color()
		local df = get_date_font()
		local tf = get_time_font()
		return '<span font="' .. icon_font .. '" foreground="' .. tc .. '">󰥔 </span>' ..
			'<span foreground="' .. date_color .. '" font="' .. df .. '">%a %d %b </span>' ..
			'<span foreground="' .. tc .. '" font="' .. tf .. '">%H:%M</span>'
	end

	local clock = wibox.widget.textclock(make_format(), 60)

	-- Calendar popup — rebuilt on theme switch
	local cal_popup

	local function create_popup()
		local bg_base = beautiful.bg_normal or "#181818"
		local accent = get_time_color()
		local df = get_date_font()
		local tf = get_time_font()

		cal_popup = awful.widget.calendar_popup.month({
			start_sunday = false,
			long_weekdays = true,
			style_month = {
				bg_color     = bg_base .. "f0",
				border_color = accent,
				border_width = 1,
				padding      = beautiful.useless_gap and beautiful.useless_gap * 3 or 10,
			},
			style_header = {
				fg_color     = accent,
				font         = tf,
			},
			style_weekday = {
				fg_color     = date_color,
				font         = df,
			},
			style_normal = {
				fg_color     = beautiful.fg_focus or "#d4d4d4",
				font         = df,
			},
			style_focus = {
				fg_color     = bg_base,
				bg_color     = accent,
				font         = config.focus_font or "Geist Bold 10",
				shape        = gears.shape.circle,
			},
		})
		cal_popup:attach(clock, "tr", { on_hover = false })
	end

	create_popup()

	-- Update clock format and popup on theme switch
	broker.connect_signal("data::theme", function()
		clock:set_format(make_format())
		create_popup()
	end)

	return clock
end

return M
