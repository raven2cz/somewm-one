---------------------------------------------------------------------------
--- Client fixes — app-specific workarounds for Steam and mpv.
--
-- Connects client property signals to fix known app-specific issues.
--
-- Usage from rc.lua:
--   require("fishlive.config.client_fixes").setup()
--
-- Must run AFTER rules.setup() — the mpv rule sets `floating = true`
-- and titlebars; this module's property handlers only run for clients
-- already classified by the rule engine.
--
-- @module fishlive.config.client_fixes
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local naughty = require("naughty")

local M = { _initialized = false, _resizing = setmetatable({}, { __mode = "k" }) }

local function titlebar_sizes(c)
	local _, top = c:titlebar_top()
	local _, right = c:titlebar_right()
	local _, bottom = c:titlebar_bottom()
	local _, left = c:titlebar_left()
	return top or 0, right or 0, bottom or 0, left or 0
end

-- Content area of a client, i.e. what the aspect ratio describes.
-- Only titlebars come off: c:geometry() has been border-exclusive since the
-- kolo10 upstream sync (3f6cfd9/a247cd5), and the compositor's own aspect
-- clamp in window.c/objects/client.c uses the same definition. Subtracting the
-- border here as well made the two disagree by 2*border_width, and since
-- update_mpv_aspect re-derives the ratio from geometry on every
-- property::size, the disagreement compounded and the window crept smaller.
local function content_size(c, geo)
	local top, right, bottom, left = titlebar_sizes(c)
	return geo.width - left - right,
		geo.height - top - bottom
end

function M.update_mpv_aspect(c)
	if c.class ~= "mpv" or not c.floating or c.fullscreen or c.maximized then
		return
	end

	-- Skip if a geometry animation is in flight. anim_client emits
	-- property::size for every interpolated frame; capturing aspect from
	-- mid-animation geometry creates a feedback loop where the C-side
	-- aspect_ratio constraint and update_mpv_aspect drift the ratio per
	-- frame (observed on the fullscreen→windowed return path: ratio
	-- shifted ~2 % per F-cycle and grew over repeated cycles).
	local ok, anim = pcall(require, "anim_client")
	if ok and anim.is_geo_animating and anim.is_geo_animating(c) then
		return
	end

	local cw, ch = content_size(c, c:geometry())
	if cw > 0 and ch > 0 then
		c.aspect_ratio = cw / ch
	end
end

local function apply_aspect_geometry(c, geo, args)
	if not c.aspect_ratio or c.aspect_ratio <= 0
			or c.fullscreen or c.maximized then
		return geo
	end

	-- Titlebars only; see content_size() on why the border is not included.
	local top, right, bottom, left = titlebar_sizes(c)
	local deco_w = left + right
	local deco_h = top + bottom
	local cw = geo.width - deco_w
	local ch = geo.height - deco_h
	if cw <= 0 or ch <= 0 then
		return geo
	end

	local corner = args and args.corner or ""
	local has_left = corner:find("left", 1, true) ~= nil
	local has_right = corner:find("right", 1, true) ~= nil
	local has_top = corner:find("top", 1, true) ~= nil
	local has_bottom = corner:find("bottom", 1, true) ~= nil
	local ratio = c.aspect_ratio

	if (has_left or has_right) and not (has_top or has_bottom) then
		ch = math.max(1, math.floor(cw / ratio + 0.5))
	elseif (has_top or has_bottom) and not (has_left or has_right) then
		cw = math.max(1, math.floor(ch * ratio + 0.5))
	else
		local current = cw / ch
		if current > ratio then
			cw = math.max(1, math.floor(ch * ratio + 0.5))
		else
			ch = math.max(1, math.floor(cw / ratio + 0.5))
		end
	end

	local new_w = cw + deco_w
	local new_h = ch + deco_h
	local right_edge = geo.x + geo.width
	local bottom_edge = geo.y + geo.height

	if has_left then
		geo.x = right_edge - new_w
	elseif not has_right then
		geo.x = geo.x + math.floor((geo.width - new_w) / 2 + 0.5)
	end
	if has_top then
		geo.y = bottom_edge - new_h
	elseif not has_bottom then
		geo.y = geo.y + math.floor((geo.height - new_h) / 2 + 0.5)
	end
	geo.width = new_w
	geo.height = new_h

	return geo
end

function M.setup()
	if M._initialized then return end
	M._initialized = true
	local mouse_resize = require("awful.mouse.resize")

	-- Steam bug: windows positioned outside screen bounds
	client.connect_signal("property::position", function(c)
		if c.class == "Steam" then
			local g = c.screen.geometry
			if c.y + c.height > g.height then
				c.y = g.height - c.height
				naughty.notification { message = "restricted window: " .. c.name }
			end
			if c.x + c.width > g.width then
				c.x = g.width - c.width
			end
		end
	end)

	mouse_resize.add_enter_callback(function(c)
		if c.class == "mpv" then
			M._resizing[c] = true
		end
	end, "mouse.resize")

	mouse_resize.add_move_callback(function(c, geo, args)
		if c.class == "mpv" then
			return apply_aspect_geometry(c, geo, args)
		end
	end, "mouse.resize")

	mouse_resize.add_leave_callback(function(c)
		if c.class == "mpv" then
			M._resizing[c] = nil
		end
	end, "mouse.resize")

	-- mpv: update aspect ratio when video changes (playlist advancement).
	-- mpv resizes the window to match the new video's native dimensions,
	-- which emits property::size. We recapture the ratio so subsequent
	-- user resizes maintain the new video's proportions.
	client.connect_signal("property::size", function(c)
		if c.class == "mpv" and not M._resizing[c] then
			M.update_mpv_aspect(c)
		end
	end)
end

return M
