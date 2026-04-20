---------------------------------------------------------------------------
--- Output configuration — per-monitor modes, scale, transform, position.
--
-- Wires an `output.connect_signal("added", ...)` handler that applies the
-- first matching profile from a user-supplied list to each new output. A
-- profile's `match` can key on `o.name`, `o.make`, or `o.model` (or any
-- combination, all keys must match). The `apply` block sets any of `mode`,
-- `scale`, `transform`, `position` — only fields present are written.
--
-- Typical usage from rc.lua:
--   require("fishlive.config.output").setup({
--       profiles = {
--           { match = { name = "DP-3" },
--             apply = { mode = { width=3840, height=2160, refresh=143963 },
--                       transform = "normal",
--                       position  = { x = 0, y = 0 } } },
--           { match = { make = "HP", model = "HP U28" },
--             apply = { transform = "90",
--                       position  = { x = -2160, y = 0 } } },
--       },
--       laptop_scale = 1.5,   -- applied to any output whose name starts eDP
--   })
--
-- @module fishlive.config.output
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local M = { _initialized = false }

-- True iff every non-nil key in `match` compares equal (string match) to the
-- corresponding field on `o`. Absent keys on `match` are ignored.
local function profile_matches(match, o)
	if match.name  and o.name  ~= match.name  then return false end
	if match.make  and not (o.make  and o.make:match(match.make))   then return false end
	if match.model and not (o.model and o.model:match(match.model)) then return false end
	return match.name or match.make or match.model
end

local function apply_profile(o, apply)
	if apply.mode      then o.mode      = apply.mode      end
	if apply.transform then o.transform = apply.transform end
	if apply.position  then o.position  = apply.position  end
	if apply.scale     then o.scale     = apply.scale     end
end

--- Install the output.added handler.
-- @tparam table args
-- @tparam[opt={}] table args.profiles List of { match = {...}, apply = {...} }
-- @tparam[opt] number args.laptop_scale Scale applied to any eDP* output
function M.setup(args)
	if M._initialized then return end
	M._initialized = true

	args = args or {}
	local profiles     = args.profiles or {}
	local laptop_scale = args.laptop_scale

	if not _G.output then return end

	_G.output.connect_signal("added", function(o)
		for _, profile in ipairs(profiles) do
			if profile.match and profile.apply and profile_matches(profile.match, o) then
				apply_profile(o, profile.apply)
				break
			end
		end
		if laptop_scale and o.name and o.name:match("^eDP") then
			o.scale = laptop_scale
		end
	end)
end

return M
