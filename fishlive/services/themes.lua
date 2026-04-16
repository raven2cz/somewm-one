---------------------------------------------------------------------------
--- Theme service — scan, preview, and switch themes at runtime.
--
-- Each theme lives in ~/.config/somewm/themes/{name}/ with:
--   theme.lua      — color definitions (beautiful module format)
--   wallpapers/    — per-tag wallpapers (1.jpg, 2.jpg, ...)
--   icons/         — optional theme-specific icons
--   layouts/       — optional layout indicator images
--   titlebar/      — optional titlebar button images
--
-- IPC API (via somewm-client eval):
--   require('fishlive.services.themes').scan_json()
--   require('fishlive.services.themes').switch("theme_name")
--   require('fishlive.services.themes').get_current()
--   require('fishlive.services.themes').get_palette_json("theme_name")
--
-- @module fishlive.services.themes
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local awful = require("awful")
local beautiful = require("beautiful")
local gears = require("gears")
local broker = require("fishlive.broker")

local themes = {}

-- State file for persisting active theme across restarts
local STATE_FILE = gears.filesystem.get_configuration_dir() .. ".active_theme"

--- Validate that a theme name is a safe basename (no path traversal).
-- @tparam string name Theme name to validate
-- @treturn boolean True if safe
local function is_safe_name(name)
	if not name or name == "" then return false end
	-- Only allow alphanumeric, dash, underscore, dot (no slashes, no ..)
	if name:match("[/\\]") or name == ".." or name == "." then return false end
	return name:match("^[%w%-_%.]+$") ~= nil
end

-- Color keys to extract from theme.lua for palette preview
local PALETTE_KEYS = {
	"bg_normal", "bg_focus", "bg_minimize",
	"fg_normal", "fg_focus", "fg_minimize",
	"border_color_active", "border_color_marked",
	"bg_urgent",
	"widget_cpu_color", "widget_gpu_color", "widget_memory_color",
	"widget_disk_color", "widget_network_color", "widget_volume_color",
}

--- Get the themes base directory.
-- @treturn string Path to themes/ directory
local function get_themes_dir()
	return gears.filesystem.get_configuration_dir() .. "themes/"
end

--- Read the persisted active theme name.
-- @treturn string Theme name (defaults to "default")
function themes.get_current()
	local f = io.open(STATE_FILE, "r")
	if not f then return "default" end
	local name = f:read("*l")
	f:close()
	if not name or name == "" then return "default" end
	-- Validate theme exists
	local path = get_themes_dir() .. name .. "/theme.lua"
	if gears.filesystem.file_readable(path) then return name end
	return "default"
end

--- Save the active theme name to state file.
-- @tparam string name Theme name
local function save_current(name)
	local f = io.open(STATE_FILE, "w")
	if not f then return end
	f:write(name .. "\n")
	f:close()
end

--- Extract color palette from a theme.lua without applying it.
-- Uses sandboxed loadfile to safely read theme colors.
-- @tparam string theme_path Absolute path to theme.lua
-- @treturn table|nil Palette table {bg_normal="#...", ...} or nil on error
function themes.get_palette(theme_path)
	if not gears.filesystem.file_readable(theme_path) then return nil end

	-- Sandboxed environment: whitelisted require only, no io/os/debug
	local SAFE_MODULES = {
		["beautiful.theme_assets"] = true,
		["beautiful.xresources"] = true,
		["ruled.notification"] = true,
		["gears.filesystem"] = true,
		["gears"] = true,
		["gears.color"] = true,
		["gears.shape"] = true,
		["dpi"] = true,
		["math"] = true,
		["string"] = true,
		["table"] = true,
	}
	local safe_require = function(mod)
		if SAFE_MODULES[mod] then return require(mod) end
		error("sandbox: module '" .. tostring(mod) .. "' not allowed", 2)
	end
	local sandbox = {
		require = safe_require,
		tostring = tostring,
		tonumber = tonumber,
		pairs = pairs,
		ipairs = ipairs,
		type = type,
		math = math,
		string = string,
		table = table,
		setmetatable = setmetatable,
		getmetatable = getmetatable,
		unpack = unpack or table.unpack,
	}

	-- Load theme.lua in sandboxed environment
	-- Lua 5.1: use setfenv; Lua 5.2+: use load with env parameter
	local chunk, err
	if setfenv then
		-- Lua 5.1 / LuaJIT
		chunk, err = loadfile(theme_path)
		if not chunk then return nil end
		setfenv(chunk, sandbox)
	else
		-- Lua 5.2+: read file and use load() with env
		local f = io.open(theme_path, "r")
		if not f then return nil end
		local code = f:read("*a")
		f:close()
		chunk, err = load(code, theme_path, "t", sandbox)
		if not chunk then return nil end
	end
	local ok, result = pcall(chunk)
	if not ok or type(result) ~= "table" then return nil end

	local palette = {}
	for _, key in ipairs(PALETTE_KEYS) do
		if result[key] then
			palette[key] = tostring(result[key])
		end
	end

	-- Also grab theme_name and font if present
	palette.theme_name = result.theme_name or nil
	palette.font = result.font or nil

	return palette
end

--- Wallpaper file extensions to look for.
local WP_EXTENSIONS = { jpg = true, jpeg = true, png = true, webp = true }

--- Count wallpaper files in a theme's wallpapers/ directory.
-- Uses safe Lua io.popen with %q-escaped paths to prevent shell injection.
-- @tparam string theme_dir Path to theme directory
-- @treturn number Number of wallpaper files found
local function count_wallpapers(theme_dir)
	local wp_dir = theme_dir .. "wallpapers/"
	local count = 0
	local handle = io.popen(string.format(
		'ls %s 2>/dev/null', string.format("%q", wp_dir)))
	if handle then
		for line in handle:lines() do
			local ext = line:match("%.([^%.]+)$")
			if ext and WP_EXTENSIONS[ext:lower()] then
				count = count + 1
			end
		end
		handle:close()
	end
	return count
end

--- Scan all available themes.
-- @treturn table List of {name, path, palette, wallpaper_count}
function themes.scan()
	local themes_dir = get_themes_dir()
	local result = {}

	-- List directories in themes/ (safe: %q escapes the path)
	local handle = io.popen(string.format(
		'ls -1d %s*/ 2>/dev/null', string.format("%q", themes_dir)))
	if not handle then return result end

	for line in handle:lines() do
		local name = line:match("([^/]+)/$")
		if name then
			local theme_lua = themes_dir .. name .. "/theme.lua"
			if gears.filesystem.file_readable(theme_lua) then
				local palette = themes.get_palette(theme_lua)
				table.insert(result, {
					name = name,
					path = themes_dir .. name .. "/",
					palette = palette or {},
					wallpaper_count = count_wallpapers(themes_dir .. name .. "/"),
					active = (name == themes.get_current()),
				})
			end
		end
	end
	handle:close()

	-- Sort: active first, then alphabetically
	table.sort(result, function(a, b)
		if a.active ~= b.active then return a.active end
		return a.name < b.name
	end)

	return result
end

--- Get scan results as JSON string for IPC.
-- @treturn string JSON array of theme objects
function themes.scan_json()
	local list = themes.scan()
	local parts = {}

	for _, t in ipairs(list) do
		local palette_parts = {}
		if t.palette then
			for k, v in pairs(t.palette) do
				local ek = k:gsub('\\', '\\\\'):gsub('"', '\\"')
				local ev = tostring(v):gsub('\\', '\\\\'):gsub('"', '\\"')
				table.insert(palette_parts, '"' .. ek .. '":"' .. ev .. '"')
			end
		end

		table.insert(parts, string.format(
			'{"name":"%s","path":"%s","wallpaper_count":%d,"active":%s,"palette":{%s}}',
			t.name:gsub('"', '\\"'),
			t.path:gsub('"', '\\"'),
			t.wallpaper_count,
			tostring(t.active),
			table.concat(palette_parts, ",")
		))
	end

	return "[" .. table.concat(parts, ",") .. "]"
end

--- Get palette for a specific theme as JSON.
-- @tparam string theme_name Theme directory name
-- @treturn string JSON object with palette colors
function themes.get_palette_json(theme_name)
	if not is_safe_name(theme_name) then return "{}" end
	local theme_lua = get_themes_dir() .. theme_name .. "/theme.lua"
	local palette = themes.get_palette(theme_lua)
	if not palette then return "{}" end

	local parts = {}
	for k, v in pairs(palette) do
		local ek = k:gsub('\\', '\\\\'):gsub('"', '\\"')
		local ev = tostring(v):gsub('\\', '\\\\'):gsub('"', '\\"')
		table.insert(parts, '"' .. ek .. '":"' .. ev .. '"')
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

--- Switch to a different theme.
-- Calls beautiful.init() with the new theme, re-applies wallpapers,
-- and saves the selection for persistence across restarts.
-- @tparam string theme_name Theme directory name
-- @treturn boolean True if switch succeeded
function themes.switch(theme_name)
	if not is_safe_name(theme_name) then return false end

	local themes_dir = get_themes_dir()
	local theme_lua = themes_dir .. theme_name .. "/theme.lua"

	if not gears.filesystem.file_readable(theme_lua) then
		return false
	end

	-- Apply new theme via beautiful
	beautiful.init(theme_lua)

	-- Re-apply wallpapers for all screens using new theme's wallpapers
	local wp_service = require("fishlive.services.wallpaper")
	local wppath = themes_dir .. theme_name .. "/wallpapers/"

	-- Update wallpaper service paths (wallpapers/ and user-wallpapers/)
	wp_service._wppath = wppath
	wp_service._user_wppath = wppath:gsub("wallpapers/$", "user-wallpapers/")
	-- Clear overrides (they belonged to the previous theme)
	wp_service._overrides = {}

	-- Clear tag_slide animation cache ONCE for all screens — wallpaper_cache_clear()
	-- is global (clears every screen's cache), so calling it inside the per-screen
	-- loop would wipe entries preloaded for earlier screens in this same theme switch.
	if root.wallpaper_cache_clear then root.wallpaper_cache_clear() end

	-- Re-apply wallpapers and rebuild slide cache for all screens
	for scr in screen do
		scr._wppath = wppath
		local sel = scr.selected_tag
		if sel then
			local wp = wp_service._resolve(sel.name)
			if wp then
				-- Clear cached path so apply() doesn't skip as redundant
				scr._current_wallpaper = nil
				wp_service.apply(scr, wp)
			end
		end
		-- Rebuild tag_slide animation cache with new theme's resolved paths
		if root.wallpaper_cache_preload then
			local paths = {}
			for _, tag in ipairs(scr.tags) do
				local wp = wp_service._resolve(tag.name)
				if wp then table.insert(paths, wp) end
			end
			if #paths > 0 then
				root.wallpaper_cache_preload(paths, scr, { fit = "cover" })
			end
		end
	end

	-- Persist selection
	save_current(theme_name)

	-- Notify shell
	broker.emit_signal("data::theme", {
		name = theme_name,
		path = themes_dir .. theme_name .. "/",
	})

	return true
end

return themes
