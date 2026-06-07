-- Author: Ame林汀
-- Website: vlicecream.github.io
-- File: plugin/UVCS.lua
-- Purpose: Reload and bootstrap the UVCS plugin entrypoint.
-- License: MIT

-- Unload cached UVCS modules so re-sourcing the plugin resets state cleanly.
-- 卸载缓存的 UVCS 模块，以便重新采购插件以干净地重置状态。
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
