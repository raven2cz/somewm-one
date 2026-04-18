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
local menubar_utils = require("menubar.utils")
local portraits = require("fishlive.services.portraits")
local dpi      = beautiful.xresources.apply_dpi

local M = {}

-- naughty's icon_path_handler runs gears.surface.load_uncached_silently() on
-- the image-path hint. When the hint is an XDG icon NAME (e.g., Claude Code's
-- notify-send --icon=claude-ai), the load fails and returns a 0x0 error
-- surface — which is still truthy, so the stock nil-check never fires and
-- the imagebox renders empty. Treat a 0x0 surface as "no icon" and try to
-- resolve the original hint as an XDG name before falling back.
local function surface_has_content(icon)
	local ok_w, w = pcall(function() return icon:get_width() end)
	local ok_h, h = pcall(function() return icon:get_height() end)
	return ok_w and ok_h and (w or 0) > 0 and (h or 0) > 0
end

local function lookup_xdg(name)
	if type(name) ~= "string" or name == "" then return nil end
	if name:sub(1, 1) == "/" then return nil end
	return menubar_utils.lookup_icon(name) or menubar_utils.lookup_icon(name:lower())
end

--- Resolve icon for display without modifying n.icon (avoids signal loops).
local function resolve_icon(n)
	local icon = n.icon
	if type(icon) == "string" then
		if icon ~= "" and icon:sub(1, 1) == "/" then
			return icon
		end
	elseif icon and surface_has_content(icon) then
		return icon
	end

	-- Retry: maybe the DBus hint was an XDG icon name (image-path / app_icon).
	local xdg = lookup_xdg(n.image) or lookup_xdg(n.app_icon) or lookup_xdg(n.app_name)
	if xdg then return xdg end

	-- Random image from the user's default portrait collection.
	local portrait = portraits.random_image()
	if portrait then return portrait end

	return beautiful.notification_icon_default
end

---------------------------------------------------------------------------
-- Auto-initialization (runs once on first require)
---------------------------------------------------------------------------

-- Naughty defaults
naughty.config.defaults.ontop = true
naughty.config.defaults.icon_size = dpi(360)
naughty.config.defaults.timeout = 15
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
			implicit_timeout = 15,
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
			implicit_timeout = 12,
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
		maximum_width = dpi(900),
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
						-- Match the naughty.config.defaults.icon_size / per-urgency
						-- ruled.notification icon_size of dpi(360). Portrait 4:5.
						forced_width   = dpi(288),
						forced_height  = dpi(360),
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
						top    = dpi(4),
						left   = dpi(6),
						widget = wibox.container.margin,
					},
					spacing = dpi(4),
					layout  = wibox.layout.fixed.horizontal,
				},
				margins = dpi(16),
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
M._surface_has_content = surface_has_content
M._lookup_xdg = lookup_xdg

return M
