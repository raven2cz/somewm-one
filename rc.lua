--  _ __ __ ___   _____ _ __
-- | '__/ _` \ \ / / _ \ '_ \   Antonin Fischer (raven2cz)
-- | | | (_| |\ V /  __/ | | |  https://fishlive.org/
-- |_|  \__,_| \_/ \___|_| |_|  https://github.com/raven2cz/somewm
--
-- somewm-one — customized rc.lua for the somewm Wayland compositor.
-- Orchestration only: framework init, theme load, keybindings/menus/screen/rules
-- delegated to fishlive.config.*. See plans/project/somewm-one/ for the full tree.
--
-- awesome_mode: api-level=4:screen=on

pcall(require, "luarocks.loader")

-- Standard libraries
local gears = require("gears")
local awful = require("awful")
require("awful.autofocus")
local wibox = require("wibox")
local beautiful = require("beautiful")
local naughty = require("naughty")
local dpi = require("beautiful.xresources").apply_dpi
require("awful.hotkeys_popup.keys")
local machi = require("layout-machi")

-- Fishlive component framework
require("fishlive.services")

-- {{{ Error handling + log aggregation
local error_log_path = os.getenv("HOME") .. "/.local/log/somewm-errors.log"

local function log_error(title, message)
    local f = io.open(error_log_path, "a")
    if f then
        f:write(string.format("[%s] %s: %s\n", os.date("%Y-%m-%d %H:%M:%S"), title, message))
        f:close()
    end
end

naughty.connect_signal("request::display_error", function(message, startup)
    local title = "Oops, an error happened" .. (startup and " during startup!" or "!")
    log_error(title, message)
    naughty.notification {
        urgency = "critical",
        title   = title,
        message = message
    }
end)

if awesome.x11_fallback_info then
    gears.timer.delayed_call(function()
        local info = awesome.x11_fallback_info
        naughty.notification {
            urgency = "critical",
            title   = "Config contains X11 patterns - using fallback",
            message = string.format(
                "Your config was skipped because it contains X11-specific code.\n\n"
                .. "File: %s:%d\nPattern: %s\nCode: %s\n\nSuggestion: %s",
                info.config_path or "unknown", info.line_number or 0,
                info.pattern or "unknown", info.line_content or "",
                info.suggestion or "See somewm migration guide"
            ),
            timeout = 0
        }
    end)
end
-- }}}

-- {{{ Theme + init
local themes_service = require("fishlive.services.themes")
local themeName = themes_service.get_current()
beautiful.init(gears.filesystem.get_configuration_dir() .. "themes/" .. themeName .. "/theme.lua")

pcall(function() require("lockscreen").init() end)
pcall(function() require("fishlive.exit_screen").init() end)
-- }}}

-- {{{ User preferences
terminal = "ghostty"
editor = os.getenv("EDITOR") or "nvim"
editor_cmd = terminal .. " -e " .. editor
modkey = "Mod4"
altkey = "Mod1"

awesome._set_keyboard_setting("xkb_layout", "us,cz")
awesome._set_keyboard_setting("xkb_variant", ",qwerty")
awesome._set_keyboard_setting("xkb_options", "grp:alt_shift_toggle")
awesome._set_keyboard_setting("numlock", true)
-- }}}

-- {{{ Tag layouts
tag.connect_signal("request::default_layouts", function()
    awful.layout.append_default_layouts({
        awful.layout.suit.floating,
        awful.layout.suit.tile,
        machi.default_layout,
        awful.layout.suit.carousel,
        awful.layout.suit.carousel.vertical,
        awful.layout.suit.tile.left,
        awful.layout.suit.tile.bottom,
        awful.layout.suit.tile.top,
        awful.layout.suit.fair,
        awful.layout.suit.fair.horizontal,
        awful.layout.suit.spiral,
        awful.layout.suit.spiral.dwindle,
        awful.layout.suit.max,
        awful.layout.suit.max.fullscreen,
        awful.layout.suit.magnifier,
        awful.layout.suit.corner.nw,
    })
end)
-- }}}

-- {{{ Output configuration (monitor modes/scale/transform/position)
-- Two layouts auto-detected by which monitor is connected:
--   (A) HP U28 portrait + Dell G3223Q landscape   — code editing setup
--   (B) Samsung TV landscape + Dell G3223Q landscape — media setup
-- Dell is always primary at origin (0,0); first matching profile wins.
require("fishlive.config.output").setup({
    profiles = {
        -- Dell G3223Q: primary, 4K @ 144 Hz, landscape, origin
        { match = { name = "DP-3" },
          apply = { mode = { width = 3840, height = 2160, refresh = 143963 },
                    transform = "normal",
                    position  = { x = 0, y = 0 } } },
        { match = { make = "Dell", model = "G3223Q" },
          apply = { mode = { width = 3840, height = 2160, refresh = 143963 },
                    transform = "normal",
                    position  = { x = 0, y = 0 } } },

        -- HP U28 4K HDR: portrait left of Dell (transform 90 verified live).
        -- Native 3840x2160 → logical 2160x3840 after rotation.
        { match = { name = "DP-2" },
          apply = { mode = { width = 3840, height = 2160, refresh = 59997 },
                    transform = "90",
                    position  = { x = -2160, y = 0 } } },
        { match = { make = "HP", model = "HP U28" },
          apply = { mode = { width = 3840, height = 2160, refresh = 59997 },
                    transform = "90",
                    position  = { x = -2160, y = 0 } } },

        -- Samsung TV: landscape right of Dell
        { match = { make = "Samsung" },
          apply = { transform = "normal",
                    position  = { x = 3840, y = 0 } } },
    },
    laptop_scale = 1.5,
})
-- }}}

-- {{{ Menus
local menus = require("fishlive.config.menus").setup({
    terminal   = terminal,
    editor_cmd = editor_cmd,
})
-- }}}

-- {{{ Screen decoration (wibar, taglist, tasklist, wallpaper)
require("fishlive.config.screen").setup({
    modkey   = modkey,
    launcher = menus.launcher,
})
-- }}}

-- {{{ Keybindings
require("fishlive.config.keybindings").setup({
    modkey         = modkey,
    altkey         = altkey,
    terminal       = terminal,
    editor_cmd     = editor_cmd,
    start_menu     = menus.start_menu,
    desktop_menu   = menus.desktop_menu,
    portraits_menu = menus.portraits_menu,
})
-- }}}

-- {{{ Rules, client fixes, titlebars, notifications
-- ORDER MATTERS: rules.setup() must run first. titlebars/client_fixes
-- connect signals (request::titlebars, property::position/size) that
-- only fire for clients already classified by the rule engine.
require("fishlive.config.rules").setup()
require("fishlive.config.titlebars").setup()
require("fishlive.config.client_fixes").setup()
require("fishlive.components.notifications")
-- }}}

-- Master-Slave layout: new clients go to slave
client.connect_signal("manage", function(c)
    if not awesome.startup then c:to_secondary_section() end
end)

-- Sloppy focus (focus follows mouse)
client.connect_signal("mouse::enter", function(c)
    c:activate { context = "mouse_enter", raise = false }
end)

-- {{{ Autostart
local autostart = require("fishlive.autostart")

autostart.add{
    name = "nm-applet",
    cmd  = { "nm-applet" },
    mode = "respawn",
}

autostart.start_all()

awful.spawn.easy_async(os.getenv("HOME") .. "/git/github/somewm/plans/project/somewm-shell/theme-export.sh", function()
    awful.spawn.easy_async_with_shell(
        "pkill -f 'qs -c somewm' 2>/dev/null; "
        .. "rm -rf /run/user/$(id -u)/quickshell/by-id/* "
        .. "/run/user/$(id -u)/quickshell/by-pid/* "
        .. "/run/user/$(id -u)/quickshell/by-path/* "
        .. "~/.cache/quickshell/qmlcache 2>/dev/null; "
        .. "sleep 1",
        function() awful.spawn("qs -c somewm -n -d") end
    )
end)
-- }}}

-- {{{ Shell IPC (push state to QuickShell)
require("fishlive.config.shell_ipc").setup()
-- }}}

-- {{{ Animations
pcall(function()
    require("anim_client").enable({
        enabled = true,
        maximize     = { enabled = true,  duration = 0.25, easing = "ease-out-cubic" },
        fullscreen   = { enabled = true,  duration = 0.25, easing = "ease-out-cubic" },
        fade         = { enabled = true,  duration = 0.5,  easing = "ease-out-cubic" },
        minimize     = { enabled = true,  duration = 0.4,  easing = "ease-out-cubic" },
        layer        = { enabled = true,  duration = 0.2,  easing = "ease-out-cubic" },
        dialog       = { enabled = true,  duration = 0.2,  easing = "ease-out-cubic" },
        swap         = { enabled = true,  duration = 0.25, easing = "ease-out-cubic" },
        float        = { enabled = true,  duration = 0.3,  easing = "ease-out-cubic" },
        layout       = { enabled = true,  duration = 0.15, easing = "ease-out-cubic" },
        notification = { enabled = true,  duration = 0.5,  easing = "ease-out-cubic" },
        scenefx = {
            enabled       = true,
            corner_radius = 14,
            blur_enabled  = true,
            blur_opacity  = 0.75,
            blur_classes  = { "Alacritty", "ghostty", "kitty", "foot", "Rofi" },
            no_corners    = { "steam_app_*", "Wine", "Xwayland" },
        },
    })
end)

pcall(function()
    require("somewm.tag_slide").enable({
        duration  = 0.25,
        easing    = "ease-out-cubic",
        wallpaper = { enabled = true },
    })
end)
-- }}}
