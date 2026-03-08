local M = {}

function M.sln(client, solution)
    require("roslyn.store").set_client_resolved_target(client.id, {
        kind = "solution",
        target = solution,
    })
    vim.g.roslyn_nvim_selected_target = {
        kind = "solution",
        target = solution,
    }

    if not require("roslyn.config").get().silent then
        vim.notify("Initializing Roslyn for: " .. solution, vim.log.levels.INFO, { title = "roslyn.nvim" })
    end

    client:notify("solution/open", {
        solution = vim.uri_from_fname(solution),
    })

    vim.api.nvim_exec_autocmds("User", {
        pattern = "RoslynOnInit",
        data = {
            type = "solution",
            target = solution,
            client_id = client.id,
        },
    })
end

function M.project(client, projects)
    require("roslyn.store").set_client_resolved_target(client.id, {
        kind = "project",
        target = projects[1],
    })
    vim.g.roslyn_nvim_selected_target = {
        kind = "project",
        target = projects[1],
    }

    if not require("roslyn.config").get().silent then
        vim.notify("Initializing Roslyn for: project", vim.log.levels.INFO, { title = "roslyn.nvim" })
    end
    client:notify("project/open", {
        projects = vim.tbl_map(function(file)
            return vim.uri_from_fname(file)
        end, projects),
    })

    vim.api.nvim_exec_autocmds("User", {
        pattern = "RoslynOnInit",
        data = {
            type = "project",
            target = projects,
            client_id = client.id,
        },
    })
end

return M
