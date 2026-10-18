-- Fork search policy. Keep roslyn.sln.discovery unchanged for upstream updates.
local upstream = require("roslyn.sln.discovery")
local M = {}

local function normalize(path)
    return vim.fs.normalize(path)
end

function M.is_within(path, root)
    path, root = normalize(path), normalize(root)
    if vim.fn.has("win32") == 1 then
        path, root = path:lower(), root:lower()
    end
    root = root:gsub("/+$", "")
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

-- All matches in the nearest matching ancestor, not an arbitrary first project.
local function nearest(bufnr, projects)
    local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
    local cwd = vim.fn.getcwd()
    while dir and dir ~= "" do
        if not projects and not M.is_within(dir, cwd) then
            break
        end
        local solutions, csprojs = upstream.find_target_files(dir)
        local files = projects and csprojs or solutions
        if #files > 0 then
            table.sort(files)
            return files
        end
        local parent = vim.fs.dirname(dir)
        if parent == dir then
            break
        end
        dir = parent
    end
    return {}
end

function M.find_projects(bufnr)
    return nearest(bufnr, true)
end

function M.find_solutions_for_buffer(bufnr)
    if not require("roslyn.config").get().broad_search then
        return nearest(bufnr, false)
    end
    local solutions = upstream.find_solutions_for_buffer(bufnr)
    table.sort(solutions)
    return solutions
end

M.find_target_files = upstream.find_target_files
return M
