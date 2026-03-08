local M = {}

local client_id_to_solution = {}
local client_id_to_resolved_target = {}
local root_dir_to_resolved_target = {}

---@alias RoslynResolvedTargetKind "solution" | "project"

---@class RoslynResolvedTarget
---@field kind RoslynResolvedTargetKind
---@field target string

---@param client_id integer
---@param solution? string
function M.set(client_id, solution)
    client_id_to_solution[client_id] = solution
    client_id_to_resolved_target[client_id] = solution and { kind = "solution", target = solution } or nil
end

---@param client_id integer
function M.get(client_id)
    return client_id_to_solution[client_id]
end

---@param client_id integer
---@param resolved_target? RoslynResolvedTarget
function M.set_client_resolved_target(client_id, resolved_target)
    client_id_to_resolved_target[client_id] = resolved_target
    client_id_to_solution[client_id] = resolved_target and resolved_target.kind == "solution" and resolved_target.target or nil
end

---@param client_id integer
---@return RoslynResolvedTarget?
function M.get_client_resolved_target(client_id)
    return client_id_to_resolved_target[client_id]
end

---@param root_dir string
---@param resolved_target? RoslynResolvedTarget
function M.set_resolved_target(root_dir, resolved_target)
    root_dir_to_resolved_target[root_dir] = resolved_target
end

---@param root_dir string
---@return RoslynResolvedTarget?
function M.get_resolved_target(root_dir)
    return root_dir_to_resolved_target[root_dir]
end

---@deprecated Use `set_resolved_target` instead.
---@param root_dir string
---@param target? string
function M.set_target_for_root_dir(root_dir, target)
    if not target then
        return M.set_resolved_target(root_dir, nil)
    end

    M.set_resolved_target(root_dir, {
        kind = "solution",
        target = target,
    })
end

---@deprecated Use `get_resolved_target` instead.
---@param root_dir string
---@return string?
function M.get_target_for_root_dir(root_dir)
    local resolved_target = M.get_resolved_target(root_dir)
    return resolved_target and resolved_target.target or nil
end

return M
