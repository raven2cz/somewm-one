---------------------------------------------------------------------------
--- Titlebars — standard AwesomeWM titlebar request handler.
--
-- Creates titlebars with icon, title, and window control buttons, then
-- hides them by default. Toggle with Super+T (bound in keybindings.lua).
--
-- Usage from rc.lua:
--   require("fishlive.config.titlebars").setup()
--
-- Must run AFTER rules.setup() — rules.lua owns the `titlebars_enabled`
-- property; the `request::titlebars` signal fires during client manage
-- after rules apply.
--
-- @module fishlive.config.titlebars
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local awful = require("awful")
local wibox = require("wibox")

local M = { _initialized = false }

function M.setup()
	if M._initialized then return end
	M._initialized = true

	client.connect_signal("request::titlebars", function(c)
	local buttons = {
		awful.button({ }, 1, function()
			c:activate { context = "titlebar", action = "mouse_move" }
		end),
		awful.button({ }, 3, function()
			c:activate { context = "titlebar", action = "mouse_resize" }
		end),
	}

	awful.titlebar(c).widget = {
		{ -- Left
			awful.titlebar.widget.iconwidget(c),
			buttons = buttons,
			layout  = wibox.layout.fixed.horizontal
		},
		{ -- Middle
			{ -- Title
				halign = "center",
				widget = awful.titlebar.widget.titlewidget(c)
			},
			buttons = buttons,
			layout  = wibox.layout.flex.horizontal
		},
		{ -- Right
			awful.titlebar.widget.floatingbutton(c),
			awful.titlebar.widget.maximizedbutton(c),
			awful.titlebar.widget.stickybutton(c),
			awful.titlebar.widget.ontopbutton(c),
			awful.titlebar.widget.closebutton(c),
			layout = wibox.layout.fixed.horizontal()
		},
		layout = wibox.layout.align.horizontal
	}
	awful.titlebar.hide(c)
	end)
end

return M
