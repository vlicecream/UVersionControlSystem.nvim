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

function M.setup(opts)
	M.values = vim.tbl_deep_extend("force", M.values, normalize_opts(opts))
	sync_legacy_alias()
	return M.values
end

return M
