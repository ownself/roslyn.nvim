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

    client:notify("solution/open", {
        solution = vim.uri_from_fname(solution),
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

    client:notify("project/open", {
        projects = vim.tbl_map(function(file)
            return vim.uri_from_fname(file)
        end, projects),
    })
end

return M
