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
---@field show_icons      boolean  Show file/directory icons in the finder lists (both backends)
---@field grep_multiline  integer|boolean The fzf grep result layout: 1 = 2-row, 2 = 2-row + gap, false/0 = 1-row
---@field title_pos       "left"|"center"|"right"  Finder-title alignment — every layout the same (default "center")
---@field statusline      boolean  Publish the finder title + counter + query to the bottom statusline
---@field stream_slice_ms integer  Main-thread time budget (ms) of one paced stream-ingest slice (see spawn_stream)
---@field grep_max        integer  Hard cap on collected ripgrep matches per tint grep (bounds memory; kills rg at the cap)
---@field preview_debounce_ms integer  Settle time (ms) before the SYNC preview updates while scrolling (file previews are async, no debounce)
---@field preview_cache      integer  How many recently previewed files the async file-preview LRU cache keeps (instant re-visits)
---@field preview_max_lines  integer  Hard cap on lines materialised per async file preview (bounds a deep match in a huge file)
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

    -- An OPTIONAL local cap on the finder's visible rows. nil (the default) = follow the ONE central authority:
    -- the panel content-fits and grows to `lvim-utils config.dock.geometry.<layout>.height` (`height_auto`),
    -- exactly like every other lvim-tech panel. Set a number only to make THIS plugin's lists deliberately
    -- shorter than the dock allows; a per-call `opts.max_rows` overrides it.
    max_rows = nil,

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

    -- (tint list) DEBOUNCE the query match, in ms. The match itself is now NON-BLOCKING (lvim-fuzzy runs it
    -- in slices across event-loop ticks and supersedes an in-flight one when you type on), so 0 = start a
    -- fresh match on every keystroke is smooth even over millions of candidates. Raise it only to throttle
    -- how often a match STARTS (fewer starts on very fast typing). Does not affect the fzf-TUI backend.
    debounce_ms = 0,

    -- (streamed finders — files / directories …) how often, in ms, the growing pool re-renders WHILE files are
    -- still streaming in — this drives the live RESULT COUNT + the shown rows, so it must be small enough that
    -- the counter ticks up smoothly (fzf-like), not in visible jumps. The parallel match (ABI 4) ranks even a
    -- ~2M pool in tens of ms, so a fresh match every ~50 ms comfortably completes between refreshes; an empty
    -- query (just watching the tree load) re-renders even more cheaply (first-K, no match). Raise it only if a
    -- match at your tree size is slower than this interval (older single-threaded .so) so re-matches don't pile.
    stream_refresh_ms = 50,

    -- (streamed finders) the main-thread time budget, in ms, of ONE ingest slice while a listing streams in.
    -- A fast producer (fd lists ~2M files in under a second) far outpaces what the editor can ingest per event-
    -- loop pass, so stdout is queued and drained in slices of this many ms — measured around the real per-row
    -- ingest work — with a short yield to the loop between slices (input/redraw run there). Small = smoother
    -- but a longer total load; large = faster load but visible per-slice stutter (a slice IS a main-thread
    -- block). ~4 ms keeps every slice well under a frame while a ~2M-file tree still loads in seconds.
    stream_slice_ms = 4,

    -- (tint list, streamed finders) how many candidates to marshal into the native matcher per slice. Feeding
    -- a streamed pool into the engine is O(pool) Lua↔C work; doing it all at once blocks the UI (50–80 ms at
    -- millions of paths), so it is fed in `marshal_cap`-sized slices across event-loop ticks (a background
    -- timer catches the native context up to the pool). ~32k ≈ a 5–8 ms slice — the per-tick block. Lower for
    -- smoother feeding on very large trees (more ticks); raise to catch up in fewer, larger (blockier) slices.
    marshal_cap = 32768,

    -- (tint grep — live AND fixed-query) the NATIVE-BLOB STORE CEILING: how many ripgrep matches the tint grep
    -- HOLDS in the native matcher (Variant B — it keeps EVERY match like fzf keeps them in its own process, so
    -- there is NO browse cap and the counter climbs to the REAL total). rg streams into the blob paced +
    -- bounded: up to this many matches are STORED and browsable; a broader-than-this query is still fully
    -- COUNTED (the count keeps climbing to the true total) but the overflow bytes are DISCARDED in the read
    -- callback — never buffered into the editor heap → no `E41: out of memory`, ~0% main-thread block. So this
    -- is a HIGH pathological-query safety ceiling, not a normal limit: set it above your broadest real query
    -- (e.g. `hel` over `~/` ≈ 403k matches ≈ 32 MB native) so you practically never hit it. Native memory is
    -- ~80 bytes/match. Only ≤`fuzzy.max_results` rows are ever materialised in Lua regardless. (Does not affect
    -- the fzf-TUI grep — fzf owns its own result set. On an ABI < 5 library the tint grep falls back to a
    -- bounded stream that KILLS rg at this cap, the pre-Variant-B behaviour.)
    grep_max = 500000,

    -- (tint grep) CAP on the length (bytes) of each ripgrep result line — rg's own `--max-columns`, with
    -- `--max-columns-preview` so a too-long line is TRUNCATED (still shown) rather than omitted. A broad content
    -- search over a huge tree hits minified bundles / caches / logs whose single line is MEGABYTES, and
    -- `--vimgrep` prints the WHOLE matched line, so WITHOUT this cap even a few hundred k matches buffer
    -- gigabytes into the native blob (measured: "hel" over `~/` ≈ 15 GB) and one giant append blocks the UI.
    -- Capped, the same grep holds ~32 MB and never stalls. A grep row is never wider than the panel anyway, so
    -- 512 is ample; raise it if you need to fuzzy-filter on text past that column. 0 disables the cap.
    grep_max_columns = 512,

    -- (tint list — SYNC in-memory previews: lsp / diagnostics / the editable file preview) settle time, in ms,
    -- before the preview updates while SCROLLING results. Their preview is cheap but a per-move relayout is
    -- wasteful, so it is debounced to the settle. The FILE previews (files / grep) are read ASYNC (off the main
    -- thread, LRU-cached) and FOLLOW the cursor on every move, so they do NOT use this. Confirm always opens the
    -- focused row regardless of whether the preview has caught up. 0 = update every move.
    preview_debounce_ms = 60,

    -- (tint FILE previews — files / grep) how many recently previewed files to keep in the async preview's LRU
    -- cache. Re-visiting a cached file (scrolling within one grep file, or scrolling back) is INSTANT; a miss is
    -- read off the main thread. Higher = more instant re-visits at more memory (each entry is the file's first
    -- `preview_max_lines` lines).
    preview_cache = 32,

    -- (tint FILE previews) hard cap on the number of lines materialised per preview. The async read stops here,
    -- so a match DEEP in a huge file (a minified bundle, a log) never sets tens of thousands of lines on the
    -- main thread — the preview shows the file up to this line (the focus clamps). Comfortably covers normal
    -- source files; raise it if you routinely preview matches past this line in large files.
    preview_max_lines = 2000,

    -- (fzf finders) ALL terminal keys — every one configurable. Editor-side keys (preview scroll, park,
    -- quickfix) are handled by Neovim; the rest pass straight to fzf with its own bindings. The fzf-internal
    -- actions (mark, quickfix-accept) also get the matching fzf `--bind` / `--expect` wiring automatically.
    -- A value may be a single key or a LIST of keys (all bound to that action). "" / {} disables an action.
    keys = {
        -- (NORMAL mode only — while you type, the query owns the keyboard) the keymap CHEATSHEET, built from
        -- THIS table, so a rebind shows up in it. Also a `help` chip on the finder's footer bar.
        help = "g?",
        accept = "<CR>", -- open / confirm the focused item
        mark = "<Tab>", -- toggle the focused row's mark (multi-select)
        quickfix = "<C-q>", -- send every marked row (or the focused one) to the quickfix list, then close
        -- (LIVE tint grep) toggle GREP ⇄ FILTER mode: GREP mode = the typed query drives ripgrep (live search);
        -- FILTER mode = ripgrep is FROZEN at the current results and the typed query fuzzy-filters that loaded
        -- set (no re-grep). Bound in both the query input and the normal-mode list; no-op outside the live grep.
        grep_filter = "<C-g>",
        -- SWAP the current finder's backend: the tint list ⇄ the fzf-TUI (only for the command-driven finders
        -- that have both — files / grep / buffers / directories / git_files). Reopens the same finder in the
        -- other backend in place; the query is not carried (retype). Bound ONLY inside the picker. A single
        -- TOGGLE key (there are only two backends). NOTE: `<C-[>` is the terminal code for <Esc>, so it can't be
        -- used here (it would shadow Esc/abort) — pick a non-Esc chord if you rebind.
        swap_backend = { "<C-]>" },
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
    -- Show file/directory icons in the finder lists (both backends); false = plain text rows.
    show_icons = true,
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
            { "help" }, -- the cheatsheet (normal mode only — `g?` would type into the query in insert)
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

    -- The finder TITLE's alignment ("left" | "center" | "right") — layout-independent (float / area / bottom
    -- all the same), applied to the title row band and the native border-title alike. The title TEXT itself
    -- stays dynamic per finder (Files / Grep / …). A per-call `opts.title_pos` overrides this global.
    title_pos = "center",

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
        -- (live grep only) the badge shown while <C-g> FILTER mode is active (rg frozen, the query fuzzy-filters
        -- the loaded results) — so the search bar itself signals the mode, not just the title. Same spacing.
        filter_icon = "󰈲", -- nf-md-filter
        filter_label = "Filter",
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
