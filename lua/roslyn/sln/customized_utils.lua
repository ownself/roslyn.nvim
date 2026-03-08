local log = require("roslyn.log")
local sln_api = require("roslyn.sln.api")
local sln_utils = require("roslyn.sln.utils")

local M = setmetatable({}, { __index = sln_utils })

---@param targets string[]
---@param csprojs string[]
---@return string[]
local function filter_targets(targets, csprojs)
    local config = require("roslyn.config").get()
    return vim.iter(targets)
        :filter(function(target)
            if config.ignore_target and config.ignore_target(target) then
                return false
            end

            if #csprojs == 0 then
                return true
            end

            for _, csproj in ipairs(csprojs) do
                if sln_api.exists_in_target(target, csproj) then
                    return true
                end
            end
            return false
        end)
        :totable()
end

---@param paths string[]
---@return string?
local function get_shortest_path(paths)
    local shortest = nil
    for _, path in ipairs(paths) do
        local dir = vim.fs.dirname(path)
        if not shortest or #dir < #shortest then
            shortest = dir
        end
    end
    return shortest
end

-- Tracks whether a prompt_target_on_multiple selection prompt is currently showing
local _prompt_pending = false

---@param bufnr number
---@return string[]
function M.find_solutions(bufnr)
    local cwd = vim.fs.normalize(vim.fn.getcwd())
    local results = vim.fs.find(function(name)
        return name:match("%.sln$") or name:match("%.slnx$") or name:match("%.slnf$")
    end, { upward = true, path = vim.api.nvim_buf_get_name(bufnr), limit = math.huge })

    local filtered = vim.tbl_filter(function(sln_path)
        local sln_dir = vim.fs.normalize(vim.fs.dirname(sln_path))
        return sln_dir:find(cwd, 1, true) == 1
    end, results)

    log.log(string.format("find_solutions cwd: %s, found: %s, filtered: %s", cwd, vim.inspect(results), vim.inspect(filtered)))
    return filtered
end

function M.handle_prompt_target_on_multiple(bufnr, on_dir, config)
    if not config.prompt_target_on_multiple then
        return false
    end

    if vim.g.roslyn_nvim_selected_solution then
        on_dir(vim.fs.dirname(vim.g.roslyn_nvim_selected_solution))
        return true
    end

    local solutions = M.get_filtered_solutions(bufnr)
    if #solutions > 1 then
        if _prompt_pending then
            return true
        end

        _prompt_pending = true
        vim.schedule(function()
            vim.ui.select(solutions, {
                prompt = "Multiple solutions found. Select target: ",
                format_item = function(item)
                    return vim.fn.fnamemodify(item, ":t")
                end,
            }, function(file)
                _prompt_pending = false
                if file then
                    vim.g.roslyn_nvim_selected_solution = file
                    on_dir(vim.fs.dirname(file))
                    vim.schedule(function()
                        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                            if vim.api.nvim_buf_is_loaded(buf) and buf ~= bufnr then
                                local ft = vim.bo[buf].filetype
                                if ft == "cs" or ft == "razor" then
                                    vim.api.nvim_exec_autocmds("FileType", { buffer = buf })
                                end
                            end
                        end
                    end)
                end
            end)
        end)
        return true
    elseif #solutions == 1 then
        on_dir(vim.fs.dirname(solutions[1]))
        return true
    end

    return false
end

---@param bufnr number
---@return string[]
function M.get_filtered_solutions(bufnr)
    local config = require("roslyn.config").get()
    local solutions = config.broad_search and M.find_solutions_broad(bufnr) or M.find_solutions(bufnr)

    if #solutions <= 1 then
        return solutions
    end

    local nearest_sln_dir = solutions[1] and vim.fs.dirname(solutions[1]) or nil
    local csprojs = nearest_sln_dir and M.find_files_with_extensions(nearest_sln_dir, { ".csproj" }) or {}
    local filtered = filter_targets(solutions, csprojs)

    if #filtered == 0 and #solutions > 0 then
        log.log("get_filtered_solutions: filter_targets returned empty, falling back to unfiltered solutions")
        return solutions
    end

    return #filtered > 0 and filtered or solutions
end

---@param bufnr number
---@param on_dir? fun(path: string|nil)
---@return string?
function M.root_dir(bufnr, on_dir)
    local config = require("roslyn.config").get()
    if on_dir and M.handle_prompt_target_on_multiple(bufnr, on_dir, config) then
        return nil
    end

    local solutions = config.broad_search and M.find_solutions_broad(bufnr) or M.find_solutions(bufnr)
    if #solutions == 1 then
        return vim.fs.dirname(solutions[1])
    end

    local nearest_sln_dir = solutions[1] and vim.fs.dirname(solutions[1]) or nil
    local csprojs = nearest_sln_dir and M.find_files_with_extensions(nearest_sln_dir, { ".csproj" }) or {}
    local filtered_targets = filter_targets(solutions, csprojs)

    if #filtered_targets == 0 and #solutions > 0 then
        log.log("filter_targets returned empty, falling back to unfiltered solutions")
        filtered_targets = solutions
    end

    if #filtered_targets > 1 then
        local possible_solutions = vim.iter(vim.lsp.get_clients({ name = "roslyn" }))
            :map(function(client)
                local client_solution = require("roslyn.store").get(client.id)
                if client_solution and vim.list_contains(filtered_targets, client_solution) then
                    return vim.fs.dirname(client_solution)
                end
            end)
            :totable()

        if #possible_solutions == 1 and possible_solutions[1] then
            return possible_solutions[1]
        end

        if config.prompt_target_on_multiple then
            return vim.fs.dirname(filtered_targets[1])
        end

        vim.notify(
            "Multiple potential target files found. Use `:Roslyn target` to select a target.",
            vim.log.levels.INFO,
            { title = "roslyn.nvim" }
        )
        return nil
    end

    local selected_solution = vim.g.roslyn_nvim_selected_solution
    return vim.fs.dirname(filtered_targets[1])
        or selected_solution and vim.fs.dirname(selected_solution)
        or solutions[1] and vim.fs.dirname(solutions[1])
        or csprojs[1] and vim.fs.dirname(csprojs[1])
end

---@param bufnr number
---@param targets string[]
---@return string?
function M.predict_target(bufnr, targets)
    local config = require("roslyn.config").get()
    local root_dir = get_shortest_path(targets)
    local csprojs = root_dir and M.find_files_with_extensions(root_dir, { ".csproj" }) or {}
    local filtered_targets = filter_targets(targets, csprojs)

    local result = #filtered_targets > 1 and nil or filtered_targets[1]
    log.log(string.format("predict_target targets: %s, csprojs: %s, result: %s", vim.inspect(targets), vim.inspect(csprojs), result))
    return result
end

return M
