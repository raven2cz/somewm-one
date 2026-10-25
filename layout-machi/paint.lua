-- Paint at output resolution, retaining the surface between editor keys.
local cairo = require("lgi").cairo
local wibox = require("wibox")
local buffers = setmetatable({}, { __mode = "k" })

return function(wb, draw)
	local geo = wb:geometry()
	local scale = wb.screen and wb.screen.scale or 1
	local w, h = math.max(1, math.ceil(geo.width * scale)), math.max(1, math.ceil(geo.height * scale))
	local buffer = buffers[wb]
	if not buffer or buffer.w ~= w or buffer.h ~= h then
		buffer = { w = w, h = h, surface = cairo.ImageSurface.create(cairo.Format.ARGB32, w, h) }
		buffers[wb] = buffer
	end
	local cr = cairo.Context.create(buffer.surface)
	cr:set_operator(cairo.Operator.CLEAR)
	cr:paint()
	cr:set_operator(cairo.Operator.OVER)
	cr:scale(scale, scale)
	draw(nil, cr, geo.width, geo.height)
	buffer.surface:flush()
	-- bgimage is drawn at natural size; imagebox maps device pixels back
	-- into the logical workarea without cropping on scaled outputs.
	-- A new widget identity also invalidates the renderer's image raster.
	wb.widget = {
		image = buffer.surface,
		forced_width = geo.width,
		forced_height = geo.height,
		upscale = true,
		downscale = true,
		widget = wibox.widget.imagebox,
	}
end
