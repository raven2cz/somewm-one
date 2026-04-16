---------------------------------------------------------------------------
--- Tests for fishlive.services.wallpaper
---------------------------------------------------------------------------

package.path = "./plans/project/somewm-one/?.lua;" .. package.path

-- Mock dependencies
local mock_broker_signals = {}
package.preload["fishlive.broker"] = function()
	return {
		emit_signal = function(name, data)
			table.insert(mock_broker_signals, { name = name, data = data })
		end,
	}
end

package.preload["awful"] = function()
	return {
		wallpaper = function(args)
			return { screen = args.screen, widget = args.widget }
		end,
		screen = { focused = function() return nil end },
	}
end

package.preload["gears"] = function()
	return {
		filesystem = {
			file_readable = function(path)
				-- Mock: files in test_wallpapers/ are "readable"
				return path and path:match("test_wallpapers/") ~= nil
			end,
		},
	}
end

package.preload["gears.filesystem"] = function()
	return require("gears").filesystem
end

local mock_imagebox = {}
package.preload["wibox"] = function()
	return {
		widget = {
			imagebox = function(...)
				local w = { image = select(1, ...) or "", _type = "imagebox" }
				table.insert(mock_imagebox, w)
				return w
			end,
		},
		container = {
			tile = "tile_container",
		},
	}
end

package.preload["wibox.widget"] = function()
	return require("wibox").widget
end

package.preload["wibox.widget.imagebox"] = function()
	return require("wibox").widget.imagebox
end

-- Stub global root (compositor C-level object, needed by update_slide_cache)
_G.root = {
	wallpaper_cache_preload = nil,
	wallpaper_cache_clear = nil,
}

-- Stub global screen iterator (for scr in screen do ... end)
-- __call is used directly as the iterator by `for`, so it receives the
-- previous value and must return the next screen or nil.
local mock_screens = {}
_G.screen = setmetatable({}, {
	__call = function(_, prev)
		if prev == nil then
			return mock_screens[1]
		end
		for i, s in ipairs(mock_screens) do
			if s == prev then return mock_screens[i + 1] end
		end
		return nil
	end,
})

describe("wallpaper service", function()
	local wallpaper

	before_each(function()
		-- Reset module
		package.loaded["fishlive.services.wallpaper"] = nil
		mock_broker_signals = {}
		mock_imagebox = {}
		mock_screens = {}
		wallpaper = require("fishlive.services.wallpaper")
	end)

	describe("_resolve", function()
		it("returns nil when not initialized", function()
			assert.is_nil(wallpaper._resolve("1"))
		end)

		it("returns default fallback when wppath set", function()
			wallpaper._wppath = "test_wallpapers/"
			wallpaper._default = "1.jpg"
			local result = wallpaper._resolve("1")
			assert.equals("test_wallpapers/1.jpg", result)
		end)

		it("returns theme-based path when file exists", function()
			wallpaper._wppath = "test_wallpapers/"
			wallpaper._default = "1.jpg"
			local result = wallpaper._resolve("3")
			-- 3.jpg would be tried first
			assert.equals("test_wallpapers/3.jpg", result)
		end)

		it("returns override when set", function()
			wallpaper._wppath = "test_wallpapers/"
			wallpaper._default = "1.jpg"
			wallpaper._overrides["3"] = "test_wallpapers/custom.jpg"
			local result = wallpaper._resolve("3")
			assert.equals("test_wallpapers/custom.jpg", result)
		end)

		it("override takes priority over theme-based", function()
			wallpaper._wppath = "test_wallpapers/"
			wallpaper._default = "1.jpg"
			wallpaper._overrides["1"] = "test_wallpapers/override.jpg"
			local result = wallpaper._resolve("1")
			assert.equals("test_wallpapers/override.jpg", result)
		end)

		it("falls back to default when override file is gone", function()
			wallpaper._wppath = "test_wallpapers/"
			wallpaper._default = "1.jpg"
			wallpaper._overrides["3"] = "/nonexistent/file.jpg"
			local result = wallpaper._resolve("3")
			-- Override cleared, falls through to theme-based
			assert.equals("test_wallpapers/3.jpg", result)
			assert.is_nil(wallpaper._overrides["3"])
		end)
	end)

	describe("set_override", function()
		it("stores override and emits signal", function()
			wallpaper._wppath = "test_wallpapers/"
			wallpaper.set_override("5", "test_wallpapers/new.jpg")
			assert.equals("test_wallpapers/new.jpg", wallpaper._overrides["5"])
			assert.equals(1, #mock_broker_signals)
			assert.equals("data::wallpaper", mock_broker_signals[1].name)
		end)

		it("ignores empty path", function()
			wallpaper.set_override("1", "")
			assert.is_nil(wallpaper._overrides["1"])
		end)
	end)

	describe("clear_override", function()
		it("removes override and emits signal", function()
			wallpaper._wppath = "test_wallpapers/"
			wallpaper._overrides["3"] = "test_wallpapers/old.jpg"
			wallpaper.clear_override("3")
			assert.is_nil(wallpaper._overrides["3"])
			assert.equals(1, #mock_broker_signals)
		end)
	end)

	describe("save_to_theme", function()
		it("returns false when wppath not set", function()
			assert.is_false(wallpaper.save_to_theme("1", "test_wallpapers/new.jpg"))
		end)

		it("returns false for empty source_path", function()
			wallpaper._wppath = "test_wallpapers/"
			assert.is_false(wallpaper.save_to_theme("1", ""))
		end)

		it("returns false for unreadable source", function()
			wallpaper._wppath = "test_wallpapers/"
			assert.is_false(wallpaper.save_to_theme("1", "/nonexistent/file.jpg"))
		end)

		-- Note: full save_to_theme test requires filesystem access
		-- which is tested in integration tests
	end)

	describe("get_overrides_json", function()
		it("returns empty object when no overrides", function()
			assert.equals("{}", wallpaper.get_overrides_json())
		end)

		it("returns JSON with overrides", function()
			wallpaper._overrides["1"] = "/path/to/wall.jpg"
			local json = wallpaper.get_overrides_json()
			assert.truthy(json:match('"1"'))
			assert.truthy(json:match('wall%.jpg'))
		end)
	end)

	describe("get_current", function()
		it("returns empty string when no screen focused", function()
			assert.equals("", wallpaper.get_current())
		end)
	end)

	describe("apply", function()
		it("is a public function", function()
			assert.is_function(wallpaper.apply)
		end)
	end)

	describe("get_browse_dirs_json", function()
		it("returns empty array when no browse dirs", function()
			assert.equals("[]", wallpaper.get_browse_dirs_json())
		end)

		it("returns JSON array of dirs", function()
			wallpaper._browse_dirs = { "/home/user/Pictures/wallpapers", "/opt/walls" }
			local json = wallpaper.get_browse_dirs_json()
			assert.truthy(json:match("/home/user/Pictures/wallpapers"))
			assert.truthy(json:match("/opt/walls"))
			-- Should be a valid JSON array
			assert.equals("[", json:sub(1, 1))
			assert.equals("]", json:sub(-1))
		end)

		it("escapes special characters in paths", function()
			wallpaper._browse_dirs = { '/path/with"quotes' }
			local json = wallpaper.get_browse_dirs_json()
			assert.truthy(json:match('\\"'))
		end)
	end)

	describe("get_tags_json", function()
		it("returns empty array when no screen focused", function()
			assert.equals("[]", wallpaper.get_tags_json())
		end)

		it("returns tag names from focused screen", function()
			-- Mock awful.screen.focused to return a screen with tags
			local awful = require("awful")
			local old_focused = awful.screen.focused
			awful.screen.focused = function()
				return {
					tags = {
						{ name = "1" }, { name = "2" }, { name = "web" },
					}
				}
			end
			local json = wallpaper.get_tags_json()
			assert.equals('["1","2","web"]', json)
			awful.screen.focused = old_focused
		end)
	end)

	describe("get_theme_wallpapers_dir", function()
		it("returns empty when not initialized", function()
			assert.equals("", wallpaper.get_theme_wallpapers_dir())
		end)

		it("returns wppath when set", function()
			wallpaper._wppath = "test_wallpapers/themes/default/wallpapers/"
			assert.equals("test_wallpapers/themes/default/wallpapers/", wallpaper.get_theme_wallpapers_dir())
		end)
	end)

	describe("_resolve 4-tier chain", function()
		it("user-wallpapers takes priority over theme wallpapers", function()
			wallpaper._user_wppath = "test_wallpapers/user/"
			wallpaper._wppath = "test_wallpapers/theme/"
			wallpaper._default = "1.jpg"
			-- Both dirs match test_wallpapers/ pattern in mock
			local result = wallpaper._resolve("1")
			assert.equals("test_wallpapers/user/1.jpg", result)
		end)

		it("override takes priority over user-wallpapers", function()
			wallpaper._overrides["1"] = "test_wallpapers/override.jpg"
			wallpaper._user_wppath = "test_wallpapers/user/"
			wallpaper._wppath = "test_wallpapers/theme/"
			wallpaper._default = "1.jpg"
			local result = wallpaper._resolve("1")
			assert.equals("test_wallpapers/override.jpg", result)
		end)

		it("falls to default wallpapers when user-wallpapers missing", function()
			wallpaper._user_wppath = "/nonexistent/user/"
			wallpaper._wppath = "test_wallpapers/theme/"
			wallpaper._default = "1.jpg"
			local result = wallpaper._resolve("1")
			assert.equals("test_wallpapers/theme/1.jpg", result)
		end)

		it("falls to global default when theme wallpapers missing", function()
			wallpaper._user_wppath = "/nonexistent/user/"
			wallpaper._wppath = "/nonexistent/theme/"
			wallpaper._default_wppath = "test_wallpapers/default/"
			wallpaper._default = "1.jpg"
			local result = wallpaper._resolve("1")
			assert.equals("test_wallpapers/default/1.jpg", result)
		end)
	end)

	describe("save_to_theme path traversal", function()
		it("rejects tag names with slashes", function()
			wallpaper._user_wppath = "test_wallpapers/"
			assert.is_false(wallpaper.save_to_theme("../etc", "test_wallpapers/img.jpg"))
		end)

		it("rejects tag names with backslashes", function()
			wallpaper._user_wppath = "test_wallpapers/"
			assert.is_false(wallpaper.save_to_theme("..\\etc", "test_wallpapers/img.jpg"))
		end)

		it("rejects dotdot tag names", function()
			wallpaper._user_wppath = "test_wallpapers/"
			assert.is_false(wallpaper.save_to_theme("..", "test_wallpapers/img.jpg"))
		end)

		it("rejects single dot tag names", function()
			wallpaper._user_wppath = "test_wallpapers/"
			assert.is_false(wallpaper.save_to_theme(".", "test_wallpapers/img.jpg"))
		end)
	end)

	describe("get_resolved_json", function()
		it("returns empty array when no screen focused", function()
			assert.equals("[]", wallpaper.get_resolved_json())
		end)

		it("returns resolved wallpaper per tag with isUserOverride", function()
			local awful = require("awful")
			local old_focused = awful.screen.focused
			awful.screen.focused = function()
				return {
					tags = {
						{ name = "1" }, { name = "2" }, { name = "3" },
					}
				}
			end
			wallpaper._wppath = "test_wallpapers/theme/"
			wallpaper._user_wppath = "/nonexistent/user/"
			wallpaper._default = "1.jpg"
			local json = wallpaper.get_resolved_json()
			-- All should resolve to theme wallpapers, none are user overrides
			assert.truthy(json:match('"tag":"1"'))
			assert.truthy(json:match('"tag":"2"'))
			assert.truthy(json:match('"tag":"3"'))
			assert.truthy(json:match('"isUserOverride":false'))
			assert.is_nil(json:match('"isUserOverride":true'))
			awful.screen.focused = old_focused
		end)

		it("detects user-wallpaper overrides", function()
			local awful = require("awful")
			local old_focused = awful.screen.focused
			awful.screen.focused = function()
				return {
					tags = {
						{ name = "1" }, { name = "2" },
					}
				}
			end
			wallpaper._wppath = "test_wallpapers/theme/"
			wallpaper._user_wppath = "test_wallpapers/user/"
			wallpaper._default = "1.jpg"
			-- Both dirs match test_wallpapers/ mock, so user-wallpapers exists
			local json = wallpaper.get_resolved_json()
			-- user-wallpapers found → isUserOverride:true
			assert.truthy(json:match('"isUserOverride":true'))
			awful.screen.focused = old_focused
		end)

		it("returns valid JSON array format", function()
			local awful = require("awful")
			local old_focused = awful.screen.focused
			awful.screen.focused = function()
				return { tags = { { name = "1" } } }
			end
			wallpaper._wppath = "test_wallpapers/"
			wallpaper._default = "1.jpg"
			local json = wallpaper.get_resolved_json()
			assert.equals("[", json:sub(1, 1))
			assert.equals("]", json:sub(-1))
			awful.screen.focused = old_focused
		end)
	end)

	describe("clear_user_wallpaper", function()
		it("returns false when not initialized", function()
			assert.is_false(wallpaper.clear_user_wallpaper("1"))
		end)

		it("returns false for empty tag name", function()
			wallpaper._user_wppath = "test_wallpapers/"
			assert.is_false(wallpaper.clear_user_wallpaper(""))
		end)

		it("returns false for nil tag name", function()
			wallpaper._user_wppath = "test_wallpapers/"
			assert.is_false(wallpaper.clear_user_wallpaper(nil))
		end)

		it("rejects path traversal in tag names", function()
			wallpaper._user_wppath = "test_wallpapers/"
			assert.is_false(wallpaper.clear_user_wallpaper("../etc"))
			assert.is_false(wallpaper.clear_user_wallpaper(".."))
			assert.is_false(wallpaper.clear_user_wallpaper("."))
			assert.is_false(wallpaper.clear_user_wallpaper("a/b"))
			assert.is_false(wallpaper.clear_user_wallpaper("a\\b"))
		end)

		it("accepts valid alphanumeric tag names", function()
			wallpaper._user_wppath = "/nonexistent/user-wp/"
			-- Returns false because no files to remove, but doesn't error
			local result = wallpaper.clear_user_wallpaper("1")
			assert.is_false(result)
		end)

		it("clears in-memory override for the tag", function()
			wallpaper._user_wppath = "/nonexistent/user-wp/"
			wallpaper._wppath = "test_wallpapers/"
			wallpaper._default = "1.jpg"
			wallpaper._overrides["3"] = "test_wallpapers/custom.jpg"
			wallpaper.clear_user_wallpaper("3")
			assert.is_nil(wallpaper._overrides["3"])
		end)

		it("emits data::wallpaper signal", function()
			wallpaper._user_wppath = "/nonexistent/user-wp/"
			wallpaper._wppath = "test_wallpapers/"
			wallpaper._default = "1.jpg"
			mock_broker_signals = {}
			wallpaper.clear_user_wallpaper("1")
			assert.equals(1, #mock_broker_signals)
			assert.equals("data::wallpaper", mock_broker_signals[1].name)
		end)

		it("rejects tag names with special chars", function()
			wallpaper._user_wppath = "test_wallpapers/"
			assert.is_false(wallpaper.clear_user_wallpaper("tag name"))
			assert.is_false(wallpaper.clear_user_wallpaper("tag;rm"))
			assert.is_false(wallpaper.clear_user_wallpaper("$(cmd)"))
		end)

		it("accepts tag names with dashes and underscores", function()
			wallpaper._user_wppath = "/nonexistent/user-wp/"
			-- Should not error, just return false (no files)
			local result = wallpaper.clear_user_wallpaper("my-tag_1")
			assert.is_false(result)
		end)
	end)

	describe("view_tag", function()
		it("is a public function", function()
			assert.is_function(wallpaper.view_tag)
		end)
	end)
end)
