---------------------------------------------------------------------------
--- Tests for fishlive.services.spotify
--
-- The parser is the whole risk surface of this service: everything else is
-- the shared service base, already covered by service_spec. It has to be
-- total -- a "not running" result is a real state the widget needs in order
-- to hide itself, so returning nil (which the service base treats as "no
-- change") would leave a stale track on the bar forever.
---------------------------------------------------------------------------

package.path = "./?.lua;" .. package.path

-- The module registers a producer on require, so stub the two collaborators
-- it reaches for. Neither is exercised here; only the parser is.
package.preload["fishlive.broker"] = function()
	return { register_producer = function() end }
end
package.preload["fishlive.service"] = function()
	return { new = function(opts) return opts end }
end

local spotify = require("fishlive.services.spotify")

local SEP = "@|@"
local function line(status, artist, title, album)
	return table.concat({ status, artist, title, album }, SEP) .. "\n"
end

describe("spotify service", function()

	describe("parse", function()
		it("reads a playing track", function()
			local d = spotify.parse(line("Playing", "Röyksopp", "Eple", "Melody A.M."))
			assert.is_true(d.running)
			assert.is_true(d.playing)
			assert.are.equal("Röyksopp", d.artist)
			assert.are.equal("Eple", d.title)
			assert.are.equal("Melody A.M.", d.album)
			assert.are.equal("󰐊", d.icon)
		end)

		it("reads a paused track and switches the icon", function()
			local d = spotify.parse(line("Paused", "Air", "La Femme d'Argent", "Moon Safari"))
			assert.is_true(d.running)
			assert.is_false(d.playing)
			assert.are.equal("󰏤", d.icon)
		end)

		it("reports not running for empty output", function()
			-- nil listed separately: ipairs would stop at it and quietly skip
			-- every case after it.
			for _, out in ipairs({ "", "\n", "   \n" }) do
				local d = spotify.parse(out)
				assert.is_false(d.running)
				assert.are.equal("", d.title)
			end
			assert.is_false(spotify.parse(nil).running)
		end)

		it("never returns nil, whatever it is handed", function()
			-- nil would mean "no change" to the service base and the widget
			-- would keep showing a track that stopped playing.
			for _, out in ipairs({ "garbage", "a@|@b", "No players found\n", "\n\n" }) do
				assert.is_not_nil(spotify.parse(out))
			end
			assert.is_not_nil(spotify.parse(nil))
		end)

		it("reports not running when the field count is wrong", function()
			assert.is_false(spotify.parse("Playing@|@only@|@three").running)
			assert.is_false(spotify.parse("Playing@|@a@|@b@|@c@|@d").running)
		end)

		it("reports not running when artist and title are both empty", function()
			assert.is_false(spotify.parse(line("Playing", "", "", "")).running)
		end)

		it("keeps a track that has an artist but no title", function()
			local d = spotify.parse(line("Playing", "Some Podcast", "", ""))
			assert.is_true(d.running)
			assert.are.equal("Some Podcast", d.artist)
		end)

		it("takes only the first line", function()
			local d = spotify.parse(line("Playing", "A", "B", "C")
				.. line("Paused", "X", "Y", "Z"))
			assert.are.equal("A", d.artist)
			assert.is_true(d.playing)
		end)

		it("preserves separators-adjacent text and empty middle fields", function()
			local d = spotify.parse(line("Playing", "A", "", "C"))
			assert.are.equal("A", d.artist)
			assert.are.equal("", d.title)
			assert.are.equal("C", d.album)
		end)

		it("passes through markup that playerctl already escaped", function()
			-- playerctl's markup_escape does this upstream; the parser must not
			-- unescape or double-escape it.
			local d = spotify.parse(line("Playing", "AC&amp;DC", "T.N.T.", "High Voltage"))
			assert.are.equal("AC&amp;DC", d.artist)
		end)
	end)

	describe("commands", function()
		local function follow_has(arg)
			for _, a in ipairs(spotify.FOLLOW_CMD) do
				if a == arg then return true end
			end
			return false
		end

		it("scopes every command to the spotify player", function()
			assert.is_truthy(spotify.METADATA_CMD:find("-p spotify", 1, true))
			assert.is_true(follow_has("-p"))
			assert.is_true(follow_has("spotify"))
		end)

		it("silences metadata stderr, which is noisy with no player", function()
			assert.is_truthy(spotify.METADATA_CMD:find("2>/dev/null", 1, true))
		end)

		it("follows rather than polls", function()
			assert.is_true(follow_has("--follow"))
		end)

		it("line-buffers the follow stream", function()
			-- Without stdbuf, playerctl block buffers into a pipe: the first
			-- line arrives and every later one sits in the buffer, so track
			-- changes only showed up when the backstop poll came round, five
			-- seconds later.
			assert.are.equal("stdbuf", spotify.FOLLOW_CMD[1])
			assert.are.equal("-oL", spotify.FOLLOW_CMD[2])
		end)

		it("passes the follow command as a table, not a string", function()
			-- awful.spawn splits a string command shell-like, which mangles
			-- the {{...}} template; a table reaches playerctl verbatim.
			assert.are.equal("table", type(spotify.FOLLOW_CMD))
		end)

		it("keeps a backstop poll, since follow may miss the player exiting", function()
			assert.is_truthy(spotify.service.safety_interval)
			assert.is_true(spotify.service.safety_interval > 0)
		end)
	end)
end)
