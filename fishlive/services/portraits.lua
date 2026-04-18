---------------------------------------------------------------------------
--- Portraits service — scan portrait collections, pick random images.
--
-- Provides the "random image from default collection" fallback used by
-- notifications when no per-app icon can be resolved. A collection is a
-- subdirectory of the base path containing image files.
--
-- Persistence: the currently selected default collection is stored as a
-- single line of text in ~/.config/somewm/.default_portrait (same pattern
-- as fishlive.services.themes uses for .active_theme).
--
-- Base path: beautiful.portraits_base_path with fallback to
-- ~/Pictures/wallpapers/public-wallpapers/portrait/ (matches somewm-shell
-- services/Portraits.qml default).
--
-- Emits broker signal "data::portrait_default" on set_default().
--
-- @module fishlive.services.portraits
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local beautiful = require("beautiful")
local broker = require("fishlive.broker")

local portraits = {}

-- POSIX single-quote shell escape. Lua's %q targets Lua literals, not /bin/sh
-- — `$(...)` inside double-quotes still runs. Wrapping in single quotes and
-- escaping embedded single quotes is the only portable shell-safe form.
local function shell_quote(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function config_dir()
	local xdg = os.getenv("XDG_CONFIG_HOME")
	if xdg and xdg ~= "" then return xdg .. "/somewm/" end
	local home = os.getenv("HOME")
	if not home or home == "" then return nil end
	return home .. "/.config/somewm/"
end

local function dir_exists(path)
	if type(path) ~= "string" or path == "" then return false end
	local h = io.popen("test -d " .. shell_quote(path) .. " && echo y")
	if not h then return false end
	local out = h:read("*l")
	h:close()
	return out == "y"
end

local function ensure_dir(path)
	if not path or path == "" then return false end
	os.execute("mkdir -p " .. shell_quote(path))
	return dir_exists(path)
end

local function state_file_path()
	local dir = config_dir()
	if not dir then return nil end
	return dir .. ".default_portrait"
end

local IMAGE_EXTENSIONS = { jpg = true, jpeg = true, png = true, webp = true }

local CACHE_TTL = 30 -- seconds

-- One-shot PRNG seed. os.time() alone gives identical sequences on fast
-- reloads within the same second; mixing in a per-process value (table
-- address → effectively random heap address) differentiates runs.
local _seeded = false
local function ensure_seeded()
	if _seeded then return end
	local addr = tonumber((tostring({}):match("0x(%x+)")) or "0", 16) or 0
	math.randomseed((os.time() * 1000003 + addr) % 2 ^ 31)
	_seeded = true
end

-- Collection/file name validator. Rejects path-traversal primitives and
-- disallows separators or control chars. Accepts ASCII alphanumerics,
-- dash/underscore/dot/space, and any UTF-8 continuation byte (≥ 0x80) so
-- that non-ASCII collection names (e.g. "Vánoce", "春") are usable.
local function is_safe_name(name)
	if type(name) ~= "string" or name == "" then return false end
	if name == "." or name == ".." then return false end
	if name:find("[/\\%c]") then return false end
	return name:match("^[%w%-_%. \128-\255]+$") ~= nil
end

local function trim_trailing_slash(s)
	return (s:gsub("/+$", ""))
end

--- Return base path as an absolute string with trailing slash, or nil when
-- neither theme override nor $HOME is usable.
function portraits.get_base_path()
	local path = beautiful.portraits_base_path
	if type(path) ~= "string" or path == "" then
		local home = os.getenv("HOME")
		if not home or home == "" then return nil end
		path = home .. "/Pictures/wallpapers/public-wallpapers/portrait"
	end
	return trim_trailing_slash(path) .. "/"
end

-- In-memory cache shared with tests via portraits._cache.
local _cache = {
	collections = nil,
	collections_ts = 0,
	images = {},
	images_ts = {},
}
portraits._cache = _cache

local function cache_expired(ts)
	return (os.time() - ts) >= CACHE_TTL
end

--- Drop all cached scan results.
function portraits.reset_cache()
	_cache.collections = nil
	_cache.collections_ts = 0
	_cache.images = {}
	_cache.images_ts = {}
end

--- List collections (subdirectories of base path), sorted alphabetically.
-- Unsafe names and dotfiles are filtered out.
function portraits.list_collections()
	if _cache.collections and not cache_expired(_cache.collections_ts) then
		return _cache.collections
	end

	local base = portraits.get_base_path()
	local result = {}
	if not base then
		_cache.collections = result
		_cache.collections_ts = os.time()
		return result
	end
	-- find -type d skips symlinks (default, -H); -mindepth 1 omits base itself.
	local cmd = string.format(
		"find %s -mindepth 1 -maxdepth 1 -type d 2>/dev/null",
		shell_quote(base)
	)
	local handle = io.popen(cmd)
	if handle then
		for line in handle:lines() do
			local name = line:match("([^/]+)$")
			if name and is_safe_name(name) then
				table.insert(result, name)
			end
		end
		handle:close()
	end
	table.sort(result)

	_cache.collections = result
	_cache.collections_ts = os.time()
	return result
end

--- List absolute image paths in a collection (filtered by extension).
-- Symlinks are skipped (only regular files pass `find -type f`).
function portraits.list_images(collection)
	if not is_safe_name(collection) then return {} end

	local cached = _cache.images[collection]
	if cached and not cache_expired(_cache.images_ts[collection] or 0) then
		return cached
	end

	local base = portraits.get_base_path()
	local result = {}
	if not base then
		_cache.images[collection] = result
		_cache.images_ts[collection] = os.time()
		return result
	end
	local dir = base .. collection .. "/"
	local cmd = string.format(
		"find %s -mindepth 1 -maxdepth 1 -type f 2>/dev/null",
		shell_quote(dir)
	)
	local handle = io.popen(cmd)
	if handle then
		for line in handle:lines() do
			local name = line:match("([^/]+)$")
			if name and is_safe_name(name) then
				local ext = name:match("%.([^%.]+)$")
				if ext and IMAGE_EXTENSIONS[ext:lower()] then
					table.insert(result, dir .. name)
				end
			end
		end
		handle:close()
	end

	_cache.images[collection] = result
	_cache.images_ts[collection] = os.time()
	return result
end

--- Read persisted default collection name, validating it still exists.
-- Returns nil explicitly when the stored name no longer refers to a real
-- directory (no silent fallback to another collection).
function portraits.get_default()
	local state = state_file_path()
	if not state then return nil end
	local f = io.open(state, "r")
	if not f then return nil end
	local name = f:read("*l")
	f:close()
	if not name or name == "" then return nil end
	if not is_safe_name(name) then return nil end
	local base = portraits.get_base_path()
	if not base then return nil end
	if not dir_exists(base .. name) then return nil end
	return name
end

--- Persist default collection and emit signal. Returns false on validation
-- failure or I/O error.
function portraits.set_default(name)
	if not is_safe_name(name) then return false end
	local base = portraits.get_base_path()
	if not base then return false end
	if not dir_exists(base .. name) then return false end

	local state = state_file_path()
	if not state then return false end
	-- Ensure ~/.config/somewm/ exists on clean installs.
	if not ensure_dir(config_dir()) then return false end

	local f = io.open(state, "w")
	if not f then return false end
	f:write(name .. "\n")
	f:close()

	portraits.reset_cache()
	broker.emit_signal("data::portrait_default", { name = name })
	return true
end

--- Pick a random image from the given collection (or the current default
-- if `collection` is omitted). Returns nil when no usable image exists.
function portraits.random_image(collection)
	collection = collection or portraits.get_default()
	if not collection then return nil end
	local images = portraits.list_images(collection)
	if #images == 0 then return nil end
	ensure_seeded()
	return images[math.random(#images)]
end

-- Internal helpers exposed for tests.
portraits._is_safe_name = is_safe_name
portraits._shell_quote = shell_quote

return portraits
