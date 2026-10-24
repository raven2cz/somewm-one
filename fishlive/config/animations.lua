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
--   tag switch        -> KDE-like slide (M.tag_slide): a switch to a higher
--                        tag index brings the new clients in from the right
--                        edge, a lower index from the left; 0.25 s. The
--                        wallpaper switches at once (measured), and 2.1
--                        animates only the frame of a leaving client, its
--                        content snaps away, so only the arriving windows
--                        visibly slide. One global word: two screens
--                        switching in opposite directions in the same frame
--                        would share the last one (not seen in use). The v1
--                        tag_slide::start/end signals (shell collage) are
--                        emitted around the slide.
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
local gears = require("gears")
local ruled = require("ruled")

local M = { _initialized = false }

--- Client corner radius in pixels (v1: scenefx.corner_radius).
M.corner_radius = 14

--- Classes that keep square corners (Lua patterns on c.class).
M.square_classes = { "^steam_app_", "^Wine$", "^Xwayland$", "%.exe$" }

--- Window names that keep square corners (Lua patterns on c.name): the
-- WebKitGTK desktop widgets (rules.lua "webwidgets").
M.square_names = { "^somewm%-widget" }

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
	animation_tag_duration = 0.25,
}

--- Slide clients on a tag switch, direction by tag index. false keeps the
-- theme's animation_tag (fade by default).
M.tag_slide = true

--- Entrance words for a switch to a higher / lower tag index. A slide word
-- names the edge arriving clients come from (measured on 2.1: slide_right
-- enters from the right edge).
M.slide_words = { forward = "slide_right", backward = "slide_left" }

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
	local class, name = c.class or "", c.name or ""
	for _, pattern in ipairs(M.square_classes) do
		if class:find(pattern) then return true end
	end
	for _, pattern in ipairs(M.square_names) do
		if name:find(pattern) then return true end
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

	-- Tag slide: the tag word is read when the next frame is declared,
	-- after property::selected, so choosing it here applies to both the
	-- clients leaving and the ones arriving.
	local last_index = setmetatable({}, { __mode = "k" })
	-- Per-screen slide generation: a switch inside a running slide restarts
	-- it, so only the latest slide's timer may announce the end.
	local slide_gen = setmetatable({}, { __mode = "k" })
	for s in screen do
		last_index[s] = s.selected_tag and s.selected_tag.index
	end
	tag.connect_signal("property::selected", function(t)
		if not M.tag_slide or not t.screen then return end
		if not t.selected then
			-- First switch on a screen: the tag being left is the origin.
			if last_index[t.screen] == nil then last_index[t.screen] = t.index end
			return
		end
		local prev = last_index[t.screen]
		last_index[t.screen] = t.index
		if prev and prev ~= t.index then
			beautiful.animation_tag = t.index > prev
				and M.slide_words.forward or M.slide_words.backward
			-- The v1 tag_slide signals, kept for somewm-shell's collage,
			-- which defers its rebuild until the slide is over.
			local s = t.screen
			local gen = (slide_gen[s] or 0) + 1
			slide_gen[s] = gen
			awesome.emit_signal("tag_slide::start", s, t.name)
			gears.timer.start_new(beautiful.animation_tag_duration or 0, function()
				if slide_gen[s] == gen then
					awesome.emit_signal("tag_slide::end", s)
				end
				return false
			end)
		end
	end)

	-- Square while fullscreen, rounded again afterwards.
	client.connect_signal("property::fullscreen", function(c)
		c.shape = M.client_shape(c)
	end)
end

return M
