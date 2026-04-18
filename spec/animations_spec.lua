-- Unit tests for rubato animation components
-- Run: busted --helper='plans/project/somewm-one/spec/preload.lua' \
--            --lpath='plans/project/somewm-one/?.lua;plans/project/somewm-one/?/init.lua' \
--            plans/project/somewm-one/spec/animations_spec.lua

-- Stub lgi before anything loads rubato
local monotonic_time = 0
package.preload["lgi"] = function()
	return {
		GLib = {
			timeout_add = function(_, interval, cb)
				for _ = 1, 5 do
					monotonic_time = monotonic_time + interval * 1000
					cb()
				end
				return 1
			end,
			get_monotonic_time = function()
				return monotonic_time
			end,
		},
	}
end

-- Minimal stubs
package.preload["beautiful"] = function()
	return {
		xresources = { apply_dpi = function(v) return v end },
		font = "sans 10",
	}
end
package.preload["gears"] = function()
	return {
		timer = function() return { start = function() end } end,
		shape = { rounded_rect = function() end },
	}
end
package.preload["wibox"] = function()
	return {
		widget = {
			textbox = function() return {} end,
			imagebox = { name = "imagebox" },
			base = { make_widget_from_value = function() return {} end },
		},
		container = {
			place = { name = "place" },
			background = { name = "background" },
			margin = { name = "margin" },
			constraint = { name = "constraint" },
		},
		layout = {
			fixed = { horizontal = {}, vertical = {} },
		},
	}
end
package.preload["awful"] = function()
	return {
		widget = {
			taglist = {
				filter = { all = function() end },
			},
		},
		tag = { viewtoggle = function() end, viewprev = function() end, viewnext = function() end },
		button = function() return {} end,
	}
end
package.preload["naughty"] = function()
	return {
		widget = { title = {}, message = {} },
		container = { background = {} },
		layout = { box = function() return { valid = true, opacity = 1 } end },
		config = { defaults = {}, icon_dirs = {}, icon_formats = {} },
		connect_signal = function() end,
	}
end
package.preload["ruled"] = function()
	return {
		notification = {
			connect_signal = function() end,
			append_rule = function() end,
		},
	}
end

-- Stubbable XDG icon lookup (tests override the lookup table).
_G._test_menubar_icons = {}
package.preload["menubar.utils"] = function()
	return {
		lookup_icon = function(name)
			return _G._test_menubar_icons[name]
		end,
	}
end

package.preload["anim_client"] = function()
	return { fade_notification = function() end }
end

-- Stubbable portraits service for notification-fallback tests.
_G._test_portraits_random = nil
_G._test_portraits_calls = 0
package.preload["fishlive.services.portraits"] = function()
	return {
		random_image = function()
			_G._test_portraits_calls = _G._test_portraits_calls + 1
			return _G._test_portraits_random
		end,
	}
end

-- ===== Notifications component tests =====
describe("fishlive.components.notifications", function()
	local notifications
	local function make_surface(w, h)
		return { get_width = function() return w end, get_height = function() return h end }
	end

	setup(function()
		notifications = require("fishlive.components.notifications")
	end)

	before_each(function()
		_G._test_menubar_icons = {}
		_G._test_portraits_random = nil
		_G._test_portraits_calls = 0
	end)

	describe("_resolve_icon", function()
		it("returns icon for absolute path", function()
			local n = { icon = "/usr/share/icons/test.png" }
			assert.are.equal("/usr/share/icons/test.png", notifications._resolve_icon(n))
		end)

		it("falls back to default for empty-string icon", function()
			local n = { icon = "" }
			assert.is_nil(notifications._resolve_icon(n))
		end)

		it("falls back to default for nil icon", function()
			local n = { icon = nil }
			assert.is_nil(notifications._resolve_icon(n))
		end)

		it("falls back to default for relative-path icon", function()
			local n = { icon = "relative/path.png" }
			assert.is_nil(notifications._resolve_icon(n))
		end)

		it("returns a cairo surface with real dimensions", function()
			local surface = make_surface(64, 64)
			local n = { icon = surface }
			assert.are.equal(surface, notifications._resolve_icon(n))
		end)

		it("treats a 0x0 cairo error-surface as no icon (regression: notify-send --icon=<XDG-name>)", function()
			-- When libnotify puts an XDG icon name into image-path, naughty's
			-- icon_path_handler fails to load it and stores gears.surface's
			-- 0x0 default error surface, which is still truthy.
			local broken = make_surface(0, 0)
			local n = { icon = broken, image = "does-not-exist" }
			assert.is_nil(notifications._resolve_icon(n))
		end)

		it("resolves XDG icon name from n.image when n.icon is a broken surface", function()
			_G._test_menubar_icons["claude-ai"] = "/usr/share/icons/Papirus/claude.svg"
			local broken = make_surface(0, 0)
			local n = { icon = broken, image = "claude-ai" }
			assert.are.equal("/usr/share/icons/Papirus/claude.svg",
				notifications._resolve_icon(n))
		end)

		it("resolves XDG name case-insensitively", function()
			_G._test_menubar_icons["slack"] = "/usr/share/icons/slack.png"
			local n = { icon = nil, image = "Slack" }
			assert.are.equal("/usr/share/icons/slack.png",
				notifications._resolve_icon(n))
		end)

		it("falls back from image → app_icon → app_name", function()
			_G._test_menubar_icons["firefox"] = "/firefox.png"
			local n = { icon = nil, image = nil, app_icon = nil, app_name = "Firefox" }
			assert.are.equal("/firefox.png", notifications._resolve_icon(n))
		end)

		it("never treats absolute-path strings as XDG names", function()
			_G._test_menubar_icons["/tmp/foo"] = "/should-not-hit.png"
			local n = { icon = nil, image = "/tmp/foo" }
			assert.is_nil(notifications._resolve_icon(n))
		end)

		it("falls through to random portrait when XDG has no hit", function()
			_G._test_portraits_random = "/home/user/portrait/joy/a.jpg"
			local n = { icon = nil, image = nil, app_icon = nil, app_name = nil }
			assert.are.equal("/home/user/portrait/joy/a.jpg",
				notifications._resolve_icon(n))
			assert.are.equal(1, _G._test_portraits_calls)
		end)

		it("falls through to bell when portrait also returns nil", function()
			_G._test_portraits_random = nil
			local n = { icon = nil }
			assert.is_nil(notifications._resolve_icon(n))
			assert.are.equal(1, _G._test_portraits_calls)
		end)

		it("does NOT call portraits when XDG hits", function()
			_G._test_menubar_icons["firefox"] = "/firefox.png"
			_G._test_portraits_random = "/should-not-be-used.jpg"
			local n = { icon = nil, image = "firefox" }
			assert.are.equal("/firefox.png", notifications._resolve_icon(n))
			assert.are.equal(0, _G._test_portraits_calls)
		end)

		it("does NOT call portraits when n.icon is a valid absolute path", function()
			_G._test_portraits_random = "/should-not-be-used.jpg"
			local n = { icon = "/usr/share/icons/test.png" }
			assert.are.equal("/usr/share/icons/test.png", notifications._resolve_icon(n))
			assert.are.equal(0, _G._test_portraits_calls)
		end)
	end)
end)
