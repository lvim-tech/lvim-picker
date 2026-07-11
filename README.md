# lvim-picker

The fuzzy finders of the **lvim-tech** set — a unified picker (files / grep / buffers / git / LSP locations /
diagnostics / marks / …) with a real **fzf** TUI backend for the heavy command-driven finders and a Lua
tint-list backend for the structured ones, plus the shared fuzzy matching engine. Every finder shares one
look and one set of keys, and docks as a centred float, a bottom dock, or the message-zone area.

## Requirements

Requires **Neovim >= 0.12.x**, [lvim-utils](https://github.com/lvim-tech/lvim-utils),
[lvim-ui](https://github.com/lvim-tech/lvim-ui) and [lvim-fuzzy](https://github.com/lvim-tech/lvim-fuzzy)
(the shared matching engine — its optional native library makes ranking fastest, and it degrades to its own
pure-Lua matcher on its own). The fzf-TUI backend needs the `fzf` binary (and `mkfifo`);
without it the finders fall back to the Lua tint list. Optional:
[lvim-hud](https://github.com/lvim-tech/lvim-hud) (statusline title overlay) and
[lvim-msgarea](https://github.com/lvim-tech/lvim-msgarea) (the `area` dock in the message zone).

## Installation

### lvim-installer (recommended)

```vim
:LvimInstaller plugins
```

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-fuzzy" },
    { src = "https://github.com/lvim-tech/lvim-picker" },
})
require("lvim-picker").setup({})
```

## Usage

`setup()` registers `:LvimPicker <finder> [area|float|bottom]`; each finder is also a Lua function:

```vim
:LvimPicker files
:LvimPicker grep float
```

```lua
local pick = require("lvim-picker")
pick.files()
pick.grep()
pick.buffers()
pick.oldfiles()
pick.git_files()
pick.help_tags()
pick.marks()
pick.quickfix()
pick.directories()
pick.keymaps()
pick.commands()
pick.colorschemes()
```

## Dock stack

When **lvim-utils** provides the shared dock-stack manager, every opened finder KIND is an entry in the
dock stack — `files`, `grep`, `buffers` … each with the base identity `lvim-picker:<kind>`, so `:LvimPicker files`
and `:LvimPicker grep` are two distinct instances. This applies to **both** finder backends: the fzf-TUI finders
(the default `fzf_tui = true`) and the Lua tint list — the two dock through one layer. Only one is visible per
layout at a time: opening a second finder there PARKS the first (its finder spec is remembered — it stays
restorable on the stack), and re-opening a live kind rebuilds it fresh in place (no duplicate).

The dock keys every entry by **(kind, layout)**, so the same finder can be docked in more than one layout at
once — `files` in the `float` stack **and** the `bottom` stack **and** the `area` stack are three independent
entries, each with its own surface (present in multiple stacks simultaneously). Re-opening the same `(kind, layout)`
re-shows that one entry (never a duplicate in that stack); opening the same kind in a different layout is a
separate entry there.

Closing a finder the ordinary way — confirming, cancelling, `q` / `<Esc>` / `:q`, or opening another finder
over it — **parks and remembers** it: focus returns to the editor and the layout collapses, but the entry
stays on the stack (still cyclable and listed in the menu), so you can bring it back later. Only `<Leader>x`
actually kills an entry.

The dock keys (from lvim-utils.dock) apply while a finder is focused:

- `<Leader>n` / `<Leader>p` — cycle the visible finder forward / back through the current layout's stack;
- `<Leader>x` — kill the visible finder and reveal the next one on the stack;
- `<Leader>m` — a menu of every live (parked or visible) dock consumer (finders, terminal, …) across all layouts.

Without the dock manager (an older lvim-utils) the picker falls back to the classic "one finder open at a
time" behaviour — opening a finder replaces the previous one in place.

### Per-call docking (programmatic callers)

`config.dock.dock_stack` / `config.dock.force` are the picker's OWN defaults for the direct `:LvimPicker`
finders. A plugin opening a finder **through** the picker (e.g. `lvim-lsp`, `lvim-qf-loc`) can override them
**per call** on the `opts` passed to `require("lvim-picker").open(opts)` (and the built-in `files` / `grep` /
… helpers):

- `opts.dock_stack` (boolean) — override `config.dock.dock_stack` for THIS open only. `true` = managed stack
  consumer, `false` = geometry-only standalone; `nil` = inherit the config. So a caller can dock its finder
  into the stack (or keep it standalone) regardless of the picker's own default.
- `opts.force` (`{ float = {…}, area = {…}, bottom = {…} }`) — per-call anchored geometry override, same shape
  as `config.dock.force`, deep-merged over the central geometry (and winning over `config.dock.force`) for
  THIS open. `opts.height` (explicit rows) still wins over a forced height. area/bottom stay full-width
  (width ignored).

```lua
require("lvim-picker").open({
    title = "References",
    items = locations,
    on_confirm = jump,
    dock_stack = true, -- dock this finder into the shared stack for this call
    force = { area = { height = 0.4 } }, -- and force its area height to 40%
})
```

## Configuration

`setup()` merges your options into the live config in place (a nested `fuzzy` subtable merges into the fuzzy
engine's config); it is optional (the defaults below work as-is). The full default config:

```lua
require("lvim-picker").setup({
    -- Default layout for every finder: "area" (message zone) | "float" (centred) | "bottom" (dock).
    layout = "area",
    -- This plugin's OWN docking defaults, namespaced under `dock` (per-call opts.dock_stack / opts.force
    -- still override these for a single open).
    dock = {
        -- true = full dock-STACK consumer (managed: cyclable <Leader>n/p/x/m, :LvimDock, one-visible-per-layout);
        -- false = geometry-only (central size/backdrop, opens standalone, NOT in the stack). A per-call
        -- opts.dock_stack overrides this (see below).
        dock_stack = true,
        -- Per-layout ANCHORED geometry overrides, deep-merged per field OVER the global
        -- lvim-utils.config.dock.geometry.<layout>; empty {} = inherit unchanged. Each layout may carry:
        -- height, height_auto, backdrop = { enabled, mode, dim = { amount }, darken = { amount } }, auto_hide,
        -- keep_focus. float ALSO: width, width_auto. area/bottom are always full-width (width ignored). A
        -- per-call opts.force overrides this (see below).
        force = { float = {}, area = {}, bottom = {} },
    },
    -- Real fzf TUI for the heavy command-driven finders (false = the Lua tint list). Needs fzf + mkfifo.
    fzf_tui = true,
    -- All finder keys (a value is a single key or a list; "" / {} disables it).
    keys = {
        accept = "<CR>", -- open / confirm the focused item
        mark = "<Tab>", -- toggle the focused row's mark (multi-select)
        quickfix = "<C-q>", -- send marked (or focused) rows to the quickfix list, then close
        preview_down = "<C-d>", -- scroll the preview down
        preview_up = "<C-u>", -- scroll the preview up
        park = "<C-o>", -- focus the editor without closing the finder; the same key returns
        abort = { "<Esc>", "<C-c>" }, -- cancel
        nav = { "<C-j>", "<C-k>", "<C-n>", "<C-p>" }, -- passed to fzf's up/down navigation
        -- how the focused item opens: a NORMAL key (n) and an INSERT key (i) per method.
        open_methods = {
            edit = { n = "<CR>", i = "<C-CR>" }, -- the window the picker opened from
            vsplit = { n = "v", i = "<C-v>" }, -- a vertical split
            hsplit = { n = "x", i = "<C-x>" }, -- a horizontal split
        },
    },
    -- Mark indicator drawn before a marked row (multi-select).
    marker = "➤",
    -- Glyph dividing footer button groups.
    footer_separator = "●",
    -- Footer button list per mode (insert while typing · normal after <Esc>); groups of action ids.
    footer = {
        insert = {
            { "open", "vsplit", "hsplit" },
            { "move", "mark", "qf", "close", "preview", "buffer" },
        },
        normal = {
            { "open", "vsplit", "hsplit" },
            { "move", "mark", "qf", "close", "preview" },
            { "sectors" },
        },
    },
    -- fzf grep result layout: 1 = 2-row, 2 = 2-row + gap, false/0 = single-row path:lnum:col:text.
    grep_multiline = 1,
    -- Finder-title alignment: "left" | "center" | "right" — the same in every layout (float/area/bottom).
    -- The title text itself stays dynamic per finder; a per-call `opts.title_pos` overrides this.
    title_pos = "center",
    -- Publish the finder title + counter + query to the statusline (via lvim-hud) for docked finders.
    statusline = true,
    -- How `files` / `directories` list entries + what they ignore.
    source = {
        engine = "auto", -- "auto" (fd → fdfind → rg → find) | "fd" | "fdfind" | "rg" | "find"
        exclude = { ".git", ".jj" }, -- dir/file names to exclude entirely
        hidden = true, -- include dotfiles
        follow = false, -- follow symlinks
        respect_gitignore = true, -- honour .gitignore/.ignore (false = list ignored too)
        file_types = { "f", "l" }, -- entry types the files finder lists (fd --type)
    },
    -- Prompt badge before the query (either of icon/label may be "").
    prompt = {
        icon = "➤",
        label = "",
        pad_left = 1,
        icon_gap = 1,
        pad_right = 1,
        input_gap = 1,
    },
    -- Input caret: hl group (its fg = the bar colour) + a guicursor shape.
    caret = { hl = "LvimUiPickerCursor", shape = "ver25" },
    -- Highlight groups for every element (all overridable).
    hl = {
        prompt = "LvimUiPickerPrompt",
        input = "LvimUiPickerInput",
        marker = "LvimUiPickerMarker",
        row_odd = "LvimUiMsgAreaRowOdd",
        row_even = "LvimUiMsgAreaRowEven",
        sel_odd = "LvimUiMsgAreaSelOdd",
        sel_even = "LvimUiMsgAreaSelEven",
        match = "LvimUiMsgAreaMatch",
        list_title = "LvimUiPeekTitle",
        list_count = "LvimUiPeekCount",
        preview_file = "LvimUiPeekFile",
        preview_dir = "LvimUiPickerPreviewDir",
        bar = "LvimUiPeekFileBar",
    },
    -- Preview winbar (the file title bar on the preview panel).
    preview = { show_icon = true, dir_pad_left = 1, dir_pad_right = 1 },
    -- Area height per preview-stack direction (≤ 1 = fraction of the screen, > 1 = absolute rows).
    preview_heights = { horizontal = 0.33, vertical = 0.66 },
    -- Shown when there are no results (list body + preview winbar).
    empty_text = "[no matches]",
    -- The preview placeholder when nothing is focused.
    empty_preview = "Nothing to preview",
    -- Soft-wrap the list rows instead of truncating long matches.
    list_wrap = false,

    -- Result ordering + cap around the shared lvim-fuzzy engine (merged into lvim-picker.fuzzy.config).
    fuzzy = {
        sort = "score", -- ordering: "score" | a list of sort keys | a function
        max_results = 1000, -- cap on ranked results (lvim-fuzzy's own max_results also applies)
    },
})
```

## License

BSD-3-Clause.
