local function unload_uvcs()
	local ok, existing = pcall(require, "uvcs")
	if ok and type(existing) == "table" and type(existing.reset) == "function" then
		pcall(existing.reset)
	end

	for name, _ in pairs(package.loaded) do
		if name == "uvcs" or name:match("^uvcs%.") then
			package.loaded[name] = nil
		end
	end
end

if vim.g.loaded_uvcs == 1 then
	unload_uvcs()
else
	vim.g.loaded_uvcs = 1
end

require("uvcs").setup()
