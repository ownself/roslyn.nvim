-- Portable regression runner: nvim --headless -u NONE -l test/fork_smoke.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(root, "p")
local old_cwd = vim.fn.getcwd()
package.path = old_cwd .. "/?.lua;" .. package.path
local function write(path, lines)
    path = root .. "/" .. path
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines or {}, path)
    return vim.fs.normalize(path)
end
local function buffer(path)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, path)
    return buf
end
local function solution(name, project)
    return write(name, { 'Project("{GUID}") = "App", "' .. project .. '", "{GUID}"' })
end
local passed = 0
local function check(name, fn)
    fn()
    passed = passed + 1
    print("PASS: " .. name)
end
local ok, err = xpcall(function()
    for _, dir in ipairs({ "lua", "lsp", "plugin", "test" }) do
        for _, path in ipairs(vim.fn.globpath(dir, "**/*.lua", false, true)) do
            assert(loadfile(path))
        end
    end
    vim.cmd.cd(root)
    local discovery = require("roslyn.fork.discovery")
    local target = require("roslyn.fork.target")
    local store = require("roslyn.fork.store")
    local upstream = require("roslyn.target")
    local project = write("src/App.csproj")
    local buf = buffer(write("src/Program.cs"))
    check("standalone project", function()
        local result = target.resolve(buf)
        assert(result.kind == "project" and result.target == project)
    end)
    local sln = solution("App.sln", "src/App.csproj")
    check("matching solution", function()
        assert(target.resolve(buf).target == sln)
    end)
    check("single unrelated solution falls back to project", function()
        solution("App.sln", "Other.csproj")
        assert(target.resolve(buf).target == project)
        solution("App.sln", "src/App.csproj")
    end)
    check("ignore_target also applies to single solution", function()
        require("roslyn.config").get().ignore_target = function()
            return true
        end
        assert(target.resolve(buf).kind == "project")
        require("roslyn.config").get().ignore_target = nil
    end)
    check("nearest solution level and cwd boundary", function()
        local nested = solution("src/Nested.sln", "App.csproj")
        assert(discovery.find_solutions_for_buffer(buf)[1] == nested)
        vim.fn.delete(nested)
        assert(not discovery.is_within(root .. "-other", root))
        vim.cmd.cd(root .. "/src")
        assert(#discovery.find_solutions_for_buffer(buf) == 0)
        vim.cmd.cd(root)
    end)
    local second = solution("Other.sln", "src/App.csproj")
    check("ambiguity and cancellation do not initialize", function()
        assert(target.resolve(buf).kind == "ambiguous")
        local select = vim.ui.select
        local done = false
        vim.ui.select = function(_, _, callback)
            callback(nil)
            done = true
        end
        target.root_dir(buf, function()
            error("cancelled selection initialized")
        end)
        assert(vim.wait(1000, function()
            return done
        end))
        vim.ui.select = select
        assert(store.get_resolved_target(root) == nil)
    end)
    check("coalesced selection resumes every waiting buffer", function()
        local select = vim.ui.select
        local calls, resumed = 0, 0
        vim.ui.select = function(_, _, callback)
            calls = calls + 1
            callback(second)
        end
        target.root_dir(buf, function()
            resumed = resumed + 1
        end)
        target.root_dir(buf, function()
            resumed = resumed + 1
        end)
        assert(vim.wait(1000, function()
            return resumed == 2
        end))
        assert(calls == 1)
        vim.ui.select = select
        assert(target.resolve(buf).target == second)
    end)
    check("one-shot decision and session memory have separate lifetimes", function()
        assert(upstream.consume(root).target == second)
        assert(upstream.consume(root) == nil)
        assert(target.consume(root).target == second)
        vim.fn.delete(second)
        assert(target.resolve(buf).target == sln)
    end)
    check("global display state cannot override resolution", function()
        vim.g.roslyn_nvim_selected_target = { kind = "solution", target = "unrelated.sln" }
        require("roslyn.store").set_selected_target("unrelated.sln")
        assert(target.resolve(buf).target == sln)
    end)
    check("multiple csproj use all nearest candidates", function()
        local extra = write("src/Extra.csproj")
        solution("App.sln", "src/Extra.csproj")
        assert(#discovery.find_projects(buf) == 2)
        assert(target.resolve(buf).target == sln)
        vim.fn.delete(sln)
        assert(target.resolve(buf).kind == "ambiguous")
        vim.fn.delete(extra)
    end)
    check("daemon command includes the current client process id", function()
        local config = dofile(vim.fs.joinpath(old_cwd, "lsp", "roslyn.lua"))
        assert(config.cmd[2] == "--stdio")
        assert(config.cmd[3] == "--daemon-mode")
        assert(config.cmd[4] == "--clientProcessId")
        assert(config.cmd[5] == tostring(vim.uv.os_getpid()))
    end)
    check("virtual content request passes buffer in the fourth argument", function()
        local generated = vim.api.nvim_create_buf(false, true)
        local client = {
            request_sync = function(_, method, params, timeout, bufnr)
                assert(method == "workspace/textDocumentContent")
                assert(params.uri == "roslyn-source-generated://smoke")
                assert(timeout == nil and bufnr == generated)
                return { result = { text = "namespace Generated {}\r\n" } }
            end,
        }
        require("roslyn.utils").populate_virtual_buffer_content(client, "roslyn-source-generated://smoke", generated)
        assert(vim.api.nvim_buf_get_lines(generated, 0, 1, false)[1] == "namespace Generated {}")
        assert(not vim.bo[generated].modifiable and not vim.bo[generated].modified)
    end)
    check("actual LSP startup, reuse and deterministic initialization", function()
        local mock = require("test.utils.mock_server")
        mock.reset()
        local config = dofile(vim.fs.joinpath(old_cwd, "lsp", "roslyn.lua"))
        config.cmd = mock.server
        local selected_root
        config.root_dir(buf, function(path)
            selected_root = path
        end)
        assert(selected_root == vim.fs.dirname(project))
        config.root_dir = selected_root
        local id = vim.lsp.start(config, { bufnr = buf })
        assert(id)
        assert(vim.wait(2000, function()
            return #mock.notifications > 0
        end))
        assert(mock.notifications[1].method == "project/open")
        assert(mock.notifications[1].params.projects[1] == vim.uri_from_fname(project))
        assert(store.get_client_resolved_target(id).target == project)
        local other = buffer(write("src/Other.cs"))
        assert(vim.lsp.start(config, { bufnr = other }) == id)
        assert(#mock.notifications == 1)
        local client = vim.lsp.get_client_by_id(id)
        client:stop(true)
        assert(client:is_stopped())
    end)
    check("manual initialization synchronizes session and client state", function()
        local notifications = {}
        local client = {
            id = 99,
            notify = function(_, method)
                notifications[#notifications + 1] = method
            end,
        }
        require("roslyn.lsp.on_init").project(client, { project })
        assert(store.get_client_resolved_target(99).kind == "project")
        assert(store.get_resolved_target(vim.fs.dirname(project)).target == project)
        assert(notifications[1] == "project/open")
        assert(store.get(99) == nil)
    end)
    check("Unity Editor/Player filters remain selectable and generator is available", function()
        local p = write("Unity/Game.Editor.csproj")
        write("Unity/Game.Player.csproj")
        local unity = solution("Unity/Game.sln", "Game.Editor.csproj")
        vim.fn.writefile({ 'Project("{GUID}") = "Player", "Game.Player.csproj", "{GUID}"' }, unity, "a")
        local ubuf = buffer(write("Unity/Assets/Game.cs"))
        local editor = write(
            "Unity/Game.Editor.slnf",
            { "{", '  "solution": {', '    "projects": [', '      "Game.Editor.csproj"', "    ]", "  }", "}" }
        )
        write(
            "Unity/Game.Player.slnf",
            { "{", '  "solution": {', '    "projects": [', '      "Game.Player.csproj"', "    ]", "  }", "}" }
        )
        local result = target.resolve(ubuf)
        assert(result.kind == "ambiguous" and #result.targets == 3)
        assert(vim.list_contains(result.targets, editor))
        local commands = require("roslyn.fork.commands").subcommands(function() end)
        assert(type(commands.unityslnf.impl) == "function")
        -- Run the real generator and validate its JSON output.
        vim.cmd.cd(root .. "/Unity")
        commands.unityslnf.impl()
        local json = vim.json.decode(table.concat(vim.fn.readfile(editor), "\n"))
        assert(json.solution.projects[1] == "Game.Editor.csproj")
        assert(vim.fs.basename(p) == json.solution.projects[1])
        vim.cmd.cd(root)
    end)
end, debug.traceback)
vim.cmd.cd(old_cwd)
vim.fn.delete(root, "rf")
if not ok then
    error(err)
end
print(string.format("%d fork regression checks passed", passed))
