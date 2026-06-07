-- Author: Ame林汀
-- Website: vlicecream.github.io
-- File: lua/uvcs/config.lua
-- Purpose: Store default UVCS settings and merge user overrides.
-- License: MIT

local M = {}

local defaults = {
	enable = true,
	prompt_on_readonly_save = true,
	provider = "auto",
	p4 = {
		command = "p4",
		env = nil,
		port = nil,
		user = nil,
		client = nil,
		charset = nil,
		config = nil,
	},
}

-- Normalize user options and legacy aliases before merging config values.
-- 在合并配置值之前规范用户选项和旧别名。
local function normalize_opts(opts)
	if type(opts) ~= "table" then
		return {}
	end

	if type(opts.vcs) ~= "table" then
		return opts
	end

	local normalized = vim.deepcopy(opts.vcs)
	for key, value in pairs(opts) do
		if key ~= "vcs" then
			normalized[key] = value
		end
	end

	return normalized
end

-- Keep legacy top-level config aliases in sync with the nested config table.
-- 使旧的顶级配置别名与嵌套配置表保持同步。
local function sync_legacy_alias()
	M.values.vcs = {
		enable = M.values.enable,
		prompt_on_readonly_save = M.values.prompt_on_readonly_save,
		provider = M.values.provider,
		p4 = M.values.p4,
	}
end

M.values = vim.deepcopy(defaults)
sync_legacy_alias()

-- Merge user options into the default UVCS configuration.
-- 将用户选项合并到默认 UVCS 配置中。
function M.setup(opts)
	M.values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), normalize_opts(opts))
	sync_legacy_alias()
	return M.values
end

return M
