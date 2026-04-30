--!native

export type OutputCallback = (number) -> ()
export type InputCallback = () -> number

export type BrainfFunction = (...IntoBuffer) -> buffer

export type RunCallbacks = {
	input: InputCallback,
	output: OutputCallback,
}

export type IntoBuffer = string | buffer

local function into_buffer(input: IntoBuffer): buffer
	return if type(input) == "string" then buffer.fromstring(input) else input
end

local DEFAULT_MEMORY_SIZE = 65536
local MEMORY_EXPANDS_BY = 4096

local ADVANCE = string.byte(">") -- 0x3E
local RETREAT = string.byte("<") -- 0x3C
local INCREMENT = string.byte("+") -- 0x2B
local DECREMENT = string.byte("-") -- 0x2D
local OUTPUT = string.byte(".") -- 0x2E
local INPUT = string.byte(",") -- 0x2C
local LOOP_BEGIN = string.byte("[") -- 0x5B
local NEWLINE = string.byte("\n")
local LOOP_END = string.byte("]") -- 0x5D

export type Location = {
	line: number,
	col: number,
}

export type ValidationError =
	{
		type: "unfinished_loop",
		location: Location,
	}
	| {
		type: "unexpected_loop_end",
		location: Location,
	}

export type ValidationResult =
	{
		ok: true,
	}
	| {
		ok: false,
		errors: { ValidationError },
	}

export type RuntimeError = {
	type: "out_of_bounds",
	location: Location,
}

local function is_syntax(byte: number): boolean
	return byte == ADVANCE
		or byte == RETREAT
		or byte == INCREMENT
		or byte == DECREMENT
		or byte == OUTPUT
		or byte == INPUT
		or byte == LOOP_BEGIN
		or byte == LOOP_END
end

local function get_location(src: buffer, position: number): Location
	if position > buffer.len(src) then
		error("cursor larger than source text")
	end

	local line = 1
	local col = 1

	for offset = 0, position do
		local char = buffer.readu8(src, offset)
		if char == NEWLINE then
			line += 1
			col = 1
		else
			col += 1
		end
	end

	return {
		line = line,
		col = col,
	}
end

local function trim_buffer(src: buffer, size: number): buffer
	local dst = buffer.create(size)
	buffer.copy(dst, 0, src, 0, size)
	return dst
end

local brainf = {}

local OP_ADVANCE = 0x3E
local OP_RETREAT = 0x3C
local OP_INCREMENT = 0x2B
local OP_DECREMENT = 0x2D
local OP_OUTPUT = 0x2E
local OP_INPUT = 0x2C
local OP_JUMPIFZ = 0x5B
local OP_JUMPIFNZ = 0x5D

--[=[
    Compiles the given brainf source into a compact intermediate representation.

    The IR format consists of a series of variable-width instructions: 
    - 0x3E <amount:u8>	ADVANCE		Advances the cell by `amount`
    - 0x3C <amount:u8>	RETREAT		Retreats the cell by `amount`
    - 0x2B <amount:u8>	INCREMENT	Increments the current cell by `amount`
    - 0x2D <amount:u8>	DECREMENT	Decrements the current cell by `amount`
    - 0x2E 				OUTPUT		Outputs the value of the current cell
    - 0x2C 				INPUT		Sets the value of the current cell to an inputted value
    - 0x5B <addr:u32>	JUMPIFZ		Jumps to `addr` if the current cells value is zero
    - 0x5D <addr:u32>	JUMPIFNZ	Jumps to `addr` if the current cells value isn't zero
]=]
function brainf.compile(src: IntoBuffer): buffer
	local src = into_buffer(src)
	local src_len = buffer.len(src)

	local validation_result = brainf.validate(src)
	if not validation_result.ok then
		error(`syntax error`)
	end

	local temp = buffer.create(1024)
	local temp_len = 1024
	local temp_cursor = 0

	local function check_temp_size(size: number)
		if temp_cursor + size >= temp_len then
			temp_len *= 2
			local new_ir = buffer.create(temp_len)
			buffer.copy(new_ir, 0, temp)
			temp = new_ir
		end
	end

	local function write_u8(value: number)
		check_temp_size(1)
		buffer.writeu8(temp, temp_cursor, value)
		temp_cursor += 1
	end

	local function write_u32(value: number)
		check_temp_size(4)
		buffer.writeu32(temp, temp_cursor, value)
		temp_cursor += 4
	end

	local src_cursor = 0

	local function run_length(of: number): number
		local count = 0
		local i = src_cursor
		while i < src_len do
			local insn = buffer.readu8(src, i)
			i += 1

			if insn == of then
				count += 1

				if count == 254 then
					break
				end
			else
				break
			end
		end
		return count
	end

	while src_cursor < src_len do
		local insn = buffer.readu8(src, src_cursor)
		src_cursor += 1

		if not is_syntax(insn) then
			continue
		end

		write_u8(insn)
		if insn == ADVANCE or insn == RETREAT or insn == INCREMENT or insn == DECREMENT then
			local additional = run_length(insn)
			write_u8(additional + 1)
			src_cursor += additional
		elseif insn == LOOP_BEGIN then
			write_u32(0)
		elseif insn == LOOP_END then
			write_u32(0)
		end
	end

	local ir_len = temp_cursor
	local ir = trim_buffer(temp, ir_len)

	local cursor = 0

	local loop_begin_stack = {}

	while cursor < ir_len do
		local insn = buffer.readu8(ir, cursor)
		cursor += 1

		if insn == LOOP_BEGIN then
			table.insert(loop_begin_stack, cursor + 4)

			local i = cursor + 4
			local skip_dest
			while true do
				local insn = buffer.readu8(ir, i)
				i += 1
				if insn == LOOP_END then
					skip_dest = i + 4
					break
				end
			end

			buffer.writeu32(ir, cursor, skip_dest or error(""))
			cursor += 4
		elseif insn == LOOP_END then
			buffer.writeu32(ir, cursor, table.remove(loop_begin_stack) or error(""))
			cursor += 4
		end
	end

	return ir
end

function brainf.run(src: IntoBuffer, callbacks: RunCallbacks)
	local src = into_buffer(src)
	local validation_result = brainf.validate(src)
	if not validation_result.ok then
		error(`syntax error`)
	end

	local instructions = brainf.compile(src)

	local instruction_pointer = 0
	local instruction_count = buffer.len(instructions)
	local memory = buffer.create(DEFAULT_MEMORY_SIZE)
	local memory_size = DEFAULT_MEMORY_SIZE

	local data_pointer = 0

	while instruction_pointer < instruction_count do
		local insn = buffer.readu8(instructions, instruction_pointer)
		instruction_pointer += 1
		if not is_syntax(insn) then
			continue
		end

		if insn == OP_ADVANCE then
			data_pointer += buffer.readu8(instructions, instruction_pointer)
			instruction_pointer += 1

			if data_pointer > memory_size then
				memory_size += MEMORY_EXPANDS_BY
				local new_memory = buffer.create(memory_size)
				buffer.copy(new_memory, 0, memory)
				memory = new_memory
			end
		elseif insn == OP_RETREAT then
			data_pointer -= buffer.readu8(instructions, instruction_pointer)
			instruction_pointer += 1

			if data_pointer < 0 then
				error({
					type = "out_of_bounds",
					location = get_location(src, data_pointer),
				})
			end
		elseif insn == OP_INCREMENT then
			local amount = buffer.readu8(instructions, instruction_pointer)
			buffer.writeu8(memory, data_pointer, buffer.readu8(memory, data_pointer) + amount)
			instruction_pointer += 1
		elseif insn == OP_DECREMENT then
			local amount = buffer.readu8(instructions, instruction_pointer)
			buffer.writeu8(memory, data_pointer, buffer.readu8(memory, data_pointer) - amount)
			instruction_pointer += 1
		elseif insn == OP_OUTPUT then
			callbacks.output(buffer.readu8(memory, data_pointer))
		elseif insn == OP_INPUT then
			buffer.writeu8(memory, data_pointer, callbacks.input())
		elseif insn == OP_JUMPIFZ then
			if buffer.readu8(memory, data_pointer) == 0 then
				instruction_pointer = buffer.readu32(instructions, instruction_pointer)
			else
				instruction_pointer += 4
			end
		elseif insn == OP_JUMPIFNZ then
			if buffer.readu8(memory, data_pointer) ~= 0 then
				instruction_pointer = buffer.readu32(instructions, instruction_pointer)
			else
				instruction_pointer += 4
			end
		else
			error(`unexpected instruction {string.char(insn)}, did stripping fail?`)
		end
	end
end

function brainf.transpile(src: IntoBuffer): string
	local src = into_buffer(src)
	local src_len = buffer.len(src)

	local validation_result = brainf.validate(src)
	if not validation_result.ok then
		error(`syntax error`)
	end

	local buf: { string } = {}

	local function write(str: string)
		table.insert(buf, str)
	end

	local indent_level = 1

	local function indent(): string
		return string.rep(" ", 4 * indent_level)
	end

	write("return function(input: () -> number, output: (number) -> ())\n")
	write("    local data_pointer = 0\n")
	write(
		"    local memory = setmetatable(table.create(30000, 0), { __index = function(self, idx) return rawget(self, idx) or 0 end })\n\n"
	)

	local cursor = 0

	while cursor < src_len do
		local insn = buffer.readu8(src, cursor)
		cursor += 1

		if not is_syntax(insn) then
			continue
		end

		if insn ~= LOOP_END then
			write(indent())
		end

		if insn == ADVANCE then
			write("data_pointer += 1")
		elseif insn == RETREAT then
			write("data_pointer -= 1; assert(data_pointer >= 0)")
		elseif insn == INCREMENT then
			write("memory[data_pointer] = (memory[data_pointer] + 1) % 256")
		elseif insn == DECREMENT then
			write("memory[data_pointer] = (memory[data_pointer] - 1) % 256")
		elseif insn == OUTPUT then
			write("output(memory[data_pointer])")
		elseif insn == INPUT then
			write("memory[data_pointer] = input()")
		elseif insn == LOOP_BEGIN then
			write("while memory[data_pointer] ~= 0 do")
			indent_level += 1
		elseif insn == LOOP_END then
			indent_level -= 1
			write(indent())
			write("end")
		end

		write("\n")
	end

	write("end\n")

	return table.concat(buf, "")
end

function brainf.wrap(src: IntoBuffer): BrainfFunction
	return function(...: IntoBuffer): buffer
		local args = { ... }
		local input_values: { number } = {}
		local output_values: { number } = {}

		input_values[1] = #args
		for i, arg in { ... } do
			local arg = into_buffer(arg)
			local arg_len = buffer.len(arg)
			if arg_len > 255 then
				error(`argument #{i}'s length exceeds 255`)
			end

			table.insert(input_values, arg_len)
			for offset = 0, arg_len - 1 do
				table.insert(input_values, buffer.readu8(arg, offset))
			end
		end

		local input_cursor = 0

		brainf.run(src, {
			input = function(): number
				input_cursor += 1
				return input_values[input_cursor] or 0
			end,

			output = function(value)
				table.insert(output_values, value)
			end,
		})

		local output = buffer.create(#output_values)
		for i = 1, #output_values do
			buffer.writeu8(output, i - 1, output_values[1])
		end

		return output
	end
end

function brainf.validate(src: IntoBuffer): ValidationResult
	local src = into_buffer(src)
	local src_len = buffer.len(src)
	local errors: { ValidationError } = {}

	local loops = {}

	for offset = 0, src_len - 1 do
		local char = buffer.readu8(src, offset)
		if char == LOOP_BEGIN then
			table.insert(loops, offset)
		elseif char == LOOP_END then
			if #loops == 0 then
				table.insert(errors, {
					type = "unexpected_loop_end" :: "unexpected_loop_end",
					location = get_location(src, offset),
				})
			else
				table.remove(loops)
			end
		end
	end

	for _, loop_offset in loops do
		table.insert(errors, {
			type = "unfinished_loop" :: "unfinished_loop",
			location = get_location(src, loop_offset),
		})
	end

	if #errors > 0 then
		return {
			ok = false,
			errors = errors,
		}
	else
		return {
			ok = true,
		}
	end
end

--[=[
	Strips unnecessary characters from a brainf source text. 
]=]
function brainf.strip(src: IntoBuffer): buffer
	local src = into_buffer(src)
	local src_len = buffer.len(src)
	local temp = buffer.create(src_len)

	local read_cursor = 0
	local write_cursor = 0

	while read_cursor < src_len do
		local char = buffer.readu8(src, read_cursor)
		read_cursor += 1
		if is_syntax(char) then
			buffer.writeu8(temp, write_cursor, char)
			write_cursor += 1
		end
	end

	return trim_buffer(temp, write_cursor)
end

return brainf
