---------------------------------------------------------------------------
--- Animations and client corners on somewm 2.x.
--
-- somewm 2.1 animates through the Clay declaration: theme keys for every
-- trigger, `c.animation` per client, `animation = { visible = ... }` on
-- wiboxes and popups. This module replaces the v1 `anim_client.lua`, which
-- drove `awesome.start_animation` (removed in 2.1) and SceneFX corner/blur
-- properties (no SceneFX in 2.x).
--
-- Mapping from the v1 anim_client config:
--   fade (map)        -> animation_appear = "fade", 0.5 s
--   close             -> animation_disappear = "fade", 0.4 s
--   maximize/fullscr. -> animation_maximize_duration 0.25 s
--   float toggle      -> animation_floating_duration 0.3 s
--   layout + swap     -> animation_layout_duration 0.15 s
--   focus             -> animation_focus_duration 0.15 s (border colour ease,
--                        new in 2.1, had no v1 equivalent)
--   tag switch        -> animation_tag = "fade", 0.2 s (v1 tag_slide is not
--                        available on 2.x; see somewm plans/v2/)
--   scenefx corners   -> c.shape = 14 through a rule, square for games/Wine
--   notifications     -> M.popup_animation, used by components/notifications
--   blur, minimize fade, layer-surface and dialog-specific animations have
--   no 2.1 equivalent and are dropped.
--
-- Theme files may set any `animation_*` key themselves; `apply_theme_keys`
-- only fills keys the active theme left unset, and runs again after every
-- theme switch (beautiful.init replaces the whole theme table).
--
-- Usage from rc.lua (after beautiful.init, before rules are evaluated for
-- the first client):
--   require("fishlive.config.animations").setup()
--
-- @module fishlive.config.animations
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local beautiful = require("beautiful")
local ruled = require("ruled")

local M = { _initialized = false }

--- Client corner radius in pixels (v1: scenefx.corner_radius).
M.corner_radius = 14

--- Classes that keep square corners (Lua patterns, matched by ruled).
M.square_classes = { "^steam_app_", "^Wine$", "^Xwayland$", "%.exe$" }

--- Defaults for the animation theme keys.
M.theme_defaults = {
	animation_appear = "fade",
	animation_appear_duration = 0.5,
	animation_disappear = "fade",
	animation_disappear_duration = 0.4,
	animation_maximize_duration = 0.25,
	animation_floating_duration = 0.3,
	animation_layout_duration = 0.15,
	animation_focus_duration = 0.15,
	animation_tag = "fade",
	animation_tag_duration = 0.2,
}

--- Animation policy for notification popups (awful.popup `animation`).
M.popup_animation = {
	visible = { duration = 0.5, enter = "fade", exit = "fade" },
}

--- Fill unset animation keys on the active theme.
function M.apply_theme_keys()
	for key, value in pairs(M.theme_defaults) do
		if beautiful[key] == nil then
			beautiful[key] = value
		end
	end
end

local function is_square_class(c)
	local class = c.class or ""
	for _, pattern in ipairs(M.square_classes) do
		if class:find(pattern) then return true end
	end
	return false
end

--- The radius a client should carry right now (nil = square).
function M.client_shape(c)
	if c.fullscreen or is_square_class(c) then return nil end
	return M.corner_radius
end

function M.setup()
	if M._initialized then return end
	M._initialized = true

	M.apply_theme_keys()

	ruled.client.connect_signal("request::rules", function()
		ruled.client.append_rule {
			id = "v2_corners",
			rule = {},
			callback = function(c)
				c.shape = M.client_shape(c)
			end,
		}
	end)

	-- Square while fullscreen, rounded again afterwards.
	client.connect_signal("property::fullscreen", function(c)
		c.shape = M.client_shape(c)
	end)
end

return M
