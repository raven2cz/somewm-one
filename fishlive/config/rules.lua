---------------------------------------------------------------------------
--- Client rules — ruled.client rule definitions.
--
-- All rules for client matching (floating, dialogs, tag assignments,
-- app-specific overrides). References screen[1].tags[...], so call AFTER
-- fishlive.config.screen.setup().
--
-- Usage from rc.lua:
--   require("fishlive.config.rules").setup()
--
-- Must run BEFORE titlebars.setup() and client_fixes.setup() — those
-- modules attach signal handlers that assume the rule set is in place.
--
-- @module fishlive.config.rules
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local awful = require("awful")
local ruled = require("ruled")
local client_fixes = require("fishlive.config.client_fixes")
local lgi_ok, lgi = pcall(require, "lgi")
local cairo = lgi_ok and lgi.cairo or _G.cairo

local M = { _initialized = false }

function M.setup()
	if M._initialized then return end
	M._initialized = true

	ruled.client.connect_signal("request::rules", function()
	-- All clients will match this rule.
	ruled.client.append_rule {
		id         = "global",
		rule       = {},
		properties = {
			focus     = awful.client.focus.filter,
			raise     = true,
			screen    = awful.screen.preferred,
			placement = awful.placement.no_overlap + awful.placement.no_offscreen
		}
	}

	-- Dialogs are floating and centered
	ruled.client.append_rule {
		id         = "dialogs",
		rule_any   = { type = { "dialog" } },
		except_any = {},
		properties = { floating = true },
		callback   = function(c) awful.placement.centered(c, nil) end
	}

	-- Add titlebars to normal clients and dialogs
	ruled.client.append_rule {
		id         = "titlebars",
		rule_any   = { type = { "normal", "dialog" } },
		properties = { titlebars_enabled = true }
	}

	-- Ulauncher
	ruled.client.append_rule {
		id         = "ulauncher",
		rule_any   = { name = { "Ulauncher - Application Launcher" } },
		properties = {
			focus        = awful.client.focus.filter,
			raise        = true,
			screen       = awful.screen.preferred,
			border_width = 0,
		}
	}

	-- Floating clients
	ruled.client.append_rule {
		id         = "floating",
		rule_any   = {
			instance = { "copyq", "pinentry" },
			class    = {
				"Arandr", "Blueman-manager", "Gpick", "Kruler", "Sxiv",
				"Tor Browser", "Wpa_gui", "veromix", "xtightvncviewer",
				"Pamac-manager",
				"Polkit-gnome-authentication-agent-1",
				"Polkit-kde-authentication-agent-1",
				"Gcr-prompter",
			},
			name     = {
				"Event Tester",
				"Remmina Remote Desktop Client",
				"win0",
			},
			role     = {
				"AlarmWindow",
				"ConfigManager",
				"pop-up",
			}
		},
		properties = { floating = true },
		callback   = function(c) awful.placement.centered(c, nil) end
	}

	-- FullHD Resolution for Remmina sessions
	ruled.client.append_rule {
		id         = "remmina",
		rule_any   = { instance = { "remmina" } },
		except_any = { name = { "Remmina Remote Desktop Client" } },
		properties = { floating = true },
		callback   = function(c)
			c.width = 1980
			c.height = 1080
			awful.placement.centered(c, nil)
		end
	}

	-- mpv: floating with aspect ratio preservation
	ruled.client.append_rule {
		id         = "mpv",
		rule_any   = { class = { "mpv" } },
		properties = {
			floating  = true,
			titlebars_enabled = true,
		},
		callback   = function(c)
			client_fixes.update_mpv_aspect(c)
			awful.placement.centered(c, nil)
		end
	}

	-- Blender -> active screen + active tag (handles case when screen[1] is off)
	ruled.client.append_rule {
		id         = "blender",
		rule_any   = { name = { "Blender" } },
		callback   = function(c)
			local s = awful.screen.focused()
			c.screen = s
			local t = s.selected_tag
			if t then c:move_to_tag(t) end
		end,
	}

	-- Obsidian -> active screen + active tag (handles case when screen[1] is off)
	ruled.client.append_rule {
		id         = "obsidian",
		rule_any   = { name = { "Obsidian" } },
		callback   = function(c)
			local s = awful.screen.focused()
			c.screen = s
			local t = s.selected_tag
			if t then c:move_to_tag(t) end
		end,
	}

	-- GLava visualizer (click-through, no focus)
	ruled.client.append_rule {
		id         = "glava",
		rule_any   = { name = { "GLava" } },
		properties = {
			focusable = false,
			ontop = true,
			skip_taskbar = true
		},
		callback   = function(c)
			local img = cairo.ImageSurface(cairo.Format.A1, 0, 0)
			c.shape_input = img._native
			img.finish()
		end
	}

	-- Web widgets (WebKitGTK) — no blur/corners to avoid SceneFX crash
	ruled.client.append_rule {
		id         = "webwidgets",
		rule_any   = { name = { "somewm%-widget.*" } },
		properties = {
			floating       = true,
			ontop          = true,
			border_width   = 0,
			corner_radius  = 0,
			backdrop_blur  = false,
			shadow         = { enabled = false },
		},
	}
	end)
end

return M
