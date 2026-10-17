if vim.g.loaded_roslyn_plugin ~= nil then
    return
end
vim.g.loaded_roslyn_plugin = true

if vim.fn.has("nvim-0.12") == 0 then
    return vim.notify("roslyn.nvim requires at least nvim 0.12", vim.log.levels.WARN, { title = "roslyn.nvim" })
end

vim.treesitter.language.register("c_sharp", "csharp")

vim.filetype.add({
    extension = {
        razor = "razor",
        cshtml = "razor",
    },
})

local group = vim.api.nvim_create_augroup("roslyn.nvim", { clear = true })

-- Updates `vim.g.roslyn_nvim_selected_target` when entering a C# or Razor buffer
-- so that it always reflects the current buffer's active target.
vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = { "*.cs", "*.razor", "*.cshtml" },
    callback = function(args)
        local client = vim.lsp.get_clients({ name = "roslyn", bufnr = args.buf })[1]
        if client then
            local resolved_target = require("roslyn.store").get_client_resolved_target(client.id)
            vim.g.roslyn_nvim_selected_target = resolved_target
        end
    end,
})

vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "cs", "razor" },
    callback = function()
        require("roslyn.commands").create_roslyn_commands()
    end,
})

vim.api.nvim_create_autocmd({ "BufReadCmd" }, {
    group = group,
    pattern = "roslyn-source-generated://*",
    callback = function(args)
        vim.bo[args.buf].swapfile = false
        vim.bo[args.buf].buftype = "nofile"
        vim.bo[args.buf].readonly = true

        local client = vim.lsp.get_clients({ name = "roslyn" })[1]
        assert(client, "Must have a `roslyn` client to load roslyn source generated file")
        require("roslyn.utils").populate_virtual_buffer_content(client, args.match, args.buf)

        -- This triggers FileType event which should fire up the lsp client if not already running
        vim.bo[args.buf].filetype = "cs"
        vim.lsp.buf_attach_client(args.buf, client.id)
    end,
})
