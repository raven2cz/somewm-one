---------------------------
-- Tokyo Night theme      --
---------------------------

local theme_assets = require("beautiful.theme_assets")
local xresources = require("beautiful.xresources")
local rnotification = require("ruled.notification")
local dpi = xresources.apply_dpi

local gfs = require("gears.filesystem")
local themes_path = gfs.get_configuration_dir() .. "themes/"

local theme = {}

-- Fonts — same as default
theme.font          = "Geist 10"
theme.font_large    = "Geist 12"
theme.font_notify   = "CommitMono Nerd Font Propo 11"

-- Colors — Tokyo Night palette
local bg_base       = "#1a1b26"  -- Background
local bg_surface    = "#24283b"  -- Surface
local bg_overlay    = "#414868"  -- Surface bright
local fg_main       = "#c0caf5"  -- Foreground
local fg_dim        = "#a9b1d6"  -- Foreground dim
local fg_muted      = "#565f89"  -- Comment
local accent        = "#7aa2f7"  -- Blue
local accent_dim    = "#bb9af7"  -- Purple
local urgent        = "#f7768e"  -- Red
local green         = "#9ece6a"  -- Green
local marked        = "#ff9e64"  -- Orange

theme.bg_normal     = bg_base
theme.bg_focus      = bg_surface
theme.bg_urgent     = urgent
theme.bg_minimize   = bg_overlay
theme.bg_systray    = bg_base

theme.fg_normal     = fg_dim
theme.fg_focus      = fg_main
theme.fg_urgent     = bg_base
theme.fg_minimize   = fg_muted

-- Borders — blue accent
theme.useless_gap         = dpi(3)
theme.border_width        = dpi(1)
theme.border_color_normal = bg_base
theme.border_color_active = accent
theme.border_color_marked = marked

-- Wibar
theme.wibar_bg            = bg_base
theme.wibar_fg            = fg_dim
theme.wibar_height        = dpi(26)
theme.wibar_border_width  = 0
theme.wibar_border_color  = bg_base
theme.bg_systray          = bg_base
theme.systray_icon_spacing = dpi(4)

-- Drawin/wibar shadow
theme.shadow_drawin_enabled   = true
theme.shadow_drawin_radius    = 30
theme.shadow_drawin_offset_x  = 0
theme.shadow_drawin_offset_y  = 6
theme.shadow_drawin_opacity   = 0.5
theme.shadow_drawin_color     = "#000000"

-- Taglist
theme.taglist_font        = "Geist SemiBold 11"
theme.taglist_bg_focus    = accent
theme.taglist_fg_focus    = bg_base
theme.taglist_bg_urgent   = urgent
theme.taglist_fg_urgent   = bg_base
theme.taglist_bg_occupied = bg_surface
theme.taglist_fg_occupied = fg_dim
theme.taglist_bg_empty    = "transparent"
theme.taglist_fg_empty    = fg_muted

-- Tasklist
theme.tasklist_font       = "Geist 10"
theme.tasklist_bg_focus   = bg_surface
theme.tasklist_fg_focus   = fg_main
theme.tasklist_bg_normal  = "transparent"
theme.tasklist_fg_normal  = fg_muted

-- Lockscreen
theme.lockscreen_bg_color     = bg_base .. "ee"
theme.lockscreen_fg_color     = fg_main
theme.lockscreen_input_bg     = bg_surface
theme.lockscreen_border_color = accent
theme.lockscreen_error_color  = urgent
theme.lockscreen_font         = "Geist 14"
theme.lockscreen_font_large   = "Geist Bold 48"
theme.lockscreen_bg_image     = themes_path .. "default/wallpapers/1.jpg"

-- Exit screen
theme.exit_screen_bg          = bg_base .. "dd"
theme.exit_screen_fg          = fg_main
theme.exit_screen_icon        = accent
theme.exit_screen_icon_hover  = urgent
theme.exit_screen_bg_image    = themes_path .. "default/wallpapers/1.jpg"

-- Notifications
theme.notification_font          = "CommitMono Nerd Font Propo 14"
theme.notification_bg            = bg_base .. "ee"
theme.notification_fg            = fg_main
theme.notification_border_color  = accent_dim
theme.notification_border_width  = dpi(0)
theme.notification_margin        = dpi(16)
theme.notification_icon_size     = dpi(170)
theme.notification_max_width     = dpi(700)
theme.notification_spacing       = dpi(10)
theme.notification_icon_default  = themes_path .. "default/icons/notification.png"

-- Hotkeys popup
theme.hotkeys_font             = "Geist 11"
theme.hotkeys_description_font = "Geist 10"
theme.hotkeys_bg               = bg_base
theme.hotkeys_fg               = fg_main
theme.hotkeys_modifiers_fg     = accent
theme.hotkeys_border_color     = accent_dim
theme.hotkeys_border_width     = dpi(1)
theme.hotkeys_group_margin     = dpi(16)

-- Tooltip
theme.tooltip_font         = "Geist 10"
theme.tooltip_bg_color     = bg_surface
theme.tooltip_fg_color     = fg_main
theme.tooltip_border_color = accent_dim
theme.tooltip_border_width = dpi(1)

-- Menu
theme.menu_font         = "Geist 11"
theme.menu_bg_normal    = bg_base
theme.menu_bg_focus     = bg_surface
theme.menu_fg_normal    = fg_dim
theme.menu_fg_focus     = fg_main
theme.menu_border_color = accent_dim
theme.menu_border_width = dpi(1)
theme.menu_submenu_icon = themes_path.."default/submenu.png"
theme.menu_height = dpi(22)
theme.menu_width  = dpi(180)
theme.menu_radius       = dpi(8)
theme.menu_item_height  = dpi(28)
theme.menu_icon_font    = "Symbols Nerd Font Mono 14"

-- Generate taglist squares:
local taglist_square_size = dpi(4)
theme.taglist_squares_sel = theme_assets.taglist_squares_sel(
    taglist_square_size, theme.fg_normal
)
theme.taglist_squares_unsel = theme_assets.taglist_squares_unsel(
    taglist_square_size, theme.fg_normal
)

-- Titlebar buttons (shared from default theme)
theme.titlebar_close_button_normal = themes_path.."default/titlebar/close_normal.png"
theme.titlebar_close_button_focus  = themes_path.."default/titlebar/close_focus.png"
theme.titlebar_minimize_button_normal = themes_path.."default/titlebar/minimize_normal.png"
theme.titlebar_minimize_button_focus  = themes_path.."default/titlebar/minimize_focus.png"
theme.titlebar_ontop_button_normal_inactive = themes_path.."default/titlebar/ontop_normal_inactive.png"
theme.titlebar_ontop_button_focus_inactive  = themes_path.."default/titlebar/ontop_focus_inactive.png"
theme.titlebar_ontop_button_normal_active = themes_path.."default/titlebar/ontop_normal_active.png"
theme.titlebar_ontop_button_focus_active  = themes_path.."default/titlebar/ontop_focus_active.png"
theme.titlebar_sticky_button_normal_inactive = themes_path.."default/titlebar/sticky_normal_inactive.png"
theme.titlebar_sticky_button_focus_inactive  = themes_path.."default/titlebar/sticky_focus_inactive.png"
theme.titlebar_sticky_button_normal_active = themes_path.."default/titlebar/sticky_normal_active.png"
theme.titlebar_sticky_button_focus_active  = themes_path.."default/titlebar/sticky_focus_active.png"
theme.titlebar_floating_button_normal_inactive = themes_path.."default/titlebar/floating_normal_inactive.png"
theme.titlebar_floating_button_focus_inactive  = themes_path.."default/titlebar/floating_focus_inactive.png"
theme.titlebar_floating_button_normal_active = themes_path.."default/titlebar/floating_normal_active.png"
theme.titlebar_floating_button_focus_active  = themes_path.."default/titlebar/floating_focus_active.png"
theme.titlebar_maximized_button_normal_inactive = themes_path.."default/titlebar/maximized_normal_inactive.png"
theme.titlebar_maximized_button_focus_inactive  = themes_path.."default/titlebar/maximized_focus_inactive.png"
theme.titlebar_maximized_button_normal_active = themes_path.."default/titlebar/maximized_normal_active.png"
theme.titlebar_maximized_button_focus_active  = themes_path.."default/titlebar/maximized_focus_active.png"

theme.wallpaper = themes_path.."default/wallpapers/1.jpg"

-- Layout icons (shared from default theme)
theme.layout_fairh = themes_path.."default/layouts/fairhw.png"
theme.layout_fairv = themes_path.."default/layouts/fairvw.png"
theme.layout_floating  = themes_path.."default/layouts/floatingw.png"
theme.layout_magnifier = themes_path.."default/layouts/magnifierw.png"
theme.layout_max = themes_path.."default/layouts/maxw.png"
theme.layout_fullscreen = themes_path.."default/layouts/fullscreenw.png"
theme.layout_tilebottom = themes_path.."default/layouts/tilebottomw.png"
theme.layout_tileleft   = themes_path.."default/layouts/tileleftw.png"
theme.layout_tile = themes_path.."default/layouts/tilew.png"
theme.layout_tiletop = themes_path.."default/layouts/tiletopw.png"
theme.layout_spiral  = themes_path.."default/layouts/spiralw.png"
theme.layout_dwindle = themes_path.."default/layouts/dwindlew.png"
theme.layout_cornernw = themes_path.."default/layouts/cornernww.png"
theme.layout_cornerne = themes_path.."default/layouts/cornernew.png"
theme.layout_cornersw = themes_path.."default/layouts/cornersww.png"
theme.layout_cornerse = themes_path.."default/layouts/cornersew.png"

-- Widget component colors (Tokyo Night palette)
theme.theme_name              = "tokyo-night"
theme.widget_spacing          = dpi(6)
theme.widget_font             = "Geist 10"
theme.widget_cpu_color        = "#7dcfff"  -- Cyan
theme.widget_gpu_color        = green      -- #9ece6a Green
theme.widget_memory_color     = "#bb9af7"  -- Purple
theme.widget_disk_color       = "#e0af68"  -- Yellow
theme.widget_network_color    = "#2ac3de"  -- Teal
theme.widget_volume_color     = "#f7768e"  -- Red
theme.widget_updates_color    = "#ff9e64"  -- Orange
theme.widget_keyboard_color   = "#7dcfff"  -- Cyan
theme.widget_clock_color      = accent     -- #7aa2f7 Blue
theme.terminal                = "ghostty"

-- Shadow configuration
theme.shadow_enabled    = true
theme.shadow_radius     = 30
theme.shadow_offset_x   = 5
theme.shadow_offset_y   = 5
theme.shadow_opacity    = 0.65
theme.shadow_color      = "#000000"
theme.shadow_clip       = "directional"

-- Generate Awesome icon:
theme.awesome_icon = theme_assets.awesome_icon(
    theme.menu_height, theme.bg_focus, theme.fg_focus
)

-- Icon theme for application icons
theme.icon_theme = "Papirus-Dark"

return theme
