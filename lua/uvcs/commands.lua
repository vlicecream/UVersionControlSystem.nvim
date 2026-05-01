local project = require("uvcs.project")
local uvcs = require("uvcs")

local M = {}

local function scratch(title, lines)
	vim.cmd("botright new")
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "uvcs-status"
	pcall(vim.api.nvim_buf_set_name, buf, "uvcs://" .. title:gsub("%s+", "-"):lower() .. "/" .. tostring(buf))
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modified = false
end

function M.login()
	local ok, result = pcall(function()
		return require("uvcs.p4").login()
	end)

	if ok and result ~= false then
		vim.notify("UVCS: P4 login successful", vim.log.levels.INFO)
		return
	end

	local err = ok and "login failed" or result
	vim.notify("UVCS: P4 login failed: " .. tostring(err), vim.log.levels.ERROR)
end

function M.dashboard()
	uvcs.open_dashboard("all")
end

function M.commit()
	uvcs.open_commit_ui(nil, nil)
end

function M.checkout()
	local path = vim.api.nvim_buf_get_name(0)
	if path == "" then
		return vim.notify("UVCS: no file in current buffer", vim.log.levels.WARN)
	end

	local provider = uvcs.detect_for_path(path)
	if not provider then
		return vim.notify("UVCS: no VCS provider detected for this file", vim.log.levels.WARN)
	end

	if provider.name() ~= "p4" then
		return vim.notify("UVCS: checkout is a no-op for " .. provider.name():upper(), vim.log.levels.INFO)
	end

	local ok, err = provider.checkout(path)
	if ok then
		vim.bo[0].readonly = false
		vim.notify("UVCS: p4 edit " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
	else
		vim.notify("UVCS checkout failed: " .. tostring(err), vim.log.levels.ERROR)
	end
end

function M.pending_changelists()
	local buf_path = vim.api.nvim_buf_get_name(0)
	local root = buf_path ~= "" and project.find_project_root(buf_path) or nil
	if not root then
		return vim.notify("UVCS: could not find .uproject", vim.log.levels.ERROR)
	end

	local provider = uvcs.detect(root)
	if not provider or provider.name() ~= "p4" then
		return vim.notify("UVCS: no P4 provider detected", vim.log.levels.WARN)
	end

	if not provider.pending_changelists then
		return vim.notify("UVCS: pending_changelists not available", vim.log.levels.WARN)
	end

	local changes = provider.pending_changelists(root)
	if #changes == 0 then
		return vim.notify("UVCS: no pending changelists", vim.log.levels.INFO)
	end

	print(vim.inspect(changes))
end

function M.debug()
	local path = vim.api.nvim_buf_get_name(0)
	local root = project.find_project_root(path)
	local lines = {
		"UVCS Debug",
		"",
		"Current buffer: " .. (path ~= "" and path or "(none)"),
		"Project root: " .. tostring(root or "(not in Unreal project)"),
	}

	if root then
		local provider = uvcs.detect(root)
		if provider then
			lines[#lines + 1] = "Provider: " .. provider.name():upper()

			if provider.name() == "p4" then
				lines[#lines + 1] = "P4 config source: " .. tostring(provider.config_source())
				lines[#lines + 1] = "P4 command: " .. tostring(provider.p4_cmd("info")[1])

				local info, info_err = provider.info(root)
				if info then
					lines[#lines + 1] = "P4 client: " .. tostring(info["client name"] or "?")
					lines[#lines + 1] = "P4 user: " .. tostring(info["user name"] or "?")
					lines[#lines + 1] = "P4 root: " .. tostring(info["client root"] or "?")
					lines[#lines + 1] = "P4 server: " .. tostring(info["server address"] or "?")
				else
					lines[#lines + 1] = "P4 info: " .. tostring(info_err)
				end

				if path ~= "" then
					lines[#lines + 1] = ""
					lines[#lines + 1] = "Current file:"
					lines[#lines + 1] = "  writable: " .. tostring(vim.fn.filewritable(path) == 1)
					lines[#lines + 1] = "  buffer readonly: " .. tostring(vim.bo[0].readonly)
					lines[#lines + 1] = "  p4 opened: " .. tostring(provider.is_opened(path))
				end

				lines[#lines + 1] = ""
				lines[#lines + 1] = "All opened files:"
				local opened_files = provider.opened(root)
				if #opened_files > 0 then
					for _, file in ipairs(opened_files) do
						lines[#lines + 1] = "  [" .. file.action .. "] " .. file.path
					end
				else
					lines[#lines + 1] = "  (none)"
				end
			end
		else
			lines[#lines + 1] = "Provider: none (not in a VCS workspace)"
		end
	end

	scratch("UVCS Debug", lines)
end

function M.help()
	print([[
UVCS commands:

  :UVCS              Open VCS dashboard
  :UVCS dashboard    Open VCS dashboard
  :UVCS changes      Alias of dashboard
  :UVCS changelists  Alias of dashboard
  :UVCS checkout     Checkout current file (p4 edit)
  :UVCS commit       Open visual commit UI
  :UVCS login        Interactive P4 login
  :UVCS debug        Debug subcommands
  :UVCS help         Show this help
]])
end

function M.debug_help()
	print([[
UVCS debug commands:

  :UVCS debug vcs         Print VCS diagnostics
  :UVCS debug p4-changes  Print pending P4 changelists
  :UVCS debug help        Show this help
]])
end

local function split_first(text)
	local head, tail = (text or ""):match("^%s*(%S*)%s*(.-)%s*$")
	if head == "" then
		return "help", ""
	end

	return head:lower(), tail or ""
end

local function dispatch_debug(tail)
	local sub = split_first(tail)
	local handlers = {
		help = M.debug_help,
		vcs = M.debug,
		["p4-changes"] = M.pending_changelists,
		p4changes = M.pending_changelists,
	}

	local handler = handlers[sub]
	if not handler then
		vim.notify("Unknown UVCS debug command: " .. tostring(sub), vim.log.levels.ERROR)
		return M.debug_help()
	end

	handler()
end

function M.dispatch(args)
	local input = args.args or ""
	if vim.trim(input) == "" then
		return M.dashboard()
	end

	local sub, tail = split_first(input)
	local handlers = {
		help = M.help,
		dashboard = M.dashboard,
		changes = M.dashboard,
		changelists = M.dashboard,
		checkout = M.checkout,
		commit = M.commit,
		login = M.login,
		debug = function()
			dispatch_debug(tail)
		end,
	}

	local handler = handlers[sub]
	if not handler then
		vim.notify("Unknown UVCS command: " .. sub, vim.log.levels.ERROR)
		return M.help()
	end

	handler()
end

function M.register()
	pcall(vim.api.nvim_del_user_command, "UVCS")

	vim.api.nvim_create_user_command("UVCS", M.dispatch, {
		nargs = "*",
		complete = function(arglead, cmdline, cursorpos)
			local user_items = {
				"dashboard",
				"changes",
				"changelists",
				"checkout",
				"commit",
				"login",
				"debug",
				"help",
			}
			local debug_items = {
				"vcs",
				"p4-changes",
				"help",
			}

			local line = cmdline or ""
			local before_cursor = line:sub(1, (cursorpos or (#line + 1)) - 1)
			local tail = before_cursor:match("^%s*UVCS%s*(.-)%s*$") or ""
			local first = tail:match("^(%S+)")
			local items = first and first:lower() == "debug" and debug_items or user_items
			local needle = (arglead or ""):lower()

			if first and first:lower() == "debug" and tail:lower():match("^debug%s*$") then
				needle = ""
			end

			return vim.tbl_filter(function(item)
				return item:find(needle, 1, true) == 1
			end, items)
		end,
	})
end

return M
