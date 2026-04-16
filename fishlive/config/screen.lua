---------------------------------------------------------------------------
--- Screen decoration — tags, taglist, tasklist, wibar, wallpaper.
--
-- Handles request::desktop_decoration signal including tag persistence
-- across monitor hotplug. Uses factory.widget_bar() for the right-side
-- wibar components.
--
-- Defaults are owned here; rc.lua only passes real dependencies:
--   require("fishlive.config.screen").setup({
--       modkey   = modkey,
--       launcher = menus.launcher,
--   })
--
-- Theme can override wibar components via beautiful.wibar_components.
--
-- @module fishlive.config.screen
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")
local beautiful = require("beautiful")
local factory = require("fishlive.factory")

local M = {}

-- Default wibar right-side components (theme can override via beautiful.wibar_components)
local default_components = {
	"keyboard", "updates", "cpu", "gpu", "memory",
	"disk", "network", "volume", "systray", "clock", "layoutbox",
}

--- Set up screen decorations: tags, taglist, tasklist, wibar, wallpaper.
-- @tparam table args
-- @tparam string args.modkey Primary modifier key (default "Mod4")
-- @tparam widget args.launcher Wibar launcher widget (from menus.setup)
function M.setup(args)
	args = args or {}
	local launcher = args.launcher
	local modkey = args.modkey or "Mod4"
	local components = beautiful.wibar_components or default_components

	-- Resolve theme name for wallpaper path from beautiful
	local theme_name = beautiful.theme_name or "default"

	screen.connect_signal("request::desktop_decoration", function(s)
		-- Restore saved tags if this output was previously removed (hotplug)
		local output_name = s.output and s.output.name
		local restore = output_name and awful.permissions.saved_tags
			and awful.permissions.saved_tags[output_name]
		if restore then
			awful.permissions.saved_tags[output_name] = nil
			local client_tags = {}
			for _, td in ipairs(restore) do
				local t = awful.tag.add(td.name, {
					screen = s,
					layout = td.layout,
					master_width_factor = td.master_width_factor,
					master_count = td.master_count,
					gap = td.gap,
					selected = td.selected,
				})
				for _, c in ipairs(td.clients) do
					if c.valid then
						if not client_tags[c] then client_tags[c] = {} end
						table.insert(client_tags[c], t)
					end
				end
			end
			for c, tags in pairs(client_tags) do
				c:move_to_screen(s)
				c:tags(tags)
			end
		else
			awful.tag({ "1", "2", "3", "4", "5", "6", "7", "8", "9" }, s, awful.layout.layouts[1])
		end

		-- Promptbox, taglist, tasklist
		s.mypromptbox = awful.widget.prompt()

		s.mytaglist = awful.widget.taglist {
			screen  = s,
			filter  = awful.widget.taglist.filter.all,
			buttons = {
				awful.button({ }, 1, function(t) t:view_only() end),
				awful.button({ modkey }, 1, function(t)
					if client.focus then client.focus:move_to_tag(t) end
				end),
				awful.button({ }, 3, awful.tag.viewtoggle),
				awful.button({ modkey }, 3, function(t)
					if client.focus then client.focus:toggle_tag(t) end
				end),
				awful.button({ }, 4, function(t) awful.tag.viewprev(t.screen) end),
				awful.button({ }, 5, function(t) awful.tag.viewnext(t.screen) end),
			}
		}

		s.mytasklist = awful.widget.tasklist {
			screen  = s,
			filter  = awful.widget.tasklist.filter.currenttags,
			buttons = {
				awful.button({ }, 1, function(c)
					c:activate { context = "tasklist", action = "toggle_minimization" }
				end),
				awful.button({ }, 3, function() awful.menu.client_list { theme = { width = 250 } } end),
				awful.button({ }, 4, function() awful.client.focus.byidx(-1) end),
				awful.button({ }, 5, function() awful.client.focus.byidx( 1) end),
			}
		}

		-- Wibar (visual params from theme: wibar_*, shadow_drawin_*)
		s.mywibox = awful.wibar {
			position     = beautiful.wibar_position or "top",
			screen       = s,
			border_width = beautiful.wibar_border_width or 0,
			shadow = {
				enabled  = beautiful.shadow_drawin_enabled,
				radius   = beautiful.shadow_drawin_radius,
				offset_x = beautiful.shadow_drawin_offset_x,
				offset_y = beautiful.shadow_drawin_offset_y,
				opacity  = beautiful.shadow_drawin_opacity,
				color    = beautiful.shadow_drawin_color,
			},
			widget = {
				layout = wibox.layout.align.horizontal,
				{ -- Left widgets
					layout = wibox.layout.fixed.horizontal,
					launcher,
					s.mytaglist,
					s.mypromptbox,
				},
				s.mytasklist,
				factory.widget_bar(s, components),
			}
		}

		-- Tag-based Wallpaper System
		local wppath = beautiful.wallpaper_dir
			or (gears.filesystem.get_configuration_dir()
				.. "themes/" .. theme_name .. "/wallpapers/")

		local wp_service = require("fishlive.services.wallpaper")
		wp_service.init(s, wppath, "1.jpg", {
			browse_dirs = {
				os.getenv("HOME") .. "/Pictures/wallpapers",
			}
		})
	end)
end

return M
