---------------------------------------------------------------------------
--- Keybindings — all global keyboard/mouse bindings + client defaults.
--
-- Extracted from rc.lua for cleanliness. All bindings are registered
-- via awful.keyboard/mouse.append_global_keybindings().
--
-- Usage from rc.lua:
--   require("fishlive.config.keybindings").setup({
--       modkey = modkey,
--       altkey = altkey,
--       terminal = terminal,
--       editor_cmd = editor_cmd,
--       start_menu = start_menu,
--       desktop_menu = desktop_menu,
--   })
--
-- @module fishlive.config.keybindings
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local hotkeys_popup = require("awful.hotkeys_popup")
local menubar = require("menubar")
local machi = require("layout-machi")
local recording = require("fishlive.config.recording")

-- Evaluate a Lua expression and return its result (replaces awful.util.eval).
local function lua_eval(s)
    local f, err = load("return " .. s)
    if not f then
        f, err = load(s)
    end
    if f then
        local ok, result = pcall(f)
        if ok then return tostring(result) end
        return "error: " .. tostring(result)
    end
    return "parse error: " .. tostring(err)
end

local M = {}

--- Register all global and client keybindings + mouse bindings.
-- @tparam table args
-- @tparam string args.modkey Primary modifier key (e.g. "Mod4")
-- @tparam string args.altkey Alt modifier key (e.g. "Mod1")
-- @tparam string args.terminal Terminal emulator command
-- @tparam string args.editor_cmd Editor launch command
-- @tparam table args.start_menu fishlive.menu instance for Super+W
-- @tparam table args.desktop_menu fishlive.menu instance for right-click
-- @tparam table args.portraits_menu fishlive.menu instance for Super+Shift+P
function M.setup(args)
	local modkey = args.modkey
	local altkey = args.altkey
	local terminal = args.terminal
	local editor_cmd = args.editor_cmd
	local start_menu = args.start_menu
	local desktop_menu = args.desktop_menu
	local portraits_menu = args.portraits_menu

	-- somewm-shell overlay state (set via IPC from Quickshell Panels.qml)
	-- When true, desktop scroll-to-switch-tags is suppressed.
	-- Stored on awesome global to avoid polluting _G.
	awesome._shell_overlay = awesome._shell_overlay or false

	---------------------------------------------------------------------------
	-- Mouse bindings
	---------------------------------------------------------------------------

	awful.mouse.append_global_mousebindings({
		awful.button({ }, 3, function() desktop_menu:toggle() end),
		awful.button({ }, 4, function() if not awesome._shell_overlay then awful.tag.viewprev() end end),
		awful.button({ }, 5, function() if not awesome._shell_overlay then awful.tag.viewnext() end end),
		awful.button({ modkey, altkey }, 4, function()
			awful.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+")
		end),
		awful.button({ modkey, altkey }, 5, function()
			awful.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")
		end),
	})

	---------------------------------------------------------------------------
	-- General Awesome keys
	---------------------------------------------------------------------------

	awful.keyboard.append_global_keybindings({
		awful.key({ modkey, "Control" }, "s", hotkeys_popup.show_help,
			{description="show help", group="awesome"}),
		awful.key({ modkey }, "s", function() awful.spawn("rofi -show-icons -modi window,drun -show drun") end,
			{ description = "show rofi drun", group = "launcher" }),
		awful.key({ modkey }, "w", function() start_menu:toggle() end,
			{description = "show main menu", group = "awesome"}),
		awful.key({ modkey, "Shift" }, "p", function()
			if portraits_menu then portraits_menu:toggle() end
		end, {description = "switch default portrait collection", group = "awesome"}),
		awful.key({ modkey, "Shift" }, "r", awesome.restart,
			{description = "reload configuration", group = "awesome"}),
		awful.key({ modkey }, "q", function() awesome.emit_signal("exit_screen::toggle") end,
			{description = "exit screen (power/session)", group = "awesome"}),
		awful.key({ modkey, "Shift" }, "q", function() awesome.quit() end,
			{description = "quit somewm", group = "awesome"}),
		awful.key({ modkey, "Shift" }, "Escape", function() awesome.lock() end,
			{description = "lock screen", group = "awesome"}),
		awful.key({ modkey, "Shift" }, "l", function() awesome.lock() end,
			{description = "lock screen", group = "awesome"}),
		awful.key({ modkey, "Shift" }, "x",
			function()
				awful.prompt.run {
					prompt       = "Run Lua code: ",
					textbox      = awful.screen.focused().mypromptbox.widget,
					exe_callback = lua_eval,
					history_path = gears.filesystem.get_cache_dir() .. "/history_eval"
				}
			end,
			{description = "lua execute prompt", group = "awesome"}),
		awful.key({ modkey }, "Return", function() awful.spawn(terminal) end,
			{description = "open a terminal", group = "launcher"}),
		awful.key({ modkey }, "r", function() awful.screen.focused().mypromptbox:run() end,
			{description = "run prompt", group = "launcher"}),
		awful.key({ modkey }, "p", function() menubar.show() end,
			{description = "show the menubar", group = "launcher"}),

		-- somewm-shell: panel toggles
		awful.key({ modkey }, "d", function()
			awful.spawn("qs ipc -c somewm call somewm-shell:panels toggle dashboard")
		end, { description = "toggle dashboard", group = "shell" }),
		awful.key({ modkey }, "z", function()
			awful.spawn("qs ipc -c somewm call somewm-shell:panels toggle controlpanel")
		end, { description = "toggle control panel", group = "shell" }),
		awful.key({ modkey }, "x", function()
			awful.spawn("qs ipc -c somewm call somewm-shell:panels toggle dock")
		end, { description = "toggle dock", group = "shell" }),
		awful.key({ modkey, "Shift" }, "m", function()
			awful.spawn("qs ipc -c somewm call somewm-shell:panels toggle media")
		end, { description = "toggle media tab", group = "shell" }),
		awful.key({ modkey, "Shift" }, "w", function()
			awful.spawn("qs ipc -c somewm call somewm-shell:panels toggle wallpapers")
		end, { description = "toggle wallpaper picker", group = "shell" }),
		awful.key({ modkey, "Shift" }, "o", function()
			awful.spawn("qs ipc -c somewm call somewm-shell:collage editToggle")
		end, { description = "toggle collage edit mode", group = "shell" }),
		awful.key({ modkey }, "c", function()
			awful.spawn("qs ipc -c somewm call somewm-shell:panels closeAll")
		end, { description = "close all shell panels", group = "shell" }),
		awful.key({ modkey, "Shift" }, "e", function()
			awful.spawn("qs ipc -c somewm call somewm-shell:panels toggle weather")
		end, { description = "toggle weather", group = "shell" }),
		awful.key({ modkey, "Shift" }, "a", function()
			awful.spawn("qs ipc -c somewm call somewm-shell:panels toggle ai-chat")
		end, { description = "toggle AI chat", group = "shell" }),

		-- machi layout special keybindings
		awful.key({ modkey }, ".", function() machi.default_editor.start_interactive() end,
			{ description = "machi: edit the current machi layout", group = "layout" }),
		awful.key({ modkey }, "/", function() machi.switcher.start(client.focus) end,
			{ description = "machi: switch between windows", group = "layout" }),

		-- Volume control (PipeWire/wpctl) + OSD overlay
		awful.key({ modkey, altkey }, "k", function()
			awful.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+")
			awful.spawn.easy_async("wpctl get-volume @DEFAULT_AUDIO_SINK@", function(out)
				local vol = tonumber(out:match("Volume:%s+([%d%.]+)"))
				if vol then awful.spawn("qs ipc -c somewm call somewm-shell:panels showOsd volume " .. math.floor(vol * 100)) end
			end)
		end, { description = "volume up", group = "audio" }),
		awful.key({ modkey, altkey }, "j", function()
			awful.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")
			awful.spawn.easy_async("wpctl get-volume @DEFAULT_AUDIO_SINK@", function(out)
				local vol = tonumber(out:match("Volume:%s+([%d%.]+)"))
				if vol then awful.spawn("qs ipc -c somewm call somewm-shell:panels showOsd volume " .. math.floor(vol * 100)) end
			end)
		end, { description = "volume down", group = "audio" }),
		awful.key({ modkey, altkey }, "m", function()
			awful.spawn("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")
			awful.spawn.easy_async("wpctl get-volume @DEFAULT_AUDIO_SINK@", function(out)
				local vol = tonumber(out:match("Volume:%s+([%d%.]+)"))
				local muted = out:match("%[MUTED%]")
				awful.spawn("qs ipc -c somewm call somewm-shell:panels showOsd volume " .. (muted and "0" or math.floor((vol or 0) * 100)))
			end)
		end, { description = "toggle mute", group = "audio" }),
		awful.key({ modkey, altkey }, "0", function()
			awful.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0%")
			awful.spawn("qs ipc -c somewm call somewm-shell:panels showOsd volume 0")
		end, { description = "volume 0%", group = "audio" }),

		-- Brightness control (brightnessctl) + OSD overlay
		awful.key({ modkey, altkey }, "l", function()
			awful.spawn.easy_async("brightnessctl set 5%+", function()
				awful.spawn.easy_async("brightnessctl -m info", function(out)
					local pct = tonumber(out:match(",([%d]+)%%,"))
					if pct then awful.spawn("qs ipc -c somewm call somewm-shell:panels showOsd brightness " .. pct) end
				end)
			end)
		end, { description = "brightness up", group = "audio" }),
		awful.key({ modkey, altkey }, "h", function()
			awful.spawn.easy_async("brightnessctl set 5%-", function()
				awful.spawn.easy_async("brightnessctl -m info", function(out)
					local pct = tonumber(out:match(",([%d]+)%%,"))
					if pct then awful.spawn("qs ipc -c somewm call somewm-shell:panels showOsd brightness " .. pct) end
				end)
			end)
		end, { description = "brightness down", group = "audio" }),

		-- Screenshots (grim + slurp)
		awful.key({ }, "Print", function()
			awful.spawn("grim ~/Pictures/screenshot-" .. os.date("%Y%m%d-%H%M%S") .. ".png")
		end, { description = "screenshot full screen", group = "screenshot" }),
		awful.key({ "Shift" }, "Print", function()
			awful.spawn.with_shell('grim -g "$(slurp)" ~/Pictures/screenshot-' .. os.date("%Y%m%d-%H%M%S") .. '.png')
		end, { description = "screenshot region (slurp)", group = "screenshot" }),
		awful.key({ "Control" }, "Print", function()
			awful.spawn.with_shell("grim - | wl-copy")
		end, { description = "screenshot to clipboard", group = "screenshot" }),
		awful.key({ "Control", "Shift" }, "Print", function()
			awful.spawn.with_shell('grim -g "$(slurp)" - | wl-copy')
		end, { description = "screenshot region to clipboard", group = "screenshot" }),
	})

	---------------------------------------------------------------------------
	-- Screen recording (gpu-screen-recorder, NVENC)
	---------------------------------------------------------------------------

	awful.keyboard.append_global_keybindings({
		awful.key({ modkey, altkey }, "r", recording.toggle,
			{ description = "start/stop screen recording", group = "recording" }),
		awful.key({ modkey, altkey }, "p", recording.pause_resume,
			{ description = "pause/resume recording", group = "recording" }),
	})

	---------------------------------------------------------------------------
	-- Carousel layout keybindings
	---------------------------------------------------------------------------

	local carousel = awful.layout.suit.carousel
	awful.keyboard.append_global_keybindings({
		awful.key({ modkey, "Control" }, "Left", function()
			local t = awful.screen.focused().selected_tag
			if t then carousel.scroll_by(t, -0.5) end
		end, { description = "carousel: scroll left", group = "carousel" }),
		awful.key({ modkey, "Control" }, "Right", function()
			local t = awful.screen.focused().selected_tag
			if t then carousel.scroll_by(t, 0.5) end
		end, { description = "carousel: scroll right", group = "carousel" }),
		awful.key({ modkey, "Control" }, "equal", carousel.cycle_column_width,
			{ description = "carousel: cycle column width", group = "carousel" }),
		awful.key({ modkey, "Control" }, "minus", function() carousel.adjust_column_width(-0.1) end,
			{ description = "carousel: shrink column", group = "carousel" }),
		awful.key({ modkey, "Control" }, "plus", function() carousel.adjust_column_width(0.1) end,
			{ description = "carousel: grow column", group = "carousel" }),
		awful.key({ modkey, "Control", "Shift" }, "Left", function() carousel.move_column(-1) end,
			{ description = "carousel: move column left", group = "carousel" }),
		awful.key({ modkey, "Control", "Shift" }, "Right", function() carousel.move_column(1) end,
			{ description = "carousel: move column right", group = "carousel" }),
		awful.key({ modkey, "Control" }, "i", function() carousel.consume_window(-1) end,
			{ description = "carousel: consume window from left", group = "carousel" }),
		awful.key({ modkey, "Control" }, "o", function() carousel.consume_window(1) end,
			{ description = "carousel: consume window from right", group = "carousel" }),
		awful.key({ modkey, "Control" }, "e", carousel.expel_window,
			{ description = "carousel: expel window to own column", group = "carousel" }),
		awful.key({ modkey, "Control" }, "Home", carousel.focus_first_column,
			{ description = "carousel: focus first column", group = "carousel" }),
		awful.key({ modkey, "Control" }, "End", carousel.focus_last_column,
			{ description = "carousel: focus last column", group = "carousel" }),
	})

	-- Enable 3-finger swipe gesture for carousel viewport panning
	pcall(function() carousel.make_gesture_binding() end)

	---------------------------------------------------------------------------
	-- Tags related keybindings
	---------------------------------------------------------------------------

	awful.keyboard.append_global_keybindings({
		awful.key({ modkey }, "Left", awful.tag.viewprev,
			{description = "view previous", group = "tag"}),
		awful.key({ modkey }, "Right", awful.tag.viewnext,
			{description = "view next", group = "tag"}),
		awful.key({ modkey }, "Escape", awful.tag.history.restore,
			{description = "go back", group = "tag"}),
	})

	---------------------------------------------------------------------------
	-- Focus related keybindings
	---------------------------------------------------------------------------

	awful.keyboard.append_global_keybindings({
		awful.key({ modkey }, "j", function() awful.client.focus.byidx(1) end,
			{description = "focus next by index", group = "client"}),
		awful.key({ modkey }, "k", function() awful.client.focus.byidx(-1) end,
			{description = "focus previous by index", group = "client"}),
		awful.key({ modkey }, "Tab", function()
			awful.client.focus.history.previous()
			if client.focus then client.focus:raise() end
		end, {description = "go back", group = "client"}),
		awful.key({ modkey, "Control" }, "j", function() awful.screen.focus_relative(1) end,
			{description = "focus the next screen", group = "screen"}),
		awful.key({ modkey, "Control" }, "k", function() awful.screen.focus_relative(-1) end,
			{description = "focus the previous screen", group = "screen"}),
		awful.key({ modkey, "Control" }, "n", function()
			local c = awful.client.restore()
			if c then c:activate { raise = true, context = "key.unminimize" } end
		end, {description = "restore minimized", group = "client"}),
	})

	---------------------------------------------------------------------------
	-- Layout related keybindings
	---------------------------------------------------------------------------

	awful.keyboard.append_global_keybindings({
		awful.key({ modkey, "Shift" }, "j", function() awful.client.swap.byidx(1) end,
			{description = "swap with next client by index", group = "client"}),
		awful.key({ modkey, "Shift" }, "k", function() awful.client.swap.byidx(-1) end,
			{description = "swap with previous client by index", group = "client"}),
		awful.key({ modkey }, "u", awful.client.urgent.jumpto,
			{description = "jump to urgent client", group = "client"}),
		awful.key({ modkey }, "l", function() awful.tag.incmwfact(0.05) end,
			{description = "increase master width factor", group = "layout"}),
		awful.key({ modkey }, "h", function() awful.tag.incmwfact(-0.05) end,
			{description = "decrease master width factor", group = "layout"}),
		awful.key({ modkey, "Shift" }, "h", function() awful.tag.incnmaster(1, nil, true) end,
			{description = "increase the number of master clients", group = "layout"}),
		awful.key({ modkey, "Shift" }, "l", function() awful.tag.incnmaster(-1, nil, true) end,
			{description = "decrease the number of master clients", group = "layout"}),
		awful.key({ modkey, "Control" }, "h", function() awful.tag.incncol(1, nil, true) end,
			{description = "increase the number of columns", group = "layout"}),
		awful.key({ modkey, "Control" }, "l", function() awful.tag.incncol(-1, nil, true) end,
			{description = "decrease the number of columns", group = "layout"}),
		awful.key({ modkey }, "space", function() awful.layout.inc(1) end,
			{description = "select next", group = "layout"}),
		awful.key({ modkey, "Shift" }, "space", function() awful.layout.inc(-1) end,
			{description = "select previous", group = "layout"}),
	})

	---------------------------------------------------------------------------
	-- Numrow / numpad tag keybindings
	---------------------------------------------------------------------------

	awful.keyboard.append_global_keybindings({
		awful.key {
			modifiers   = { modkey },
			keygroup    = "numrow",
			description = "only view tag",
			group       = "tag",
			on_press    = function(index)
				local screen = awful.screen.focused()
				local tag = screen.tags[index]
				if tag then tag:view_only() end
			end,
		},
		awful.key {
			modifiers   = { modkey, "Control" },
			keygroup    = "numrow",
			description = "toggle tag",
			group       = "tag",
			on_press    = function(index)
				local screen = awful.screen.focused()
				local tag = screen.tags[index]
				if tag then awful.tag.viewtoggle(tag) end
			end,
		},
		awful.key {
			modifiers   = { modkey, "Shift" },
			keygroup    = "numrow",
			description = "move focused client to tag",
			group       = "tag",
			on_press    = function(index)
				if client.focus then
					local tag = client.focus.screen.tags[index]
					if tag then client.focus:move_to_tag(tag) end
				end
			end,
		},
		awful.key {
			modifiers   = { modkey, "Control", "Shift" },
			keygroup    = "numrow",
			description = "toggle focused client on tag",
			group       = "tag",
			on_press    = function(index)
				if client.focus then
					local tag = client.focus.screen.tags[index]
					if tag then client.focus:toggle_tag(tag) end
				end
			end,
		},
		awful.key {
			modifiers   = { modkey },
			keygroup    = "numpad",
			description = "select layout directly",
			group       = "layout",
			on_press    = function(index)
				local t = awful.screen.focused().selected_tag
				if t then t.layout = t.layouts[index] or t.layout end
			end,
		},
	})

	---------------------------------------------------------------------------
	-- Client default mouse/key bindings
	---------------------------------------------------------------------------

	client.connect_signal("request::default_mousebindings", function()
		awful.mouse.append_client_mousebindings({
			awful.button({ }, 1, function(c)
				c:activate { context = "mouse_click" }
			end),
			awful.button({ modkey }, 1, function(c)
				c:activate { context = "mouse_click", action = "mouse_move" }
			end),
			awful.button({ modkey }, 3, function(c)
				c:activate { context = "mouse_click", action = "mouse_resize" }
			end),
		})
	end)

	client.connect_signal("request::default_keybindings", function()
		awful.keyboard.append_client_keybindings({
			-- Fullscreen with pre-all-state memento so Super+F off restores
			-- to the true pre-max/pre-fs geometry, not the intermediate max rect.
			-- AwesomeWM's default shares data[c]["maximize"] for both states so
			-- entering FS from max overwrites the pre-max memento. We keep our
			-- own per-client memento to avoid that collision.
			awful.key({ modkey }, "f", function(c)
				if c.fullscreen then
					local saved = c._pre_fs_geom
					c.fullscreen = false
					if saved then
						c.maximized = false
						c.maximized_horizontal = false
						c.maximized_vertical = false
						c:geometry(saved)
						c._pre_fs_geom = nil
						c._pre_max_geom = nil
						c._pre_max_v_geom = nil
					end
				else
					-- Carry the correct pre-max memento through fullscreen.
					-- _pre_max_geom covers Super+M, _pre_max_v_geom covers Super+Ctrl+M.
					-- If the client was maximized via a non-keybinding path (titlebar,
					-- client request, rule) no memento exists — fall back to current
					-- geometry, matching pre-fix behavior (no regression).
					if c.maximized then
						c._pre_fs_geom = c._pre_max_geom or c:geometry()
					elseif c.maximized_vertical then
						c._pre_fs_geom = c._pre_max_v_geom or c:geometry()
					else
						c._pre_fs_geom = c:geometry()
					end
					c.fullscreen = true
				end
			end, {description = "toggle fullscreen", group = "client"}),
			awful.key({ modkey, "Shift" }, "c", function(c) c:kill() end,
				{description = "close", group = "client"}),
			awful.key({ modkey, "Control" }, "space", function(c) c.floating = not c.floating end,
				{description = "toggle floating", group = "client"}),
			awful.key({ modkey, "Control" }, "Return", function(c) c:swap(awful.client.visible(c.screen)[1]) end,
				{description = "move to master", group = "client"}),
			awful.key({ modkey }, "o", function(c) c:move_to_screen() end,
				{description = "move to screen", group = "client"}),
			awful.key({ modkey, "Control" }, "t", function(c) c.ontop = not c.ontop end,
				{description = "toggle keep on top", group = "client"}),
			awful.key({ modkey }, "t", awful.titlebar.toggle,
				{ description = "Show/Hide Titlebars", group = "client" }),
			awful.key({ modkey }, "n", function(c)
				local anim = require("anim_client")
				anim.fade_minimize(c)
			end, {description = "minimize", group = "client"}),
			-- Maximize with pre-max memento (Bug 2 preservation) and no
			-- auto-raise (Bug 1: maximize is not an ontop request).
			-- If currently fullscreen, treat Super+M as "exit FS + unmax"
			-- since FS visually hides the maximized layer.
			awful.key({ modkey }, "m", function(c)
				if c.fullscreen then
					local saved = c._pre_fs_geom
					c.fullscreen = false
					c.maximized = false
					c.maximized_horizontal = false
					c.maximized_vertical = false
					if saved then
						c:geometry(saved)
						c._pre_fs_geom = nil
						c._pre_max_geom = nil
						c._pre_max_v_geom = nil
					end
				elseif c.maximized then
					local saved = c._pre_max_geom
					c.maximized = false
					if saved then
						c:geometry(saved)
						c._pre_max_geom = nil
					end
				else
					c._pre_max_geom = c:geometry()
					c.maximized = true
				end
			end, {description = "(un)maximize", group = "client"}),
			awful.key({ modkey, "Control" }, "m", function(c)
				if c.maximized_vertical then
					local saved = c._pre_max_v_geom
					c.maximized_vertical = false
					if saved then
						c:geometry(saved)
						c._pre_max_v_geom = nil
					end
				else
					c._pre_max_v_geom = c:geometry()
					c.maximized_vertical = true
				end
			end, {description = "(un)maximize vertically", group = "client"}),
		})
	end)
end

return M
