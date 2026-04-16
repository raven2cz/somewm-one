---------------------------------------------------------------------------
--- Notifications component — naughty config + display with anim_client fade-in.
--
-- Auto-initializes on require (like services). All theme values are read
-- dynamically from beautiful at display time, so colorscheme changes
-- take effect immediately for new notifications.
--
-- Features:
--   - Notification history (global awesome._notif_history, last 50)
--   - Shell IPC push on each notification
--   - Fade-in animation via anim_client (gracefully skipped if unavailable)
--
-- Usage from rc.lua:
--   require("fishlive.components.notifications")
--
-- @module fishlive.components.notifications
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local awful    = require("awful")
local naughty  = require("naughty")
local wibox    = require("wibox")
local gears    = require("gears")
local beautiful = require("beautiful")
local ruled    = require("ruled")
local dpi      = beautiful.xresources.apply_dpi

local M = {}

--- Resolve icon for display without modifying n.icon (avoids signal loops).
local function resolve_icon(n)
	local icon = n.icon
	if type(icon) == "string" then
		if icon == "" or icon:sub(1, 1) ~= "/" then
			return beautiful.notification_icon_default
		end
	elseif not icon then
		return beautiful.notification_icon_default
	end
	return icon
end

---------------------------------------------------------------------------
-- Auto-initialization (runs once on first require)
---------------------------------------------------------------------------

-- Naughty defaults
naughty.config.defaults.ontop = true
naughty.config.defaults.icon_size = dpi(360)
naughty.config.defaults.timeout = 10
naughty.config.defaults.hover_timeout = 300
naughty.config.defaults.margin = dpi(16)
naughty.config.defaults.border_width = 0
naughty.config.defaults.position = "top_middle"
naughty.config.defaults.shape = function(cr, w, h)
	gears.shape.rounded_rect(cr, w, h, dpi(6))
end

naughty.config.padding = dpi(8)
naughty.config.spacing = dpi(8)
naughty.config.icon_dirs = {
	"/usr/share/icons/Papirus-Dark/",
	"/usr/share/icons/Tela/",
	"/usr/share/icons/Adwaita/",
	"/usr/share/icons/hicolor/",
}
naughty.config.icon_formats = { "svg", "png", "jpg", "gif" }

-- Rules read beautiful.* dynamically via request::rules signal
ruled.notification.connect_signal("request::rules", function()
	ruled.notification.append_rule {
		rule       = { urgency = "critical" },
		properties = {
			font             = beautiful.font,
			bg               = beautiful.bg_urgent or "#cc2233",
			fg               = "#ffffff",
			margin           = dpi(16),
			icon_size        = dpi(360),
			position         = "top_middle",
			implicit_timeout = 0,
		}
	}
	ruled.notification.append_rule {
		rule       = { urgency = "normal" },
		properties = {
			font             = beautiful.font,
			bg               = beautiful.notification_bg,
			fg               = beautiful.notification_fg,
			margin           = dpi(16),
			position         = "top_middle",
			implicit_timeout = 10,
			icon_size        = dpi(360),
			opacity          = 0.9,
		}
	}
	ruled.notification.append_rule {
		rule       = { urgency = "low" },
		properties = {
			font             = beautiful.font,
			bg               = beautiful.notification_bg,
			fg               = beautiful.notification_fg,
			margin           = dpi(16),
			position         = "top_middle",
			implicit_timeout = 8,
			icon_size        = dpi(360),
			opacity          = 0.9,
		}
	}
end)

-- Notification history for somewm-shell sidebar (stored on awesome to avoid _G pollution)
awesome._notif_history = awesome._notif_history or {}

-- Display handler with fade-in animation
naughty.connect_signal("request::display", function(n)
	-- Record notification in history table (for shell sidebar)
	table.insert(awesome._notif_history, {
		title    = n.title or "",
		message  = n.message or "",
		app_name = n.app_name or "",
	})
	-- Keep last 50 entries
	while #awesome._notif_history > 50 do
		table.remove(awesome._notif_history, 1)
	end
	-- Push refresh to somewm-shell
	awful.spawn.with_shell("qs ipc -c somewm call somewm-shell:notifications refresh")

	-- Pick icon for display without modifying n.icon (avoids signal loops)
	local display_icon = resolve_icon(n)

	local popup = naughty.layout.box {
		notification = n,
		border_width = 0,
		maximum_width = dpi(700),
		shape = function(cr, w, h)
			gears.shape.rounded_rect(cr, w, h, dpi(6))
		end,
		widget_template = {
			{
				{
					{
						image          = display_icon,
						resize         = true,
						upscale        = true,
						forced_width   = dpi(138),
						forced_height  = dpi(170),
						clip_shape     = function(cr, w, h)
							gears.shape.rounded_rect(cr, w, h, dpi(4))
						end,
						widget         = wibox.widget.imagebox,
					},
					{
						{
							{
								align  = "left",
								markup = n.title and ('<span font="Geist SemiBold 13" color="#e2b55a">'
									.. gears.string.xml_escape(n.title) .. '</span>') or "",
								widget = wibox.widget.textbox,
							},
							{
								align  = "left",
								font   = "CommitMono Nerd Font Propo 12",
								widget = naughty.widget.message,
							},
							spacing = dpi(6),
							layout  = wibox.layout.fixed.vertical,
						},
						top    = dpi(8),
						widget = wibox.container.margin,
					},
					spacing = dpi(12),
					layout  = wibox.layout.fixed.horizontal,
				},
				margins = dpi(20),
				widget  = wibox.container.margin,
			},
			id     = "background_role",
			widget = naughty.container.background,
		},
	}

	-- FadeIn animation (uses compositor frame-synced animation engine)
	local anim_ok, anim = pcall(require, "anim_client")
	if anim_ok and anim.fade_notification then
		anim.fade_notification(popup)
	end
end)

-- Export internals for testing
M._resolve_icon = resolve_icon

return M
