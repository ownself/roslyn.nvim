---@type vim.lsp.Config
return {
    name = "roslyn",
    filetypes = { "cs", "razor" },
    cmd = {
        require("roslyn.utils").get_roslyn_lsp_path(),
        "--stdio",
        "--daemon-mode",
        "--clientProcessId",
        tostring(vim.uv.os_getpid()),
    },
    cmd_env = {
        Configuration = vim.env.Configuration or "Debug",
        -- Fixes LSP navigation in decompiled files for systems with symlinked TMPDIR (macOS)
        TMPDIR = vim.env.TMPDIR and vim.fn.resolve(vim.env.TMPDIR) or nil,
    },
    root_dir = function(bufnr, on_dir)
        require("roslyn.fork.target").root_dir(bufnr, on_dir)
    end,
    on_init = {
        --- @param client vim.lsp.Client
        function(client)
            if not client.config.root_dir then
                return
            end
            require("roslyn.log").log(string.format("lsp on_init root_dir: %s", client.config.root_dir))

            local on_init = require("roslyn.lsp.on_init")
            local cached_target = require("roslyn.fork.target").consume(client.config.root_dir)

            if not cached_target then
                require("roslyn.log").log(
                    string.format("lsp on_init missing cached target for root_dir: %s", client.config.root_dir)
                )
                return
            end

            if cached_target.kind == "solution" then
                return on_init.sln(client, cached_target.target)
            end

            if cached_target.kind == "project" then
                return on_init.project(client, { cached_target.target })
            end

            require("roslyn.log").log(
                string.format("lsp on_init unknown cached target kind: %s", vim.inspect(cached_target))
            )
        end,
    },
    on_exit = {
        function(_, _, client_id)
            require("roslyn.fork.store").set_client_resolved_target(client_id, nil)
            vim.schedule(function()
                require("roslyn.roslyn_emitter").emit("stopped")
                vim.notify("Roslyn server stopped", vim.log.levels.INFO, { title = "roslyn.nvim" })
            end)
        end,
    },
    commands = require("roslyn.lsp.commands"),
    handlers = require("roslyn.lsp.handlers"),
}
