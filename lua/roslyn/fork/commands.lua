local M = {}

function M.subcommands(on_stopped)
    return {
        config = {
            impl = function()
                local bufnr = vim.api.nvim_get_current_buf()
                local client = vim.lsp.get_clients({ name = "roslyn", bufnr = bufnr })[1]

                -- Find Directory.Build.targets or Directory.Build.props
                local root_dir = client and client.config.root_dir or vim.fn.getcwd()
                local build_files = vim.fs.find(
                    { "Directory.Build.targets", "Directory.Build.props" },
                    { upward = true, path = root_dir, limit = math.huge }
                )

                local configurations = { "Debug", "Release" } -- Default configurations

                -- Try to parse Configurations from build files
                for _, file in ipairs(build_files) do
                    local content = vim.fn.readfile(file)
                    for _, line in ipairs(content) do
                        local configs = line:match("<Configurations>([^<]+)</Configurations>")
                        if configs then
                            configurations = vim.split(configs, ";", { trimempty = true })
                            break
                        end
                    end
                    if #configurations > 2 then
                        break
                    end
                end

                local current_config = vim.env.Configuration or "Debug"

                vim.ui.select(configurations, {
                    prompt = string.format("Select Configuration (current: %s): ", current_config),
                    format_item = function(item)
                        if item == current_config then
                            return item .. " (current)"
                        end
                        return item
                    end,
                }, function(choice)
                    if not choice then
                        return
                    end

                    if choice == current_config then
                        vim.notify(
                            "Configuration unchanged: " .. choice,
                            vim.log.levels.INFO,
                            { title = "roslyn.nvim" }
                        )
                        return
                    end

                    vim.env.Configuration = choice
                    vim.notify(
                        "Configuration changed to: " .. choice .. ". Restarting LSP...",
                        vim.log.levels.INFO,
                        { title = "roslyn.nvim" }
                    )

                    -- Restart LSP to apply new configuration
                    if client then
                        on_stopped(function()
                            vim.lsp.enable("roslyn")
                        end)
                        local force_stop = vim.uv.os_uname().sysname == "Windows_NT"
                        client:stop(force_stop)
                    else
                        vim.lsp.enable("roslyn")
                    end
                end)
            end,
        },
        unityslnf = {
            impl = function()
                local bufnr = vim.api.nvim_get_current_buf()
                local client = vim.lsp.get_clients({ name = "roslyn", bufnr = bufnr })[1]
                local root_dir = client and client.config.root_dir or vim.fn.getcwd()

                -- Find .sln files in root_dir (non-recursive)
                local sln_files = {}
                for entry, entry_type in vim.fs.dir(root_dir) do
                    if entry_type == "file" and entry:match("%.sln$") then
                        sln_files[#sln_files + 1] = vim.fs.normalize(vim.fs.joinpath(root_dir, entry))
                    end
                end

                if #sln_files == 0 then
                    vim.notify("No .sln files found in: " .. root_dir, vim.log.levels.WARN, { title = "roslyn.nvim" })
                    return
                end

                local total_generated = 0

                for _, sln_path in ipairs(sln_files) do
                    local sln_name = vim.fs.basename(sln_path)

                    -- Parse .sln to extract csproj paths (relative paths as written in sln)
                    local file = io.open(sln_path, "r")
                    if not file then
                        vim.notify("Cannot open: " .. sln_name, vim.log.levels.WARN, { title = "roslyn.nvim" })
                        goto continue_sln
                    end

                    local all_projects = {}
                    local pattern = 'Project%("{[^}]+}"%)[^=]*=%s*"[^"]+"%s*,%s*"([^"]+%.csproj)"%s*,%s*"{[^}]+}"'
                    for line in file:lines() do
                        local csproj_path = line:match(pattern)
                        if csproj_path then
                            all_projects[#all_projects + 1] = csproj_path
                        end
                    end
                    file:close()

                    if #all_projects == 0 then
                        vim.notify("No projects found in: " .. sln_name, vim.log.levels.INFO, { title = "roslyn.nvim" })
                        goto continue_sln
                    end

                    -- Classify projects by Unity naming convention
                    local has_player = false
                    local has_editor = false
                    local player_projects = {}
                    local editor_projects = {}
                    local common_projects = {}

                    for _, proj in ipairs(all_projects) do
                        local proj_filename = vim.fs.basename(proj)
                        if proj_filename:match("%.Player%.csproj$") then
                            has_player = true
                            player_projects[#player_projects + 1] = proj
                        elseif proj_filename:match("%.Editor%.csproj$") then
                            has_editor = true
                            editor_projects[#editor_projects + 1] = proj
                        else
                            common_projects[#common_projects + 1] = proj
                        end
                    end

                    if not (has_player and has_editor) then
                        vim.notify(
                            sln_name .. ": No Editor/Player project pair found, skipping",
                            vim.log.levels.INFO,
                            { title = "roslyn.nvim" }
                        )
                        goto continue_sln
                    end

                    -- Common projects go into both groups
                    vim.list_extend(player_projects, common_projects)
                    vim.list_extend(editor_projects, common_projects)

                    table.sort(player_projects)
                    table.sort(editor_projects)

                    local sln_base = sln_name:match("^(.+)%.sln$")
                    local sln_dir = vim.fs.dirname(sln_path)

                    -- Generate .slnf files
                    local function write_slnf(projects, slnf_name)
                        -- Build JSON string with indentation matching Python's json.dump(indent=2)
                        local rel_sln = sln_name:gsub("\\", "/")
                        local proj_lines = {}
                        for _, p in ipairs(projects) do
                            proj_lines[#proj_lines + 1] = string.format('      "%s"', p:gsub("\\", "/"))
                        end

                        local json_str = "{\n"
                            .. '  "solution": {\n'
                            .. string.format('    "path": "%s",\n', rel_sln)
                            .. '    "projects": [\n'
                            .. table.concat(proj_lines, ",\n")
                            .. "\n    ]\n"
                            .. "  }\n"
                            .. "}\n"

                        local slnf_path = vim.fs.joinpath(sln_dir, slnf_name)
                        local out = io.open(slnf_path, "w")
                        if not out then
                            vim.notify("Cannot write: " .. slnf_name, vim.log.levels.ERROR, { title = "roslyn.nvim" })
                            return false
                        end
                        out:write(json_str)
                        out:close()
                        return true
                    end

                    local editor_slnf = sln_base .. ".Editor.slnf"
                    local player_slnf = sln_base .. ".Player.slnf"

                    if write_slnf(editor_projects, editor_slnf) then
                        total_generated = total_generated + 1
                        vim.notify(
                            string.format("Generated: %s (%d projects)", editor_slnf, #editor_projects),
                            vim.log.levels.INFO,
                            { title = "roslyn.nvim" }
                        )
                    end

                    if write_slnf(player_projects, player_slnf) then
                        total_generated = total_generated + 1
                        vim.notify(
                            string.format("Generated: %s (%d projects)", player_slnf, #player_projects),
                            vim.log.levels.INFO,
                            { title = "roslyn.nvim" }
                        )
                    end

                    ::continue_sln::
                end

                if total_generated > 0 then
                    vim.notify(
                        string.format("Done! Generated %d .slnf file(s)", total_generated),
                        vim.log.levels.INFO,
                        { title = "roslyn.nvim" }
                    )
                end
            end,
        },
        context = {
            impl = function()
                local bufnr = vim.api.nvim_get_current_buf()
                local client = vim.lsp.get_clients({ name = "roslyn", bufnr = bufnr })[1]
                if not client then
                    vim.notify("Roslyn LSP client not found", vim.log.levels.WARN, { title = "roslyn.nvim" })
                    return
                end

                local store = require("roslyn.fork.store")
                local discovery = require("roslyn.fork.discovery")
                local sln_api = require("roslyn.sln.api")

                local lines = { "Roslyn context info:" }

                -- Configuration
                local configuration = client.config.cmd_env and client.config.cmd_env.Configuration or "Debug"
                table.insert(lines, string.format("  Configuration: %s", configuration))

                -- Current target
                local resolved_target = store.get_client_resolved_target(client.id)
                if resolved_target and resolved_target.kind == "solution" then
                    local solution = resolved_target.target
                    table.insert(lines, string.format("  Target: solution"))
                    table.insert(lines, string.format("  Solution: %s", vim.fn.fnamemodify(solution, ":.")))

                    -- List projects in solution
                    local projects = sln_api.projects(solution)
                    if #projects > 0 then
                        table.insert(lines, string.format("  Projects in solution (%d):", #projects))
                        for i, proj in ipairs(projects) do
                            table.insert(lines, string.format("    %d. %s", i, vim.fn.fnamemodify(proj, ":t")))
                        end
                    end
                elseif resolved_target and resolved_target.kind == "project" then
                    table.insert(lines, "  Target: project")
                    table.insert(
                        lines,
                        string.format("  Project: %s", vim.fn.fnamemodify(resolved_target.target, ":."))
                    )

                    -- Show csproj files in root_dir
                    if client.config.root_dir then
                        local _, csprojs = discovery.find_target_files(client.config.root_dir)
                        if #csprojs > 0 then
                            table.insert(lines, string.format("  Projects (%d):", #csprojs))
                            for i, proj in ipairs(csprojs) do
                                table.insert(lines, string.format("    %d. %s", i, vim.fn.fnamemodify(proj, ":t")))
                            end
                        end
                    end
                else
                    table.insert(lines, "  Target: (unknown)")
                end

                -- Current file's nearest csproj
                local file_path = vim.api.nvim_buf_get_name(bufnr)
                local nearest_csproj = vim.fs.find(function(name)
                    return name:match("%.csproj$") ~= nil
                end, { upward = true, path = file_path })[1]

                if nearest_csproj then
                    table.insert(lines, string.format("  Nearest csproj: %s", vim.fn.fnamemodify(nearest_csproj, ":.")))
                end

                -- Root dir
                table.insert(lines, string.format("  Root dir: %s", client.config.root_dir or "(unknown)"))

                vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "roslyn.nvim" })
            end,
        },
    }
end

return M
