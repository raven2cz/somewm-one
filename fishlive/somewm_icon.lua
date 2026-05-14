---------------------------------------------------------------------------
--- somewm "S" launcher icon.
--
-- Draws the blocky "S" wordmark letter (the somewm logo, replacing
-- AwesomeWM's "a") as a cairo ImageSurface for use as beautiful.awesome_icon.
-- Theme-aware: reads beautiful.* at generate() time, so it picks up the
-- active theme's colors. Call after beautiful.init().
--
-- Usage from rc.lua:
--   beautiful.awesome_icon = require("fishlive.somewm_icon").generate()
--
-- Ported from upstream somewmrc.lua. The "s" is letter 3 in the "awesome"
-- wordmark of beautiful.theme_assets.gen_awesome_name: a square filled with
-- `fg`, with two thin horizontal cuts in `bg` at y=1/3 (right two-thirds)
-- and y=2/3 (left two-thirds).
--
-- @module fishlive.somewm_icon
-- @author Antonin Fischer (raven2cz)
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local cairo     = require("lgi").cairo
local gears     = require("gears")
local beautiful = require("beautiful")

local M = {}

--- Generate the "S" icon as a cairo ImageSurface.
-- @treturn cairo.ImageSurface
function M.generate()
    local size = math.floor(beautiful.menu_height or 16)
    local fg   = beautiful.wallpaper_logo_color or beautiful.fg_focus or "#ffffff"
    local bg   = beautiful.wibar_bg or beautiful.bg_normal

    local img = cairo.ImageSurface(cairo.Format.ARGB32, size, size)
    local cr  = cairo.Context(img)
    cr:set_line_width(size / 18)

    cr:set_source(gears.color(fg))
    cr:rectangle(0, 0, size, size)
    cr:fill()

    if bg then
        cr:set_source(gears.color(bg))
    else
        cr:set_operator(cairo.Operator.CLEAR)
    end
    cr:move_to(size / 3, size / 3); cr:rel_line_to(size * 2 / 3, 0); cr:stroke()
    cr:move_to(0, size * 2 / 3);    cr:rel_line_to(size * 2 / 3, 0); cr:stroke()
    cr:set_operator(cairo.Operator.OVER)

    return img
end

return M
