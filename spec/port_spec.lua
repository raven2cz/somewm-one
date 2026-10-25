-- Regression checks for the 2.1 port, with no compositor dependencies.
local function signals()
	local object = { handlers = {} }
	function object.connect_signal(name, fn) object.handlers[name] = fn end
	function object.disconnect_signal(name, fn)
		assert.equals(fn, object.handlers[name])
		object.handlers[name] = nil
	end
	return object
end

local function instance()
	local object = { handlers = {} }
	function object:connect_signal(name, fn) self.handlers[name] = fn end
	function object:disconnect_signal(name, fn)
		assert.equals(fn, self.handlers[name])
		self.handlers[name] = nil
	end
	return object
end

describe("2.1 port", function()
	local loaded, globals
	local function stub(name, value)
		if loaded[name] == nil then loaded[name] = { package.loaded[name] } end
		package.loaded[name] = value
	end
	before_each(function()
		loaded, globals = {}, {}
		for _, name in ipairs { "awesome", "client", "screen", "tag", "drawin", "mouse",
			"RUBATO_MANAGER", "RUBATO_TIMEOUTS", "RUBATO_DIR" } do
			globals[name] = { _G[name] }
		end
	end)
	after_each(function()
		for name, value in pairs(loaded) do package.loaded[name] = value[1] end
		for name, value in pairs(globals) do _G[name] = value[1] end
	end)

	describe("client fixes", function()
		local fixes, callbacks, placement
		before_each(function()
			_G.client = signals()
			callbacks = {}
			stub("awful.mouse.resize", {
				add_enter_callback = function(fn) callbacks.enter = fn end,
				add_move_callback = function(fn) callbacks.move = fn end,
				add_leave_callback = function(fn) callbacks.leave = fn end,
			})
			placement = spy.new(function() end)
			stub("awful", { placement = { no_offscreen = placement } })
			fixes = dofile("fishlive/config/client_fixes.lua")
			fixes.setup()
		end)
		it("captures the full mpv frame including titlebars", function()
			local c = { class = "mpv", floating = true,
				geometry = function() return { width = 1600, height = 930 } end }
			fixes.update_mpv_aspect(c)
			assert.equals(1600 / 930, c.aspect_ratio)
		end)
		it("keeps the ratio and opposite edge during a left resize", function()
			local c = { class = "mpv", aspect_ratio = 2 }
			local geo = callbacks.move(c, { x = 100, y = 100, width = 800, height = 600 }, { corner = "left" })
			assert.same({ x = 100, y = 200, width = 800, height = 400 }, geo)
		end)
		it("does not recapture the ratio during a drag", function()
			local c = { class = "mpv", floating = true, aspect_ratio = 2,
				geometry = function() return { width = 900, height = 300 } end }
			callbacks.enter(c)
			client.handlers["property::size"](c)
			assert.equals(2, c.aspect_ratio)
			callbacks.leave(c)
			client.handlers["property::size"](c)
			assert.equals(3, c.aspect_ratio)
		end)
		it("places Steam inside the screen workarea with native origin handling", function()
			local c = { class = "Steam", screen = { geometry = { x = -1920, y = 1080 } } }
			client.handlers["property::position"](c)
			assert.spy(placement).was_called_with(c, { honor_workarea = true })
		end)
	end)

	it("refreshes keyboard map names and disconnects both listeners", function()
		_G.awesome = signals()
		local names, group, last = "pc+us+cz(qwerty):2+grp:alt_shift_toggle", 1
		awesome.xkb_get_group_names = function() return names end
		awesome.xkb_get_layout_group = function() return group end
		stub("fishlive.broker", { register_producer = function() end,
			emit_signal = function(_, data) last = data end })
		local keyboard = dofile("fishlive/services/keyboard.lua")
		keyboard:start()
		assert.same({ "us", "cz" }, last.layouts)
		names, group = "pc+de", 0
		awesome.handlers["xkb::map_changed"]()
		assert.same({ "de" }, last.layouts)
		assert.equals("de", last.layout)
		keyboard:stop()
		assert.is_nil(next(awesome.handlers))
	end)

	it("reads notification theme rules at display time and forwards width and opacity", function()
		local theme = { font = "old", notification_bg = "#111111", notification_fg = "#eeeeee",
			xresources = { apply_dpi = function(v) return v end } }
		local rules, display, args = {}, nil, nil
		stub("beautiful", theme)
		stub("awful", { spawn = { with_shell = function() end } })
		stub("gears", { shape = {}, string = { xml_escape = function(v) return v end } })
		stub("wibox", { widget = {}, container = {}, layout = { fixed = {} } })
		stub("ruled", { notification = {
			connect_signal = function(_, fn) fn() end,
			append_rule = function(rule) rules[#rules + 1] = rule end,
		} })
		stub("naughty", { config = { defaults = {} }, widget = {}, container = {},
			connect_signal = function(_, fn) display = fn end,
			layout = { box = function(a) args = a end } })
		stub("menubar.utils", { lookup_icon = function() end })
		stub("fishlive.services.portraits", { random_image = function() end })
		stub("fishlive.config.animations", { popup_animation = {} })
		_G.awesome = {}
		dofile("fishlive/components/notifications.lua")
		theme.font, theme.notification_bg = "new", "#222222"
		assert.equals("new", rules[2].properties.font())
		assert.equals("#222222", rules[2].properties.bg())
		display { opacity = 0.9 }
		assert.equals(0.9, args.opacity)
		assert.equals(900, theme.notification_width)
		assert.equals(900, args.maximum_width)
		theme.notification_width = 1000
		display { opacity = 1 }
		assert.equals(1000, args.maximum_width)
	end)

	it("hides the previous calendar on theme rebuild", function()
		local popups, theme_change = {}, nil
		local function text()
			return { set_format = function() end }
		end
		stub("wibox", { widget = setmetatable({ textbox = text, textclock = text },
			{ __call = function(_, args) return args end }), layout = { fixed = {} } })
		stub("gears", { shape = {} })
		stub("beautiful", {})
		stub("fishlive.widget_helper", {})
		stub("fishlive.broker", { connect_signal = function(_, fn) theme_change = fn end })
		stub("awful", { widget = { calendar_popup = { month = function()
			local popup = { attach = function() end }
			popups[#popups + 1] = popup
			return popup
		end } } })
		dofile("fishlive/components/clock.lua").create({}, {})
		popups[1].visible = true
		theme_change()
		assert.equals(2, #popups)
		assert.is_false(popups[1].visible)
	end)

	describe("menu", function()
		local menu, popup, placed, bars
		before_each(function()
			_G.client, _G.drawin, _G.mouse = signals(), signals(), {}
			bars = { { visible = true, drawable = instance() } }
			drawin.get = function() return bars end
			placed = {}
			stub("awful", {
				popup = function(args)
					popup = instance()
					popup.width, popup.height, popup.drawin = 1, 1, {}
					return popup
				end,
				button = function(_, _, fn) return fn end,
				keygrabber = function() return { stop = function() end } end,
				mouse = { append_global_mousebinding = function() end, remove_global_mousebinding = function() end },
				placement = {
					under_mouse = function(p) placed[#placed + 1] = { p.width, p.height } end,
					no_offscreen = function() end,
				},
			})
			stub("gears", { shape = {}, string = {}, timer = { start_new = function() end } })
			stub("wibox", { container = {}, layout = { fixed = { vertical = function()
				return { reset = function() end }
			end } } })
			stub("beautiful", {})
			stub("beautiful.xresources", { apply_dpi = function(v) return v end })
			stub("fishlive.broker", { connect_signal = function() end })
			menu = dofile("fishlive/menu.lua").new { items = {} }
			menu:show()
		end)
		it("repositions when solved dimensions arrive, without position loops", function()
			popup.width, popup.height = 220, 180
			popup.handlers["property::geometry"](popup)
			assert.same({ 220, 180 }, placed[#placed])
			local count = #placed
			popup.handlers["property::geometry"](popup)
			assert.equals(count, #placed)
			menu:hide()
			popup.width = 300
			popup.handlers["property::geometry"](popup)
			assert.equals(count, #placed)
		end)
		it("closes on client presses and removes all outside observers", function()
			client.handlers["button::press"]({}, 1, 1, 1)
			assert.is_false(popup.visible)
			assert.is_nil(client.handlers["button::press"])
			assert.is_nil(drawin.handlers["property::visible"])
			assert.is_nil(bars[1].drawable.handlers["button::press"])
		end)
		it("observes existing and newly shown wibars but excludes itself", function()
			local watcher = drawin.handlers["property::visible"]
			popup.drawin.visible = true
			watcher(popup.drawin)
			local bar = { visible = true, drawable = instance() }
			watcher(bar)
			bar.drawable.handlers["button::press"]({}, 1, 1, 1)
			assert.is_false(popup.visible)
			assert.is_nil(bar.drawable.handlers["button::press"])
		end)
	end)

	it("omits stock nested suits and registers Machi cleanup only once", function()
		stub("layout-machi.engine", {})
		stub("layout-machi.paint", function() end)
		stub("gears.filesystem", { get_cache_dir = function() return "/tmp/nonexistent-machi-spec" end })
		stub("gears.object", {})
		stub("beautiful", {})
		stub("beautiful.xresources", { apply_dpi = function(v) return v end })
		stub("wibox", {})
		stub("naughty", {})
		stub("gears", {})
		stub("lgi", {})
		stub("awful", { mouse = { resize = { add_enter_callback = function() end } }, layout = {} })
		local editor = assert(loadfile("layout-machi/editor.lua"))("layout-machi.editor")
		assert.same({}, editor.nested_layouts)
		stub("layout-machi.editor", editor)
		_G.screen = {}
		local scr = { workarea = { x = 0, y = 0, width = 800, height = 600 } }
		screen[1], screen[scr] = scr, scr
		local t = instance()
		t.screen = scr
		local connects = 0
		local connect = t.connect_signal
		function t:connect_signal(name, fn) connects = connects + 1; connect(self, name, fn) end
		scr.selected_tag = t
		local layout = assert(loadfile("layout-machi/layout.lua"))("layout-machi.layout").create {
			name = "test", editor = {
				get_last_cmd = function() end,
				run_cmd = function() return { { x = 0, y = 0, width = 800, height = 600, habitable = true, layout = "0" } } end,
			},
		}
		local c = { x = 0, y = 0, width = 800, height = 600, border_width = 0 }
		local p = { screen = 1, tag = t, clients = { c }, geometries = {}, useless_gap = 0 }
		layout.arrange(p)
		assert.same({ x = 0, y = 0, width = 800, height = 600 }, p.geometries[c])
		layout.arrange(p)
		assert.equals(2, connects)
		t.handlers["property::layout"](t)
		assert.is_nil(next(t.handlers))
		layout.arrange(p)
		assert.equals(4, connects)
	end)

	it("reuses and clears the Machi canvas at output resolution", function()
		local surfaces, operations = {}, {}
		stub("lgi", { cairo = {
			Format = { ARGB32 = 0 }, Operator = { CLEAR = 0, OVER = 1 },
			ImageSurface = { create = function(_, w, h)
				local s = { width = w, height = h, flush = function() end }
				surfaces[#surfaces + 1] = s
				return s
			end },
			Context = { create = function()
				return { set_operator = function(_, op) operations[#operations + 1] = op end,
					paint = function() end, scale = function(_, x, y) assert.equals(1.5, x); assert.equals(x, y) end }
			end },
		} })
		stub("wibox", { widget = { imagebox = {} } })
		local paint = dofile("layout-machi/paint.lua")
		local wb = { screen = { scale = 1.5 }, geometry = function() return { width = 800, height = 600 } end }
		local draw = spy.new(function(_, _, w, h) assert.equals(800, w); assert.equals(600, h) end)
		paint(wb, draw)
		local previous = wb.widget
		paint(wb, draw)
		assert.equals(1, #surfaces)
		assert.equals(1200, surfaces[1].width)
		assert.equals(900, surfaces[1].height)
		assert.same({ 0, 1, 0, 1 }, operations)
		assert.is_not.equal(previous, wb.widget)
		assert.equals(800, wb.widget.forced_width)
		assert.spy(draw).was_called(2)
	end)
	describe("wallpaper rendering", function()
		local wallpaper, scr, trees, surfaces, source_loads
		before_each(function()
			trees, surfaces, source_loads = {}, {}, 0
			_G.screen, _G.tag = signals(), signals()
			stub("awful", { wallpaper = function(args)
				args.repaint = function(self) self.repaints = (self.repaints or 0) + 1 end
				trees[#trees + 1] = args
				return args
			end })
			stub("gears", {
				filesystem = { file_readable = function() return true end, get_configuration_dir = function() return "/test/" end },
				surface = { load_uncached_silently = function()
					source_loads = source_loads + 1
					return { width = 1920, height = 1080 }
				end },
			})
			stub("fishlive.broker", {})
			stub("fishlive.startup_timer", { mark = function() end })
			stub("wibox", { widget = { imagebox = function() return {} end }, container = { place = {} } })
			stub("lgi", { cairo = {
				Format = { ARGB32 = 0 },
				ImageSurface = function(_, w, h)
					local surf = { width = w, height = h }
					surfaces[#surfaces + 1] = surf
					return surf
				end,
				Context = function() return { scale = function() end, set_source_surface = function() end, paint = function() end } end,
			} })
			wallpaper = dofile("fishlive/services/wallpaper.lua")
			wallpaper._scopes_loaded = true
			wallpaper._resolve_for_screen = function(_, name) return "test/" .. name .. ".jpg" end
			scr = { index = 1, scale = 1.5, geometry = { width = 800, height = 600 },
				tags = { { name = "1" } }, selected_tag = { name = "7" } }
			wallpaper.init(scr, "test/wallpapers/")
		end)
		it("initializes the restored selected tag at device resolution", function()
			assert.equals("test/7.jpg", scr._current_wallpaper)
			assert.equals(1200, surfaces[1].width)
			assert.equals(900, surfaces[1].height)
			assert.equals(800, trees[1].widget[1].forced_width)
		end)
		it("reuses the wallpaper and cached covers across tag switches", function()
			wallpaper.apply(scr, "test/1.jpg")
			wallpaper.apply(scr, "test/7.jpg")
			assert.equals(1, #trees)
			assert.equals(2, #surfaces)
			assert.equals(2, source_loads)
			assert.equals(2, trees[1].repaints)
		end)
		it("bounds the cover cache", function()
			for n = 1, 3 do wallpaper.apply(scr, "test/" .. n .. ".jpg") end
			wallpaper.apply(scr, "test/7.jpg")
			assert.equals(5, #surfaces)
		end)
		it("switches for tags added after initialization", function()
			local late = { name = "9", screen = scr, selected = true }
			scr.selected_tag = late
			tag.handlers["property::selected"](late)
			assert.equals("test/9.jpg", scr._current_wallpaper)
		end)
		it("rebuilds on explicit wallpaper requests and scale changes", function()
			screen.handlers["request::wallpaper"](scr)
			assert.equals(2, #surfaces)
			scr.scale = 2
			screen.handlers["property::scale"](scr)
			assert.equals(1600, surfaces[3].width)
			assert.equals(1200, surfaces[3].height)
			assert.equals(1, #trees)
		end)
		it("reloads an overwritten file on explicit reapplication", function()
			scr._current_wallpaper = nil
			wallpaper.apply(scr, "test/7.jpg")
			assert.equals(2, source_loads)
		end)
		it("keeps renderer state separate per screen", function()
			local other = { index = 2, scale = 1, geometry = { width = 500, height = 900 }, tags = {} }
			wallpaper.init(other, "test/wallpapers/")
			assert.equals(2, #trees)
			assert.equals(500, surfaces[2].width)
			assert.equals(900, surfaces[2].height)
			assert.equals(1200, trees[1].widget[1].image.width)
		end)
	end)

	it("stops idle Rubato sources, restarts on retarget, and removes sources on exit", function()
		_G.RUBATO_DIR, _G.RUBATO_MANAGER, _G.RUBATO_TIMEOUTS = "fishlive.rubato.", nil, nil
		_G.awesome = signals()
		local now, callbacks, removed, next_source = 0, {}, {}, 0
		stub("lgi", { GLib = {
			PRIORITY_DEFAULT = 0,
			get_monotonic_time = function() return now end,
			timeout_add = function(_, _, fn)
				next_source = next_source + 1
				callbacks[next_source] = fn
				return next_source
			end,
			source_remove = function(id) removed[#removed + 1] = id end,
		} })
		local manager = assert(loadfile("fishlive/rubato/manager.lua"))("fishlive.rubato.manager")
		stub("fishlive.rubato.manager", manager)
		local timed = assert(loadfile("fishlive/rubato/timed.lua"))("fishlive.rubato.timed")
		local obj = timed { duration = 1, intro = 0.2, outro = 0.2 }
		obj.target = 1
		assert.is_true(callbacks[1]())
		now = 2000000
		assert.is_false(callbacks[1]())
		assert.is_nil(RUBATO_TIMEOUTS[1][60])
		obj.target = 0
		assert.equals(2, next_source)
		awesome.handlers.exit()
		assert.same({ 2 }, removed)
		assert.is_nil(RUBATO_TIMEOUTS[1][60])
	end)

end)
