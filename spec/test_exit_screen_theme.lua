#!/usr/bin/env lua5.4
---------------------------------------------------------------------------
--- Standalone test for exit_screen theme rebuild functionality
--- Runs without busted (busted has broken deps on this system)
---------------------------------------------------------------------------

package.path = "./plans/project/somewm-one/?.lua;./plans/project/somewm-one/?/init.lua;" .. package.path

-- Track test results
local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  PASS: " .. name)
    else
        failed = failed + 1
        print("  FAIL: " .. name .. " — " .. tostring(err))
    end
end
local function assert_eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end
end
local function assert_true(v, msg)
    if not v then error((msg or "expected true"), 2) end
end

-- ==========================================================================
-- Stubs (same as exit_screen_spec.lua)
-- ==========================================================================

local beautiful_colors = {
    bg_normal = "#181818",
    fg_focus = "#d4d4d4",
    fg_urgent = "#e06c75",
    border_color_active = "#e2b55a",
}

package.preload["lgi"] = function()
    return {
        GLib = {
            PRIORITY_DEFAULT = 0,
            get_monotonic_time = function() return 0 end,
            timeout_add = function(_, _, cb) return 1 end,
        },
    }
end

package.preload["beautiful"] = function()
    return beautiful_colors
end

package.preload["beautiful.xresources"] = function()
    return { apply_dpi = function(v) return v end }
end

local widget_mt = {
    __index = {
        connect_signal = function() end,
        buttons = function() end,
        setup = function() end,
    },
}
local function make_widget(t)
    t = t or {}
    return setmetatable(t, widget_mt)
end

package.preload["wibox"] = function()
    local wibox_call_mt = {
        __call = function(_, t) return make_widget(t) end,
    }
    return setmetatable({
        widget = setmetatable({
            textbox = setmetatable({}, { __call = function(_, t) return make_widget(t) end }),
            textclock = setmetatable({}, { __call = function(_, t) return make_widget(t) end }),
            imagebox = setmetatable({}, { __call = function(_, t) return make_widget(t) end }),
        }, { __call = function(_, t) return make_widget(t) end }),
        container = {
            background = setmetatable({}, { __call = function(_, ...) return make_widget({}) end }),
            margin = setmetatable({}, { __call = function(_, ...) return make_widget({ left = 0, right = 0, top = 0, bottom = 0 }) end }),
            place = setmetatable({}, { __call = function(_, t) return make_widget(t) end }),
            constraint = setmetatable({}, { __call = function(_, t) return make_widget(t) end }),
        },
        layout = {
            fixed = { horizontal = { is_layout = true }, vertical = { is_layout = true } },
            stack = { is_layout = true },
        },
    }, wibox_call_mt)
end

-- Stub awesome global with signal tracking
local awesome_signals = {}
_G.awesome = {
    version = "v9999",
    api_level = 9999,
    connect_signal = function(name, fn)
        awesome_signals[name] = awesome_signals[name] or {}
        table.insert(awesome_signals[name], fn)
    end,
    disconnect_signal = function(name, fn)
        if awesome_signals[name] then
            for i, f in ipairs(awesome_signals[name]) do
                if f == fn then table.remove(awesome_signals[name], i); break end
            end
        end
    end,
    emit_signal = function(name, ...)
        if awesome_signals[name] then
            for _, fn in ipairs(awesome_signals[name]) do fn(...) end
        end
    end,
    restart = function() end,
    quit = function() end,
    lock = function() end,
}

_G.mouse = { current_wibox = nil }
_G.screen = setmetatable({ primary = { geometry = { x = 0, y = 0, width = 1920, height = 1080 } } }, {
    __index = function(_, k) if k == 1 then return _G.screen.primary end end,
})

package.preload["awful"] = function()
    return {
        keygrabber = function(t) return { start = function() end, stop = function() end } end,
        button = function() return {} end,
        screen = { focused = function() return _G.screen.primary end },
        spawn = { with_shell = function() end },
    }
end

package.preload["gears"] = function()
    return {
        shape = { rounded_rect = function() end },
        table = { join = function(...) return {} end },
        timer = { start_new = function(_, cb) cb() return true end },
        surface = { load_uncached_silently = function(path) return path and {} or nil end },
        filesystem = { get_configuration_dir = function() return "" end },
    }
end

-- Stub broker for data::theme signal
local broker_signals = {}
package.preload["fishlive.broker"] = function()
    return {
        connect_signal = function(name, fn)
            broker_signals[name] = broker_signals[name] or {}
            table.insert(broker_signals[name], fn)
        end,
        emit_signal = function(name, ...)
            if broker_signals[name] then
                for _, fn in ipairs(broker_signals[name]) do fn(...) end
            end
        end,
    }
end

-- ==========================================================================
-- Tests
-- ==========================================================================

print("\n=== Exit Screen Theme Rebuild Tests ===\n")

-- Fresh load
package.loaded["fishlive.exit_screen"] = nil
local es = require("fishlive.exit_screen")

test("init creates exit_wb", function()
    es._reset()
    awesome_signals = {}
    broker_signals = {}
    es._state._signals_connected = nil
    es.init()
    assert_true(es._state.initialized, "should be initialized")
    assert_true(es._state.exit_wb ~= nil, "exit_wb should exist")
    assert_true(es._state._signals_connected, "_signals_connected should be set")
end)

test("init caches config from beautiful", function()
    assert_eq(es._state.cfg.icon_color, "#e2b55a", "icon_color")
    assert_eq(es._state.cfg.fg_color, "#d4d4d4", "fg_color")
end)

test("data::theme signal handler is registered", function()
    assert_true(broker_signals["data::theme"] ~= nil, "data::theme handler exists")
    assert_true(#broker_signals["data::theme"] == 1, "exactly one handler")
end)

test("awesome signals registered exactly once", function()
    assert_true(awesome_signals["exit_screen::open"] ~= nil, "open registered")
    assert_true(awesome_signals["exit_screen::close"] ~= nil, "close registered")
    assert_true(awesome_signals["exit_screen::toggle"] ~= nil, "toggle registered")
    assert_eq(#awesome_signals["exit_screen::open"], 1, "one open handler")
    assert_eq(#awesome_signals["exit_screen::close"], 1, "one close handler")
    assert_eq(#awesome_signals["exit_screen::toggle"], 1, "one toggle handler")
end)

test("data::theme rebuilds with new colors", function()
    -- Change beautiful colors to simulate theme switch
    beautiful_colors.border_color_active = "#ff5555"  -- dracula red
    beautiful_colors.fg_focus = "#f8f8f2"  -- dracula fg
    beautiful_colors.bg_normal = "#282a36"  -- dracula bg

    -- Emit data::theme
    local broker = require("fishlive.broker")
    broker.emit_signal("data::theme")

    -- Verify rebuild happened
    assert_true(es._state.initialized, "should be re-initialized")
    assert_true(es._state.exit_wb ~= nil, "exit_wb should be recreated")
    assert_eq(es._state.cfg.icon_color, "#ff5555", "icon_color should be new")
    assert_eq(es._state.cfg.fg_color, "#f8f8f2", "fg_color should be new")
end)

test("no duplicate signal handlers after rebuild", function()
    -- After rebuild, should still have exactly 1 handler per signal
    assert_eq(#awesome_signals["exit_screen::open"], 1, "still one open handler")
    assert_eq(#awesome_signals["exit_screen::close"], 1, "still one close handler")
    assert_eq(#awesome_signals["exit_screen::toggle"], 1, "still one toggle handler")
    assert_eq(#broker_signals["data::theme"], 1, "still one theme handler")
end)

test("double init is idempotent", function()
    local wb1 = es._state.exit_wb
    es.init()  -- should be no-op (initialized=true)
    assert_true(es._state.exit_wb == wb1, "exit_wb unchanged after double init")
end)

-- Summary
print(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed > 0 and 1 or 0)
