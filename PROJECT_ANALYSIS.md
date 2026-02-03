# Roslyn.nvim 项目分析文档

> 这是一个为 Neovim 提供 C# 语言服务的 LSP 插件，基于微软的 Roslyn 语言服务器。

## 目录

- [项目概述](#项目概述)
- [目录结构](#目录结构)
- [核心架构](#核心架构)
- [初始化流程](#初始化流程)
- [与 Roslyn LSP 服务器的通信](#与-roslyn-lsp-服务器的通信)
- [配置选项](#配置选项)
- [特殊功能](#特殊功能)
- [测试结构](#测试结构)
- [关键数据流](#关键数据流)

---

## 项目概述

roslyn.nvim 是一个 Neovim 插件，为 C# 开发提供完整的语言服务支持。它通过与微软的 Roslyn 语言服务器通信，提供以下功能：

- 代码补全、悬停提示、跳转定义
- 诊断信息（错误和警告）
- 代码操作（重构、快速修复）
- Razor/CSHTML 模板支持
- 多解决方案管理
- 源代码生成文件支持

**系统要求**: Neovim >= 0.11

---

## 目录结构

```
roslyn.nvim/
├── plugin/
│   └── roslyn.lua                    # 插件入口点，自动命令设置
├── lsp/
│   └── roslyn.lua                    # LSP 服务器配置
├── lua/roslyn/
│   ├── init.lua                      # 主模块导出
│   ├── config.lua                    # 配置管理
│   ├── commands.lua                  # 用户命令 (:Roslyn)
│   ├── health.lua                    # 健康检查集成
│   ├── log.lua                       # 调试日志
│   ├── store.lua                     # 客户端 ID 到解决方案的映射
│   ├── roslyn_emitter.lua            # 服务器生命周期事件系统
│   ├── lsp/
│   │   ├── on_init.lua              # LSP 初始化逻辑
│   │   ├── handlers.lua             # LSP 事件处理器
│   │   ├── commands.lua             # 基于 LSP 的代码操作
│   │   └── diagnostics.lua          # 诊断刷新逻辑
│   ├── sln/
│   │   ├── api.lua                  # 解决方案文件解析 (.sln, .slnx, .slnf)
│   │   └── utils.lua                # 解决方案/项目发现工具
│   └── razor/
│       ├── documentManager.lua       # 虚拟 HTML 文档管理
│       ├── handlers.lua             # Razor 请求转发
│       ├── htmlDocument.lua         # HTML 文档表示
│       └── types.lua                # Razor 类型定义
├── test/
│   ├── api_spec.lua                 # 解决方案解析测试
│   ├── predict_spec.lua             # 目标预测测试
│   ├── lsp_integration_spec.lua      # LSP 集成测试
│   └── utils/
│       ├── helpers.lua              # 测试工具
│       └── mock_server.lua          # 模拟 LSP 服务器
└── Makefile, README.md, LICENSE.txt
```

---

## 核心架构

### 1. 插件入口 (plugin/roslyn.lua)

这是插件的引导文件，负责：

- **版本检查**: 确保 Neovim >= 0.11
- **LSP 注册**: 调用 `vim.lsp.enable("roslyn")`
- **Treesitter 注册**: 注册 C# 语言解析
- **文件类型设置**: 注册 `.razor` 和 `.cshtml` 扩展名
- **自动命令设置**:
  - `BufEnter`: 更新当前缓冲区的选定解决方案
  - `FileType`: 在进入 C# 或 Razor 文件时创建 `:Roslyn` 命令
  - `BufWritePost`/`InsertLeave`: 刷新诊断信息
  - `BufReadCmd`: 通过自定义协议加载源代码生成文件

### 2. LSP 服务器配置 (lsp/roslyn.lua)

提供 `vim.lsp.Config` 配置：

**命令设置**:
- 检测平台特定的 roslyn 二进制文件（Windows 上为 `roslyn.cmd`，其他为 `roslyn`）
- 检查 Mason 安装路径
- 配置 Razor 扩展路径
- 添加 CLI 参数: `--logLevel=Information`, `--extensionLogDirectory`, `--stdio`

**能力配置**:
- 启用 `textDocument.diagnostic.dynamicRegistration`（诊断必需）
- 配置 Razor 协同托管

**根目录解析**:
- 检查通过 `vim.g.roslyn_nvim_selected_solution` 锁定的目标
- 处理源代码生成文件 (`roslyn-source-generated://*` 协议)
- 调用 `utils.root_dir()` 进行自动解决方案检测

### 3. 解决方案/项目发现 (sln/)

**api.lua - 解决方案文件解析**:
- `M.projects(target)` - 从解决方案文件提取项目路径
- 支持 `.sln`（Visual Studio）、`.slnx`（新格式）、`.slnf`（解决方案筛选器）
- 跨 Windows/Unix 系统规范化路径

**utils.lua - 解决方案搜索**:
- `M.find_solutions(bufnr)` - 向上搜索 .sln/.slnx/.slnf 文件
- `M.find_solutions_broad(bufnr)` - 从 git/解决方案根目录递归搜索
- `M.find_csproj_file(bufnr)` - 向上查找最近的 .csproj
- `M.root_dir(bufnr)` - 智能根目录检测
- `M.predict_target(bufnr, targets)` - 根据当前文件的项目选择解决方案

### 4. LSP 处理器 (lsp/handlers.lua)

处理 Roslyn 特定协议的自定义处理器：

**标准处理器**:
- `client/registerCapability` - 控制文件监视行为
- `workspace/projectInitializationComplete` - 通知用户、刷新诊断、触发事件
- `workspace/refreshSourceGeneratedDocument` - 更新源代码生成文件内容

**Roslyn 特定处理器**:
- `workspace/_roslyn_projectNeedsRestore` - 协调项目恢复
- `workspace/_roslyn_restore` - 向服务器发送恢复请求

**Razor 处理器** (转发到 HTML LS):
- `razor/updateHtml` - 更新虚拟 HTML 文档
- 多个 `textDocument/*` 处理器转发到 HTML LS

### 5. 代码操作 (lsp/commands.lua)

处理特殊的 Roslyn 代码操作类型：

- **嵌套代码操作**: `roslyn.client.nestedCodeAction` - 呈现嵌套操作菜单
- **全部修复操作**: `roslyn.client.fixAllCodeAction` - 提示用户选择修复范围
- **复杂编辑完成**: `roslyn.client.completionComplexEdit` - 应用复杂编辑

### 6. Razor/CSHTML 支持 (razor/)

**虚拟 HTML 文档系统**:
- 为 Razor 文件的 HTML 部分创建虚拟 HTML 缓冲区
- 路径格式: `<original-uri>__virtual.html`

**组件职责**:
- `documentManager.lua`: 管理 Razor URI 到 HTML 文档的映射
- `htmlDocument.lua`: 创建/管理虚拟 HTML 缓冲区，通过协程路由 LSP 请求
- `handlers.lua`: 转发请求到 HTML LS 并返回结果

---

## 初始化流程

```
用户打开 .cs 文件
    ↓
plugin.lua BufEnter 自动命令触发
    ↓
vim.lsp.get_clients() 触发客户端启动
    ↓
lsp/roslyn.lua root_dir() 被调用
    ↓
sln/utils.lua 查找解决方案/项目
    ↓
on_init.lua.sln() 或 .project() 被调用
    ↓
solution/open 或 project/open 通知发送到服务器
    ↓
RoslynOnInit 用户事件触发
```

---

## 与 Roslyn LSP 服务器的通信

### 协议流程

#### 1. 初始化
- Neovim 使用配置的命令启动 Roslyn 进程
- 标准 LSP initialize/initialized 握手
- on_init 处理器确定目标（解决方案/项目）

#### 2. 自定义通知 (客户端 → 服务器)
| 通知 | 描述 |
|------|------|
| `solution/open` | 打开解决方案文件 |
| `project/open` | 打开没有解决方案的项目 |

#### 3. 自定义请求 (服务器 → 客户端)
| 请求 | 描述 |
|------|------|
| `sourceGeneratedDocument/_roslyn_getText` | 获取源代码生成文件内容 |
| `codeAction/resolve` | 解析嵌套代码操作 |
| `codeAction/resolveFixAll` | 解析"全部修复"代码操作 |
| `workspace/_roslyn_restore` | 协调项目恢复 |
| `workspace/_roslyn_projectNeedsRestore` | 服务器请求客户端恢复项目 |

#### 4. 标准 LSP 功能
- 诊断（通过 `textDocument/diagnostic` 自定义刷新）
- 悬停、跳转定义、引用、实现
- 补全、签名帮助
- 代码镜头、内联提示
- 格式化、输入时格式化
- 重命名（Razor 简化版）
- 语义标记

#### 5. Razor 协同托管
- 服务器内部托管 HTML LS
- 服务器通过 `textDocument/*` 处理器请求 HTML 功能
- Neovim 转发到真实的 HTML LS 客户端并返回结果

---

## 配置选项

### 插件配置

```lua
require("roslyn").setup({
    -- 文件监视模式
    -- "auto": 自动检测
    -- "roslyn": 使用 Roslyn 内置文件监视
    -- "off": 关闭文件监视
    filewatching = "auto",

    -- 当发现多个解决方案时的选择函数
    -- function(targets) -> target
    choose_target = nil,

    -- 过滤要忽略的解决方案
    -- function(target) -> boolean
    ignore_target = nil,

    -- 是否递归搜索解决方案（而不是只向上搜索）
    broad_search = false,

    -- 锁定到特定解决方案
    -- 使用 vim.g.roslyn_nvim_selected_solution
    lock_target = false,

    -- 抑制初始化通知
    silent = false,

    -- 启用调试日志
    debug = false,
})
```

### LSP 设置配置

通过 `vim.lsp.config("roslyn", { settings = {...} })` 配置：

| 类别 | 设置项 | 描述 |
|------|--------|------|
| 后台分析 | `dotnet_analyzer_diagnostics_scope` | 分析器诊断范围 |
| | `dotnet_compiler_diagnostics_scope` | 编译器诊断范围 |
| 代码镜头 | `dotnet_enable_references_code_lens` | 启用引用代码镜头 |
| | `dotnet_enable_tests_code_lens` | 启用测试代码镜头 |
| 补全 | `dotnet_provide_regex_completions` | 提供正则表达式补全 |
| | `dotnet_show_completion_items_from_unimported_namespaces` | 显示未导入命名空间的补全项 |
| | `dotnet_show_name_completion_suggestions` | 显示名称补全建议 |
| 内联提示 | 多个选项 | 控制各类提示的显示 |
| 符号搜索 | `dotnet_search_reference_assemblies` | 搜索引用程序集 |
| 格式化 | `dotnet_organize_imports_on_format` | 格式化时组织导入 |

---

## 特殊功能

### 1. 多解决方案支持

- 检测和管理不同解决方案的多个 LSP 客户端
- 每个客户端维护自己的 root_dir 和附加的缓冲区
- 智能重用逻辑：在可能时尝试重用现有客户端
- `:Roslyn target` 命令允许手动选择

### 2. 源代码生成文件

- 自定义协议: `roslyn-source-generated://` URI
- 通过 `sourceGeneratedDocument/_roslyn_getText` 延迟获取内容
- 将文件设为只读以防止意外编辑
- 当服务器通过 `workspace/refreshSourceGeneratedDocument` 通知时刷新

### 3. 代码操作

- **嵌套代码操作**: 多级操作层次结构
- **全部修复**: 用户选择范围的参数化"全部修复"操作
- **复杂编辑**: 带有括号自动清理的特殊补全编辑

### 4. Razor/CSHTML 支持

- 使用 Roslyn 内置的 Razor 扩展
- 协同托管的 HTML 语言服务器
- 每个 Razor 文件的虚拟 HTML 文档缓冲区
- HTML 特定功能（悬停、补全）通过 HTML LS 转发

### 5. 诊断刷新

- 在 `BufWritePost` 和 `InsertLeave` 时手动刷新
- 通过 `textDocument/diagnostic` 请求新诊断

### 6. 解决方案锁定

- `lock_target` 选项将客户端固定到特定解决方案
- 存储在 `vim.g.roslyn_nvim_selected_solution`
- 适用于一致的多解决方案设置

---

## 测试结构

### 测试框架

使用 Busted（Lua 测试框架）配合 nvim-test 辅助工具。

### 测试文件

| 文件 | 描述 |
|------|------|
| `api_spec.lua` | 解决方案/项目解析测试 |
| `predict_spec.lua` | 目标预测测试 |
| `lsp_integration_spec.lua` | 完整 LSP 集成测试（24 个测试） |

### 测试工具

- **helpers.lua**: 扩展 nvim-test 的工具
  - `create_file()`, `create_sln_file()`, `create_slnf_file()`, `create_slnx_file()`
  - 临时目录管理
- **mock_server.lua**: 最小化的模拟 Roslyn 服务器
  - 捕获通知/请求
  - 可在测试之间重置

---

## 关键数据流

### 代码操作流程

```
用户运行 :Roslyn target 或 vim.lsp.buf.code_action()
    ↓
LSP 返回带有 roslyn.client.* 命令的代码操作
    ↓
lsp/commands.lua 处理器被调用
    ↓
如果是嵌套: 呈现菜单 → 用户选择 → codeAction/resolve
如果是全部修复: 呈现选项 → 用户选择 → codeAction/resolveFixAll
    ↓
通过 vim.lsp.util.apply_workspace_edit() 应用编辑
```

### Razor 请求流程

```
用户在 .razor 文件中悬停/补全
    ↓
Roslyn 服务器接收请求
    ↓
Roslyn 发送 textDocument/hover（或其他）处理器请求
    ↓
lsp/handlers.lua forward() 被调用
    ↓
razor/handlers.lua.forward() 被调用
    ↓
documentManager 获取虚拟 HTML 文档
    ↓
htmlDocument.lspRequest() 通过 HTML LS 客户端（在协程中）
    ↓
结果返回给 Roslyn
    ↓
Roslyn 返回给 Neovim
```

---

## 设计模式与决策

1. **延迟初始化**: Razor 扩展和 HTML LS 在运行时检测
2. **基于协程的转发**: HTML 请求使用 Lua 协程进行异步处理
3. **事件系统**: 使用 roslyn_emitter 进行服务器生命周期管理
4. **状态存储**: 客户端 ID → 解决方案映射在单独模块中维护
5. **优雅降级**: 多解决方案检测 → csproj 回退 → 错误消息
6. **广泛搜索优化**: 忽略 obj/、bin/、.git/ 以防止误匹配
7. **校验和验证**: 虚拟 HTML 文档跟踪校验和以检测过期状态
8. **跨平台路径处理**: 将 Windows 反斜杠规范化为正斜杠

---

## 用户命令

| 命令 | 描述 |
|------|------|
| `:Roslyn target` | 选择目标解决方案 |
| `:Roslyn restart` | 重启 LSP 服务器 |
| `:Roslyn stop` | 停止 LSP 服务器 |

---

## 用户事件

| 事件 | 触发时机 |
|------|----------|
| `RoslynOnInit` | 解决方案/项目打开后 |
| `RoslynInitialized` | 项目初始化完成后 |

---

*文档生成日期: 2026-02-03*
