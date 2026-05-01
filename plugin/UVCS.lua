if vim.g.loaded_uvcs == 1 then
	return
end

vim.g.loaded_uvcs = 1

require("uvcs").setup()
