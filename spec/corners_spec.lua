-- Unit tests for client corners, borders and shadow corners
-- (fishlive.config.animations on somewm 2.x).
-- Run: busted --helper='spec/preload.lua' \
--            --lpath='?.lua;?/init.lua' \
--            spec/corners_spec.lua

local mock_beautiful = {}
local stubs = {
	beautiful = function() return mock_beautiful end,
	gears = function() return { timer = { start_new = function() end } } end,
	ruled = function()
		return { client = { connect_signal = function() end, append_rule = function() end } }
	end,
}

-- somewm returns a settings table for every explicit shadow override.
local function make_client(props)
	local c = { class = "Alacritty", name = "term", shadow = { enabled = true, corner_radius = 14 } }
	for k, v in pairs(props or {}) do c[k] = v end
	return c
end

describe("fishlive.config.animations corners", function()
	local animations

	setup(function()
		-- Other spec files install their own stubs, including one for this
		-- very module: load the real file against this file's stubs.
		for name, loader in pairs(stubs) do
			package.loaded[name] = nil
			package.preload[name] = loader
		end
		animations = dofile("fishlive/config/animations.lua")
	end)

	before_each(function()
		for k in pairs(mock_beautiful) do mock_beautiful[k] = nil end
		animations.corner_radius = 14
	end)

	describe("apply_corners", function()
		it("rounds a normal client and retains its theme border", function()
			local c = make_client { border_width = 3 }
			animations.apply_corners(c)
			assert.equals(14, c.shape)
			assert.equals(3, c.border_width)
		end)

		it("leaves a rounded client's shadow to the theme", function()
			local shadow = { enabled = true, corner_radius = 14 }
			local c = make_client { shadow = shadow }
			animations.apply_corners(c)
			assert.equals(shadow, c.shadow)
		end)

		it("keeps games square, with their border and a square shadow", function()
			local c = make_client { class = "steam_app_2592160" }
			animations.apply_corners(c)
			assert.is_nil(c.shape)
			assert.is_nil(c.border_width)
			assert.same({ corner_radius = 0 }, c.shadow)
		end)

		it("keeps Wine and .exe windows square", function()
			for _, class in ipairs { "Wine", "sierrachart.exe", "Xwayland" } do
				local c = make_client { class = class }
				animations.apply_corners(c)
				assert.is_nil(c.shape, class)
			end
		end)

		it("keeps the web widgets square by name", function()
			local c = make_client { class = "WebKitWebProcess", name = "somewm-widget-clock" }
			animations.apply_corners(c)
			assert.is_nil(c.shape)
		end)

		it("does not turn a disabled shadow back on for a square client", function()
			local c = make_client { class = "Wine", shadow = false }
			animations.apply_corners(c)
			assert.is_false(c.shadow)
		end)

		it("preserves a disabled override table and its fields", function()
			local shadow = { enabled = false, radius = 19 }
			local c = make_client { class = "Wine", shadow = shadow }
			animations.apply_corners(c)
			assert.equals(shadow, c.shadow)
		end)

		it("rounds a client that is fullscreen at manage time (2.1 squares it while fullscreen)", function()
			local c = make_client { fullscreen = true }
			animations.apply_corners(c)
			assert.equals(14, c.shape)
		end)

		it("follows a changed corner radius", function()
			animations.corner_radius = 8
			local c = make_client()
			animations.apply_corners(c)
			assert.equals(8, c.shape)
		end)
	end)

	describe("refresh_shadows", function()
		it("refreshes only enabled square clients using fresh defaults", function()
			local game = make_client { class = "steam_app_123", shadow = { enabled = true, radius = 99 } }
			local wine = make_client { class = "Wine" }
			local widget = make_client { name = "somewm-widget-clock", shadow = { enabled = false } }
			local off = make_client { class = "Wine", shadow = false }
			local terminal = make_client()
			local original_client = client
			_G.client = { get = function() return { game, wine, widget, off, terminal } end }
			local ok, err = pcall(animations.refresh_shadows)
			_G.client = original_client
			assert.is_true(ok, err)
			assert.same({ corner_radius = 0 }, game.shadow)
			assert.same({ corner_radius = 0 }, wine.shadow)
			assert.same({ enabled = false }, widget.shadow)
			assert.is_false(off.shadow)
			assert.same({ enabled = true, corner_radius = 14 }, terminal.shadow)
		end)
	end)

	describe("apply_theme_keys", function()
		it("rounds client shadows like the clients and keeps drawin shadows square", function()
			animations.apply_theme_keys()
			assert.equals(14, mock_beautiful.shadow_corner_radius)
			assert.equals(0, mock_beautiful.shadow_drawin_corner_radius)
		end)

		it("keeps shadow corner radii a theme sets itself", function()
			mock_beautiful.shadow_corner_radius = 20
			mock_beautiful.shadow_drawin_corner_radius = 6
			animations.apply_theme_keys()
			assert.equals(20, mock_beautiful.shadow_corner_radius)
			assert.equals(6, mock_beautiful.shadow_drawin_corner_radius)
		end)

		it("fills the animation keys", function()
			animations.apply_theme_keys()
			assert.equals("fade", mock_beautiful.animation_appear)
		end)
	end)
end)
