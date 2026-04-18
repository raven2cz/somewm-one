---------------------------------------------------------------------------
--- Service registry — explicit list, loaded before factory.
--
-- Each service self-registers with fishlive.broker on require; requiring this
-- module is the one-line boot step in rc.lua that brings the whole producer
-- layer online before any widget is constructed.
--
-- @module fishlive.services
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

require("fishlive.services.cpu")
require("fishlive.services.memory")
require("fishlive.services.gpu")
require("fishlive.services.disk")
require("fishlive.services.network")
require("fishlive.services.volume")
require("fishlive.services.updates")
require("fishlive.services.keyboard")
require("fishlive.services.wallpaper")
require("fishlive.services.themes")
require("fishlive.services.portraits")
