-- Fork policy and async UI; upstream roslyn.target remains an unmodified baseline.
local discovery = require("roslyn.fork.discovery")
local store = require("roslyn.fork.store")
local upstream = require("roslyn.target")
local M = {}
local prompts = {}

local function decision(kind, path)
    return {
        kind = kind,
        target = path,
        root_dir = vim.fs.dirname(path),
        projects = kind == "project" and { path } or nil,
    }
end

local function remembered(kind, paths)
    for _, path in ipairs(paths) do
        local cached = store.get_resolved_target(vim.fs.dirname(path))
        if cached and cached.kind == kind and vim.list_contains(paths, cached.target) then
            return decision(kind, cached.target)
        end
    end
end

function M.resolve(bufnr)
    if vim.api.nvim_buf_get_name(bufnr):match("^roslyn%-source%-generated://") then
        local client = vim.lsp.get_clients({ name = "roslyn" })[1]
        if client then
            return { kind = "reuse", root_dir = client.config.root_dir }
        end
    end
    local config = require("roslyn.config").get()
    local projects = discovery.find_projects(bufnr)
    local solutions = {}
    for _, path in ipairs(discovery.find_solutions_for_buffer(bufnr)) do
        local valid = #projects == 0
        for _, project in ipairs(projects) do
            if require("roslyn.sln.api").exists_in_target(path, project) then
                valid = true
                break
            end
        end
        if valid and not (config.ignore_target and config.ignore_target(path)) then
            solutions[#solutions + 1] = path
        end
    end
    local kind, paths = "solution", solutions
    if #paths == 0 then
        kind, paths = "project", projects
    end
    if #paths == 0 then
        return { kind = "none" }
    end
    local cached = remembered(kind, paths)
    if cached then
        return cached
    end
    if #paths == 1 then
        return decision(kind, paths[1])
    end
    if kind == "solution" then
        local active = {}
        for _, client in ipairs(vim.lsp.get_clients({ name = "roslyn" })) do
            local target = store.get(client.id)
            if target and vim.list_contains(paths, target) then
                active[target] = true
            end
        end
        local targets = vim.tbl_keys(active)
        if #targets == 1 then
            return decision(kind, targets[1])
        end
    end
    return { kind = "ambiguous", target_kind = kind, targets = paths }
end

function M.remember(result)
    if result.kind ~= "solution" and result.kind ~= "project" then
        return
    end
    store.set_resolved_target(result.root_dir, { kind = result.kind, target = result.target })
    upstream.remember(result)
end

-- Never infer a new target from whichever buffer happens to be current in on_init.
function M.consume(root)
    local result = upstream.consume(root)
    if result then
        return result
    end
    local cached = store.get_resolved_target(root)
    return cached and decision(cached.kind, cached.target) or nil
end

function M.root_dir(bufnr, on_dir)
    local result = M.resolve(bufnr)
    if result.root_dir then
        M.remember(result)
        on_dir(result.root_dir)
        return
    end
    if result.kind ~= "ambiguous" then
        return
    end
    -- Coalesce only identical candidate sets. Independent workspaces can prompt independently.
    local key = result.target_kind .. "\n" .. table.concat(result.targets, "\n")
    if prompts[key] then
        table.insert(prompts[key], { bufnr = bufnr, callback = on_dir })
        return
    end
    prompts[key] = { { bufnr = bufnr, callback = on_dir } }
    vim.schedule(function()
        vim.ui.select(result.targets, {
            prompt = result.target_kind == "solution" and "Multiple solutions found. Select target: "
                or "Multiple projects found. Select target: ",
            format_item = function(path)
                return vim.fn.fnamemodify(path, ":.")
            end,
        }, function(path)
            local waiters = prompts[key]
            prompts[key] = nil
            if not path or not vim.list_contains(result.targets, path) or not vim.uv.fs_stat(path) then
                return
            end
            local selected = decision(result.target_kind, path)
            M.remember(selected)
            for _, waiter in ipairs(waiters) do
                if vim.api.nvim_buf_is_valid(waiter.bufnr) then
                    waiter.callback(selected.root_dir)
                end
            end
            vim.schedule(function()
                for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                    if
                        vim.api.nvim_buf_is_loaded(buf)
                        and (vim.bo[buf].filetype == "cs" or vim.bo[buf].filetype == "razor")
                    then
                        vim.api.nvim_exec_autocmds("FileType", { buffer = buf })
                    end
                end
            end)
        end)
    end)
end

return M
