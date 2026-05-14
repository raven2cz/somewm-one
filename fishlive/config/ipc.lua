---------------------------------------------------------------------------
--- Custom IPC commands — expose Lua to `somewm-client run <name>`.
--
-- ipc.register(name, handler) makes a command callable from the CLI:
--   somewm-client <name> [args...]
-- The handler receives the CLI args as varargs and returns nil (success)
-- or a result string. Errors are raised with error().
--
-- NOTE: require("awful.ipc") directly — `awful/init.lua` does not export
-- `ipc`, so `awful.ipc` is nil during config load.
--
-- This module is a scaffold: one working example (`focused-tag`) plus the
-- pattern for adding more. Wire from rc.lua:
--   require("fishlive.config.ipc").setup()
--
-- @module fishlive.config.ipc
-- @author Antonin Fischer (raven2cz)
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local awful = require("awful")
local ipc   = require("awful.ipc")

local M = { _initialized = false }

function M.setup()
	if M._initialized then return end
	M._initialized = true

	-- Example: `somewm-client run focused-tag` -> prints the focused tag name.
	ipc.register("focused-tag", function()
		local s = awful.screen.focused()
		local t = s and s.selected_tag
		return t and t.name or ""
	end)

	-- Add more commands here, e.g.:
	--   ipc.register("client-count", function()
	--       return tostring(#client.get())
	--   end)
	--   ipc.register("view-tag", function(name)
	--       local s = awful.screen.focused()
	--       for _, t in ipairs(s and s.tags or {}) do
	--           if t.name == name then t:view_only() return end
	--       end
	--       error("no tag named " .. tostring(name))
	--   end)
end

return M
