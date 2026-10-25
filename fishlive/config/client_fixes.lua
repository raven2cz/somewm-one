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

local awful = require("awful")

local M = { _initialized = false, _resizing = setmetatable({}, { __mode = "k" }) }

function M.update_mpv_aspect(c)
	if c.class ~= "mpv" or not c.floating or c.fullscreen or c.maximized then
		return
	end

	-- The native aspect clamp includes titlebars and excludes borders.
	local geo = c:geometry()
	local cw, ch = geo.width, geo.height
	if cw > 0 and ch > 0 then
		c.aspect_ratio = cw / ch
	end
end

local function apply_aspect_geometry(c, geo, args)
	if not c.aspect_ratio or c.aspect_ratio <= 0
			or c.fullscreen or c.maximized then
		return geo
	end

	local cw, ch = geo.width, geo.height
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

	local new_w = cw
	local new_h = ch
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
			awful.placement.no_offscreen(c, { honor_workarea = true })
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
