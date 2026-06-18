local function get_default_cmd()
    local resolved = require("roslyn.utils").get_roslyn_lsp_path()
    local exe = resolved or "Microsoft.CodeAnalysis.LanguageServer"

    local cmd = { exe, "--stdio" }

    local roslyn_extensions = require("roslyn.config").get().extensions or {}
    if next(roslyn_extensions) then
        vim.deprecate("roslyn.nvim extensions", 'vim.lsp.config("roslyn", { cmd = ... })', "soon", "roslyn.nvim")
    end

    for ext_name, extension in pairs(roslyn_extensions) do
        if extension.enabled then
            local resolved_config = type(extension.config) == "function" and extension.config() or extension.config

            local resolved_path = type(resolved_config.path) == "function" and resolved_config.path()
                or resolved_config.path

            if resolved_path == nil then
                vim.notify(
                    string.format("Extension '%s' is enabled but no path was provided. Skipping...", ext_name),
                    vim.log.levels.WARN,
                    { title = "roslyn.nvim" }
                )
            else
                vim.list_extend(cmd, { "--extension=" .. resolved_path })
            end

            if resolved_config.args then
                local resolved_args = type(resolved_config.args) == "function" and resolved_config.args()
                    or resolved_config.args
                if resolved_args then
                    vim.list_extend(cmd, resolved_args)
                end
            end
        end
    end

    return cmd
end

---@type vim.lsp.Config
return {
    name = "roslyn",
    filetypes = { "cs", "razor" },
    cmd = function(dispatchers, config)
        return vim.lsp.rpc.start(get_default_cmd(), dispatchers, {
            cwd = config.cmd_cwd,
            env = config.cmd_env,
            detached = config.detached,
        })
    end,
    cmd_env = {
        Configuration = vim.env.Configuration or "Debug",
        -- Fixes LSP navigation in decompiled files for systems with symlinked TMPDIR (macOS)
        TMPDIR = vim.env.TMPDIR and vim.fn.resolve(vim.env.TMPDIR) or nil,
    },
    root_dir = function(bufnr, on_dir)
        -- For source-generated files, use the root_dir from the existing client
        local buf_name = vim.api.nvim_buf_get_name(bufnr)
        if buf_name:match("^roslyn%-source%-generated://") then
            local existing_client = vim.lsp.get_clients({ name = "roslyn" })[1]
            if existing_client and existing_client.config.root_dir then
                on_dir(existing_client.config.root_dir)
                return
            end
        end

        local root_dir = require("roslyn.sln.customized_utils").root_dir(bufnr, on_dir)
        if root_dir then
            on_dir(root_dir)
        end
    end,
    on_init = {
        --- @param client vim.lsp.Client
        function(client)
            if not client.config.root_dir then
                return
            end
            require("roslyn.log").log(string.format("lsp on_init root_dir: %s", client.config.root_dir))

            local on_init = require("roslyn.lsp.on_init")
            local store = require("roslyn.store")

            local cached_target = store.get_resolved_target(client.config.root_dir)

            if not cached_target then
                require("roslyn.log").log(string.format("lsp on_init missing cached target for root_dir: %s", client.config.root_dir))
                return
            end

            if cached_target.kind == "solution" then
                return on_init.sln(client, cached_target.target)
            end

            if cached_target.kind == "project" then
                return on_init.project(client, { cached_target.target })
            end

            require("roslyn.log").log(string.format("lsp on_init unknown cached target kind: %s", vim.inspect(cached_target)))
        end,
    },
    on_exit = {
        function(_, _, client_id)
            require("roslyn.store").set_client_resolved_target(client_id, nil)
            vim.schedule(function()
                require("roslyn.roslyn_emitter").emit("stopped")
                vim.notify("Roslyn server stopped", vim.log.levels.INFO, { title = "roslyn.nvim" })
            end)
        end,
    },
    commands = require("roslyn.lsp.commands"),
    handlers = require("roslyn.lsp.handlers"),
}
