local M = {}

local timers = {} -- bufnr -> timer_id

---Refresh diagnostics for a single buffer (with debounce)
---@param client vim.lsp.Client
---@param bufnr integer
---@param delay? integer debounce delay in ms (default 100)
function M.refresh_buf(client, bufnr, delay)
    if not (vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
        return
    end

    -- Cancel previous timer for this buffer
    if timers[bufnr] then
        vim.fn.timer_stop(timers[bufnr])
        timers[bufnr] = nil
    end

    timers[bufnr] = vim.defer_fn(function()
        timers[bufnr] = nil
        if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
            client:request(
                vim.lsp.protocol.Methods.textDocument_diagnostic,
                { textDocument = vim.lsp.util.make_text_document_params(bufnr) },
                nil,
                bufnr
            )
        end
    end, delay or 100)
end

---Refresh diagnostics for all attached buffers
---@param client vim.lsp.Client
function M.refresh(client)
    for buf in pairs(client.attached_buffers) do
        M.refresh_buf(client, buf)
    end
end

return M
