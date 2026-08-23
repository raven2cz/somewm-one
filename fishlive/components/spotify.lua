---------------------------------------------------------------------------
--- Spotify wibar widget — now playing, with a scrolling title.
--
-- Ported from streetturtle's awesome-wm-widgets spotify-widget, rewritten for
-- this config's broker/service split. Differences worth knowing:
--
--   * playerctl instead of the `sp` script, so it reads MPRIS directly and
--     needs no helper binary.
--   * One producer for all screens instead of two `awful.widget.watch` polls
--     per widget per second. The original spawned four shell processes a
--     second on a two-monitor setup; this spawns one only when something
--     actually changes.
--   * The title scrolls only while it does not fit, and the scroll animation
--     is paused whenever the widget is hidden, so an idle bar costs nothing.
--
-- Subscribes to broker signal `data::spotify`. Hides itself when Spotify is
-- not running. Mouse buttons:
--   1 → play/pause, 3 → raise the Spotify window,
--   4 (scroll up) → next track, 5 (scroll down) → previous track.
--
-- @module fishlive.components.spotify
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

local PLAY_PAUSE = "playerctl -p spotify play-pause"
local NEXT = "playerctl -p spotify next"
local PREV = "playerctl -p spotify previous"

--- Create the Spotify widget for a screen.
-- @tparam screen screen The awful.screen the widget belongs to
-- @tparam ?table config Optional: max_width (px, default 200), speed (px/s)
-- @treturn wibox.widget
function M.create(screen, config)
	config = config or {}
	local max_width = config.max_width or beautiful.spotify_max_width or 200
	local speed = config.speed or beautiful.spotify_scroll_speed or 40

	local icon = wibox.widget.textbox()
	local artist = wibox.widget.textbox()
	local title = wibox.widget.textbox()

	-- The scroll container animates only when its child does not fit, so a
	-- short title simply sits still.
	local scroller = wibox.widget {
		layout = wibox.container.scroll.horizontal,
		max_size = max_width,
		step_function = wibox.container.scroll.step_functions
			.waiting_nonlinear_back_and_forth,
		speed = speed,
		title,
	}

	local widget = wibox.widget {
		layout = wibox.layout.fixed.horizontal,
		spacing = 4,
		icon,
		artist,
		scroller,
	}
	widget.visible = false

	local tooltip = awful.tooltip {
		mode = "outside",
		preferred_positions = { "bottom" },
	}
	tooltip:add_to_object(widget)

	--- Re-render from a broker payload. Colour is read from beautiful on every
	-- update so a theme switch takes effect without rebuilding the widget,
	-- matching what widget_helper does for the other components.
	local function render(data)
		if not data or not data.running then
			if widget.visible then
				widget.visible = false
				-- Stop the animation timer while nothing is on screen.
				scroller:pause()
			end
			tooltip.markup = ""
			return
		end

		local color = beautiful.widget_spotify_color or "#1db954"
		icon.markup = string.format('<span font="%s" foreground="%s">%s</span>',
			wh.icon_font, color, data.icon)
		artist.markup = string.format('<span font="%s" foreground="%s">%s</span>',
			wh.number_font, color, data.artist)
		title.markup = string.format('<span font="%s" foreground="%s">%s</span>',
			wh.number_font, color, data.title)

		tooltip.markup = string.format(
			"<b>Artist</b>: %s\n<b>Song</b>: %s\n<b>Album</b>: %s",
			data.artist, data.title, data.album)

		if not widget.visible then
			widget.visible = true
			scroller:continue()
		end
	end

	broker.connect_signal("data::spotify", render)

	widget:buttons(gears.table.join(
		awful.button({}, 1, function() awful.spawn.with_shell(PLAY_PAUSE .. " &") end),
		awful.button({}, 3, function()
			for _, c in ipairs(client.get()) do
				if c.class == "Spotify" then
					c:jump_to()
					return
				end
			end
		end),
		awful.button({}, 4, function() awful.spawn.with_shell(NEXT .. " &") end),
		awful.button({}, 5, function() awful.spawn.with_shell(PREV .. " &") end)
	))

	return widget
end

return M
