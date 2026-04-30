local brainf = require("./src")
local luau = require("@lune/luau")
local stdio = require("@lune/stdio")
local fs = require("@lune/fs")

local src = "+[+> +[+> +[+ ] <] <]"
fs.writeFile("dump.bin", brainf.compile(src))

local start = os.clock()
brainf.run(src, {
	input = function()
		return 0
	end,
	output = function(val) end,
})

local stop = os.clock()
print(`{(stop - start) * 1000}ms`)
