-- Session selection memory is separate from upstream's one-shot pending decisions.
local M = {}
local clients = {}
local remembered = {}

---@class RoslynResolvedTarget
---@field kind "solution" | "project"
---@field target string

function M.set_resolved_target(root, target)
    remembered[vim.fs.normalize(root)] = target
end

function M.get_resolved_target(root)
    return remembered[vim.fs.normalize(root)]
end

function M.set_client_resolved_target(id, target)
    clients[id] = target
    -- Preserve the upstream solution-only API for upstream target consumers.
    require("roslyn.store").set(id, target and target.kind == "solution" and target.target or nil)
    if target then
        M.set_resolved_target(vim.fs.dirname(target.target), target)
        vim.g.roslyn_nvim_selected_target = target
    end
end

function M.get_client_resolved_target(id)
    return clients[id]
end

function M.get(id)
    local target = clients[id]
    return target and target.kind == "solution" and target.target or nil
end

return M
