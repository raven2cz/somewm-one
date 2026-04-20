---------------------------------------------------------------------------
--- Wallpaper service — per-tag wallpaper management with override support.
--
-- Replaces inline wallpaper code in rc.lua with a proper service.
-- Supports per-tag user wallpapers and theme wallpapers with a 4-tier
-- resolution chain:
--   0. In-memory override (runtime preview, not persisted)
--   1. user-wallpapers/{tag}.{ext} (user choice, per-theme, HIGHEST disk)
--   2. wallpapers/{tag}.{ext} (theme default)
--   3. themes/default/wallpapers/{tag}.{ext} (global fallback, LOWEST)
--
-- IPC API (via somewm-client eval):
--   require('fishlive.services.wallpaper').save_to_theme(tag_name, path)
--   require('fishlive.services.wallpaper').set_override(tag_name, path)
--   require('fishlive.services.wallpaper').clear_override(tag_name)
--   require('fishlive.services.wallpaper').get_overrides_json()
--   require('fishlive.services.wallpaper').get_current()
--   require('fishlive.services.wallpaper').get_browse_dirs_json()
--   require('fishlive.services.wallpaper').get_tags_json()
--   require('fishlive.services.wallpaper').get_theme_wallpapers_dir()
--   require('fishlive.services.wallpaper').get_resolved_json()
--   require('fishlive.services.wallpaper').clear_user_wallpaper(tag_name)
--   require('fishlive.services.wallpaper').view_tag(tag_name)
--
-- @module fishlive.services.wallpaper
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")
local broker = require("fishlive.broker")

local wallpaper = {}

-- State
wallpaper._overrides = {}         -- { [tag_name] = "/absolute/path.jpg" } (runtime only)
wallpaper._wppath = nil           -- themes/{active}/wallpapers/
wallpaper._user_wppath = nil      -- themes/{active}/user-wallpapers/
wallpaper._default_wppath = nil   -- themes/default/wallpapers/ (global fallback)
wallpaper._default = "1.jpg"      -- fallback wallpaper filename
wallpaper._browse_dirs = {}       -- dirs for folder browsing in picker
wallpaper._initialized = false

-- Image extensions to try when resolving tag wallpapers
local IMG_EXTENSIONS = { ".jpg", ".png", ".webp", ".jpeg" }

-- Whitelisted extensions for save operations
local SAFE_EXT = { jpg = true, jpeg = true, png = true, webp = true }

--- Try to find a wallpaper for a tag in a given directory.
-- @tparam string dir Directory path (must end with /)
-- @tparam string tag_name Tag name
-- @treturn string|nil Absolute path if found, nil otherwise
local function find_in_dir(dir, tag_name)
	if not dir then return nil end
	for _, ext in ipairs(IMG_EXTENSIONS) do
		local path = dir .. tag_name .. ext
		if gears.filesystem.file_readable(path) then
			return path
		end
	end
	return nil
end

--- Update tag_slide wallpaper cache for a specific path.
-- Call after changing a wallpaper so animation overlays use the new image.
-- @tparam string path Absolute path to the new wallpaper
local function update_slide_cache(path)
	if not path or not root.wallpaper_cache_preload then return end
	for scr in screen do
		root.wallpaper_cache_preload({ path }, scr, { fit = "cover" })
	end
end

--- Build a cover-scaled Cairo surface for the given image and screen geometry.
-- Matches the C-side cache formula: scale = max(scale_x, scale_y), centered.
-- @tparam string path  Absolute path to the image file
-- @tparam number scr_w Screen width in pixels
-- @tparam number scr_h Screen height in pixels
-- @treturn cairo.ImageSurface|nil  Cropped, cover-scaled surface (or nil on error)
local function make_cover_surface(path, scr_w, scr_h)
	local lgi   = require("lgi")
	local cairo = lgi.cairo

	-- Load source surface via gears (handles PNG, JPEG, etc.)
	local src = gears.surface(path)
	if not src then return nil end

	local img_w = src.width
	local img_h = src.height
	if img_w == 0 or img_h == 0 then return nil end

	-- Cover: use the LARGER scale factor so the image fills the screen on
	-- both axes, cropping the overflow (identical to the C-side cache logic).
	local scale_x = scr_w / img_w
	local scale_y = scr_h / img_h
	local scale   = math.max(scale_x, scale_y)

	-- Scaled image size after applying cover scale
	local sw = img_w * scale
	local sh = img_h * scale

	-- Center the scaled image over the screen (negative offsets = crop)
	local offset_x = (scr_w - sw) / 2
	local offset_y = (scr_h - sh) / 2

	-- Draw into a screen-sized surface — the clip provided by the surface
	-- boundary is what implements the crop in cover mode.
	local dst = cairo.ImageSurface(cairo.Format.ARGB32, scr_w, scr_h)
	local cr  = cairo.Context(dst)

	cr:scale(scale, scale)
	cr:set_source_surface(src, offset_x / scale, offset_y / scale)
	cr:paint()

	return dst
end

--- Apply wallpaper to a screen using awful.wallpaper API (HiDPI-aware).
-- Uses cover scaling to match the C-side tag_slide animation cache exactly,
-- preventing the visual "jump" when the animation overlay is destroyed.
-- @tparam screen scr The screen object
-- @tparam string path Absolute path to wallpaper image
local function apply_wallpaper(scr, path)
	if not path or not gears.filesystem.file_readable(path) then
		return false
	end

	-- Skip redundant updates
	if scr._current_wallpaper == path then return true end

	local geo  = scr.geometry
	local surf = make_cover_surface(path, geo.width, geo.height)

	-- Create a fresh awful.wallpaper each time — the constructor handles
	-- repaint and properly replaces the previous wallpaper for this screen.
	if surf then
		-- Fast path: hand the pre-scaled cover surface directly to imagebox.
		-- With resize=false the imagebox renders it 1:1 (no further scaling),
		-- which is exactly the cover-cropped output we computed above.
		awful.wallpaper {
			screen = scr,
			widget = {
				{
					image  = surf,
					resize = false,
					widget = wibox.widget.imagebox,
				},
				valign = "center",
				halign = "center",
				tiled  = false,
				widget = wibox.container.tile,
			}
		}
	else
		-- Fallback: contain scaling if surface construction fails.
		awful.wallpaper {
			screen = scr,
			widget = {
				{
					image     = path,
					upscale   = true,
					downscale = true,
					widget    = wibox.widget.imagebox,
				},
				valign = "center",
				halign = "center",
				tiled  = false,
				widget = wibox.container.tile,
			}
		}
	end

	scr._current_wallpaper = path
	return true
end

--- Resolve wallpaper path for a tag using the 4-tier priority chain.
-- 0. In-memory override (runtime preview)
-- 1. user-wallpapers/{tag}.{ext} (user choice, per-theme)
-- 2. wallpapers/{tag}.{ext} (theme default)
-- 3. themes/default/wallpapers/{tag}.{ext} (global fallback)
-- @tparam string tag_name The tag name (e.g. "1", "2", ...)
-- @treturn string|nil Absolute path to the wallpaper file, or nil
function wallpaper._resolve(tag_name)
	-- 0. Check in-memory override (runtime preview)
	if wallpaper._overrides[tag_name] then
		local path = wallpaper._overrides[tag_name]
		if gears.filesystem.file_readable(path) then
			return path
		end
		-- Override file disappeared — clear it
		wallpaper._overrides[tag_name] = nil
	end

	-- 1. User wallpapers: user-wallpapers/{tag}.{ext}
	local found = find_in_dir(wallpaper._user_wppath, tag_name)
	if found then return found end

	-- 2. Theme wallpapers: wallpapers/{tag}.{ext}
	found = find_in_dir(wallpaper._wppath, tag_name)
	if found then return found end

	-- 3. Global fallback: themes/default/wallpapers/{tag}.{ext}
	found = find_in_dir(wallpaper._default_wppath, tag_name)
	if found then return found end

	-- 4. Last resort: default file in theme wallpapers
	if wallpaper._wppath then
		local path = wallpaper._wppath .. wallpaper._default
		if gears.filesystem.file_readable(path) then
			return path
		end
	end

	-- 5. Very last resort: default file in global fallback
	if wallpaper._default_wppath then
		local path = wallpaper._default_wppath .. wallpaper._default
		if gears.filesystem.file_readable(path) then
			return path
		end
	end

	return nil
end

--- Initialize the wallpaper service for a screen.
-- Call this inside awful.screen.connect_for_each_screen.
--
-- @tparam screen scr The screen object
-- @tparam string wppath Base wallpaper directory (themes/name/wallpapers/)
-- @tparam[opt="1.jpg"] string default_wallpaper Default fallback filename
-- @tparam[opt] table opts Options: { browse_dirs = {"/path1", "/path2"} }
function wallpaper.init(scr, wppath, default_wallpaper, opts)
	wallpaper._wppath = wppath
	wallpaper._user_wppath = wppath:gsub("wallpapers/$", "user-wallpapers/")
	wallpaper._default_wppath = gears.filesystem.get_configuration_dir()
		.. "themes/default/wallpapers/"
	wallpaper._default = default_wallpaper or "1.jpg"
	wallpaper._browse_dirs = opts and opts.browse_dirs or {}

	-- Expose wppath for tag_slide animation overlays
	scr._wppath = wppath

	-- Initial wallpaper: use screen's first tag name
	local first_tag = scr.tags and scr.tags[1]
	local init_tag = first_tag and first_tag.name or "1"
	local path = wallpaper._resolve(init_tag)
	if path then apply_wallpaper(scr, path) end

	-- Pre-cache all resolved wallpapers for tag_slide animation overlays.
	-- Clear stale cache only ONCE per session — cache_clear() is global (wipes
	-- all screens), so on multi-screen setups (connect_for_each_screen runs
	-- per screen) repeated clears would erase entries preloaded for screens
	-- processed earlier. Previous-session staleness is handled by the first call.
	if root.wallpaper_cache_clear and not wallpaper._cache_cleared_this_session then
		root.wallpaper_cache_clear()
		wallpaper._cache_cleared_this_session = true
	end
	if root.wallpaper_cache_preload then
		local paths = {}
		for _, tag in ipairs(scr.tags) do
			local wp = wallpaper._resolve(tag.name)
			if wp then table.insert(paths, wp) end
		end
		if #paths > 0 then root.wallpaper_cache_preload(paths, scr, { fit = "cover" }) end
	end

	-- Switch wallpaper on tag selection
	for _, tag in ipairs(scr.tags) do
		tag:connect_signal("property::selected", function(t)
			if t.selected then
				local wp = wallpaper._resolve(t.name)
				if wp then apply_wallpaper(t.screen, wp) end
			end
		end)
	end

	-- Re-apply on screen geometry change (hotplug, transform/resolution switch).
	-- apply_wallpaper's cover surface bakes in geo.width × geo.height at apply
	-- time; if the screen comes up with a pre-transform geometry (e.g. HP
	-- portrait transiently visible as 3840×2160 landscape before transform "90"
	-- settles to 2160×3840) the cover surface ends up with stale dimensions and
	-- the wallpaper shows letterboxed on the final orientation. Invalidate this
	-- screen's cache entries, drop _current_wallpaper, then re-run apply and
	-- cache preload so both the active surface and the cached scene buffers
	-- match the final output layout.
	scr:connect_signal("property::geometry", function(s)
		if root.wallpaper_cache_invalidate_screen then
			root.wallpaper_cache_invalidate_screen(s.index)
		end
		s._current_wallpaper = nil

		local sel = s.selected_tag
		local tag_name = sel and sel.name or (s.tags[1] and s.tags[1].name) or "1"
		local wp = wallpaper._resolve(tag_name)
		if wp then apply_wallpaper(s, wp) end

		if root.wallpaper_cache_preload then
			local paths = {}
			for _, tag in ipairs(s.tags) do
				local p = wallpaper._resolve(tag.name)
				if p then table.insert(paths, p) end
			end
			if #paths > 0 then root.wallpaper_cache_preload(paths, s, { fit = "cover" }) end
		end
	end)
end

--- Set a wallpaper override for a tag (runtime preview, not persisted).
-- The override persists in memory until cleared or save_to_theme is called.
-- If the tag is currently selected, the wallpaper is applied immediately.
--
-- @tparam string tag_name Tag name (e.g. "1")
-- @tparam string path Absolute path to wallpaper image
function wallpaper.set_override(tag_name, path)
	if not path or path == "" then return end
	wallpaper._overrides[tag_name] = path

	-- Apply immediately if this tag is currently selected on any screen
	for scr in screen do
		local sel = scr.selected_tag
		if sel and sel.name == tag_name then
			apply_wallpaper(scr, path)
		end
	end

	-- Update tag_slide cache so animation uses new wallpaper
	update_slide_cache(path)

	-- Notify shell of change
	broker.emit_signal("data::wallpaper", wallpaper._get_state())
end

--- Clear a wallpaper override for a tag, reverting to resolved wallpaper.
-- @tparam string tag_name Tag name
function wallpaper.clear_override(tag_name)
	wallpaper._overrides[tag_name] = nil

	-- Revert to resolved wallpaper if this tag is currently selected
	local resolved = wallpaper._resolve(tag_name)
	for scr in screen do
		local sel = scr.selected_tag
		if sel and sel.name == tag_name then
			if resolved then apply_wallpaper(scr, resolved) end
		end
	end

	-- Update tag_slide cache so animation uses reverted wallpaper
	if resolved then update_slide_cache(resolved) end

	broker.emit_signal("data::wallpaper", wallpaper._get_state())
end

--- Save a wallpaper into the user-wallpapers directory for the active theme.
-- Copies the source file to user-wallpapers/{tag_name}.{ext}.
-- Does NOT overwrite theme default wallpapers in wallpapers/.
-- Each theme has its own user-wallpapers/ directory.
--
-- @tparam string tag_name Tag name (e.g. "3")
-- @tparam string source_path Absolute path to source wallpaper image
-- @treturn boolean True if saved and applied successfully
function wallpaper.save_to_theme(tag_name, source_path)
	if not source_path or source_path == "" then return false end
	if not wallpaper._user_wppath then return false end
	-- Validate tag_name: only safe basenames (no path traversal)
	if not tag_name or tag_name == "" then return false end
	if tag_name:match("[/\\]") or tag_name == ".." or tag_name == "." then return false end
	if not gears.filesystem.file_readable(source_path) then return false end

	-- Determine extension from source, whitelist only image extensions
	local ext = source_path:match("%.([^%.]+)$") or "jpg"
	ext = ext:lower()
	if not SAFE_EXT[ext] then ext = "jpg" end

	-- Ensure user-wallpapers/ directory exists
	-- Use Lua's lfs or fallback to safe os.execute with single-quote escaping
	local safe_path = wallpaper._user_wppath:gsub("'", "'\\''")
	os.execute("mkdir -p -- '" .. safe_path .. "'")

	-- Remove any existing file for this tag in user-wallpapers/ (different ext)
	for _, e in ipairs({ "jpg", "jpeg", "png", "webp" }) do
		local old = wallpaper._user_wppath .. tag_name .. "." .. e
		os.remove(old)
	end

	-- Copy source to user-wallpapers dir
	local dest = wallpaper._user_wppath .. tag_name .. "." .. ext
	local src_file = io.open(source_path, "rb")
	if not src_file then return false end
	local data = src_file:read("*a")
	src_file:close()

	local dst_file = io.open(dest, "wb")
	if not dst_file then return false end
	dst_file:write(data)
	dst_file:close()

	-- Clear any in-memory override (user-wallpapers file is the source now)
	wallpaper._overrides[tag_name] = nil

	-- Apply immediately on all screens showing this tag
	for scr in screen do
		local sel = scr.selected_tag
		if sel and sel.name == tag_name then
			scr._current_wallpaper = nil  -- force re-apply
			apply_wallpaper(scr, dest)
		end
	end

	-- Update tag_slide cache so animation uses new wallpaper
	update_slide_cache(dest)

	broker.emit_signal("data::wallpaper", wallpaper._get_state())
	return true
end

--- Set the main wallpaper (tag "1" override).
-- Convenience function for the shell wallpaper picker.
-- @tparam string path Absolute path to wallpaper image
function wallpaper.set_main_wallpaper(path)
	wallpaper.set_override("1", path)
end

--- Get current wallpaper state as a table.
-- @treturn table { current, overrides, wppath, user_wppath, browse_dirs }
function wallpaper._get_state()
	local current = nil
	local focused = awful.screen.focused()
	if focused then
		current = focused._current_wallpaper
	end
	return {
		current = current or "",
		overrides = wallpaper._overrides,
		wppath = wallpaper._wppath or "",
		user_wppath = wallpaper._user_wppath or "",
		browse_dirs = wallpaper._browse_dirs,
	}
end

--- Get overrides as JSON string (for IPC).
-- @treturn string JSON representation of override map
function wallpaper.get_overrides_json()
	local parts = {}
	for k, v in pairs(wallpaper._overrides) do
		local ek = k:gsub('\\', '\\\\'):gsub('"', '\\"')
		local ev = v:gsub('\\', '\\\\'):gsub('"', '\\"')
		table.insert(parts, '"' .. ek .. '":"' .. ev .. '"')
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

--- Get the current wallpaper path for the focused screen (for IPC).
-- @treturn string Current wallpaper path or empty string
function wallpaper.get_current()
	local focused = awful.screen.focused()
	return focused and focused._current_wallpaper or ""
end

--- Get browse directories as JSON array (for IPC).
-- @treturn string JSON array of directory paths
function wallpaper.get_browse_dirs_json()
	local parts = {}
	for _, dir in ipairs(wallpaper._browse_dirs) do
		local ed = dir:gsub('\\', '\\\\'):gsub('"', '\\"')
		table.insert(parts, '"' .. ed .. '"')
	end
	return "[" .. table.concat(parts, ",") .. "]"
end

--- Get tag names from the focused screen as JSON array (for IPC).
-- @treturn string JSON array of tag name strings
function wallpaper.get_tags_json()
	local focused = awful.screen.focused()
	if not focused then return "[]" end
	local parts = {}
	for _, tag in ipairs(focused.tags) do
		local et = tag.name:gsub('\\', '\\\\'):gsub('"', '\\"')
		table.insert(parts, '"' .. et .. '"')
	end
	return "[" .. table.concat(parts, ",") .. "]"
end

--- Get the active theme wallpapers directory path (for IPC).
-- @treturn string Path to active theme's wallpapers/ directory
function wallpaper.get_theme_wallpapers_dir()
	return wallpaper._wppath or ""
end

--- Get resolved wallpaper state for every tag on focused screen (for IPC).
-- Returns the actual wallpaper displayed per tag (result of _resolve()),
-- including whether it's a user-override or theme default.
-- @treturn string JSON array of {tag, path, isUserOverride} objects
function wallpaper.get_resolved_json()
	local focused = awful.screen.focused()
	if not focused then return "[]" end
	local parts = {}
	for _, tag in ipairs(focused.tags) do
		local tag_name = tag.name
		local path = wallpaper._resolve(tag_name)
		-- A user-wallpaper file exists on disk for this tag (deletable via reset)
		local is_user = find_in_dir(wallpaper._user_wppath, tag_name) ~= nil
		local ep = (path or ""):gsub('\\', '\\\\'):gsub('"', '\\"')
		local et = tag_name:gsub('\\', '\\\\'):gsub('"', '\\"')
		table.insert(parts,
			'{"tag":"' .. et .. '","path":"' .. ep ..
			'","isUserOverride":' .. tostring(is_user) .. '}')
	end
	return "[" .. table.concat(parts, ",") .. "]"
end

--- Delete user-wallpaper file for a tag, reverting to theme default (for IPC).
-- Only removes files from user-wallpapers/ directory. Theme defaults are protected.
-- @tparam string tag_name Tag name to clear
-- @treturn boolean True if a file was actually removed
function wallpaper.clear_user_wallpaper(tag_name)
	if not tag_name or tag_name == "" then return false end
	if not tag_name:match("^[%w%-_]+$") then return false end
	if not wallpaper._user_wppath then return false end

	-- Remove user-wallpaper file for this tag (all extensions)
	local removed = false
	for _, ext in ipairs(IMG_EXTENSIONS) do
		local path = wallpaper._user_wppath .. tag_name .. ext
		if os.remove(path) then removed = true end
	end

	-- Also clear any in-memory override
	wallpaper._overrides[tag_name] = nil

	-- Re-resolve and apply on all screens showing this tag
	local resolved = wallpaper._resolve(tag_name)
	for scr in screen do
		local sel = scr.selected_tag
		if sel and sel.name == tag_name then
			scr._current_wallpaper = nil  -- force re-apply
			if resolved then apply_wallpaper(scr, resolved) end
		end
	end

	if resolved then update_slide_cache(resolved) end
	broker.emit_signal("data::wallpaper", wallpaper._get_state())
	return removed
end

--- Switch to a specific tag on the focused screen (for IPC).
-- Used by the wallpaper picker tag selector.
-- @tparam string tag_name Tag name to switch to
function wallpaper.view_tag(tag_name)
	local focused = awful.screen.focused()
	if not focused then return end
	for _, tag in ipairs(focused.tags) do
		if tag.name == tag_name then
			tag:view_only()
			return
		end
	end
end

--- Apply a wallpaper to a screen (public wrapper for theme switching).
-- @tparam screen scr The screen object
-- @tparam string path Absolute path to wallpaper image
-- @treturn boolean True if applied
function wallpaper.apply(scr, path)
	return apply_wallpaper(scr, path)
end

return wallpaper
