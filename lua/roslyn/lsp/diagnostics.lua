local M = {}

---Refresh diagnostics for a single buffer
---@param client vim.lsp.Client
---@param bufnr integer
function M.refresh_buf(client, bufnr)
    if (vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
        client:request(
            vim.lsp.protocol.Methods.textDocument_diagnostic,
            { textDocument = vim.lsp.util.make_text_document_params(bufnr) },
            nil,
            bufnr
        )
    end
end

---Refresh diagnostics for all attached buffers
---@param client vim.lsp.Client
function M.refresh(client)
    for buf in pairs(client.attached_buffers) do
        M.refresh_buf(client, buf)
    end
end

return M
