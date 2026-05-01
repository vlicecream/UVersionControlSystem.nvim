# UVersionControlSystem.nvim

Unreal Engine VCS companion for Neovim.

[English](#english) | [中文](#中文)

---

## English

`UVersionControlSystem.nvim` owns the Unreal-facing source-control layer:

- Perforce workspace detection
- checkout / add / revert
- readonly edit prompts
- pending changelists and shelves
- visual dashboard and commit UI

It is designed to work standalone, or as the VCS companion for `UCore.nvim`.

### Requirements

- Neovim 0.10+
- `p4` command-line client
- An Unreal project with a `.uproject` file

### Installation

```lua
return {
  {
    "vlicecream/UVersionControlSystem.nvim",
    lazy = false,
    opts = {
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

With `UCore.nvim`:

```lua
return {
  {
    "vlicecream/UCore.nvim",
    lazy = false,
    build = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1",
    dependencies = {
      { "vlicecream/UVersionControlSystem.nvim", lazy = false, opts = {} },
      { "vlicecream/UTreeSitter.nvim", lazy = false, dependencies = { "nvim-treesitter/nvim-treesitter" }, opts = {} },
    },
    config = function()
      require("ucore").setup({
        auto_boot = true,
        ui = { picker = "telescope" },
      })
    end,
  },
}
```

### Commands

```vim
:UVCS                    " Open dashboard
:UVCS dashboard          " Open dashboard
:UVCS checkout           " p4 edit current file
:UVCS add                " p4 add current file
:UVCS revert             " p4 revert current file
:UVCS commit             " Open visual commit UI
:UVCS debug vcs          " Print diagnostics
:checkhealth uvcs        " Environment diagnostics
```

The user-facing command surface stays intentionally small. Changelists and shelves are handled inside the dashboard UI rather than through extra top-level commands.

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

## 中文

`UVersionControlSystem.nvim` 负责 Unreal 项目里的版本控制层：

- Perforce 工作区检测
- checkout / add / revert
- 只读文件编辑提示
- pending changelist / shelf
- 可视化 dashboard 和 commit UI

它可以单独使用，也可以作为 `UCore.nvim` 的 VCS 配套插件。

### 依赖

- Neovim 0.10+
- `p4` 命令行客户端
- 含 `.uproject` 的 Unreal 项目

### 安装

```lua
return {
  {
    "vlicecream/UVersionControlSystem.nvim",
    lazy = false,
    opts = {
      p4 = {
        command = "p4",
      },
    },
  },
}
```

配合 `UCore.nvim`：

```lua
return {
  {
    "vlicecream/UCore.nvim",
    lazy = false,
    build = "pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1",
    dependencies = {
      { "vlicecream/UVersionControlSystem.nvim", lazy = false, opts = {} },
      { "vlicecream/UTreeSitter.nvim", lazy = false, dependencies = { "nvim-treesitter/nvim-treesitter" }, opts = {} },
    },
    config = function()
      require("ucore").setup({
        auto_boot = true,
        ui = { picker = "telescope" },
      })
    end,
  },
}
```

### 命令

```vim
:UVCS                    " 打开 dashboard
:UVCS dashboard          " 打开 dashboard
:UVCS checkout           " 对当前文件执行 p4 edit
:UVCS add                " 对当前文件执行 p4 add
:UVCS revert             " 对当前文件执行 p4 revert
:UVCS commit             " 打开可视化提交界面
:UVCS debug vcs          " 输出诊断信息
:checkhealth uvcs        " 环境诊断
```

对外命令面保持精简。changelist 和 shelf 仍然会在 dashboard 里展示和处理，但不再额外暴露成顶层命令。

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
