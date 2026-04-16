---------------------------------------------------------------------------
--- Tests for fishlive.services.themes
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

local mock_beautiful_path = nil
package.preload["beautiful"] = function()
	return {
		init = function(path) mock_beautiful_path = path end,
	}
end

local mock_config_dir = "/tmp/somewm-test-themes/"
package.preload["gears"] = function()
	return {
		filesystem = {
			get_configuration_dir = function() return mock_config_dir end,
			file_readable = function(path)
				if not path then return false end
				-- Check if file actually exists for test
				local f = io.open(path, "r")
				if f then f:close(); return true end
				return false
			end,
		},
	}
end

package.preload["gears.filesystem"] = function()
	return require("gears").filesystem
end

package.preload["awful"] = function()
	return {
		screen = { focused = function() return nil end },
	}
end

package.preload["wibox"] = function()
	return {
		widget = { imagebox = function() return {} end },
		container = { tile = "tile" },
	}
end

-- Stub screen iterator (for scr in screen do ... end)
-- In Lua, `for var in callable_table do` uses __call as the iterator function.
-- __call must return nil to signal end of iteration.
local _screen_list = {}
_G.screen = setmetatable({}, {
	__call = function(_, prev)
		if prev == nil then
			return _screen_list[1]
		end
		for i, s in ipairs(_screen_list) do
			if s == prev then return _screen_list[i + 1] end
		end
		return nil
	end,
})

describe("themes service", function()
	local themes
	local test_dir

	setup(function()
		-- Create temporary test theme directories
		test_dir = mock_config_dir
		os.execute("mkdir -p '" .. test_dir .. "themes/default/wallpapers'")
		os.execute("mkdir -p '" .. test_dir .. "themes/dark/wallpapers'")

		-- Create minimal theme.lua files
		local f1 = io.open(test_dir .. "themes/default/theme.lua", "w")
		f1:write([[
local theme = {}
theme.theme_name = "default"
theme.bg_normal = "#181818"
theme.bg_focus = "#232323"
theme.fg_normal = "#888888"
theme.fg_focus = "#d4d4d4"
theme.border_color_active = "#e2b55a"
theme.bg_urgent = "#e06c75"
theme.widget_cpu_color = "#7daea3"
return theme
]])
		f1:close()

		local f2 = io.open(test_dir .. "themes/dark/theme.lua", "w")
		f2:write([[
local theme = {}
theme.theme_name = "dark"
theme.bg_normal = "#0d0d0d"
theme.bg_focus = "#1a1a1a"
theme.fg_normal = "#999999"
theme.fg_focus = "#ffffff"
theme.border_color_active = "#61afef"
theme.bg_urgent = "#e06c75"
theme.widget_cpu_color = "#56b6c2"
return theme
]])
		f2:close()

		-- Create some test wallpapers
		for i = 1, 3 do
			local wf = io.open(test_dir .. "themes/default/wallpapers/" .. i .. ".jpg", "w")
			wf:write("fake jpg " .. i)
			wf:close()
		end
	end)

	teardown(function()
		os.execute("rm -rf '" .. test_dir .. "'")
	end)

	before_each(function()
		package.loaded["fishlive.services.themes"] = nil
		package.loaded["fishlive.services.wallpaper"] = nil
		mock_broker_signals = {}
		mock_beautiful_path = nil
		-- Clean state file
		os.remove(test_dir .. ".active_theme")
		themes = require("fishlive.services.themes")
	end)

	describe("get_current", function()
		it("returns 'default' when no state file", function()
			assert.equals("default", themes.get_current())
		end)

		it("returns saved theme name", function()
			local f = io.open(test_dir .. ".active_theme", "w")
			f:write("dark\n")
			f:close()
			assert.equals("dark", themes.get_current())
		end)

		it("falls back to default for invalid theme", function()
			local f = io.open(test_dir .. ".active_theme", "w")
			f:write("nonexistent\n")
			f:close()
			assert.equals("default", themes.get_current())
		end)
	end)

	describe("get_palette", function()
		it("extracts colors from theme.lua", function()
			local palette = themes.get_palette(test_dir .. "themes/default/theme.lua")
			assert.is_not_nil(palette)
			assert.equals("#181818", palette.bg_normal)
			assert.equals("#e2b55a", palette.border_color_active)
			assert.equals("#e06c75", palette.bg_urgent)
			assert.equals("default", palette.theme_name)
		end)

		it("extracts dark theme colors", function()
			local palette = themes.get_palette(test_dir .. "themes/dark/theme.lua")
			assert.is_not_nil(palette)
			assert.equals("#0d0d0d", palette.bg_normal)
			assert.equals("#61afef", palette.border_color_active)
			assert.equals("dark", palette.theme_name)
		end)

		it("returns nil for nonexistent file", function()
			assert.is_nil(themes.get_palette("/nonexistent/theme.lua"))
		end)
	end)

	describe("scan", function()
		it("finds available themes", function()
			local list = themes.scan()
			assert.is_true(#list >= 2)

			local names = {}
			for _, t in ipairs(list) do names[t.name] = true end
			assert.is_true(names["default"])
			assert.is_true(names["dark"])
		end)

		it("includes palette in scan results", function()
			local list = themes.scan()
			for _, t in ipairs(list) do
				if t.name == "default" then
					assert.equals("#181818", t.palette.bg_normal)
				end
			end
		end)

		it("marks active theme", function()
			local list = themes.scan()
			local found_active = false
			for _, t in ipairs(list) do
				if t.active then
					assert.equals("default", t.name)
					found_active = true
				end
			end
			assert.is_true(found_active)
		end)

		it("counts wallpapers", function()
			local list = themes.scan()
			for _, t in ipairs(list) do
				if t.name == "default" then
					assert.equals(3, t.wallpaper_count)
				end
			end
		end)
	end)

	describe("scan_json", function()
		it("returns valid JSON", function()
			local json = themes.scan_json()
			assert.is_string(json)
			assert.truthy(json:match("^%["))
			assert.truthy(json:match("%]$"))
			assert.truthy(json:match('"default"'))
		end)
	end)

	describe("get_palette_json", function()
		it("returns palette as JSON", function()
			local json = themes.get_palette_json("default")
			assert.truthy(json:match('"bg_normal"'))
			assert.truthy(json:match("#181818"))
		end)

		it("returns empty object for missing theme", function()
			assert.equals("{}", themes.get_palette_json("nonexistent"))
		end)
	end)

	describe("switch", function()
		it("returns false for nonexistent theme", function()
			assert.is_false(themes.switch("nonexistent"))
		end)

		it("rejects path traversal in theme name", function()
			assert.is_false(themes.switch("../etc"))
			assert.is_false(themes.switch("foo/bar"))
			assert.is_false(themes.switch(".."))
			assert.is_false(themes.switch("."))
			assert.is_false(themes.switch(""))
		end)

		it("calls beautiful.init with new theme path", function()
			themes.switch("dark")
			assert.equals(test_dir .. "themes/dark/theme.lua", mock_beautiful_path)
		end)

		it("persists theme selection", function()
			themes.switch("dark")
			assert.equals("dark", themes.get_current())
		end)

		it("emits data::theme signal", function()
			themes.switch("dark")
			local found = false
			for _, sig in ipairs(mock_broker_signals) do
				if sig.name == "data::theme" then
					assert.equals("dark", sig.data.name)
					found = true
				end
			end
			assert.is_true(found)
		end)
	end)
end)
