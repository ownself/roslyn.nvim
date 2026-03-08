local M = {}

local client_id_to_solution = {}
local root_dir_to_target = {}

---@param client_id integer
---@param solution? string
function M.set(client_id, solution)
    client_id_to_solution[client_id] = solution
    vim.g.roslyn_nvim_selected_solution = solution
end

---@param client_id integer
function M.get(client_id)
    return client_id_to_solution[client_id]
end

---@param root_dir string
---@param target? string
function M.set_target_for_root_dir(root_dir, target)
    root_dir_to_target[root_dir] = target
end

---@param root_dir string
---@return string?
function M.get_target_for_root_dir(root_dir)
    return root_dir_to_target[root_dir]
end

return M
