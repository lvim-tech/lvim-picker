-- lvim-picker.config: shared config for the finder — applies to EVERY finder (files / grep / buffers / …)
-- so they share one look. EVERYTHING visual is configurable here: the prompt badge content and a `hl`
-- table mapping every element to a highlight group (all overridable). setup() merges user opts in place;
-- readers do `require("lvim-picker.config")`.
--
---@module "lvim-picker.config"

---@class LvimPickerDock
---@field dock_stack      boolean  Managed dock-STACK consumer (cyclable, one-visible-per-layout) vs geometry-only standalone
---@field force           table    Per-layout ANCHORED geometry overrides ({ float, area, bottom }) deep-merged over the central dock geometry

---@class LvimPickerConfig
---@field layout          string   Default layout for every finder: "area" | "float" | "bottom"
---@field dock            LvimPickerDock  This plugin's OWN docking defaults (namespaced): dock_stack + per-layout force geometry
---@field fzf_tui         boolean  Use the real fzf TUI for heavy command-driven finders (false = the Lua tint list)
---@field keys            table    All finder keys (accept / mark / quickfix / preview scroll / park / abort / nav)
---@field marker          string   The mark indicator glyph drawn before a marked row (multi-select)
---@field grep_multiline  integer|boolean The fzf grep result layout: 1 = 2-row, 2 = 2-row + gap, false/0 = 1-row
---@field statusline      boolean  Publish the finder title + counter + query to the bottom statusline
---@field source          table    files/directories listing engine + what it ignores (engine / exclude / hidden / …)
---@field icons           table    Shared glyphs used by source helpers
---@field icon_provider    "auto"|"lvim"|"devicons"|"mini"  Which plugin supplies file icons (via lvim-utils.icons)
---@field icon_color_mode  string?  lvim-icons colour mode for file icons: "theme"|"brand"|"theme_brand"; nil = the lvim-icons global default
---@field prompt          table    The prompt badge before the query (icon / label / spacing pads)
---@field caret           table    The input caret (hl group + guicursor shape)
---@field hl              table    Highlight groups for every finder element (all overridable)
---@field preview         table    The preview winbar (devicon toggle + path pads)
---@field empty_text      string   Text shown when there are no results
---@field empty_preview   string   The preview placeholder text when nothing is focused
---@field list_wrap       boolean  Soft-wrap the list rows instead of truncating long matches

---@type LvimPickerConfig
return {
    -- The DEFAULT layout for every finder when a call (or `:LvimPicker <finder>`) gives no explicit one:
    -- "area" (the cmdheight/msgarea zone — the modern default) | "float" (a centred float) | "bottom" (a
    -- bottom dock). A per-call `opts.layout` (or a `:LvimPicker <finder> <layout>` arg) overrides it.
    layout = "area",

    -- This plugin's OWN docking defaults, NAMESPACED under `dock` (matching lvim-dependencies'
    -- `config.dock.dock_stack` / `config.dock.force`). Per-call `opts.dock_stack` / `opts.force`
    -- still override these for a single open.
    dock = {
        -- true = full dock-STACK consumer (managed: cyclable <Leader>n/p/x/m, :LvimDock,
        -- one-visible-per-layout, no overlap); false = geometry-only (central dock.slot size/
        -- backdrop, opens standalone, NOT in the stack). A per-call `opts.dock_stack` overrides this.
        dock_stack = true,
        -- Per-plugin per-layout ANCHORED geometry overrides, deep-merged per field OVER the global
        -- `lvim-utils.config.dock.geometry.<layout>`; empty {} = inherit the global unchanged. Each
        -- layout may carry: height, height_auto, backdrop = { enabled, mode, dim = { amount },
        -- darken = { amount } }, auto_hide, keep_focus. FLOAT ALSO: width, width_auto. area/bottom
        -- are ALWAYS full-width — NO width/width_auto (ignored if set). A per-call `opts.force` overrides this.
        force = { float = {}, area = {}, bottom = {} },
    },

    -- RENDERER for the heavy, command-driven finders (files / grep / git_files / directories / buffers):
    -- `true` (default) = the real fzf TUI runs inside the finder's list panel (fzf — in C — owns parsing,
    -- matching, ranking AND rendering, so it stays instant and updates CONTINUOUSLY while you type even over
    -- huge trees like ~/ with millions of files); `false` = the Lua tint-striped list (the lvim look, but it
    -- materialises + renders candidates itself, so it is slower at extreme scale). The preview stays a real
    -- Neovim window either way. The STRUCTURED finders (lsp locations / diagnostics / marks / …) always use
    -- the tint list — their data is small and in-memory, so the fzf TUI buys nothing there. Needs `fzf` +
    -- `mkfifo` on PATH; falls back to the tint list automatically when missing.
    fzf_tui = true,

    -- (fzf finders) ALL terminal keys — every one configurable. Editor-side keys (preview scroll, park,
    -- quickfix) are handled by Neovim; the rest pass straight to fzf with its own bindings. The fzf-internal
    -- actions (mark, quickfix-accept) also get the matching fzf `--bind` / `--expect` wiring automatically.
    -- A value may be a single key or a LIST of keys (all bound to that action). "" / {} disables an action.
    keys = {
        accept = "<CR>", -- open / confirm the focused item
        mark = "<Tab>", -- toggle the focused row's mark (multi-select)
        quickfix = "<C-q>", -- send every marked row (or the focused one) to the quickfix list, then close
        preview_down = "<C-d>", -- scroll the preview down
        preview_up = "<C-u>", -- scroll the preview up
        -- PARK: a focus toggle that keeps the finder OPEN. In fzf's input it focuses the editor (the real
        -- buffer) without closing; in the editor (parked) it returns to fzf's input exactly where you left.
        park = "<C-o>",
        abort = { "<Esc>", "<C-c>" }, -- cancel the finder
        nav = { "<C-j>", "<C-k>", "<C-n>", "<C-p>" }, -- passed through to fzf's own up/down navigation
        -- OPEN-METHOD keys: how the focused item opens. Each method has a NORMAL key (`n`, plain — the fzf list
        -- is in normal mode, so bare letters are safe) and an INSERT key (`i`, a Ctrl chord — plain keys type
        -- into the query). Routed through fzf `--expect`; the consumer's `on_confirm` opens the item in the
        -- window the method prepared. In an area/bottom dock the finder STAYS open afterwards (restarted in place,
        -- no flicker) per the central `lvim-utils.config.dock.geometry.<layout>.auto_hide` / `keep_focus`.
        open_methods = {
            edit = { n = "<CR>", i = "<C-CR>" }, -- the window the picker was opened from
            vsplit = { n = "v", i = "<C-v>" }, -- a vertical split
            hsplit = { n = "x", i = "<C-x>" }, -- a horizontal split (x / <C-x> — <C-h> is Backspace in a terminal)
        },
    },

    -- The MARK indicator drawn in the one blank column in front of a marked row (multi-select), in red — both
    -- backends. The canonical pointer glyph `➤` (U+27A4) reads cleanly in that single space.
    marker = "➤",
    -- Which icon plugin supplies file glyphs (both backends), resolved through lvim-utils.icons:
    -- "auto" prefers lvim-icons, then nvim-web-devicons, then mini.icons, else no icons.
    icon_provider = "auto",
    -- lvim-icons colour mode for file icons (ignored by devicons/mini): "theme" follows the
    -- colorscheme, "brand" the real brand hue, "theme_brand" a mix. nil = lvim-icons' own default.
    icon_color_mode = nil,
    icons = {
        directory = "󰉋",
    },

    -- The glyph that DIVIDES footer button GROUPS (open-methods · list-actions · frame-nav). Its colour is the
    -- `LvimUiFooterSep` highlight; the glyph itself is configurable here (a footer DIVIDER dot — distinct from
    -- the `➤` active-marker canon).
    footer_separator = "●",

    -- The FOOTER button list, DECLARED PER MODE (`insert` while typing the query · `normal` after <Esc> on the
    -- list) — each is GROUPS of action IDs (a `●` divides the groups). An id resolves to its {key, name} for THAT
    -- mode: picker-OWN ids from the picker's action registry (open / vsplit / hsplit / move / mark / qf / close /
    -- preview / buffer — labels track `keys` above); CORE ids (sectors / panel / preview_rotate / select) from the
    -- chassis (`surface.CORE_FOOTER`). The bar re-renders on every mode switch, so it always reflects reality.
    -- Edit freely to reorder / hide / regroup — purely DISPLAY (the keys stay bound regardless).
    footer = {
        insert = {
            { "open", "vsplit", "hsplit" },
            { "move", "mark", "qf", "close", "preview", "buffer" },
        },
        normal = {
            { "open", "vsplit", "hsplit" },
            { "move", "mark", "qf", "close", "preview" },
            { "sectors" }, -- core frame-nav (C-j/C-k step sectors in normal; in insert they are fzf's list nav)
        },
    },

    -- (fzf grep) MULTILINE grep entries — the fzf-lua "2-line" result layout: each match is shown as a
    -- LOCATION row (`<icon> path:lnum:col`) with the matched TEXT indented on a second row beneath it, so a
    -- long line + its path are both readable. `1` (default) = 2 rows, no gap between matches; `2` = 2 rows
    -- plus a blank gap row between matches; `false` / `0` = the classic single-row `path:lnum:col:text`.
    -- Needs fzf >= 0.53 (uses `--read0` / `--print0` / `--gap`); silently falls back to the 1-row layout on
    -- older fzf. Only the fzf-TUI grep backend honours this; the tint/Lua grep list is always single-row.
    grep_multiline = 1,

    -- Publish the finder's title + match counter + query to the bottom statusline (lvim-hud.overlay) for
    -- EVERY docked finder (area/bottom) — diagnostics, buffers, any plugin's picker. false = each finder draws
    -- the title/counter IN its own navigator instead. A per-call `opts.statusline` overrides this global.
    statusline = true,

    -- How the `files` / `directories` finders LIST entries — the engine and what it ignores, so the picker
    -- matches your fd / rg / fzf-lua setup. (The `grep` finder is ripgrep-only and uses its own command.)
    source = {
        -- The listing tool. "auto" = the first available (fd → fdfind → rg → find); or force one of
        -- "fd" | "fdfind" | "rg" | "find". `rg` lists files only (directories fall back to fd/find).
        engine = "auto",
        -- Directory / file names to EXCLUDE entirely (e.g. ".git", ".jj", "node_modules"). Defaults match
        -- fzf-lua (the `.git` + `.jj` VCS dirs).
        exclude = { ".git", ".jj" },
        -- Include dotfiles / dot-directories (fd / rg `--hidden`).
        hidden = true,
        -- Follow symbolic links (fd / rg `--follow`).
        follow = false,
        -- Honour `.gitignore` / `.ignore` / `.fdignore` (the tool default). false = list ignored files too
        -- (fd / rg `--no-ignore`). `find` has no ignore-file support and always lists everything but `exclude`.
        respect_gitignore = true,
        -- Entry types the FILES finder lists (fd `--type`): "f" = files, "l" = symlinks, "x" = executable, …
        -- Defaults to files + symlinks, like fzf-lua. (Ignored by rg / find, which list regular files.)
        file_types = { "f", "l" },
    },

    -- The PROMPT badge shown before the typed query: an icon and/or label (either may be "" — icon only /
    -- text only / icon + text). A per-call `opts.prompt` string overrides it.
    prompt = {
        icon = "➤", -- the leading glyph (the canon pointer; set your own nf glyph via setup, or "" for none)
        label = "", -- optional text after the icon (e.g. "Search"); "" for none
        -- Spacing around the badge (all configurable): `pad_left` before the icon, `icon_gap` between the
        -- icon and the label (only when both are present), `pad_right` after the icon/label (all on the
        -- badge's strong tint), `input_gap` between the badge and the typed text (on the input's light tint).
        pad_left = 1,
        icon_gap = 1,
        pad_right = 1,
        input_gap = 1,
    },

    -- The INPUT CARET — the cursor in the typed-query field, shared by EVERY finder (the fzf-TUI ones and the
    -- tint/lsp ones). `hl` is the highlight group for its COLOUR (the group's `fg` is the bar colour); `shape`
    -- is a `guicursor` shape spec: "ver25" (a 25%-wide vertical bar — the default thin blue line) | "block" |
    -- "hor20" | … The typed TEXT colour is the `hl.input` group's `fg` (below) — change it there.
    caret = {
        hl = "LvimUiPickerCursor",
        shape = "ver25",
    },

    -- Highlight groups for EVERY element — all overridable (and shared by all finders). Swap any to restyle
    -- the whole finder. The INPUT text colour is `input` (its fg); the caret colour is `caret.hl` above.
    hl = {
        prompt = "LvimUiPickerPrompt", -- the icon + label badge (default: blue tint 0.3, bold)
        input = "LvimUiPickerInput", -- the typed-text area (default: blue tint 0.1)
        marker = "LvimUiPickerMarker", -- the multi-select mark dot (default: red)
        -- list rows (tint canon — odd blue / even yellow stripes, the selected row a STRONG tint)
        row_odd = "LvimUiMsgAreaRowOdd",
        row_even = "LvimUiMsgAreaRowEven",
        sel_odd = "LvimUiMsgAreaSelOdd",
        sel_even = "LvimUiMsgAreaSelEven",
        match = "LvimUiMsgAreaMatch", -- the fuzzy-matched characters
        -- panel winbars (the lvim-lsp peek look)
        list_title = "LvimUiPeekTitle", -- the list title (single-panel layout)
        list_count = "LvimUiPeekCount", -- the result count
        preview_file = "LvimUiPeekFile", -- the previewed file name
        preview_dir = "LvimUiPickerPreviewDir", -- its directory (muted fg on the winbar bg)
        bar = "LvimUiPeekFileBar", -- the winbar fill / blank prompt row
    },

    -- The preview winbar (the file title bar on the preview panel).
    preview = {
        show_icon = true, -- show the file's devicon before the name (needs nvim-web-devicons)
        dir_pad_left = 1, -- spaces before the path
        dir_pad_right = 1, -- spaces after the path
    },

    -- Shown when there are NO results — in the list body AND in the preview's winbar (where the file name
    -- would be). A per-call `opts.empty_text` overrides it.
    empty_text = "[no matches]",

    -- The PREVIEW placeholder text — the styled "nothing to preview" bar (LvimUiPeekEmpty) shown when nothing
    -- is focused. Identical across all backends. A per-call `opts.empty_preview` overrides it.
    empty_preview = "Nothing to preview",

    -- Soft-wrap the LIST rows (no "↳" continuation marker) so a match far to the right of a long row stays
    -- visible instead of being truncated off-screen. A per-call `opts.list_wrap` overrides it.
    list_wrap = false,
}
