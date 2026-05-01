local changelists = require("uvcs.changelists")
local commit = require("uvcs.commit")
local dashboard = require("uvcs.dashboard")

return setmetatable({
	open = dashboard.open,
	refresh = dashboard.refresh,
}, {
	__index = function(_, key)
		return dashboard[key] or commit[key] or changelists[key]
	end,
})
