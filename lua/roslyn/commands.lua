local roslyn_emitter = require("roslyn.roslyn_emitter")
-- Huge credits to mrcjkb
-- https://github.com/mrcjkb/rustaceanvim/blob/2fa45427c01ded4d3ecca72e357f8a60fd8e46d4/lua/rustaceanvim/commands/init.lua
local M = {}

local cmd_name = "Roslyn"

---@param fun function
local on_stopped = function(fun)
    ---@type function | nil
    local remove_listener = nil

    local function _fun()
        fun()
        if remove_listener then
            remove_listener()
        end
    end

    remove_listener = roslyn_emitter.on("stopped", _fun)
end

---@class RoslynSubcommandTable
---@field impl fun(args: string[], opts: vim.api.keyset.user_command) The command implementation
---@field complete? fun(subcmd_arg_lead: string): string[] Command completions callback, taking the lead of the subcommand's arguments

---@type RoslynSubcommandTable[]
local subcommand_tbl = {
    restart = {
        impl = function()
            vim.deprecate(":Roslyn restart", ":lsp restart roslyn", "soon", "roslyn.nvim")
            vim.cmd.lsp("restart", "roslyn")
        end,
    },
    stop = {
        impl = function()
            vim.deprecate(":Roslyn stop", ":lsp stop roslyn", "soon", "roslyn.nvim")
            vim.cmd.lsp("stop", "roslyn")
        end,
    },
    target = {
        impl = function()
            local bufnr = vim.api.nvim_get_current_buf()
            local utils = require("roslyn.sln.utils")
            local broad_search = require("roslyn.config").get().broad_search
            local targets = broad_search and utils.find_solutions_broad(bufnr) or utils.find_solutions(bufnr)
            vim.ui.select(targets or {}, {
                prompt = "Select target solution: ",
                format_item = function(item)
                    return vim.fn.fnamemodify(item, ":.")
                end,
            }, function(file)
                if not file then
                    return
                end

                local config = vim.tbl_deep_extend("force", vim.lsp.config["roslyn"], {
                    root_dir = vim.fs.dirname(file),
                    on_init = function(client)
                        require("roslyn.lsp.on_init").sln(client, file)
                    end,
                })

                local client = vim.lsp.get_clients({ name = "roslyn", bufnr = bufnr })[1]
                if not client then
                    vim.lsp.start(config, { bufnr = bufnr })
                    return
                end

                -- Start it in the buffer we got when running the command
                -- For some reason, it is a bit problematic to stop it, and it
                -- requires the user to do some action like triggering some LSP
                -- functionality (e.g. hover) before things actually happen
                on_stopped(function()
                    vim.lsp.start(config, { bufnr = bufnr })
                end)

                local force_stop = vim.uv.os_uname().sysname == "Windows_NT"
                client:stop(force_stop)
            end)
        end,
    },
    start = {
        impl = function()
            vim.deprecate(":Roslyn start", ":lsp enable roslyn", "soon", "roslyn.nvim")
            local bufnr = vim.api.nvim_get_current_buf()
            local utils = require("roslyn.sln.utils")
            local broad_search = require("roslyn.config").get().broad_search
            local solutions = broad_search and utils.find_solutions_broad(bufnr) or utils.find_solutions(bufnr)

            -- If we have more than one solution, immediately ask to pick one
            if #solutions > 1 then
                vim.ui.select(solutions or {}, { prompt = "Select target solution: " }, function(file)
                    if not file then
                        return
                    end

                    local config = vim.tbl_deep_extend("force", vim.lsp.config["roslyn"], {
                        root_dir = vim.fs.dirname(file),
                        on_init = function(client)
                            require("roslyn.lsp.on_init").sln(client, file)
                        end,
                    })
                    vim.lsp.start(config, { bufnr = bufnr })
                end)
                return
            end

            vim.lsp.enable("roslyn")
        end,
    },
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

            local store = require("roslyn.store")
            local utils = require("roslyn.sln.utils")
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
                table.insert(lines, string.format("  Project: %s", vim.fn.fnamemodify(resolved_target.target, ":.")))

                -- Show csproj files in root_dir
                if client.config.root_dir then
                    local csprojs = utils.find_files_with_extensions(client.config.root_dir, { ".csproj" })
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

---@param opts table
---@see vim.api.nvim_create_user_command
local function roslyn(opts)
    local fargs = opts.fargs
    local cmd = fargs[1]
    local args = #fargs > 1 and vim.list_slice(fargs, 2, #fargs) or {}
    local subcommand = subcommand_tbl[cmd]
    if type(subcommand) == "table" and type(subcommand.impl) == "function" then
        subcommand.impl(args, opts)
        return
    end

    vim.notify(cmd_name .. ": Unknown subcommand: " .. cmd, vim.log.levels.ERROR, { title = "roslyn.nvim" })
end

function M.create_roslyn_commands()
    vim.api.nvim_create_user_command(cmd_name, roslyn, {
        nargs = "+",
        range = true,
        desc = "Interacts with Roslyn",
        complete = function(arg_lead, cmdline, _)
            local all_commands = vim.tbl_keys(subcommand_tbl)

            local subcmd, subcmd_arg_lead = cmdline:match("^" .. cmd_name .. "[!]*%s(%S+)%s(.*)$")
            if subcmd and subcmd_arg_lead and subcommand_tbl[subcmd] and subcommand_tbl[subcmd].complete then
                return subcommand_tbl[subcmd].complete(subcmd_arg_lead)
            end

            if cmdline:match("^" .. cmd_name .. "[!]*%s+%w*$") then
                return vim.tbl_filter(function(command)
                    return command:find(arg_lead) ~= nil
                end, all_commands)
            end
        end,
    })
end

return M
