---------------------------------------------------------------------------
--- Wallpaper service — per-tag wallpaper management with override support.
--
-- Replaces inline wallpaper code in rc.lua with a proper service.
-- Supports per-tag user wallpapers, theme wallpapers, and **scope-aware**
-- resolution (portrait vs landscape, or user-labelled scopes like
-- "presentation"). A screen carries an ordered SET of active scopes;
-- resolution walks each scope fully before falling through to the
-- unscoped baseline. Priority chain (highest first):
--
--   For each scope S in the screen's active set:
--     0. In-memory override for {S, tag}
--     1. user-wallpapers/{S}/{tag}.{ext}
--     2. wallpapers/{S}/{tag}.{ext}
--     3. themes/default/wallpapers/{S}/{tag}.{ext}
--     4. user-wallpapers/{S}/1.jpg (scoped default file)
--     5. wallpapers/{S}/1.jpg
--     6. themes/default/wallpapers/{S}/1.jpg
--   Unscoped baseline:
--     7. In-memory override for {unscoped, tag}
--     8. user-wallpapers/{tag}.{ext}
--     9. wallpapers/{tag}.{ext}
--    10. themes/default/wallpapers/{tag}.{ext}
--    11. wallpapers/1.jpg
--    12. themes/default/wallpapers/1.jpg
--
-- `_auto_scope_rules` derives scopes from screen geometry (portrait added
-- when height > width). `_manual_scopes` is populated from IPC / JSON
-- persistence (step 4 of the rollout; empty placeholder in step 1).
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

-- Empty string identifies the unscoped baseline bucket.
local UNSCOPED = ""

-- State
wallpaper._overrides = {}         -- { [scope] = { [tag_name] = path } }
wallpaper._wppath = nil           -- themes/{active}/wallpapers/
wallpaper._user_wppath = nil      -- themes/{active}/user-wallpapers/
wallpaper._default_wppath = nil   -- themes/default/wallpapers/ (global fallback)
wallpaper._default = "1.jpg"      -- fallback wallpaper filename
wallpaper._browse_dirs = {}       -- dirs for folder browsing in picker
wallpaper._initialized = false

-- Auto-scope rules: each entry is function(scr) -> scope_name or nil.
-- Run on every _scopes_for_screen() call, so geometry flips re-derive.
wallpaper._auto_scope_rules = {
	function(scr)
		local g = scr and scr.geometry
		if not g or not g.width or not g.height then return nil end
		if g.width == 0 or g.height == 0 then return nil end
		if g.height > g.width then return "portrait" end
		return nil
	end,
}

-- Manual scope state: { [screen_key] = { "presentation", ... } }.
-- Populated from ~/.config/somewm/screen_scopes.json in step 4 of the
-- rollout; empty placeholder in step 1 so all screens produce only their
-- auto-scopes.
wallpaper._manual_scopes = {}

-- Negative cache for missing scope directories.
-- Key: absolute scoped-dir path ending in "/". True means "dir confirmed
-- absent, skip every find under it". Invalidated on theme switch and on
-- save operations that mkdir a scope dir.
wallpaper._scope_dir_missing = {}

-- Image extensions to try when resolving tag wallpapers
local IMG_EXTENSIONS = { ".jpg", ".png", ".webp", ".jpeg" }

-- Whitelisted extensions for save operations
local SAFE_EXT = { jpg = true, jpeg = true, png = true, webp = true }

--- Get the per-scope override bucket (auto-creates).
-- @tparam string|nil scope Scope name, or empty/nil for unscoped baseline
-- @treturn table Reference to the bucket (mutations affect state)
local function overrides_for(scope)
	local key = scope or UNSCOPED
	local t = wallpaper._overrides[key]
	if not t then
		t = {}
		wallpaper._overrides[key] = t
	end
	return t
end

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

--- Look up a tag file inside a scope subdirectory, short-circuiting via
-- the negative cache if the scope dir is known to be absent.
-- @tparam string base_dir Base directory ending with "/" (e.g. wallpapers/)
-- @tparam string scope Scope name (empty string bypasses subdir)
-- @tparam string tag_name Tag name
-- @treturn string|nil Absolute path or nil
local function find_in_scoped_dir(base_dir, scope, tag_name)
	if not base_dir then return nil end
	if not scope or scope == UNSCOPED then
		return find_in_dir(base_dir, tag_name)
	end
	local scoped_dir = base_dir .. scope .. "/"
	if wallpaper._scope_dir_missing[scoped_dir] then return nil end
	local found = find_in_dir(scoped_dir, tag_name)
	if found then return found end
	-- Stat once — if the dir itself does not exist, mark it missing so
	-- subsequent tag lookups short-circuit the whole subtree.
	if not gears.filesystem.dir_readable(scoped_dir) then
		wallpaper._scope_dir_missing[scoped_dir] = true
	end
	return nil
end

--- Default-file fallback inside a scope subdirectory (`{base}/{S}/1.jpg`).
-- Respects the same negative-cache shortcut as find_in_scoped_dir.
-- @tparam string base_dir Base directory ending with "/"
-- @tparam string scope Scope name (empty string bypasses subdir)
-- @treturn string|nil Absolute path or nil
local function scoped_default_file(base_dir, scope)
	if not base_dir then return nil end
	if not scope or scope == UNSCOPED then return nil end
	local scoped_dir = base_dir .. scope .. "/"
	if wallpaper._scope_dir_missing[scoped_dir] then return nil end
	local path = scoped_dir .. wallpaper._default
	if gears.filesystem.file_readable(path) then return path end
	if not gears.filesystem.dir_readable(scoped_dir) then
		wallpaper._scope_dir_missing[scoped_dir] = true
	end
	return nil
end

--- Look up the compositor output matching a screen by name.
-- AwesomeWM's `screen` object does not expose make/model; the compositor's
-- `output` global does. Iterating outputs for a 2–3-monitor setup is
-- O(n) and cheap.
-- @tparam screen scr
-- @treturn userdata|nil Output object or nil
local function output_for_screen(scr)
	if not scr or not scr.name or not _G.output then return nil end
	for o in _G.output do
		if o.name == scr.name then return o end
	end
	return nil
end

--- Sanitise a value destined to flow through the minimal JSON writer/
-- reader. Characters the parser can't round-trip (double-quote,
-- backslash) are replaced with `_`. Real-world EDID make/model strings
-- don't contain these, so this only bites synthetic / odd displays.
local function sanitize_for_json(s)
	if type(s) ~= "string" then return s end
	return (s:gsub('[\\"]', "_"))
end

--- Compute a stable persistence key for a screen.
-- Prefers `<make>|<model>` so HP plugged into DP-2 today / DP-4 tomorrow
-- keeps its scope list. Falls back to screen.name for virtual outputs
-- where make/model are absent. Returns empty string only when the screen
-- argument is fully unusable (should not happen in practice). Sanitises
-- values so the minimal JSON reader/writer round-trips cleanly.
-- @tparam screen scr
-- @treturn string Key suitable for wallpaper._manual_scopes indexing
function wallpaper._screen_key(scr)
	local o = output_for_screen(scr)
	if o then
		local make  = o.make
		local model = o.model
		if make and make ~= "" and model and model ~= "" then
			return sanitize_for_json(make) .. "|" .. sanitize_for_json(model)
		end
	end
	if scr and scr.name and scr.name ~= "" then return sanitize_for_json(scr.name) end
	return UNSCOPED
end

--- Resolve a `screen.name` string to the live screen object.
-- @tparam string name Screen name (e.g. "DP-2")
-- @treturn screen|nil
local function screen_by_name(name)
	if not name or name == "" then return nil end
	for s in screen do
		if s.name == name then return s end
	end
	return nil
end

--- Compute the ordered active scope list for a screen.
-- Manual scopes first (highest priority, already stored LIFO — latest
-- add sits at index 1), auto-scopes appended after. Duplicates dropped.
-- @tparam screen scr
-- @treturn table Ordered list of scope names (may be empty)
function wallpaper._scopes_for_screen(scr)
	local out = {}
	local seen = {}
	local manual = wallpaper._manual_scopes[wallpaper._screen_key(scr)] or {}
	for _, s in ipairs(manual) do
		if s and s ~= "" and not seen[s] then
			table.insert(out, s); seen[s] = true
		end
	end
	for _, rule in ipairs(wallpaper._auto_scope_rules) do
		local s = rule(scr)
		if s and s ~= "" and not seen[s] then
			table.insert(out, s); seen[s] = true
		end
	end
	return out
end

--- Resolve a tag's wallpaper given an explicit scope list.
-- Walks the priority chain described in the module header. Returns the
-- first readable path; nil if every tier misses.
-- @tparam string tag_name The tag name (e.g. "1")
-- @tparam table|nil scopes Ordered scope list (defaults to {} = unscoped-only)
-- @treturn string|nil Absolute path or nil
function wallpaper._resolve(tag_name, scopes)
	scopes = scopes or {}

	-- 1) Walk each scope fully before falling through.
	for _, S in ipairs(scopes) do
		-- Scoped override
		local bucket = wallpaper._overrides[S]
		if bucket then
			local override = bucket[tag_name]
			if override then
				if gears.filesystem.file_readable(override) then return override end
				bucket[tag_name] = nil
			end
		end
		-- Scoped tag-specific files
		local p = find_in_scoped_dir(wallpaper._user_wppath, S, tag_name)
		if p then return p end
		p = find_in_scoped_dir(wallpaper._wppath, S, tag_name)
		if p then return p end
		p = find_in_scoped_dir(wallpaper._default_wppath, S, tag_name)
		if p then return p end
		-- Scoped default file (preserves orientation when tag file absent)
		p = scoped_default_file(wallpaper._user_wppath, S)
		if p then return p end
		p = scoped_default_file(wallpaper._wppath, S)
		if p then return p end
		p = scoped_default_file(wallpaper._default_wppath, S)
		if p then return p end
	end

	-- 2) Unscoped baseline — preserves legacy behavior identically.
	local bucket = wallpaper._overrides[UNSCOPED]
	if bucket then
		local override = bucket[tag_name]
		if override then
			if gears.filesystem.file_readable(override) then return override end
			bucket[tag_name] = nil
		end
	end
	local p = find_in_dir(wallpaper._user_wppath, tag_name)
	if p then return p end
	p = find_in_dir(wallpaper._wppath, tag_name)
	if p then return p end
	p = find_in_dir(wallpaper._default_wppath, tag_name)
	if p then return p end
	if wallpaper._wppath then
		local path = wallpaper._wppath .. wallpaper._default
		if gears.filesystem.file_readable(path) then return path end
	end
	if wallpaper._default_wppath then
		local path = wallpaper._default_wppath .. wallpaper._default
		if gears.filesystem.file_readable(path) then return path end
	end
	return nil
end

--- Convenience wrapper — resolve a tag using a screen's own scope set.
-- @tparam screen scr
-- @tparam string tag_name
-- @treturn string|nil
function wallpaper._resolve_for_screen(scr, tag_name)
	return wallpaper._resolve(tag_name, wallpaper._scopes_for_screen(scr))
end

--- Primary scope (highest-priority) for a screen, or unscoped if empty.
-- Used by IPC writers to decide which bucket to mutate, and by
-- get_overrides_json()/_get_state() to pick the flat shape returned to
-- shell consumers.
-- @tparam screen scr
-- @treturn string Primary scope (may be "" for unscoped)
function wallpaper._primary_scope_for_screen(scr)
	local scopes = wallpaper._scopes_for_screen(scr)
	return scopes[1] or UNSCOPED
end

--- Primary scope of the currently-focused screen (writer default target).
-- @treturn string
function wallpaper._focused_primary_scope()
	local focused = awful.screen.focused()
	if not focused then return UNSCOPED end
	return wallpaper._primary_scope_for_screen(focused)
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

	-- Load persisted manual-scope sets (once per session — init() runs per
	-- screen, but _load_manual_scopes replaces state idempotently).
	if not wallpaper._scopes_loaded then
		wallpaper._load_manual_scopes()
		wallpaper._scopes_loaded = true
	end

	-- Expose wppath for tag_slide animation overlays
	scr._wppath = wppath

	-- Initial wallpaper: use screen's first tag name
	local first_tag = scr.tags and scr.tags[1]
	local init_tag = first_tag and first_tag.name or "1"
	local path = wallpaper._resolve_for_screen(scr, init_tag)
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
			local wp = wallpaper._resolve_for_screen(scr, tag.name)
			if wp then table.insert(paths, wp) end
		end
		if #paths > 0 then root.wallpaper_cache_preload(paths, scr, { fit = "cover" }) end
	end

	-- Switch wallpaper on tag selection
	for _, tag in ipairs(scr.tags) do
		tag:connect_signal("property::selected", function(t)
			if t.selected then
				local wp = wallpaper._resolve_for_screen(t.screen, t.name)
				if wp then apply_wallpaper(t.screen, wp) end
			end
		end)
	end

	-- Re-apply on screen geometry change (hotplug, transform/resolution switch).
	-- Scope may flip (portrait↔landscape) — _resolve_for_screen picks it up
	-- since auto-scope rules re-evaluate on every call. apply_wallpaper's
	-- cover surface bakes in geo.width × geo.height at apply time; invalidate
	-- this screen's cache entries, drop _current_wallpaper, then re-run apply
	-- and cache preload so both the active surface and the cached scene
	-- buffers match the final output layout.
	scr:connect_signal("property::geometry", function(s)
		if root.wallpaper_cache_invalidate_screen then
			root.wallpaper_cache_invalidate_screen(s.index)
		end
		s._current_wallpaper = nil

		local sel = s.selected_tag
		local tag_name = sel and sel.name or (s.tags[1] and s.tags[1].name) or "1"
		local wp = wallpaper._resolve_for_screen(s, tag_name)
		if wp then apply_wallpaper(s, wp) end

		if root.wallpaper_cache_preload then
			local paths = {}
			for _, tag in ipairs(s.tags) do
				local p = wallpaper._resolve_for_screen(s, tag.name)
				if p then table.insert(paths, p) end
			end
			if #paths > 0 then root.wallpaper_cache_preload(paths, s, { fit = "cover" }) end
		end
	end)
end

-------------------------------------------------------------------------
-- Persistence — screen_scopes.json
-------------------------------------------------------------------------

--- Path to the manual-scope persistence file.
-- @treturn string
local function screen_scopes_path()
	return gears.filesystem.get_configuration_dir() .. "screen_scopes.json"
end

--- Escape a string for JSON output.
-- @tparam string s
-- @treturn string
local function json_escape(s)
	return (tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'))
end

--- Serialise _manual_scopes to JSON (keyed by persistence key).
-- Shape: {"HP|HP U28":["portrait","presentation"],"DP-5":[]}
-- @tparam table data  { [key] = { "scope", ... } }
-- @treturn string
local function manual_scopes_to_json(data)
	local parts = {}
	for key, list in pairs(data or {}) do
		local items = {}
		for _, s in ipairs(list) do
			table.insert(items, '"' .. json_escape(s) .. '"')
		end
		table.insert(parts, '"' .. json_escape(key) .. '":[' .. table.concat(items, ",") .. ']')
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

--- Minimal JSON reader for screen_scopes.json shape.
-- Accepts { "key": [ "str", "str" ], ... }. Returns {} on parse error
-- rather than raising — stale/partial files degrade to "no manual scopes"
-- so session startup is never blocked by bad state.
-- @tparam string text
-- @treturn table Parsed `{ [key] = { "scope", ... } }`
local function parse_manual_scopes_json(text)
	local out = {}
	if not text or text == "" then return out end
	-- Strip whitespace outside strings — good enough for our constrained shape.
	-- For each top-level "key": [ ... ] match, extract key + list contents.
	for key, body in text:gmatch('"([^"\\]*)"%s*:%s*%[([^%]]*)%]') do
		local list = {}
		for item in body:gmatch('"([^"\\]*)"') do
			table.insert(list, item)
		end
		out[key] = list
	end
	return out
end

--- Load manual-scope state from disk into wallpaper._manual_scopes.
-- Safe to call multiple times; each call replaces the in-memory state.
function wallpaper._load_manual_scopes()
	local path = screen_scopes_path()
	local f = io.open(path, "r")
	if not f then
		wallpaper._manual_scopes = {}
		return
	end
	local text = f:read("*a") or ""
	f:close()
	wallpaper._manual_scopes = parse_manual_scopes_json(text)
end

--- Persist wallpaper._manual_scopes atomically via .tmp + os.rename.
-- Guarantees the on-disk file is either the previous version or the full
-- new version — never a half-written body. Write failures (e.g. ENOSPC)
-- delete the tmp file so the original never gets replaced with a
-- truncated copy.
function wallpaper._save_manual_scopes()
	local path = screen_scopes_path()
	local tmp  = path .. ".tmp"
	local body = manual_scopes_to_json(wallpaper._manual_scopes) .. "\n"
	local f = io.open(tmp, "w")
	if not f then return false end
	local ok, err = f:write(body)
	f:close()
	if not ok then
		-- write() returned nil on disk-full / IO error — abandon tmp and
		-- preserve the existing on-disk state.
		os.remove(tmp)
		return false, err
	end
	-- os.rename is atomic on POSIX when both paths are on the same fs.
	local renamed = os.rename(tmp, path)
	if not renamed then
		os.remove(tmp)
		return false
	end
	return true
end

-------------------------------------------------------------------------
-- Scope-set mutation (IPC writers)
-------------------------------------------------------------------------

--- After any mutation: re-resolve and re-apply wallpapers on the affected
-- screen(s) so the scope change takes visual effect immediately, then
-- broadcast a broker signal so the shell can refresh its UI.
-- @tparam screen|nil scr If nil, all screens are refreshed.
local function refresh_after_scope_change(scr)
	local screens = {}
	if scr then
		table.insert(screens, scr)
	else
		for s in screen do table.insert(screens, s) end
	end
	for _, s in ipairs(screens) do
		local sel = s.selected_tag
		if sel then
			local wp = wallpaper._resolve_for_screen(s, sel.name)
			if wp then
				s._current_wallpaper = nil
				apply_wallpaper(s, wp)
				update_slide_cache(wp)
			end
		end
	end
	broker.emit_signal("data::screen_scopes", {
		all = wallpaper._manual_scopes,
	})
	broker.emit_signal("data::wallpaper", wallpaper._get_state())
end

--- Validate that a scope name is a safe basename (used both as dir name
-- and filesystem path component).
local function is_safe_scope(name)
	if not name or name == "" then return false end
	if name:match("[/\\]") or name == ".." or name == "." then return false end
	return name:match("^[%w%-_%.]+$") ~= nil
end

--- Add a manual scope to a screen (LIFO — prepend so latest wins).
-- Idempotent: re-adding an existing scope moves it to the front.
-- @tparam string screen_name
-- @tparam string scope
-- @treturn boolean True on success
function wallpaper.add_scope_to_screen(screen_name, scope)
	if not is_safe_scope(scope) then return false end
	local scr = screen_by_name(screen_name)
	if not scr then return false end
	local key = wallpaper._screen_key(scr)
	local list = wallpaper._manual_scopes[key] or {}
	-- Remove existing occurrence, then prepend.
	local filtered = {}
	for _, s in ipairs(list) do
		if s ~= scope then table.insert(filtered, s) end
	end
	table.insert(filtered, 1, scope)
	wallpaper._manual_scopes[key] = filtered
	wallpaper._save_manual_scopes()
	refresh_after_scope_change(scr)
	return true
end

--- Remove a manual scope from a screen.
-- No-op if the scope isn't present.
-- @tparam string screen_name
-- @tparam string scope
-- @treturn boolean True if something was actually removed
function wallpaper.remove_scope_from_screen(screen_name, scope)
	local scr = screen_by_name(screen_name)
	if not scr then return false end
	local key = wallpaper._screen_key(scr)
	local list = wallpaper._manual_scopes[key]
	if not list then return false end
	local removed = false
	local filtered = {}
	for _, s in ipairs(list) do
		if s == scope then removed = true
		else table.insert(filtered, s) end
	end
	if removed then
		if #filtered == 0 then
			wallpaper._manual_scopes[key] = nil
		else
			wallpaper._manual_scopes[key] = filtered
		end
		wallpaper._save_manual_scopes()
		refresh_after_scope_change(scr)
	end
	return removed
end

--- Replace the full manual-scope list for a screen (callers pass
-- highest-priority scope first — natural order).
-- @tparam string screen_name
-- @tparam table scopes_list Ordered list of scope names
-- @treturn boolean
function wallpaper.set_screen_scopes(screen_name, scopes_list)
	local scr = screen_by_name(screen_name)
	if not scr then return false end
	local key = wallpaper._screen_key(scr)
	local filtered = {}
	local seen = {}
	for _, s in ipairs(scopes_list or {}) do
		if is_safe_scope(s) and not seen[s] then
			table.insert(filtered, s); seen[s] = true
		end
	end
	if #filtered == 0 then
		wallpaper._manual_scopes[key] = nil
	else
		wallpaper._manual_scopes[key] = filtered
	end
	wallpaper._save_manual_scopes()
	refresh_after_scope_change(scr)
	return true
end

--- Flip a scope on/off on a screen (add if absent, remove if present).
-- @tparam string screen_name
-- @tparam string scope
-- @treturn boolean Final presence: true if scope is now active
function wallpaper.toggle_scope_on_screen(screen_name, scope)
	if not is_safe_scope(scope) then return false end
	local scr = screen_by_name(screen_name)
	if not scr then return false end
	local key = wallpaper._screen_key(scr)
	local list = wallpaper._manual_scopes[key] or {}
	local present = false
	for _, s in ipairs(list) do
		if s == scope then present = true; break end
	end
	if present then
		wallpaper.remove_scope_from_screen(screen_name, scope)
		return false
	else
		wallpaper.add_scope_to_screen(screen_name, scope)
		return true
	end
end

-------------------------------------------------------------------------
-- Helpers for IPC readers (screen target resolution)
-------------------------------------------------------------------------

--- Resolve a reader's target screen — named arg wins, else focused.
local function target_screen(screen_name)
	if screen_name and screen_name ~= "" then
		return screen_by_name(screen_name)
	end
	return awful.screen.focused()
end

-------------------------------------------------------------------------
-- Save destination
-------------------------------------------------------------------------

--- Compute the destination directory for user-wallpapers given a scope.
-- Unscoped → legacy `user-wallpapers/`. Scoped → `user-wallpapers/<S>/`.
-- Creates the directory (mkdir -p) on demand and invalidates the negative
-- cache entry so subsequent resolves see the new dir.
-- @tparam string scope Scope name (empty = unscoped)
-- @treturn string|nil Destination directory path (ends with "/") or nil
local function user_dest_dir(scope)
	if not wallpaper._user_wppath then return nil end
	local dest_dir = wallpaper._user_wppath
	if scope and scope ~= UNSCOPED then
		dest_dir = dest_dir .. scope .. "/"
	end
	local safe_path = dest_dir:gsub("'", "'\\''")
	os.execute("mkdir -p -- '" .. safe_path .. "'")
	-- Invalidate any cached "missing" entry for the scoped variant of all
	-- three base dirs — resolver should re-probe after this mkdir.
	if scope and scope ~= UNSCOPED then
		wallpaper._scope_dir_missing[wallpaper._user_wppath    .. scope .. "/"] = nil
		wallpaper._scope_dir_missing[(wallpaper._wppath or "") .. scope .. "/"] = nil
		if wallpaper._default_wppath then
			wallpaper._scope_dir_missing[wallpaper._default_wppath .. scope .. "/"] = nil
		end
	end
	return dest_dir
end

--- Set a wallpaper override for a tag (runtime preview, not persisted).
-- Writes to the given `scope` bucket, or the focused screen's primary
-- scope when `scope` is nil (legacy single-arg form). If the tag is
-- currently selected on any screen whose chain reaches this bucket, its
-- wallpaper is re-applied immediately.
--
-- @tparam string tag_name Tag name (e.g. "1")
-- @tparam string path Absolute path to wallpaper image
-- @tparam[opt] string scope Target scope (empty = unscoped baseline)
function wallpaper.set_override(tag_name, path, scope)
	if not path or path == "" then return end
	if scope == nil then scope = wallpaper._focused_primary_scope() end
	if scope and scope ~= UNSCOPED and not is_safe_scope(scope) then return end
	overrides_for(scope)[tag_name] = path

	-- Re-apply on every screen whose current resolution chain reaches
	-- this override. _resolve_for_screen will pick it up iff the screen's
	-- scope set includes `scope` (or `scope` is unscoped).
	for scr in screen do
		local sel = scr.selected_tag
		if sel and sel.name == tag_name then
			local wp = wallpaper._resolve_for_screen(scr, tag_name)
			if wp then
				scr._current_wallpaper = nil
				apply_wallpaper(scr, wp)
			end
		end
	end

	update_slide_cache(path)
	broker.emit_signal("data::wallpaper", wallpaper._get_state())
end

--- Clear a wallpaper override for a tag, reverting to resolved wallpaper.
-- If `scope` is given, clears only that bucket. If omitted, sweeps ALL
-- scope buckets — preserves the legacy "clear means clear everywhere"
-- semantic for callers that haven't been updated to pass an explicit
-- scope (e.g. pre-step-5 QS picker).
-- @tparam string tag_name Tag name
-- @tparam[opt] string scope Target scope (empty = unscoped baseline)
function wallpaper.clear_override(tag_name, scope)
	if scope ~= nil then
		if scope ~= UNSCOPED and not is_safe_scope(scope) then return end
		local bucket = wallpaper._overrides[scope]
		if bucket then bucket[tag_name] = nil end
	else
		for _, bucket in pairs(wallpaper._overrides) do
			bucket[tag_name] = nil
		end
	end

	-- Revert to resolved wallpaper on affected screens.
	for scr in screen do
		local sel = scr.selected_tag
		if sel and sel.name == tag_name then
			local resolved = wallpaper._resolve_for_screen(scr, tag_name)
			if resolved then
				scr._current_wallpaper = nil
				apply_wallpaper(scr, resolved)
				update_slide_cache(resolved)
			end
		end
	end

	broker.emit_signal("data::wallpaper", wallpaper._get_state())
end

--- Save a wallpaper into the user-wallpapers directory for the active theme.
-- Writes to `user-wallpapers/<scope>/<tag>.<ext>` (or the legacy
-- `user-wallpapers/<tag>.<ext>` when the scope is unscoped). Does NOT
-- overwrite theme default wallpapers in wallpapers/.
--
-- @tparam string tag_name Tag name (e.g. "3")
-- @tparam string source_path Absolute path to source wallpaper image
-- @tparam[opt] string scope Target scope (empty = unscoped; defaults to
--   focused screen's primary scope). QS picker passes its own screen's
--   scope to avoid focus-drift hitting the wrong bucket.
-- @treturn boolean True if saved and applied successfully
function wallpaper.save_to_theme(tag_name, source_path, scope)
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

	if scope == nil then scope = wallpaper._focused_primary_scope() end
	if scope and scope ~= UNSCOPED and not is_safe_scope(scope) then return false end
	local dest_dir = user_dest_dir(scope)
	if not dest_dir then return false end

	-- Remove any existing file for this tag in the destination dir (different ext)
	for _, e in ipairs({ "jpg", "jpeg", "png", "webp" }) do
		os.remove(dest_dir .. tag_name .. "." .. e)
	end

	-- Copy source to destination
	local dest = dest_dir .. tag_name .. "." .. ext
	local src_file = io.open(source_path, "rb")
	if not src_file then return false end
	local data = src_file:read("*a")
	src_file:close()

	local dst_file = io.open(dest, "wb")
	if not dst_file then return false end
	dst_file:write(data)
	dst_file:close()

	-- Clear any in-memory override for this scope (user-wp file supersedes).
	local bucket = wallpaper._overrides[scope]
	if bucket then bucket[tag_name] = nil end

	-- Apply immediately on all screens showing this tag whose chain reaches
	-- the destination scope.
	for scr in screen do
		local sel = scr.selected_tag
		if sel and sel.name == tag_name then
			local wp = wallpaper._resolve_for_screen(scr, tag_name)
			if wp then
				scr._current_wallpaper = nil
				apply_wallpaper(scr, wp)
			end
		end
	end

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
-- Returns overrides for the focused screen's primary scope as a flat map
-- (backward-compatible shape for shell consumers).
-- @treturn table { current, overrides, wppath, user_wppath, browse_dirs }
function wallpaper._get_state()
	local current = nil
	local focused = awful.screen.focused()
	if focused then
		current = focused._current_wallpaper
	end
	local scope = wallpaper._focused_primary_scope()
	return {
		current = current or "",
		overrides = wallpaper._overrides[scope] or {},
		wppath = wallpaper._wppath or "",
		user_wppath = wallpaper._user_wppath or "",
		browse_dirs = wallpaper._browse_dirs,
	}
end

--- Get overrides as JSON string (for IPC).
-- Flat `{<tag>:<path>,…}` for the target screen's primary scope
-- (backward-compatible shape — QS unchanged).
-- @tparam[opt] string screen_name Screen to target (defaults to focused)
-- @treturn string JSON representation of override map
function wallpaper.get_overrides_json(screen_name)
	local scr = target_screen(screen_name)
	local scope = scr and wallpaper._primary_scope_for_screen(scr) or UNSCOPED
	local bucket = wallpaper._overrides[scope] or {}
	local parts = {}
	for k, v in pairs(bucket) do
		local ek = k:gsub('\\', '\\\\'):gsub('"', '\\"')
		local ev = v:gsub('\\', '\\\\'):gsub('"', '\\"')
		table.insert(parts, '"' .. ek .. '":"' .. ev .. '"')
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

--- Get overrides for ALL scopes as nested JSON.
-- Shape: `{"<scope>":{<tag>:<path>,...},...}`. Scope "" is the unscoped
-- baseline. Exposed for future UI that wants cross-scope visibility.
-- @treturn string JSON object
function wallpaper.get_overrides_all_json()
	local outer = {}
	for scope, bucket in pairs(wallpaper._overrides) do
		local parts = {}
		for k, v in pairs(bucket) do
			local ek = k:gsub('\\', '\\\\'):gsub('"', '\\"')
			local ev = v:gsub('\\', '\\\\'):gsub('"', '\\"')
			table.insert(parts, '"' .. ek .. '":"' .. ev .. '"')
		end
		table.insert(outer, '"' .. json_escape(scope) .. '":{' .. table.concat(parts, ",") .. '}')
	end
	return "{" .. table.concat(outer, ",") .. "}"
end

--- Get the active scope list for a screen (or the focused one) as JSON.
-- @tparam[opt] string screen_name Screen to target (defaults to focused)
-- @treturn string JSON array, e.g. `["presentation","portrait"]`
function wallpaper.get_active_scopes_json(screen_name)
	local scr = target_screen(screen_name)
	if not scr then return "[]" end
	local parts = {}
	for _, s in ipairs(wallpaper._scopes_for_screen(scr)) do
		table.insert(parts, '"' .. json_escape(s) .. '"')
	end
	return "[" .. table.concat(parts, ",") .. "]"
end

--- Dump all persisted manual-scope sets keyed by persistence key.
-- Shape: `{"HP|HP U28":["portrait"],"DP-5":["cinema"]}`.
-- @treturn string JSON object
function wallpaper.get_all_screen_scopes_json()
	return manual_scopes_to_json(wallpaper._manual_scopes)
end

--- Dump every scope name currently known to the system (auto rules that
-- fire on any live screen, plus every manual scope in _manual_scopes).
-- Lets the QS picker render a registry of chips / show available options.
-- @treturn string JSON array
function wallpaper.get_registered_scopes_json()
	local seen = {}
	local out = {}
	local function add(name)
		if name and name ~= "" and not seen[name] then
			seen[name] = true; table.insert(out, name)
		end
	end
	for _, rule in ipairs(wallpaper._auto_scope_rules) do
		for s in screen do
			add(rule(s))
		end
	end
	for _, list in pairs(wallpaper._manual_scopes) do
		for _, s in ipairs(list) do add(s) end
	end
	local parts = {}
	for _, s in ipairs(out) do
		table.insert(parts, '"' .. json_escape(s) .. '"')
	end
	return "[" .. table.concat(parts, ",") .. "]"
end

--- Get the current wallpaper path for a screen (for IPC).
-- @tparam[opt] string screen_name Screen to target (defaults to focused)
-- @treturn string Current wallpaper path or empty string
function wallpaper.get_current(screen_name)
	local scr = target_screen(screen_name)
	return scr and scr._current_wallpaper or ""
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

--- Get tag names from a screen as JSON array (for IPC).
-- @tparam[opt] string screen_name Screen to target (defaults to focused)
-- @treturn string JSON array of tag name strings
function wallpaper.get_tags_json(screen_name)
	local scr = target_screen(screen_name)
	if not scr then return "[]" end
	local parts = {}
	for _, tag in ipairs(scr.tags) do
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

--- Get resolved wallpaper state for every tag on a screen (for IPC).
-- Walks the target screen's scope set per _resolve_for_screen.
-- `isUserOverride` reflects whether a user-wallpapers file exists on disk
-- for the primary scope of the target screen (so the QS "reset" action
-- targets the right file).
-- @tparam[opt] string screen_name Screen to target (defaults to focused)
-- @treturn string JSON array of {tag, path, isUserOverride} objects
function wallpaper.get_resolved_json(screen_name)
	local focused = target_screen(screen_name)
	if not focused or not focused.tags then return "[]" end
	local scope = wallpaper._primary_scope_for_screen(focused)
	local parts = {}
	for _, tag in ipairs(focused.tags) do
		local tag_name = tag.name
		local path = wallpaper._resolve_for_screen(focused, tag_name)
		-- A user-wallpaper file exists on disk for this tag in the primary
		-- scope (matches the dir that clear_user_wallpaper will target).
		local is_user
		if scope == UNSCOPED then
			is_user = find_in_dir(wallpaper._user_wppath, tag_name) ~= nil
		else
			is_user = find_in_scoped_dir(wallpaper._user_wppath, scope, tag_name) ~= nil
		end
		local ep = (path or ""):gsub('\\', '\\\\'):gsub('"', '\\"')
		local et = tag_name:gsub('\\', '\\\\'):gsub('"', '\\"')
		table.insert(parts,
			'{"tag":"' .. et .. '","path":"' .. ep ..
			'","isUserOverride":' .. tostring(is_user) .. '}')
	end
	return "[" .. table.concat(parts, ",") .. "]"
end

--- Delete user-wallpaper file for a tag, reverting to theme default (for IPC).
-- Targets `user-wallpapers/<scope>/<tag>.<ext>` where scope is `scope` if
-- given, else the focused screen's primary scope. Theme defaults and
-- other scopes remain untouched.
-- @tparam string tag_name Tag name to clear
-- @tparam[opt] string scope Target scope (empty = unscoped baseline)
-- @treturn boolean True if a file was actually removed
function wallpaper.clear_user_wallpaper(tag_name, scope)
	if not tag_name or tag_name == "" then return false end
	if not tag_name:match("^[%w%-_]+$") then return false end
	if not wallpaper._user_wppath then return false end

	if scope == nil then scope = wallpaper._focused_primary_scope() end
	if scope and scope ~= UNSCOPED and not is_safe_scope(scope) then return false end
	local target_dir = wallpaper._user_wppath
	if scope ~= UNSCOPED then target_dir = target_dir .. scope .. "/" end

	local removed = false
	for _, ext in ipairs(IMG_EXTENSIONS) do
		local path = target_dir .. tag_name .. ext
		if os.remove(path) then removed = true end
	end

	-- Also clear any in-memory override for this scope.
	local bucket = wallpaper._overrides[scope]
	if bucket then bucket[tag_name] = nil end

	-- Re-resolve and apply on all screens showing this tag.
	for scr in screen do
		local sel = scr.selected_tag
		if sel and sel.name == tag_name then
			local wp = wallpaper._resolve_for_screen(scr, tag_name)
			if wp then
				scr._current_wallpaper = nil
				apply_wallpaper(scr, wp)
				update_slide_cache(wp)
			end
		end
	end

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

--- Switch to a specific tag on a specific screen (for IPC).
-- Per-screen picker uses this so clicking a tag chip on the DP-2 panel
-- switches DP-2's tag, not the focused screen's.
-- @tparam string screen_name Target screen name (e.g. "DP-2")
-- @tparam string tag_name Tag name to switch to
function wallpaper.view_tag_on_screen(screen_name, tag_name)
	local scr = screen_by_name(screen_name)
	if not scr then return end
	for _, tag in ipairs(scr.tags) do
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
