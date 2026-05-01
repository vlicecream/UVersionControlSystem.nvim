# UVersionControlSystem.nvim

Unreal Engine version-control companion for Neovim.

[English](#english) | [中文](#中文)

---

## English

`UVersionControlSystem.nvim` is the VCS layer in the U-series stack.

It focuses on:

- Perforce workspace detection
- checkout / add / revert
- readonly save prompts
- dashboard for local files and pending changelists
- visual commit UI

The top-level command surface stays intentionally small. Changelists, diffs, submit flow, and shelf-adjacent workflow live inside the dashboard and commit UI rather than as extra public commands.

### Features

- detect Unreal project roots and matching P4 workspace
- prompt on readonly save and offer `p4 edit`
- `:UVCS checkout`, `:UVCS add`, `:UVCS revert`, `:UVCS commit`
- dashboard for opened files, local candidates, and pending changelists
- commit window with file selection, message editing, diff, revert, and submit

### Requirements

- Neovim 0.10+
- `p4` command-line client
- An Unreal project with a `.uproject` file

### Installation

#### Recommended Stack

```lua
return {
  {
    "vlicecream/UTreeSitter.nvim",
    main = "utreesitter",
    lazy = false,
    dependencies = {
      {
        "nvim-treesitter/nvim-treesitter",
        build = ":TSUpdate",
        opts = function(_, opts)
          opts = opts or {}
          opts.auto_install = true
          opts.indent = { enable = true }
          return opts
        end,
      },
    },
    opts = {},
  },

  {
    "vlicecream/UVersionControlSystem.nvim",
    main = "uvcs",
    lazy = false,
    opts = {
      enable = true,
      prompt_on_readonly_save = true,
      provider = "auto",
      p4 = {
        command = "p4",
        -- port = "127.0.0.1:1666",
        -- user = "YourUser",
        -- client = "YourWorkspace",
      },
    },
  },

  {
    "vlicecream/UCore.nvim",
    main = "ucore",
    lazy = false,
    build = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1",
    dependencies = {
      {
        "windwp/nvim-autopairs",
        event = "InsertEnter",
        opts = {},
      },

      {
        "saghen/blink.cmp",
        opts = function(_, opts)
          opts.sources = opts.sources or {}
          opts.sources.default = opts.sources.default or { "lsp", "path", "snippets", "buffer" }

          if not vim.tbl_contains(opts.sources.default, "ucore") then
            table.insert(opts.sources.default, "ucore")
          end

          opts.sources.providers = opts.sources.providers or {}
          opts.sources.providers.ucore = {
            name = "UCore",
            module = "ucore.completion.blink",
            async = true,
            timeout_ms = 2000,
            min_keyword_length = 0,
            score_offset = 50,
          }

          return opts
        end,
      },

      {
        "nvim-telescope/telescope.nvim",
        dependencies = {
          "nvim-lua/plenary.nvim",
          "nvim-tree/nvim-web-devicons",
        },
      },
    },
    opts = {
      auto_boot = true,
      completion = {
        enable = true,
        keymap = "<C-l>",
      },
      ui = {
        picker = "telescope",
      },
    },
  },
}
```

#### Standalone

```lua
return {
  {
    "vlicecream/UVersionControlSystem.nvim",
    main = "uvcs",
    lazy = false,
    opts = {
      enable = true,
      prompt_on_readonly_save = true,
      provider = "auto",
      p4 = {
        command = "p4",
        -- port = "127.0.0.1:1666",
        -- user = "YourUser",
        -- client = "YourWorkspace",
      },
    },
  },
}
```

### Quick Start

Open any file inside an Unreal project and run:

```vim
:UVCS
```

This opens the dashboard.

### Commands

```vim
:UVCS
:UVCS dashboard
:UVCS checkout
:UVCS add
:UVCS revert
:UVCS commit
:UVCS debug vcs
:checkhealth uvcs
```

### Configuration

```lua
require("uvcs").setup({
  enable = true,
  prompt_on_readonly_save = true,
  provider = "auto",
  p4 = {
    command = "p4",
    env = nil,
    port = nil,
    user = nil,
    client = nil,
    charset = nil,
    config = nil,
  },
})
```

Legacy `vcs = { ... }` input is still normalized, but new configs should use the top-level `uvcs` options directly.

### Workflow Notes

- use `:UVCS` for the dashboard
- use `:UVCS commit` for the submit window
- use the dashboard UI for pending changelists and per-file actions
- readonly buffers can prompt for `p4 edit` automatically on save

### Related Repositories

```text
UTreeSitter                  grammar + queries + parser tests
UTreeSitter.nvim             Neovim parser/filetype/highlight integration
UVersionControlSystem.nvim   Unreal VCS dashboard and actions
UCore.nvim                   Unreal project index, RPC, navigation, completion
```

### License

MIT

---

## 中文

`UVersionControlSystem.nvim` 是 U 系列里的版本控制层。

它主要负责：

- Perforce 工作区检测
- checkout / add / revert
- 只读保存提示
- 本地文件和 pending changelist dashboard
- 可视化 commit 窗口

顶层命令面会保持精简。changelist、diff、submit 以及相关流程放在 dashboard 和 commit UI 里处理，不再额外扩成一堆公开命令。

### 特性

- 检测 Unreal 项目根目录和对应的 P4 工作区
- 只读保存时提示并提供 `p4 edit`
- `:UVCS checkout`、`:UVCS add`、`:UVCS revert`、`:UVCS commit`
- dashboard 展示 opened 文件、本地候选文件和 pending changelist
- commit 窗口支持文件勾选、提交信息编辑、diff、revert、submit

### 依赖

- Neovim 0.10+
- `p4` 命令行客户端
- 含 `.uproject` 的 Unreal 项目

### 安装

#### 推荐组合

```lua
return {
  {
    "vlicecream/UTreeSitter.nvim",
    main = "utreesitter",
    lazy = false,
    dependencies = {
      {
        "nvim-treesitter/nvim-treesitter",
        build = ":TSUpdate",
        opts = function(_, opts)
          opts = opts or {}
          opts.auto_install = true
          opts.indent = { enable = true }
          return opts
        end,
      },
    },
    opts = {},
  },

  {
    "vlicecream/UVersionControlSystem.nvim",
    main = "uvcs",
    lazy = false,
    opts = {
      enable = true,
      prompt_on_readonly_save = true,
      provider = "auto",
      p4 = {
        command = "p4",
        -- port = "127.0.0.1:1666",
        -- user = "YourUser",
        -- client = "YourWorkspace",
      },
    },
  },

  {
    "vlicecream/UCore.nvim",
    main = "ucore",
    lazy = false,
    build = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1",
    dependencies = {
      {
        "windwp/nvim-autopairs",
        event = "InsertEnter",
        opts = {},
      },

      {
        "saghen/blink.cmp",
        opts = function(_, opts)
          opts.sources = opts.sources or {}
          opts.sources.default = opts.sources.default or { "lsp", "path", "snippets", "buffer" }

          if not vim.tbl_contains(opts.sources.default, "ucore") then
            table.insert(opts.sources.default, "ucore")
          end

          opts.sources.providers = opts.sources.providers or {}
          opts.sources.providers.ucore = {
            name = "UCore",
            module = "ucore.completion.blink",
            async = true,
            timeout_ms = 2000,
            min_keyword_length = 0,
            score_offset = 50,
          }

          return opts
        end,
      },

      {
        "nvim-telescope/telescope.nvim",
        dependencies = {
          "nvim-lua/plenary.nvim",
          "nvim-tree/nvim-web-devicons",
        },
      },
    },
    opts = {
      auto_boot = true,
      completion = {
        enable = true,
        keymap = "<C-l>",
      },
      ui = {
        picker = "telescope",
      },
    },
  },
}
```

#### 单独使用

```lua
return {
  {
    "vlicecream/UVersionControlSystem.nvim",
    main = "uvcs",
    lazy = false,
    opts = {
      enable = true,
      prompt_on_readonly_save = true,
      provider = "auto",
      p4 = {
        command = "p4",
        -- port = "127.0.0.1:1666",
        -- user = "YourUser",
        -- client = "YourWorkspace",
      },
    },
  },
}
```

### 快速开始

在 Unreal 项目里打开任意文件后运行：

```vim
:UVCS
```

这会打开 dashboard。

### 命令

```vim
:UVCS
:UVCS dashboard
:UVCS checkout
:UVCS add
:UVCS revert
:UVCS commit
:UVCS debug vcs
:checkhealth uvcs
```

### 配置

```lua
require("uvcs").setup({
  enable = true,
  prompt_on_readonly_save = true,
  provider = "auto",
  p4 = {
    command = "p4",
    env = nil,
    port = nil,
    user = nil,
    client = nil,
    charset = nil,
    config = nil,
  },
})
```

旧的 `vcs = { ... }` 输入仍然会被兼容处理，但新配置建议直接写顶层 `uvcs` 选项。

### 工作流说明

- 用 `:UVCS` 打开 dashboard
- 用 `:UVCS commit` 打开提交流程窗口
- pending changelist 和逐文件操作放在 dashboard UI 里处理
- 只读 buffer 保存时可以自动提示 `p4 edit`

### 相关仓库

```text
UTreeSitter                  grammar + queries + parser tests
UTreeSitter.nvim             Neovim parser/filetype/highlight integration
UVersionControlSystem.nvim   Unreal VCS dashboard and actions
UCore.nvim                   Unreal project index, RPC, navigation, completion
```

### 许可

MIT
