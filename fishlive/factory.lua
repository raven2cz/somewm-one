---------------------------------------------------------------------------
--- Component factory — creates wibar widgets with theme fallback.
--
-- Two-level resolution:
--   1. themes/{theme_name}/components/{name}.lua  (themed override)
--   2. fishlive/components/{name}.lua             (standard)
--
-- Each component module must export: create(screen, config) -> widget
--
-- @module fishlive.factory
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local beautiful = require("beautiful")
local wibox = require("wibox")

local factory = {}

-- Resolved module cache (avoid repeated pcall/require)
local _cache = {}

--- Resolve a component module by name.
-- @tparam string name Component name (e.g. "cpu", "volume")
-- @treturn table|nil The component module, or nil
local function resolve(name)
	if _cache[name] then
		return _cache[name]
	end

	-- Level 1: themed override
	local theme_name = beautiful.theme_name or "default"
	local themed_path = "themes." .. theme_name .. ".components." .. name
	local ok, mod = pcall(require, themed_path)
	if ok and type(mod) == "table" and mod.create then
		_cache[name] = mod
		return mod
	end

	-- Level 2: standard component
	local standard_path = "fishlive.components." .. name
	ok, mod = pcall(require, standard_path)
	if ok and type(mod) == "table" and mod.create then
		_cache[name] = mod
		return mod
	end

	return nil
end

--- Create a component widget.
--
-- @tparam string name Component name (e.g. "cpu", "volume")
-- @param screen Screen object (optional, for DPI/geometry)
-- @tparam table config Extra configuration (optional)
-- @treturn widget The created wibox widget, or error placeholder
function factory.create(name, screen, config)
	local mod = resolve(name)

	if not mod then
		-- Return visible error widget instead of crashing
		local err = wibox.widget.textbox()
		err.markup = string.format(
			'<span color="#f38ba8">[%s?]</span>', name)
		io.stderr:write(string.format(
			"[factory] component not found: %s\n", name))
		return err
	end

	local ok, widget = pcall(mod.create, screen, config or {})
	if not ok then
		local err = wibox.widget.textbox()
		err.markup = string.format(
			'<span color="#f38ba8">[%s!]</span>', name)
		io.stderr:write(string.format(
			"[factory] component create error (%s): %s\n", name, widget))
		return err
	end

	return widget
end

--- Build a horizontal widget bar with auto-separators between components.
--
-- Replaces repetitive factory.create() + separator() sequences in rc.lua.
-- Components are resolved by name (same as factory.create). The special
-- name "systray" inserts wibox.widget.systray().
--
-- @tparam table screen Screen object (for DPI/geometry)
-- @tparam table names Array of component names (e.g. {"cpu", "volume", "clock"})
-- @treturn table Widget table suitable for wibox layout
function factory.widget_bar(screen, names)
	local sep = require("fishlive.widget_helper").separator
	local widgets = { layout = wibox.layout.fixed.horizontal }
	for i, name in ipairs(names) do
		if name == "systray" then
			widgets[#widgets + 1] = wibox.widget.systray()
		else
			widgets[#widgets + 1] = factory.create(name, screen)
		end
		if i < #names then
			local s = sep()
			local w = widgets[#widgets]
			-- A component that hides itself -- spotify, when nothing is
			-- playing -- would otherwise leave its separator floating on an
			-- empty stretch of bar. Mirror the component's visibility onto the
			-- separator. set_visible() emits widget::layout_changed rather
			-- than property::visible, so that is what we track; the mirror is
			-- idempotent, so the extra calls from unrelated layout changes
			-- cost nothing.
			if type(w) == "table" and w.connect_signal then
				s.visible = w.visible ~= false
				w:connect_signal("widget::layout_changed", function()
					s.visible = w.visible ~= false
				end)
			end
			widgets[#widgets + 1] = s
		end
	end
	return widgets
end

--- List all available component names (for debug/introspection).
-- @treturn table Array of component names
function factory.list()
	local names = {}
	for name in pairs(_cache) do
		names[#names + 1] = name
	end
	return names
end

--- Clear module cache (for testing or theme hot-reload).
function factory._reset()
	_cache = {}
end

return factory
