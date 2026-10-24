-- somewm 2.x no longer calls a function assigned to wibox.bgimage: widgets
-- and backgrounds are declared to Clay, and only paths and surfaces are
-- drawn. This renders such a draw function into an image surface of the
-- wibox's size once and hands the surface over instead.
local lgi = require("lgi")
local cairo = lgi.cairo

return function(wb, draw)
    local geo = wb:geometry()
    local w, h = math.max(1, math.ceil(geo.width)), math.max(1, math.ceil(geo.height))
    local surface = cairo.ImageSurface.create(cairo.Format.ARGB32, w, h)
    local cr = cairo.Context.create(surface)
    draw(nil, cr, w, h)
    surface:flush()
    wb.bgimage = surface
end
