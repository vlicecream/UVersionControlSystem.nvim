local config = require("uvcs.config")
local p4 = require("uvcs.p4")
local project = require("uvcs.project")

local M = {}

local detected_cache = {}

local function vcs_config()
	return config.values.vcs or {}
end

function M.name()
	return "p4"
end

function M.detect(root)
	if not root or root == "" then
		return nil
	end

	if vcs_config().enable == false then
		return nil
	end

	root = root:gsub("\\", "/")
	if detected_cache[root] ~= nil then
		return detected_cache[root]
	end

	local requested = (vcs_config().provider or "auto"):lower()
	if requested == "p4" or requested == "auto" then
		if p4.detect(root) then
			detected_cache[root] = p4
			return p4
		end
	end

	detected_cache[root] = nil
	return nil
end

function M.clear_cache()
	detected_cache = {}
end

function M.status(root)
	local provider = M.detect(root)
	if not provider then
		return nil, "no P4 provider detected"
	end

	return provider.opened(root), nil
end

function M.checkout(path)
	local provider = M.detect_for_path(path)
	if not provider then
		return false, "no P4 provider detected"
	end

	return provider.checkout(path)
end

function M.diff(path)
	local provider = M.detect_for_path(path)
	if not provider then
		return nil, "no P4 provider detected"
	end

	return provider.diff(path)
end

function M.commit(root, files, message, opts)
	local provider = M.detect(root)
	if not provider then
		return false, "no P4 provider detected"
	end

	return provider.commit(root, files, message, opts or {})
end

function M.revert(root, files)
	local provider = M.detect(root)
	if not provider then
		return false, "no P4 provider detected"
	end

	for _, path in ipairs(files or {}) do
		provider.do_revert(path)
	end

	return true, nil
end

function M.detect_for_path(path)
	if not path or path == "" then
		return nil
	end

	local root = project.find_project_root(path)
	if not root then
		return nil
	end

	return M.detect(root)
end

function M.is_readonly_p4(path)
	local provider = M.detect_for_path(path)
	if not provider then
		return false
	end

	if vim.fn.filewritable(path) == 1 then
		return false
	end

	if provider.is_opened(path) then
		return false
	end

	return true
end

function M.collect_changes(root)
	local items = {}
	local seen = {}
	local opened = p4.opened(root)
	local local_changes = p4.status(root)

	for _, file in ipairs(opened or {}) do
		local key = tostring(file.path or ""):lower()
		if not seen[key] then
			seen[key] = true
			table.insert(items, {
				path = file.path,
				status = file.action,
				provider = "P4",
				depot = file.depot,
			})
		end
	end

	for _, file in ipairs(local_changes or {}) do
		local key = tostring(file.path or ""):lower()
		if not seen[key] then
			seen[key] = true
			table.insert(items, {
				path = file.path,
				status = "local",
				provider = "P4",
			})
		end
	end

	return items
end

function M.open_dashboard(filter)
	require("uvcs.dashboard").open({ filter = filter or "all" })
end

function M.open_commit_ui(root, preselected_files)
	root = root or project.find_project_root_from_context()
	if not root then
		vim.notify("UVCS: no Unreal project detected", vim.log.levels.ERROR)
		return
	end

	require("uvcs.dirty").confirm_save(root, { action = "commit" }, function(ok)
		if not ok then
			return
		end

		require("uvcs.commit").open(root, { files = preselected_files })
	end)
end

function M.setup(opts)
	config.setup(opts)
	M.clear_cache()
	require("uvcs.commands").register()

	local current = vcs_config()
	if current.enable == false then
		return
	end

	if current.prompt_on_readonly_save ~= false then
		require("uvcs.readonly").setup()
	end
end

return M
