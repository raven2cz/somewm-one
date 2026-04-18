---------------------------------------------------------------------------
--- Tests for fishlive.services.portraits
---------------------------------------------------------------------------

package.path = "./plans/project/somewm-one/?.lua;" .. package.path

-- Shared test state
local test_root = "/tmp/somewm-test-portraits/"
local test_xdg = test_root .. "xdg"
local mock_config_dir = test_xdg .. "/somewm/"
local mock_base_path = test_root .. "portrait/"

-- Patch os.getenv *before* the module is required, so STATE_FILE is
-- computed inside the test sandbox rather than the real $HOME config.
local _orig_getenv = os.getenv
os.getenv = function(name)
	if name == "XDG_CONFIG_HOME" then return test_xdg end
	return _orig_getenv(name)
end

local mock_broker_signals = {}
package.preload["fishlive.broker"] = function()
	return {
		emit_signal = function(name, data)
			table.insert(mock_broker_signals, { name = name, data = data })
		end,
	}
end

package.preload["beautiful"] = function()
	return { portraits_base_path = mock_base_path }
end

describe("portraits service", function()
	local portraits
	local state_file

	local function sh(cmd)
		assert(os.execute(cmd))
	end

	setup(function()
		sh("rm -rf '" .. test_root .. "'")
		sh("mkdir -p '" .. mock_config_dir .. "'")
		sh("mkdir -p '" .. mock_base_path .. "joy'")
		sh("mkdir -p '" .. mock_base_path .. "witcher'")
		sh("mkdir -p '" .. mock_base_path .. "empty'")
		-- Image files
		sh("touch '" .. mock_base_path .. "joy/a.jpg'")
		sh("touch '" .. mock_base_path .. "joy/b.png'")
		sh("touch '" .. mock_base_path .. "joy/readme.txt'") -- should be filtered
		sh("touch '" .. mock_base_path .. "witcher/c.JPG'")  -- case-insensitive ext
		sh("touch '" .. mock_base_path .. "witcher/d.webp'")

		-- Discard any stub installed by earlier specs (animations_spec) so our
		-- package.preload mocks above are the ones `require` sees.
		package.loaded["fishlive.services.portraits"] = nil
		package.preload["fishlive.services.portraits"] = nil
		package.loaded["fishlive.broker"] = nil
		package.loaded["beautiful"] = nil

		portraits = require("fishlive.services.portraits")
		state_file = mock_config_dir .. ".default_portrait"
	end)

	teardown(function()
		sh("rm -rf '" .. test_root .. "'")
		os.getenv = _orig_getenv
		-- Don't leak our package.preload stubs into sibling specs.
		package.preload["fishlive.broker"] = nil
		package.preload["beautiful"] = nil
		package.loaded["fishlive.services.portraits"] = nil
		package.loaded["fishlive.broker"] = nil
		package.loaded["beautiful"] = nil
	end)

	before_each(function()
		mock_broker_signals = {}
		os.remove(state_file)
		portraits.reset_cache()
	end)

	describe("get_base_path", function()
		it("returns beautiful override with trailing slash", function()
			local p = portraits.get_base_path()
			assert.are.equal(mock_base_path, p)
		end)
	end)

	describe("list_collections", function()
		it("returns subdirectories sorted alphabetically", function()
			local cols = portraits.list_collections()
			assert.are.same({ "empty", "joy", "witcher" }, cols)
		end)

		it("caches between calls", function()
			local first = portraits.list_collections()
			sh("mkdir -p '" .. mock_base_path .. "newly_added'")
			local second = portraits.list_collections()
			assert.are.equal(#first, #second) -- cache hit, new dir not visible
			sh("rm -rf '" .. mock_base_path .. "newly_added'")
		end)

		it("reset_cache forces rescan", function()
			portraits.list_collections() -- prime cache
			sh("mkdir -p '" .. mock_base_path .. "fresh'")
			portraits.reset_cache()
			local cols = portraits.list_collections()
			local found = false
			for _, c in ipairs(cols) do if c == "fresh" then found = true end end
			assert.is_true(found)
			sh("rm -rf '" .. mock_base_path .. "fresh'")
			portraits.reset_cache()
		end)
	end)

	describe("list_images", function()
		it("filters by extension", function()
			local imgs = portraits.list_images("joy")
			assert.are.equal(2, #imgs)
			local names = {}
			for _, p in ipairs(imgs) do
				table.insert(names, p:match("([^/]+)$"))
			end
			table.sort(names)
			assert.are.same({ "a.jpg", "b.png" }, names)
		end)

		it("handles case-insensitive extensions", function()
			local imgs = portraits.list_images("witcher")
			assert.are.equal(2, #imgs)
		end)

		it("returns empty table for empty collection", function()
			assert.are.same({}, portraits.list_images("empty"))
		end)

		it("returns empty table for unsafe name", function()
			assert.are.same({}, portraits.list_images("../evil"))
		end)

		it("returns absolute paths", function()
			local imgs = portraits.list_images("joy")
			for _, p in ipairs(imgs) do
				assert.are.equal("/", p:sub(1, 1))
			end
		end)
	end)

	describe("set_default / get_default", function()
		it("persists selection and emits signal", function()
			assert.is_true(portraits.set_default("joy"))
			assert.are.equal("joy", portraits.get_default())
			assert.are.equal(1, #mock_broker_signals)
			assert.are.equal("data::portrait_default", mock_broker_signals[1].name)
			assert.are.equal("joy", mock_broker_signals[1].data.name)
		end)

		it("rejects unsafe name", function()
			assert.is_false(portraits.set_default("../evil"))
			assert.is_nil(portraits.get_default())
			assert.are.equal(0, #mock_broker_signals)
		end)

		it("rejects nonexistent collection", function()
			assert.is_false(portraits.set_default("does-not-exist"))
			assert.is_nil(portraits.get_default())
		end)

		it("get_default returns nil when state file absent", function()
			assert.is_nil(portraits.get_default())
		end)

		it("get_default returns nil when collection was deleted", function()
			assert.is_true(portraits.set_default("joy"))
			sh("mv '" .. mock_base_path .. "joy' '" .. mock_base_path .. "joy_gone'")
			assert.is_nil(portraits.get_default())
			sh("mv '" .. mock_base_path .. "joy_gone' '" .. mock_base_path .. "joy'")
		end)
	end)

	describe("random_image", function()
		it("returns an element from default collection", function()
			portraits.set_default("joy")
			local img = portraits.random_image()
			assert.is_not_nil(img)
			local all = portraits.list_images("joy")
			local hit = false
			for _, p in ipairs(all) do if p == img then hit = true end end
			assert.is_true(hit)
		end)

		it("returns nil when no default is set", function()
			assert.is_nil(portraits.random_image())
		end)

		it("returns nil for empty collection", function()
			assert.is_nil(portraits.random_image("empty"))
		end)

		it("returns nil for unsafe name", function()
			assert.is_nil(portraits.random_image("../evil"))
		end)

		it("honors explicit collection argument", function()
			portraits.set_default("joy")
			local img = portraits.random_image("witcher")
			assert.is_not_nil(img)
			assert.is_truthy(img:find("/witcher/"))
		end)
	end)

	describe("_is_safe_name", function()
		it("accepts alphanumeric, dash, underscore, dot, space", function()
			assert.is_true(portraits._is_safe_name("foo"))
			assert.is_true(portraits._is_safe_name("foo-bar"))
			assert.is_true(portraits._is_safe_name("foo_bar"))
			assert.is_true(portraits._is_safe_name("foo.bar"))
			assert.is_true(portraits._is_safe_name("foo bar"))
		end)

		it("rejects slashes, .., empty", function()
			assert.is_false(portraits._is_safe_name(""))
			assert.is_false(portraits._is_safe_name(".."))
			assert.is_false(portraits._is_safe_name("."))
			assert.is_false(portraits._is_safe_name("foo/bar"))
			assert.is_false(portraits._is_safe_name("foo\\bar"))
			assert.is_false(portraits._is_safe_name(nil))
		end)

		it("rejects control chars and newlines (ls/find injection)", function()
			assert.is_false(portraits._is_safe_name("foo\nbar"))
			assert.is_false(portraits._is_safe_name("foo\tbar"))
			assert.is_false(portraits._is_safe_name("foo\0bar"))
		end)

		it("accepts UTF-8 continuation bytes (non-ASCII names)", function()
			assert.is_true(portraits._is_safe_name("Vánoce"))
			assert.is_true(portraits._is_safe_name("春"))
			assert.is_true(portraits._is_safe_name("Café"))
		end)
	end)

	describe("shell safety", function()
		it("_shell_quote wraps in single quotes and escapes embedded quotes", function()
			assert.are.equal("'foo'", portraits._shell_quote("foo"))
			assert.are.equal("'it'\\''s'", portraits._shell_quote("it's"))
			-- %q would render $(id) as "\$(id)" (still shell-interpreted inside
			-- double quotes in some sh dialects); single-quote wrapping
			-- disables every metachar.
			assert.are.equal("'$(id)'", portraits._shell_quote("$(id)"))
		end)

		it("list_collections survives a hostile base path without executing it", function()
			-- Build a fake base path containing shell metachars. If the
			-- service leaked it to /bin/sh, the side-effect file would
			-- appear. find(1) just fails to stat the path → result is {}.
			local probe = "/tmp/somewm-injection-probe-" .. tostring(os.time())
			sh("rm -f '" .. probe .. "'")
			local saved = require("beautiful").portraits_base_path
			require("beautiful").portraits_base_path =
				"/tmp/nonexistent/$(touch " .. probe .. ")/"
			portraits.reset_cache()
			local cols = portraits.list_collections()
			require("beautiful").portraits_base_path = saved
			portraits.reset_cache()

			assert.are.same({}, cols)
			local f = io.open(probe, "r")
			assert.is_nil(f, "injection probe file was created — shell metachars executed")
			if f then f:close(); os.remove(probe) end
		end)

		it("list_images skips symlinks (path-traversal guard)", function()
			sh("ln -sf /etc/passwd '" .. mock_base_path .. "joy/evil.jpg'")
			portraits.reset_cache()
			local imgs = portraits.list_images("joy")
			for _, p in ipairs(imgs) do
				assert.is_nil(p:find("evil.jpg"), "symlink leaked into result")
			end
			sh("rm -f '" .. mock_base_path .. "joy/evil.jpg'")
			portraits.reset_cache()
		end)
	end)
end)
