---------------------------------------------------------------------------
--- GPU wibar widget — NVIDIA utilization and temperature.
--
-- Subscribes to broker signal `data::gpu` and renders icon + "NN% NN°C".
-- Data source is fishlive.services.gpu (NVML FFI, nvidia-smi fallback).
--
-- @module fishlive.components.gpu
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

--- Create the GPU widget for a screen.
-- @tparam screen screen The awful.screen the widget belongs to
-- @tparam ?table config Reserved (currently unused)
-- @treturn wibox.widget
function M.create(screen, config)
	local widget, update = wh.create_icon_text("widget_gpu_color", "#98c379")

	broker.connect_signal("data::gpu", function(data)
		update(data.icon, string.format("%3d%% %2d°C", data.usage, data.temp))
	end)

	return widget
end

return M
