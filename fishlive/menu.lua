---------------------------------------------------------------------------
--- Popup menu — general-purpose popup menu with hover, keyboard nav,
-- click-outside-to-close, and single-instance control.
--
-- Usage:
--   local menu = require("fishlive.menu")
--   local m = menu.new({
--       items = {
--           { icon = "󰆍", label = "Terminal", on_activate = function() ... end },
--           { separator = true },
--           { icon = "󰗼", label = "Quit", on_activate = awesome.quit },
--       },
--       close_on = "escape",   -- "escape" | "mouse_leave"
--       placement = "under_mouse",
--       width = dpi(200),
--   })
--   m:toggle()
--
-- @module fishlive.menu
---------------------------------------------------------------------------

local awful     = require("awful")
local gears     = require("gears")
local wibox     = require("wibox")
local beautiful = require("beautiful")
local dpi       = require("beautiful.xresources").apply_dpi
local broker_ok, broker = pcall(require, "fishlive.broker")

-- Escape XML special chars in labels for safe Pango markup
local xml_escape = gears.string.xml_escape

--- Safely append hex alpha suffix to a color string.
-- Only appends if the color is a 7-char hex (#RRGGBB).
local function color_alpha(color, alpha)
	if type(color) == "string" and #color == 7 and color:sub(1,1) == "#" then
		return color .. alpha
	end
	return color
end

---------------------------------------------------------------------------
-- Module state
---------------------------------------------------------------------------

local Menu = {}
Menu.__index = Menu

--- Currently visible menu (only one at a time).
local _active_menu = nil

---------------------------------------------------------------------------
-- Color helpers
---------------------------------------------------------------------------

local function colors()
	return {
		bg        = beautiful.menu_bg_normal    or "#181818",
		bg_focus  = beautiful.menu_bg_focus     or "#232323",
		fg        = beautiful.menu_fg_normal    or "#888888",
		fg_focus  = beautiful.menu_fg_focus     or "#d4d4d4",
		border    = beautiful.menu_border_color or "#c49a3a",
		accent    = beautiful.border_color_active or "#e2b55a",
		separator = beautiful.fg_minimize       or "#555555",
		radius    = beautiful.menu_radius       or dpi(8),
		icon_font = beautiful.menu_icon_font    or "Symbols Nerd Font Mono 14",
		label_font = beautiful.menu_font        or beautiful.font or "Geist 11",
	}
end

---------------------------------------------------------------------------
-- Markup helpers (xml-safe)
---------------------------------------------------------------------------

local function label_markup(font, color, text)
	return string.format('<span font="%s" foreground="%s">%s</span>',
		font, color, xml_escape(text or ""))
end

local function icon_markup(font, color, icon)
	return string.format('<span font="%s" foreground="%s">%s</span>',
		font, color, icon or "")
end

---------------------------------------------------------------------------
-- Item widget builders
---------------------------------------------------------------------------

local function make_separator(c)
	return wibox.widget {
		{
			forced_height = dpi(1),
			bg = color_alpha(c.separator, "60"),
			widget = wibox.container.background,
		},
		top = dpi(4),
		bottom = dpi(4),
		left = dpi(12),
		right = dpi(12),
		widget = wibox.container.margin,
	}
end

local function make_item_widget(item, index, menu_inst)
	local c = colors()

	-- Icon widget
	local icon_widget
	if item.icon_image then
		icon_widget = wibox.widget {
			image = item.icon_image,
			forced_width = dpi(18),
			forced_height = dpi(18),
			widget = wibox.widget.imagebox,
		}
	else
		icon_widget = wibox.widget {
			markup = icon_markup(c.icon_font, c.accent, item.icon),
			forced_width = dpi(24),
			halign = "center",
			widget = wibox.widget.textbox,
		}
	end

	-- Label widget
	local label_widget = wibox.widget {
		markup = label_markup(c.label_font, c.fg, item.label),
		widget = wibox.widget.textbox,
	}

	-- Row layout
	local row = wibox.widget {
		icon_widget,
		label_widget,
		spacing = dpi(10),
		layout = wibox.layout.fixed.horizontal,
	}

	-- Background container with rounded inner shape
	local is_checked = item.checked or (item.checked_fn and item.checked_fn())
	local bg_widget = wibox.widget {
		{
			row,
			left = dpi(12),
			right = dpi(12),
			top = dpi(7),
			bottom = dpi(7),
			widget = wibox.container.margin,
		},
		bg = is_checked and (color_alpha(c.accent, "25")) or "transparent",
		shape = function(cr, w, h)
			gears.shape.rounded_rect(cr, w, h, dpi(6))
		end,
		widget = wibox.container.background,
	}

	-- Hover signals
	bg_widget:connect_signal("mouse::enter", function()
		menu_inst._focused_index = index
		menu_inst:_update_highlights()
		local w = _G.mouse.current_wibox
		if w then w.cursor = "hand2" end
	end)

	bg_widget:connect_signal("mouse::leave", function()
		if menu_inst._focused_index == index then
			menu_inst._focused_index = 0
			menu_inst:_update_highlights()
		end
		local w = _G.mouse.current_wibox
		if w then w.cursor = "left_ptr" end
	end)

	-- Click
	bg_widget:buttons(gears.table.join(
		awful.button({}, 1, function()
			if item.on_activate then
				menu_inst:hide()
				item.on_activate()
			end
		end)
	))

	return {
		widget = bg_widget,
		icon = icon_widget,
		label = label_widget,
		item = item,
		index = index,
		is_separator = false,
	}
end

---------------------------------------------------------------------------
-- Menu methods
---------------------------------------------------------------------------

function Menu:_update_highlights()
	local c = colors()
	for _, row in ipairs(self._rows) do
		if row.is_separator then goto continue end
		local is_checked = row.item.checked
			or (row.item.checked_fn and row.item.checked_fn())
		if row.index == self._focused_index then
			row.widget.bg = c.bg_focus
			row.label.markup = label_markup(c.label_font, c.fg_focus, row.item.label)
			if not row.item.icon_image and row.item.icon then
				row.icon.markup = icon_markup(c.icon_font, c.fg_focus, row.item.icon)
			end
		elseif is_checked then
			row.widget.bg = color_alpha(c.accent, "25")
			row.label.markup = label_markup(c.label_font, c.fg_focus, row.item.label)
			if not row.item.icon_image and row.item.icon then
				row.icon.markup = icon_markup(c.icon_font, c.accent, row.item.icon)
			end
		else
			row.widget.bg = "transparent"
			row.label.markup = label_markup(c.label_font, c.fg, row.item.label)
			if not row.item.icon_image and row.item.icon then
				row.icon.markup = icon_markup(c.icon_font, c.accent, row.item.icon)
			end
		end
		::continue::
	end
end

function Menu:_resolve_items()
	if self._args.items_source then
		return self._args.items_source()
	end
	return self._args.items or {}
end

function Menu:_rebuild()
	local c = colors()
	local layout = self._layout
	layout:reset()
	self._rows = {}

	local items = self:_resolve_items()
	local nav_index = 0
	for _, item in ipairs(items) do
		if item.separator then
			local sep = make_separator(c)
			layout:add(sep)
			self._rows[#self._rows + 1] = {
				widget = sep, is_separator = true, index = -1,
			}
		else
			nav_index = nav_index + 1
			local row = make_item_widget(item, nav_index, self)
			layout:add(row.widget)
			self._rows[#self._rows + 1] = row
		end
	end
end

function Menu:_ensure_popup()
	if self._popup then return end
	local c = colors()

	self._layout = wibox.layout.fixed.vertical()
	self._layout.spacing = dpi(2)

	self._popup = awful.popup {
		widget = {
			self._layout,
			margins = dpi(6),
			widget = wibox.container.margin,
		},
		bg = color_alpha(c.bg, "f0"),
		border_color = color_alpha(c.border, "80"),
		border_width = dpi(1),
		shape = function(cr, w, h)
			gears.shape.rounded_rect(cr, w, h, c.radius)
		end,
		ontop = true,
		visible = false,
		maximum_width = self._args.width or dpi(220),
	}
end

function Menu:_start_grabber()
	if self._grabber then return end
	local self_ref = self
	self._grabber = awful.keygrabber {
		autostart = true,
		stop_key = nil,
		mask_modkeys = true,
		keypressed_callback = function(_, _, key)
			if key == "Escape" then
				self_ref:hide()
			elseif key == "Up" or key == "k" then
				self_ref:_focus_prev()
			elseif key == "Down" or key == "j" then
				self_ref:_focus_next()
			elseif key == "Return" or key == "KP_Enter" then
				self_ref:_activate_focused()
			end
		end,
	}
end

function Menu:_stop_grabber()
	if self._grabber then
		self._grabber:stop()
		self._grabber = nil
	end
end

function Menu:_focus_next()
	local nav_rows = {}
	for _, row in ipairs(self._rows) do
		if not row.is_separator then nav_rows[#nav_rows + 1] = row end
	end
	if #nav_rows == 0 then return end

	local next_idx = self._focused_index + 1
	if next_idx > #nav_rows then next_idx = 1 end
	self._focused_index = next_idx
	self:_update_highlights()
end

function Menu:_focus_prev()
	local nav_rows = {}
	for _, row in ipairs(self._rows) do
		if not row.is_separator then nav_rows[#nav_rows + 1] = row end
	end
	if #nav_rows == 0 then return end

	local prev_idx = self._focused_index - 1
	if prev_idx < 1 then prev_idx = #nav_rows end
	self._focused_index = prev_idx
	self:_update_highlights()
end

function Menu:_activate_focused()
	if self._focused_index <= 0 then return end
	for _, row in ipairs(self._rows) do
		if not row.is_separator and row.index == self._focused_index then
			if row.item.on_activate then
				self:hide()
				row.item.on_activate()
			end
			return
		end
	end
end

--- Start click-outside detection using root button binding.
-- Only intercept button 1 (left-click). Button 3 (right-click) is left
-- to the permanent desktop_menu binding in rc.lua to avoid both firing.
function Menu:_start_click_outside()
	if self._root_btn then return end
	local self_ref = self
	self._root_btn = awful.button({}, 1, function()
		self_ref:hide()
	end)
	awful.mouse.append_global_mousebinding(self._root_btn)
end

function Menu:_stop_click_outside()
	if self._root_btn then
		awful.mouse.remove_global_mousebinding(self._root_btn)
		self._root_btn = nil
	end
end

function Menu:_apply_theme()
	if not self._popup then return end
	local c = colors()
	self._popup.bg = color_alpha(c.bg, "f0")
	self._popup.border_color = color_alpha(c.border, "80")
	self._popup.shape = function(cr, w, h)
		gears.shape.rounded_rect(cr, w, h, c.radius)
	end
end

--- Show the menu, positioned relative to an optional anchor widget.
function Menu:show(anchor)
	-- Single-instance: close any other active menu
	if _active_menu and _active_menu ~= self then
		_active_menu:hide()
	end
	_active_menu = self

	self:_ensure_popup()
	self:_rebuild()
	self._focused_index = 0

	-- Position and show
	local placement = self._args.placement or "under_mouse"
	self._popup.visible = true

	-- Force geometry computation before placement so no_offscreen
	-- knows the real width/height (fixes first-show going off-screen)
	if self._popup._apply_size_now then
		self._popup:_apply_size_now(false)
	end

	if placement == "under_mouse" then
		awful.placement.under_mouse(self._popup)
		awful.placement.no_offscreen(self._popup, {
			margins = dpi(8),
		})
	elseif type(placement) == "function" then
		placement(self._popup, anchor)
	end

	-- Setup close mechanism
	local close_on = self._args.close_on or "escape"
	if close_on == "mouse_leave" then
		-- Debounce mouse_leave to avoid spurious closes when the cursor
		-- briefly crosses inter-item gaps or the popup border
		self._mouse_leave_fn = function()
			if self._ml_timer then self._ml_timer:stop() end
			self._ml_timer = gears.timer.start_new(0.08, function()
				self._ml_timer = nil
				if self._popup and self._popup.visible then
					self:hide()
				end
				return false
			end)
		end
		self._mouse_enter_fn = function()
			if self._ml_timer then
				self._ml_timer:stop()
				self._ml_timer = nil
			end
		end
		self._popup:connect_signal("mouse::leave", self._mouse_leave_fn)
		self._popup:connect_signal("mouse::enter", self._mouse_enter_fn)
	elseif close_on == "escape" then
		self:_start_grabber()
		self:_start_click_outside()
	end
end

--- Hide the menu.
function Menu:hide()
	if not self._popup then return end

	self._popup.visible = false

	-- Debounce: prevent toggle() from re-opening immediately
	-- Only needed for "escape" mode (launcher press/release race)
	local close_on = self._args.close_on or "escape"
	if close_on == "escape" then
		self._just_closed = true
		gears.timer.start_new(0.15, function()
			self._just_closed = false
			return false
		end)
	end

	if _active_menu == self then _active_menu = nil end

	self:_stop_grabber()
	self:_stop_click_outside()

	-- Cancel pending mouse-leave timer
	if self._ml_timer then
		self._ml_timer:stop()
		self._ml_timer = nil
	end

	if self._mouse_leave_fn then
		self._popup:disconnect_signal("mouse::leave", self._mouse_leave_fn)
		self._mouse_leave_fn = nil
	end
	if self._mouse_enter_fn then
		self._popup:disconnect_signal("mouse::enter", self._mouse_enter_fn)
		self._mouse_enter_fn = nil
	end

	-- Reset cursor
	local w = _G.mouse.current_wibox
	if w then w.cursor = "left_ptr" end
end

--- Toggle menu visibility.
function Menu:toggle(anchor)
	if self._popup and self._popup.visible then
		self:hide()
	else
		-- Don't re-open if just closed (press/release race)
		if self._just_closed then return end
		self:show(anchor)
	end
end

---------------------------------------------------------------------------
-- Constructor
---------------------------------------------------------------------------

local M = {}

--- Create a new popup menu.
function M.new(args)
	local self = setmetatable({}, Menu)
	self._args = args or {}
	self._popup = nil
	self._layout = nil
	self._grabber = nil
	self._root_btn = nil
	self._mouse_leave_fn = nil
	self._mouse_enter_fn = nil
	self._ml_timer = nil
	self._just_closed = false
	self._focused_index = 0
	self._rows = {}

	-- Theme reactivity
	if broker_ok then
		self._theme_fn = function()
			self:_apply_theme()
			if self._popup and self._popup.visible then
				self:_rebuild()
			end
		end
		broker.connect_signal("data::theme", self._theme_fn)
	end

	return self
end

--- Destroy the menu, disconnecting all signals.
-- Call this when the menu is no longer needed (e.g. screen removal).
function Menu:destroy()
	self:hide()
	if broker_ok and self._theme_fn then
		broker.disconnect_signal("data::theme", self._theme_fn)
		self._theme_fn = nil
	end
	self._popup = nil
	self._layout = nil
	self._rows = {}
end

--- Close whatever menu is currently active (if any).
function M.close_active()
	if _active_menu then _active_menu:hide() end
end

return M
