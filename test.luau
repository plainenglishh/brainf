local brainf = require("./src")
local luau = require("@lune/luau")
local stdio = require("@lune/stdio")
local fs = require("@lune/fs")

local src = "+++++[-.]"
fs.writeFile("dump.bin", brainf.compile(src))
brainf.run(src, {
	input = function()
		return 0
	end,
	output = function(val)
		print(val)
	end,
})
