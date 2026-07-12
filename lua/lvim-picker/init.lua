-- lvim-picker: the native fuzzy-finder — the tint-striped Lua list backend plus the ready-made finders.
-- A native fuzzy finder built on the lvim-ui.surface chassis: a centred float with a typed query
-- INPUT band on top (a surface header input), a results LIST panel on the left and a scrollable PREVIEW
-- panel on the right — the diagnostics-peek layout, but fuzzy. The MATCHING ENGINE is lvim-fuzzy — the
-- shared native matcher of the lvim-tech set (in-process FFI; its own pure-Lua fallback when the .so is
-- absent): the candidate set is prepared once per pool (a stream-grown pool appends only its tail), each
-- keystroke is one match call, and the surface renders the result. So ranking is lvim-fuzzy's exactly while
-- WE own the view (engine vs view, like the blink integration). Highlight positions are computed locally
-- (lvim-utils.utils.match_indices — the engine emits indices+scores only), so the matched characters light
-- up in the list. The LIST is viewport-virtualized: the buffer holds only the visible window of rows, so a
-- render is O(viewport) at any scale (see the viewport block in `build`).
--
---@module "lvim-picker"

local api = vim.api
local config = require("lvim-picker.config")
local fuzzy = require("lvim-picker.fuzzy")
local utils = require("lvim-utils.utils")
local iconlib = require("lvim-utils.icons")
local ui_filters = require("lvim-ui.filters")
local preview = require("lvim-ui.preview")
-- The listing commands / preview reader / async streamer live in picker.source so BOTH backends (this tint
-- one and the fzf-TUI one) list + ignore identically (config.source). Aliased as locals to keep the
-- call sites here unchanged.
local source = require("lvim-picker.source")
local has = source.has
local file_list_cmd = source.file_list_cmd
local dir_list_cmd = source.dir_list_cmd
local read_preview = source.read_preview
local run_lines = source.run_lines
local spawn_stream = source.spawn_stream
local spawn_stream_raw = source.spawn_stream_raw

--- How many lines a location/grep preview must read to always include the FOCUS line: the default 500 cap
--- plus a screenful of context below it, so a match DEEP in a large file previews at the right spot instead of
--- clamping to line 500 (the focus is otherwise `min(lnum, 500)`).
---@param lnum integer?
---@return integer
local function preview_span(lnum)
    return math.max(500, (lnum or 0) + 200)
end

--- The fzf-TUI backend for the heavy / command-driven finders (files / grep / git_files / directories /
--- buffers), or nil when it is disabled (`config.fzf_tui == false`) or unavailable (no fzf / mkfifo).
--- When present, those finders let the real fzf TUI own the list (instant over huge trees, continuous live
--- updates); the structured finders (lsp / diagnostics / …) always use the tint-striped list below.
---@return table?
--- @param opts? table  a per-call `opts.backend = "fzf"|"tint"` FORCES the backend (used by the C-]/C-[ swap);
--- nil defers to `config.fzf_tui`.
local function fzf_backend(opts)
    local force = opts and opts.backend
    if force == "tint" then
        return nil
    end
    if force ~= "fzf" and (config or {}).fzf_tui == false then
        return nil
    end
    local ok, b = pcall(require, "lvim-picker.fzf")
    return (ok and b.available() and b) or nil
end

local M = {}

-- forward declaration: opens a finder through the fzf-TUI backend MANAGED by the dock stack (defined far
-- below, after the dock layer it depends on). `pick_items` + the command-driven finders funnel their fzf
-- branch through it, so both backends dock through the SAME layer.
local open_fzf

--- Reopen the CURRENT finder in the OTHER backend (tint ⇄ fzf) — bound to the swap keys INSIDE the picker only
--- (never global). Each command-driven finder installs an `opts.reopen(backend)` closure that re-invokes ITSELF
--- with the backend forced, capturing its ORIGINAL opts (before the per-backend spec was merged in) so no
--- backend's spec fields leak into the other's open. The reopen routes through the dock, which REPLACES the
--- live entry of that kind in place. `cur` is the backend the swap fires FROM; the query is not carried (retype).
---@param cur "tint"|"fzf"
---@param opts table
local function swap_backend(cur, opts)
    if type(opts.reopen) ~= "function" then
        vim.notify("lvim-picker: this finder has no alternate backend", vim.log.levels.INFO)
        return
    end
    opts.reopen((cur == "fzf") and "tint" or "fzf")
end

--- Install `opts.reopen(backend)` on a command-driven finder so the swap keys can re-open it in the OTHER
--- backend. Captures the finder's CLEAN opts (its key + user fields — BEFORE the per-backend spec is merged in),
--- dispatching by `opts.key` (== its `M.<kind>` entry name), so no backend's spec leaks into the other's open.
--- Call at the finder's entry, right after `opts.key`.
---@param opts table
local function with_backend_swap(opts)
    opts.reopen = opts.reopen
        or function(backend)
            local fn = opts.key and M[opts.key]
            if type(fn) == "function" then
                fn(vim.tbl_extend("force", opts, { backend = backend }))
            end
        end
end

--- Route a Lua-ITEM finder through the fzf-TUI backend when available, else the tint list — so EVERY finder
--- shares one backend (only the structured lsp/diagnostics lists stay tint). Each item is encoded as
--- `idx\ttext`; fzf shows/matches only the text (`--with-nth`), and the idx recovers the full item on
--- selection, so the finder keeps its own `preview` / `on_confirm` / `on_cancel` for BOTH backends.
---@param spec { title: string, items: table[], icon?: boolean, preview?: function, on_confirm?: function, on_cancel?: function, opts?: table }
local function pick_items(spec)
    local items = spec.items or {}
    local b = fzf_backend(spec.opts)
    if b then
        local contents = {}
        for i, it in ipairs(items) do
            -- `spec.icon` → prefix the coloured ft devicon (display only; the parse recovers the item by INDEX,
            -- so the icon never has to be stripped). Keyed on the file path when present, else the text.
            local icon = spec.icon and source.file_icon(it.path or it.text) or ""
            contents[i] = i .. "\t" .. icon .. ((it.text or ""):gsub("[\t\n]", " "))
        end
        open_fzf(
            b,
            vim.tbl_extend("force", {
                title = spec.title,
                contents = contents,
                fzf_args = { "--delimiter=\t", "--with-nth=2.." }, -- hide the leading index, show/match the text
                parse = function(line)
                    local idx = tonumber(line:match("^(%d+)\t"))
                    return (idx and items[idx]) or { text = line }
                end,
                preview = spec.preview,
                on_confirm = spec.on_confirm,
                on_cancel = spec.on_cancel,
            }, spec.opts or {})
        )
        return
    end
    M.open(vim.tbl_extend("force", {
        title = spec.title,
        items = items,
        preview = spec.preview,
        on_confirm = spec.on_confirm,
        on_cancel = spec.on_cancel,
    }, spec.opts or {}))
end

local NS = api.nvim_create_namespace("lvim-utils-picker")

--- Normalise the caller's items into `{ text, icon?, _src }`. A string item is its own text; a table item
--- uses `opts.format(item)` (or `item.text`) for the display text and keeps the original as `_src`.
---@param items any[]
---@param format? fun(item: any): string
---@return table[]
local function normalize(items, format)
    local out = {}
    for i, it in ipairs(items or {}) do
        if type(it) == "string" then
            -- collapse any embedded newlines ONCE here (not later in list_row) so the fuzzy MATCH indices and
            -- the RENDERED row are computed against the SAME single-line string — otherwise a multiline text
            -- shifts the highlighted spans.
            out[i] = { text = (it:gsub("[\r\n]+", " ")), _src = it }
        else
            local t = (format and format(it)) or it.text
            if type(t) ~= "string" then
                t = tostring(t or it)
            end
            -- NOTE: items WITHOUT an explicit `icon` get their ft devicon LAZILY, per VISIBLE row, in the
            -- list render (see the viewport loop) — never here. normalize runs over the WHOLE candidate set
            -- (~2M rows when a huge tree streams in) and the uncached devicon lookup (~3 µs/row) was over
            -- half the per-row ingest cost, for icons only a ~20-row viewport ever shows.
            out[i] = {
                text = (t:gsub("[\r\n]+", " ")),
                icon = it.icon,
                icon_hl = it.icon_hl,
                _src = it,
            }
        end
    end
    return out
end

-- Single-slot cache of the candidate `texts` array, keyed by the pool table + its length: the query changes
-- on every keystroke but the candidate set does NOT, so rebuild this (and, downstream, fzf's stdin) only when
-- the pool actually changes — appended (stream → length grows), replaced (refresh → new ref) or narrowed (a
-- filter → new ref). This keeps per-keystroke work O(1) over a huge list.
---@type { pool: table[], len: integer, texts: string[] }?
local _texts_cache
--- Filter `items` (normalised `{ text, icon?, _src }`) by `query` via the shared fuzzy engine and hand the
--- ranked GRID items (`{ text, icon, icon_hl, _src, match }`) to `cb`. Empty query = all, source order.
---@param items table[]
---@param query string
---@param cb fun(list: table[])
local function filter(items, query, cb)
    local texts
    if _texts_cache and _texts_cache.pool == items then
        texts = _texts_cache.texts
        if _texts_cache.len < #items then
            -- the SAME pool grew (stream feed) — EXTEND the cached array (O(new)) instead of rebuilding it
            -- (O(all)) on every chunk; otherwise the open freezes as the list approaches its full size.
            for i = _texts_cache.len + 1, #items do
                texts[i] = items[i].text
            end
            _texts_cache.len = #items
        elseif _texts_cache.len > #items then
            texts = nil -- shrank (not expected for a stream) — rebuild below
        end
    end
    if not texts then
        texts = {}
        for i, it in ipairs(items) do
            texts[i] = it.text
        end
        _texts_cache = { pool = items, len = #items, texts = texts }
    end
    fuzzy.filter(texts, query, function(ranked)
        local out = {}
        for i, r in ipairs(ranked) do
            local it = items[r.idx]
            out[i] = { text = it.text, icon = it.icon, icon_hl = it.icon_hl, _src = it._src, match = r.match }
        end
        cb(out)
    end)
end

--- Build a list ROW for a grid item: `<lead> icon text`, plus the BYTE spans of its matched label characters
--- and the byte length of the leading column. `marked` swaps the leading blank for the mark dot.
---@param it table
---@param marked boolean  the row is marked (multi-select) → show the mark dot in the front column
---@param dot string  the mark glyph
---@return string row, { c0: integer, c1: integer }[] match_spans, integer lead_bytes
local function list_row(it, marked, dot)
    local lead = marked and dot or " "
    local icon = (it.icon and it.icon ~= "") and (it.icon .. " ") or ""
    -- `it.text` is already single-line (collapsed in `normalize`), so the match spans below (computed on the
    -- SAME string) stay aligned with what is drawn.
    local text = it.text or ""
    local row = lead .. icon .. text
    local spans = {}
    if it.match and #it.match > 0 then
        local base = #lead + #icon -- byte offset of the label within `row`
        local nch = vim.fn.strchars(text)
        for _, ci in ipairs(it.match) do
            if ci >= 0 and ci < nch then
                -- `it.match` holds codepoint (utf-32) indices; convert each to a BYTE offset via the 0.12
                -- `str_byteindex(str, encoding, index)` signature (the old positional form is deprecated).
                spans[#spans + 1] = {
                    c0 = base + vim.str_byteindex(text, "utf-32", ci),
                    c1 = base + vim.str_byteindex(text, "utf-32", ci + 1),
                }
            end
        end
    end
    return row, spans, #lead
end

-- ─── dock-stack integration (lvim-utils.dock) ──────────────────────────────────
-- Each opened finder KIND is an entry in the shared DOCK-STACK manager, whose base identity is
-- `id = "lvim-picker:<kind>"` — so `files` ≠ `grep` ≠ `buffers` stack as distinct instances, one visible
-- at a time, cyclable with `<Leader>n`/`<Leader>p`, killable with `<Leader>x`, listed in the `<Leader>m`
-- menu. The dock keys every entry by (id, LAYOUT), so the SAME kind opened in a DIFFERENT layout is a
-- SEPARATE entry with its OWN surface: `files` can be docked in float AND bottom AND area at once (one entry
-- per stack). All open-state is therefore kept PER (kind, layout) under a composite SLOT KEY. Re-opening the
-- SAME (kind, layout) RE-SHOWS that one entry (dedup) — since a finder has no meaningful "parked query", the
-- re-show REBUILDS that kind fresh in place (still the single entry for that (kind, layout)).
--
-- ONE dock layer serves BOTH backends (the tint list here AND the fzf-TUI backend in picker/fzf.lua). A
-- (kind, layout) slot is remembered by a `rebuild` CLOSURE (`pending[sk]`) that re-materialises THAT slot's
-- surface with the backend it was opened with — the tint list (`build(opts, kind)`) or the fzf TUI
-- (`require("lvim-picker.fzf").open(fzf_opts)`). The shared `route(managed, kind, layout, meta, rebuild, slot)`
-- does the managed wiring (remember the rebuild, refresh the consumer's name / icon / anchored force slot,
-- `dock.open` — STORING the returned entry key in `entry_keys[sk]`) or, when un-managed (no manager / no key /
-- `dock_stack = false`), just calls `rebuild()` directly (the classic
-- `source.close_active` replace-in-place). The consumer's `show` runs the remembered `rebuild`, `hide` parks
-- the live surface (close it, KEEP the rebuild → restorable). A NATURAL close (confirm / cancel / q / :q, or
-- replaced) also PARKS + REMEMBERS (via `dock.parked(entry_keys[sk])`): the entry stays alive, cyclable and in
-- the `<Leader>m` menu — only `<Leader>x` (the consumer's `close`) forgets the rebuild + drops it. Whichever
-- backend built it exposes its live `state` via `live[sk]`, so the consumer's
-- `buffers` / `focus` / `is_current` work uniformly (the tint state carries `.input_buf`, the fzf state
-- `.term_buf`; both carry `.st` / `.list_pan` / `.preview_pan`).

---@type table|false|nil  cached lvim-utils.dock module (nil = unprobed, false = probed & absent)
local dock_mod = nil
--- The dock-stack manager, or nil when unavailable — then the picker docks directly, un-managed.
---@return table?
local function get_dock()
    if dock_mod == nil then
        local ok, m = pcall(require, "lvim-utils.dock")
        dock_mod = ok and m or false
    end
    return dock_mod or nil
end

-- ── per-(kind, layout) state ─────────────────────────────────────────────────
-- The dock keys every entry by (id, LAYOUT): the SAME finder KIND opened in a DIFFERENT layout is a
-- SEPARATE dock entry with its OWN surface — so `files` can be docked in float AND bottom AND area at once,
-- three live entries. Every piece of open-state is therefore kept PER (kind, layout), under a composite
-- SLOT KEY `kind .. SK_SEP .. layout` (a re-open of the SAME (kind, layout) re-uses the slot → one entry per
-- stack, never a duplicate). `id` stays the base identity ("lvim-picker:<kind>") — layout is NOT baked into it;
-- the dock composes the (id, layout) entry key and RETURNS it, which we STORE in `entry_keys[sk]` and pass
-- back to the lifecycle APIs (`parked`/`refresh_leader`/`dropped`) for THIS entry.
local SK_SEP = "\30"
--- Compose the per-(kind, layout) slot key.
---@param kind string
---@param layout string
---@return string
local function slot_key(kind, layout)
    return kind .. SK_SEP .. layout
end
---@type table<string, table>   slot key → the memoised LvimDockConsumer handle (one per (kind, layout))
local consumers = {}
---@type table<string, fun()>   slot key → the REBUILD closure that re-materialises that finder on show (either
--- backend — the tint `build` or the fzf-TUI `open`); nil = forgotten/dead (the dock's `is_alive` reads this).
local pending = {}
---@type table<string, table>   slot key → the live surface `state` while it exists (nil = parked). Either backend's
--- state; the consumer reads `.st` / `.list_pan` / `.preview_pan` + `.input_buf` (tint) or `.term_buf` (fzf).
local live = {}
---@type table<string, string>  slot key → the dock ENTRY KEY (id, layout) returned by `dock.open` — passed back
--- to the lifecycle APIs (`parked`/`refresh_leader`/`dropped`) for THIS entry (never a reconstructed key).
local entry_keys = {}

--- Human label + Nerd glyph per built-in finder kind — the entry name + the `<Leader>m` dock-menu row icon.
---@type table<string, { name: string, icon: string }>
local KIND_META = {
    files = { name = "Files", icon = "󰈔" },
    grep = { name = "Grep", icon = "󰊄" },
    grep_cword = { name = "Grep (word)", icon = "󰊄" },
    grep_cWORD = { name = "Grep (WORD)", icon = "󰊄" },
    grep_word = { name = "Grep (prompt)", icon = "󰊄" },
    grep_visual = { name = "Grep (selection)", icon = "󰊄" },
    grep_curbuf = { name = "Grep (buffer)", icon = "󰊄" },
    buffers = { name = "Buffers", icon = "󰓩" },
    directories = { name = "Directories", icon = "󰉋" },
    git_files = { name = "Git files", icon = "󰊢" },
    oldfiles = { name = "Recent", icon = "󰋚" },
    help_tags = { name = "Help", icon = "󰋖" },
    commands = { name = "Commands", icon = "󰘳" },
    keymaps = { name = "Keymaps", icon = "󰌌" },
    marks = { name = "Marks", icon = "󰃀" },
    quickfix = { name = "Quickfix", icon = "󰁨" },
    jumplist = { name = "Jumplist", icon = "󰆾" },
    colorschemes = { name = "Colorschemes", icon = "󰏘" },
}

-- forward declaration: `build` constructs the finder surface; a consumer's `show` calls it to materialise a kind
local build

--- Resolve the dock KIND key for a finder open (either backend): an explicit `opts.key` wins; else a stable
--- slug from the title; else nil (no stable identity ⇒ un-managed, so it docks directly rather than force a
--- bad key). Typed on the minimal shape both `LvimPickerOpts` and `LvimFzfOpts` satisfy.
---@param opts { key?: string, title?: string }
---@return string?
local function resolve_key(opts)
    if type(opts.key) == "string" and opts.key ~= "" then
        return opts.key
    end
    local title = opts.title
    if type(title) == "string" and title ~= "" then
        local slug = title:lower():gsub("%s+", "-"):gsub("[^%w%-_]", "")
        if slug ~= "" then
            return slug
        end
    end
    return nil
end

--- The live surface buffers of slot `sk` (input / list / preview / container) — where the dock installs its
--- buffer-local `<Leader>` owner. Empty when the slot is parked (no live surface).
---@param sk string  the (kind, layout) slot key
---@return integer[]
local function kind_buffers(sk)
    local st = live[sk]
    if not st then
        return {}
    end
    local out = {}
    local function add(b)
        if b and api.nvim_buf_is_valid(b) then
            out[#out + 1] = b
        end
    end
    add(st.input_buf) -- tint: the query INPUT band buffer
    add(st.term_buf) -- fzf: the terminal buffer hosting the fzf TUI (one of input_buf/term_buf is nil)
    add(st.list_pan and st.list_pan.buf)
    add(st.preview_pan and st.preview_pan.buf)
    add(st.st and st.st.container_buf)
    return out
end

--- Every live window of slot `sk`'s surface (container / content panels / input band) — for `is_current`.
---@param sk string  the (kind, layout) slot key
---@return integer[]
local function kind_windows(sk)
    local st = live[sk]
    if not st then
        return {}
    end
    local out = {}
    local function add(w)
        if w and w ~= -1 and api.nvim_win_is_valid(w) then
            out[#out + 1] = w
        end
    end
    local s = st.st
    if s then
        add(s.container_win)
        for _, p in ipairs(s.panels or {}) do
            add(p.win)
        end
    end
    if st.input_buf then
        add(vim.fn.bufwinid(st.input_buf))
    end
    return out
end

--- Build (once, memoised in `consumers[sk]`) + return the dock consumer for finder `kind` in `layout` —
--- backend-agnostic (the tint list or the fzf TUI). There is ONE consumer PER (kind, layout): `id` is the
--- UNCHANGED base identity (`"lvim-picker:"..kind`) — the dock composes the (id, layout) entry key — and
--- `layout` is FIXED for this slot, so opening `files` in float and `files` in bottom are two independent
--- consumers / surfaces / dock entries. `show` runs this slot's remembered `rebuild` (tearing down any surface
--- still live in this slot first, so a re-open rebuilds fresh — one entry per (kind, layout)); `hide` PARKS
--- (close the surface, KEEP the rebuild → restorable); `close` tears it down AND forgets the rebuild (dropped
--- from the stack); `is_alive` tracks whether the rebuild is still remembered.
---@param kind string
---@param layout string  "float" | "area" | "bottom" — the layout THIS consumer occupies (fixed)
---@return table  the LvimDockConsumer handle
local function get_consumer(kind, layout)
    local sk = slot_key(kind, layout)
    local c = consumers[sk]
    if c then
        return c
    end
    local id = "lvim-picker:" .. kind -- base identity, UNCHANGED across layouts — the dock keys the entry by (id, layout)
    --- Close the live surface of this slot as a DOCK-DRIVEN teardown: flag `dock_teardown` so the finder's
    --- `on_close` neither re-notifies the dock nor forgets the opts, then close it.
    local function teardown_surface()
        local st = live[sk]
        if st and st.st then
            st.dock_teardown = true
            pcall(st.st.close)
        end
    end
    c = {
        id = id,
        name = kind,
        layout = layout, -- which stack THIS entry joins (fixed for this per-(kind, layout) consumer)
        show = function()
            local rebuild = pending[sk]
            if not rebuild then
                return
            end
            teardown_surface() -- a re-open of the visible slot rebuilds fresh in place
            rebuild() -- backend-specific: the tint `build(opts, kind)` or the fzf-TUI `open(fzf_opts)`
        end,
        hide = teardown_surface, -- PARK: close the surface, KEEP the rebuild (restorable on the stack)
        close = function()
            teardown_surface()
            pending[sk] = nil -- FORGET the rebuild → is_alive false → dropped from the stack
            live[sk] = nil
            entry_keys[sk] = nil
        end,
        is_alive = function()
            return pending[sk] ~= nil
        end,
        focus = function()
            local st = live[sk]
            if not st then
                return
            end
            -- The fzf backend registers its own `dock_focus` (re-enter the fzf terminal list) via the dock
            -- hooks; the tint backend has none, so fall back to focusing its INPUT band (or the container).
            if st.dock_focus then
                pcall(st.dock_focus)
                return
            end
            local w = st.input_buf and vim.fn.bufwinid(st.input_buf) or -1
            if w == -1 and st.st and st.st.container_win and api.nvim_win_is_valid(st.st.container_win) then
                w = st.st.container_win
            end
            if w ~= -1 and api.nvim_win_is_valid(w) then
                pcall(api.nvim_set_current_win, w)
            end
        end,
        buffers = function()
            return kind_buffers(sk)
        end,
        is_current = function()
            local cur = api.nvim_get_current_win()
            for _, w in ipairs(kind_windows(sk)) do
                if w == cur then
                    return true
                end
            end
            return false
        end,
    }
    consumers[sk] = c
    return c
end

---@class LvimPickerGrepSpec
---@field live boolean  true = the typed query DRIVES rg (re-grep per keystroke); false = a one-shot fixed-query grep
---@field query? string  the fixed rg query (when `live = false`) — grepped ONCE, then the typed query fuzzy-filters the blob
---@field regex? boolean  treat the query as a regex (default false = literal `--fixed-strings`)
---@field file? string  restrict the search to this single file (the curbuf grep)
---@field min_chars? integer  minimum typed chars before a live grep runs rg (default 2 — rg over a huge tree is heavy)

---@class LvimPickerOpts
---@field items? any[]  STATIC candidates (strings, or tables — see `format`), fuzzy-filtered as you type
---@field source? fun(query: string, cb: fun(items: any[]))  a LIVE source: each query produces the results (e.g. ripgrep); use instead of `items`
---@field source_raw? boolean  the `source` cb already delivers GRID items (`{ text, _src, … }`), so skip normalising them — for a progressive source that appends into one growing list (live grep)
---@field backend? "fzf"|"tint"  PER-CALL backend force (used by the C-] swap): "fzf" = the fzf TUI, "tint" = the Lua list; nil = defer to `config.fzf_tui`
---@field reopen? fun(backend: "fzf"|"tint")  installed by `with_backend_swap` on the command finders; the C-] swap key calls it to reopen this finder in the other backend
---@field count_files? boolean  count the tree's files in the background (via the files list command) and use it as the counter's TOTAL — grep shows `matches found / total files`
---@field stream? fun(feed: fun(raw: any[]), done: fun()): fun()  an ASYNC streaming producer (e.g. `fd`): feeds candidates in incrementally; returns a cancel fn
---@field blob_stream? fun(feed_bytes: fun(data: string), done: fun()): fun()  a RAW-BYTE streaming producer (GAP-5): feeds stdout chunks straight to the native matcher (no Lua per-row work); needs `blob_item`; requires ABI ≥ 5
---@field blob_item? fun(text: string): table  derive a candidate's `_src` item from its text (path) for the blob-stream path (e.g. `function(t) return { path = t } end`)
---@field grep? LvimPickerGrepSpec  the GREP controller (Variant B): hold ALL rg matches in the native blob; the MODE (grep|filter) decides whether the typed query drives rg or fuzzy-filters the frozen blob; requires ABI ≥ 5
---@field on_confirm fun(item: any)  called with the chosen item's source value
---@field on_cancel? fun()  called when the finder is dismissed without a choice (incl. replaced by the next finder)
---@field on_close? fun()  finder-owned teardown run on close (e.g. a live source killing its in-flight process)
---@field format? fun(item: any): string  display text for a table item (default: `item.text`)
---@field preview? fun(item: any): string[], string?, integer?  preview lines (+ a filetype, + a 1-based focus line) per selection (SYNCHRONOUS, in-memory finders)
---@field preview_file_of? fun(item: any): { path: string, lnum?: integer, ft?: string }?  map an item to a FILE location previewed ASYNC (read off the main thread, LRU-cached) so the preview follows the cursor while scrolling; used by files/grep
---@field preview_file? boolean  preview the item's REAL file buffer (EDITABLE, 2-way synced) instead of `preview` lines; items need `path` (+ lnum/col)
---@field preview_side? "right"|"left"|"below"|"above"|"dynamic"|"hide"  where the preview sits (default "right"); below/above stack; `dynamic` = full-width list + a peek float above (native-qf style); `hide` = no preview (toggle with <C-e>)
---@field preview_numbers? boolean  show line numbers in the preview (default true)
---@field preview_wrap? boolean  soft-wrap the preview (default false)
---@field list_wrap? boolean  soft-wrap the list rows (no "↳" marker) so far-right matches stay visible (default false)
---@field empty_text? string  shown when there are no results (list body + preview winbar)
---@field empty_preview? string  the "nothing to preview" placeholder bar text (default "Nothing to preview")
---@field title? string  the finder title — the chassis native centered border-title
---@field icon? string  an optional leading glyph fronting the title
---@field title_line? string  title placement: "row" (a top content row, default) | "statusline" (the centralized chrome overlay) | "border" (opt-in native border-title)
---@field title_pos? "left"|"center"|"right"  title alignment override for THIS open (default: `config.title_pos`, layout-independent)
---@field counter? string  match-count placement: "footer" (default — the bottom-right border) | "title" (folded into the border-title)
---@field prompt? string  the query prompt prefix (default "➤ ")
---@field keys? { key: string, name?: string, run: fun(item: any, close: fun()) }[]  extra row actions (split, code action…); `name` adds a footer hint
---@field filters? LvimUiFilterGroup[]  header filter button GROUPS — each `{ active = id, buttons = { { id, label, key?, predicate?(src), hl?, hl_active?, hl_hover_active? }, … } }`; activate a filter by its key in NORMAL mode
---@field refresh? fun(): any[]  re-fetch the static items live (e.g. on DiagnosticChanged) — see refresh_events
---@field refresh_events? string[]  autocmd events that trigger a refresh
---@field close_on_empty? boolean  dismiss the finder when a refresh leaves no items (e.g. all diagnostics fixed)
---@field max_rows? integer  natural list/preview height hint (default 15)
---@field layout? "float"|"bottom"|"area"  centred float (default), a bottom dock, or the cmdheight area (heirline above)
---@field height? integer  rows for the bottom layout (default 16)
---@field key? string  the dock KIND key — this finder's stable identity in the dock stack (id = "lvim-picker:"..key); nil ⇒ derived from the title, else un-managed
---@field dock_stack? boolean  PER-CALL override of the picker's own `config.dock.dock_stack` for THIS open: true = managed stack consumer, false = geometry-only standalone. nil ⇒ inherit `config.dock.dock_stack`. Caller plugins (lvim-lsp, lvim-qf-loc) opening THROUGH the picker set this to control docking for their entry.
---@field force? { float?: table, area?: table, bottom?: table }  PER-CALL anchored geometry override (per layout), deep-merged over the central dock geometry AND `config.dock.force`; wins for THIS open. Each layout may carry height/height_auto/backdrop/auto_hide/keep_focus (float ALSO width/width_auto; area/bottom are always full-width). `opts.height` still wins as an explicit rows size.

--- Actually CONSTRUCT + open a finder surface (the real work behind `M.open`): a centred float with a query
--- input on top, a results list and (with `preview`) a scrollable preview beside it. When `kind` is given the
--- open is MANAGED by the dock (which already parked the previous consumer, so we do NOT `close_active` here);
--- when `kind` is nil it is un-managed — `source.close_active` replaces the previous finder in place. The
--- (kind, layout) SLOT KEY (`sk`) — computed from `kind` + the resolved `opts.layout` — is what all managed
--- open-state (`live[sk]` + the `dock.parked(entry_keys[sk])` bookkeeping) is filed under, so the SAME kind
--- open in two layouts is two independent surfaces.
---@param opts LvimPickerOpts
---@param kind string?  the dock kind (managed) or nil (un-managed)
build = function(opts, kind)
    opts = opts or {}
    -- Default the LAYOUT from `config.layout` (default "area") when the caller gave none — so every
    -- finder + `:LvimPicker <finder>` lands in the configured layout unless overridden per call.
    opts.layout = opts.layout or (config or {}).layout or "area"
    -- The (kind, layout) slot key this managed open files its state under (nil ⇒ un-managed).
    local sk = kind and slot_key(kind, opts.layout) or nil
    -- UN-MANAGED only: a finder already open (EITHER backend)? Close it FIRST via the shared registry so this
    -- open replaces it in place. In the MANAGED path the DOCK enforces one-visible-per-layout — it has already
    -- PARKED the previous consumer (keeping it on the stack), so we must NOT destroy it here.
    if not kind then
        source.close_active()
    end
    local surface = require("lvim-ui.surface")
    local items = normalize(opts.items, opts.format)
    local maxr = opts.max_rows or config.max_rows
    local state = {
        filtered = items,
        sel = 1,
        -- Logical index of the FIRST rendered list row (viewport virtualization): the list buffer holds only
        -- the visible window (+ a small margin), never all filtered rows — see the viewport block below.
        view_top = 1,
        list_pan = nil,
        preview_pan = nil,
        st = nil,
        closed = false,
        -- The outcome was already delivered (confirm / cancel / a row action). While this stays false at close
        -- time the finder was dismissed externally (replaced by the next finder), which on_close treats as a
        -- cancel — so restore-on-cancel finders (colorschemes) still fire.
        handled = false,
        query = "",
        marked = {},
    }
    -- this finder's entry in the shared "open finder" registry (so the next open closes us first)
    local active_entry = {
        close = function()
            if not state.closed and state.st then
                pcall(state.st.close)
            end
        end,
    }
    local opener = api.nvim_get_current_win() -- the editor window the finder opened from (for the top-edge escape)

    -- Every highlight group is configurable + shared via `config.hl` (fall back to the built-in
    -- tint-canon / peek groups).
    local pkcfg = config or {}
    local phl = pkcfg.hl or {}
    local function hl(key, default)
        return phl[key] or default
    end
    local empty_text = opts.empty_text or pkcfg.empty_text or "[no matches]"
    local empty_preview = opts.empty_preview or pkcfg.empty_preview or "Nothing to preview"
    local prevcfg = pkcfg.preview or {}
    -- list wrap: per-call `opts.list_wrap` wins; else the shared `config.list_wrap`.
    local list_wrap = opts.list_wrap
    if list_wrap == nil then
        list_wrap = pkcfg.list_wrap == true
    end

    -- FILTER bars (optional): `opts.filters` is a list of GROUPS, each `{ buttons = { { id, label, key?,
    -- predicate?(src), hl?, hl_active? }, … }, active }`. An item is kept only if it passes EVERY group's
    -- active button predicate; the surviving pool is then fuzzy-filtered by the query. Header buttons toggle
    -- the active button live (see build_filter_bar / set_filter). `set_filter` is assigned after `refilter`.
    local filters = opts.filters
    local set_filter ---@type fun(gi: integer, id: string)
    local function active_button(g)
        for _, b in ipairs(g.buttons) do
            if b.id == g.active then
                return b
            end
        end
        return g.buttons[1]
    end
    --- True when `src` passes every group's active predicate (optionally skipping `except`).
    ---@param src any
    ---@param except? table
    ---@return boolean
    local function passes_filters(src, except)
        for _, g in ipairs(filters or {}) do
            if g ~= except then
                local b = active_button(g)
                if b and b.predicate and not b.predicate(src) then
                    return false
                end
            end
        end
        return true
    end

    -- Forward declarations — the list panel's NORMAL-mode keys (defined with the panel, early) call these,
    -- but they are assigned further down (after the providers/state are wired).
    local move, confirm, cancel, focus_input, act, scroll_preview
    local build_footer -- mode-aware footer legend (prompt ⇄ list), assigned near focus_input; used at open + on switch
    -- The GREP controller (assigned after `refilter`, referenced by it + the keymaps): (re)start rg for a query,
    -- stop the in-flight rg, and the Ctrl-g grep⇄filter toggle. Nil for non-grep finders.
    local grep_start, grep_stop, grep_toggle

    -- ── multi-select marking + quickfix (config.keys.mark / .quickfix, shared with the fzf backend) ──
    local pkc = (config or {})
    local kcfg = pkc.keys or {}
    local marker = pkc.marker or "➤"
    --- A config key value (a single key, a list, or "") → a list of keys.
    ---@param v string|string[]|nil
    ---@return string[]
    local function keylist(v)
        if type(v) == "table" then
            return v
        end
        return (type(v) == "string" and v ~= "") and { v } or {}
    end
    --- The mark-order index of a source value within `state.marked`, or nil.
    local function marked_index(src)
        for i, s in ipairs(state.marked) do
            if s == src then
                return i
            end
        end
    end
    --- Whether a source value is marked (drives the front-column dot in the render).
    local function is_marked(src)
        return src ~= nil and marked_index(src) ~= nil
    end
    --- Toggle the focused row's mark, then advance one row (multi-select `Tab` = toggle + down).
    local function mark()
        local it = state.filtered[state.sel]
        if it and it._src ~= nil then
            local i = marked_index(it._src)
            if i then
                table.remove(state.marked, i)
            else
                state.marked[#state.marked + 1] = it._src
            end
        end
        move(1) -- advance + re-render (so the new dot shows)
    end
    --- Send the marked rows (or the focused one when none are marked) to the quickfix list; close + open it.
    local function to_quickfix()
        local srcs = state.marked
        if #srcs == 0 then
            local cur = state.filtered[state.sel]
            srcs = (cur and cur._src ~= nil) and { cur._src } or {}
        end
        local qf = {}
        for _, src in ipairs(srcs) do
            if type(src) == "table" then
                qf[#qf + 1] = {
                    filename = src.path,
                    bufnr = (not src.path) and src.bufnr or nil,
                    -- 0 (not 1) when the entry has no real position (a plain file pick), so consumers can tell a
                    -- file list from a grep/diagnostic one; vim still jumps to the file's top.
                    lnum = src.lnum or 0,
                    col = src.col or 0,
                    text = src.text or "",
                }
            end
        end
        if #qf == 0 then
            return
        end
        pcall(function()
            require("lvim-hud.overlay").clear()
        end) -- idempotent — drop the finder's statusline title/counter if it published one
        if state.st then
            state.st.close()
        end
        vim.fn.setqflist({}, " ", { title = opts.title or "Picker", items = qf })
        vim.cmd("botright copen")
    end

    -- Kill the "↳" continuation marker on wrapped rows WITHOUT touching the user's global `showbreak`: the
    -- special window-local value "NONE" disables showbreak for THIS window only (an empty "" would just
    -- revert to the global) — no marker, no global mutation. (No `breakindent`: its virtual indent draws no
    -- text and so cannot carry the row tint — it would leave an un-tinted notch; instead continuations sit
    -- at column 0 as REAL wrapped text, fully covered by the row's `hl_eol` stripe.)
    local function tame_win(win, wrap)
        if win and api.nvim_win_is_valid(win) then
            vim.wo[win].wrap = wrap or false
            vim.wo[win].list = false
            vim.wo[win].showbreak = "NONE"
        end
    end

    -- The title + match counter flow through the chassis (the SINGLE title path): a native centered
    -- border-title + the count in the border (default the bottom-right border-footer, per `counter`), OR —
    -- when `title_line="statusline"` (per-call or `ui_config`) — the centralized chrome-overlay title (the
    -- chassis owns that publish, not us). `count_fn` is the live `matches / candidate-pool` count (fzf-lua
    -- style: the pool grows as a stream feeds in); `refresh_count` re-applies it to the live border / overlay
    -- after every selection move / filter / type.
    -- The counter, always the REAL numbers (never the ≤max_results shown-row count). The two numbers only ever
    -- differ when a QUERY is actually narrowing a pool, so:
    --   • NO query → a SINGLE number (the pool count) — with nothing typed, "found == total" is meaningless, so
    --     we show just the count (a plain number renders as "N", not "N/N").
    --   • a query → `matched / total`, where MATCHED is the matcher's TRUE hit count (shrinks as you narrow),
    --     TOTAL the fixed pool.
    --   • LIVE grep → always a SINGLE number: rg IS the search (there is no separate pool to narrow against),
    --     so every found row is a matched row — a lone climbing match count is the honest display.
    local function count_fn()
        -- GREP CONTROLLER (Variant B): the blob holds ALL rg matches (up to the config.grep_max store ceiling; a
        -- pathological overflow is still TALLIED, never stored). The MODE decides the counter:
        --   • GREP mode — rg IS the search, nothing filters on top, so matched == total == the REAL rg match
        --     count (`state.grep_total`, climbing to e.g. 403127 as rg streams) → shown fzf-style `N/N`.
        --   • FILTER mode (rg frozen; the typed query fuzzy-narrows the loaded blob) — `matched / loaded`, where
        --     matched (`state.match_total`, the matcher's TRUE hit count) SHRINKS as you type and `loaded`
        --     (`state.pool_n`) is the blob's candidate count.
        if opts.grep then
            if state.grep_mode == "filter" then
                local total = state.pool_n or 0
                return { current = state.match_total or total, total = total }
            end
            local n = state.grep_total or 0
            return n > 0 and { current = n, total = n } or 0
        end
        -- GREP (opts.count_files): `matches found / TOTAL FILES in the tree`. `current` = the grep matches (the
        -- fuzzy-narrowed hit count on the fixed-query/blob path, or the live-grep result count); `total` = the
        -- tree's file count (state.file_total, streamed in the background — see the file-count block). This is
        -- the denominator the user wants: how many files the grep searched, not the match count repeated.
        if opts.count_files then
            local cur
            if state.blob then
                cur = state.query == "" and (state.pool_n or 0) or (state.match_total or state.pool_n or 0)
            else
                cur = state.filtered and #state.filtered or 0
            end
            return { current = cur, total = state.file_total or cur }
        end
        if state.blob then
            local total = state.pool_n or 0
            if state.query == "" then
                return total -- no filter → just the count
            end
            return { current = state.match_total or total, total = total }
        end
        if opts.source then
            local cur = state.filtered and #state.filtered or 0
            return { current = cur, total = cur }
        end
        local cur = state.filtered and #state.filtered or 0
        if state.query == "" then
            return #items -- no filter → just the count
        end
        return { current = cur, total = #items }
    end
    local function refresh_count()
        if state.st and state.st.set_counter then
            state.st.set_counter(count_fn)
        end
    end

    -- list panel: the filtered rows in the tint canon (odd BLUE / even YELLOW full-row stripes, the
    -- selected row a STRONG tint of its accent), matched chars in red. Selection is the Sel stripe (not a
    -- window cursorline), so it survives the row tints; navigation re-renders to move it.
    -- Dynamic height: the container fits the TALLER of the two panels, capped at `max_rows`. The list
    -- contributes its result count; the preview contributes its content's line count (cached on selection).
    -- 0 results ⇒ both are 0 ⇒ only the prompt + the preview winbar show. relayout() re-fits on every change.
    state.preview_lines = {}
    --- The LIST's own content height: the result count capped at `max_rows` (0 when empty — no body row).
    ---@return integer
    local function list_h()
        return math.min(#state.filtered, maxr) -- 0 when empty (no [no matches] body row)
    end
    --- The PREVIEW's own content height: the editable file's line count (preview_file) or the cached scratch
    --- preview line count, capped at `max_rows`.
    ---@return integer
    local function preview_h()
        if opts.preview_file then
            -- the editable preview fits the FILE: a 3-line file is 3 rows; a big one is capped at max_rows
            local it = state.filtered[state.sel]
            local s = it and it._src
            if s and s.path and s.path ~= "" then
                local b = vim.fn.bufadd(s.path)
                pcall(vim.fn.bufload, b)
                return math.min(vim.api.nvim_buf_line_count(b), maxr)
            end
            return 1
        end
        if opts.preview_file_of then
            -- ASYNC file preview: track the LIST height (the result COUNT, capped at max_rows) — NOT the
            -- previewed file's own line count. The file count would change for EVERY row as you scroll →
            -- `content_h` re-fingerprints → a `relayout()` on every scroll step that visibly tears the windows.
            -- The result count is STABLE while scrolling (it only changes on a new query), so this keeps the
            -- layout put during scroll (no tear) AND still AUTO-FITS the panel to the number of matches — a
            -- few-result grep gets a compact panel instead of a full-height one (the preview shows that many
            -- context rows). Identical to `list_h()` so the two panels always agree.
            return list_h()
        end
        return math.min(#state.preview_lines, maxr)
    end
    --- True when the filter left at least one result (drives the winbar / empty-state rendering).
    ---@return boolean
    local function has_results()
        return #state.filtered > 0
    end
    -- Each panel fits ITS OWN content (+1 for its winbar with results; a single tinted row when empty). The
    -- surface MAXes them for a side-by-side (horizontal) layout, SUMs them when stacked (vertical), and the
    -- area auto-fits to that — capped at the configured height. `content_h` is just a fingerprint so `refit`
    -- relayouts whenever EITHER panel's height changes.
    local function list_panel_h()
        return has_results() and (list_h() + 1) or 1
    end
    local function preview_panel_h()
        -- empty ⇒ a SINGLE styled row (the "nothing to preview" bar, no winbar → no blank body row beneath)
        return has_results() and (preview_h() + 1) or 1
    end
    local function content_h()
        return list_h() * 1000 + preview_h()
    end

    -- ── list viewport (virtualized render) ──────────────────────────────────
    -- The list buffer holds ONLY the rows its window can show (+ VIEW_MARGIN below), never the whole
    -- filtered set — so a render is O(viewport) at ANY scale (an uncapped live-grep result or a huge static
    -- `items` open used to build every row + stripe extmark: 0.4–1.6 s and ~600k extmarks at 200k).
    -- Selection, marks and actions keep addressing LOGICAL entries (`state.filtered[state.sel]`); only the
    -- buffer-line mapping shifts by `state.view_top - 1` (each entry is exactly ONE buffer line — `normalize`
    -- collapses newlines). Row striping is keyed by the LOGICAL index, so the odd/even pattern stays put
    -- while scrolling instead of re-phasing with the slice.
    local VIEW_MARGIN = 4 -- overrender a few rows so the window height (winbar / relayout skew) never shows blanks
    --- The list viewport height: the live window height when the panel exists (a docked layout can exceed
    --- `max_rows`), else the content-fit height. May overcount by the winbar row — VIEW_MARGIN covers it.
    ---@return integer
    local function view_height()
        local p = state.list_pan
        if p and p.win and api.nvim_win_is_valid(p.win) then
            return math.max(1, api.nvim_win_get_height(p.win))
        end
        return math.max(1, list_h())
    end
    --- Clamp `state.view_top` so the selection sits inside the viewport and the slice never starts past the
    --- tail. Called at the top of every list render — every path (move / filter / stream growth) goes
    --- through the render, so the slice can never drift from the selection.
    ---@param vh integer  the viewport height
    ---@return integer view_top
    local function clamp_view(vh)
        local total = #state.filtered
        local top = state.view_top or 1
        if state.sel < top then
            top = state.sel
        elseif state.sel > top + vh - 1 then
            top = state.sel - vh + 1
        end
        top = math.max(1, math.min(top, math.max(1, total - vh + 1)))
        state.view_top = top
        return top
    end

    -- Each panel carries a WINBAR title, the lvim-lsp peek look: the list shows the title + result count,
    -- the preview shows the selected file (tail + dir). `%%` escapes a literal `%` in a name.
    --- Escape a string for use in a statusline/winbar format (doubles every literal `%`).
    ---@param s any
    ---@return string
    local function esc(s)
        return (tostring(s or ""):gsub("%%", "%%%%"))
    end
    --- Paint the LIST panel's winbar: blank with a preview (the scoped prompt overlays it), else the
    --- title + result count; nothing when there are no results (the panel is a single row).
    local function set_list_winbar()
        local p = state.list_pan
        if not (p and p.win and api.nvim_win_is_valid(p.win)) then
            return
        end
        -- No results ⇒ NO winbar (the panel is a single row — see list_panel_h); the prompt overlay owns it.
        if not has_results() then
            vim.wo[p.win].winbar = ""
            return
        end
        -- With a preview (lines OR the editable file) the scoped INPUT prompt overlays this row, so keep it
        -- blank (just reserve the row, so the first list item isn't hidden under the prompt); the title/count
        -- live in the statusline / the header. Without ANY preview the list owns its title bar.
        if opts.preview or opts.preview_file then
            vim.wo[p.win].winbar = ("%%#%s# %%="):format(hl("bar", "LvimUiPeekFileBar"))
        else
            vim.wo[p.win].winbar = ("%%#%s# %s %%#%s# %d %%#%s#%%="):format(
                hl("list_title", "LvimUiPeekTitle"),
                esc(opts.title or "Pick"),
                hl("list_count", "LvimUiPeekCount"),
                #state.filtered,
                hl("bar", "LvimUiPeekFileBar")
            )
        end
    end
    local function set_preview_winbar(pan, it)
        if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
            return
        end
        -- No results ⇒ NO winbar; the "nothing to preview" bar is the panel's single styled row instead (drawn
        -- in the preview provider `update` via `preview.render_empty`), so there is no empty body row.
        if not has_results() then
            vim.wo[pan.win].winbar = ""
            return
        end
        if it and it.path and it.path ~= "" then
            local rel = vim.fn.fnamemodify(it.path, ":~:.")
            local tail = vim.fn.fnamemodify(rel, ":t")
            local dir = vim.fn.fnamemodify(rel, ":h")
            dir = (dir == "." or dir == "") and "" or (dir .. "/")
            -- the file's icon (from the configured icon_provider, when `preview.show_icon`)
            local icon = ""
            if prevcfg.show_icon ~= false then
                local gl =
                    iconlib.get(tail, { provider = config.icon_provider, color_mode = config.icon_color_mode }).glyph
                icon = (gl and gl ~= "") and (gl .. " ") or ""
            end
            -- name = icon + file (bright); dir = padded path on the winbar bg (so it blends into the bar)
            local dpl, dpr = prevcfg.dir_pad_left or 1, prevcfg.dir_pad_right or 1
            vim.wo[pan.win].winbar = ("%%#%s# %s%s %%#%s#%s%s%s%%#%s#%%="):format(
                hl("preview_file", "LvimUiPeekFile"),
                esc(icon),
                esc(tail),
                hl("preview_dir", "LvimUiPickerPreviewDir"),
                string.rep(" ", dpl),
                esc(dir),
                string.rep(" ", dpr),
                hl("bar", "LvimUiPeekFileBar")
            )
        else
            -- A selected item with no path → its text; NO results → the empty label in the file-name spot.
            vim.wo[pan.win].winbar = ("%%#%s# %s %%#%s#%%="):format(
                hl("preview_file", "LvimUiPeekFile"),
                esc((it and it.text) or empty_text),
                hl("bar", "LvimUiPeekFileBar")
            )
        end
    end

    local list_provider = {
        cursorline = false,
        -- the SELECTION is the Sel stripe (not a window cursorline), so hide the hardware cursor while the
        -- list is focused (NORMAL mode) — the bright row, not a block cursor, shows where you are.
        hide_cursor = true,
        -- the focused row's SOURCE value — so the surface's default `open`/split/vsplit/tab can act on it
        -- without the consumer wiring anything (items already carry `path`/`lnum`/`col`).
        selection = function()
            local it = state.filtered[state.sel]
            return it and it._src or nil
        end,
        size = function()
            return math.max(30, math.floor(vim.o.columns * 0.32)), list_panel_h() -- the LIST's own height
        end,
        render = function()
            local lines, hls = {}, {}
            -- VIEWPORT: build only the visible slice (+ margin) — O(viewport) regardless of #filtered.
            local vh = view_height()
            local top = clamp_view(vh)
            local last = math.min(#state.filtered, top + vh + VIEW_MARGIN - 1)
            for li = top, last do
                local it = state.filtered[li]
                local i = li - top + 1 -- 1-based BUFFER line of logical entry `li`
                local marked = is_marked(it._src)
                -- LIVE-source rows (e.g. live grep): the query-highlight decoration is computed HERE, for the
                -- visible rows only — never over the whole result set (rg did the real matching; this only
                -- lights the query chars up). Result items are fresh tables per delivery, so the memo
                -- (`_match_done`) can never carry a stale query's spans.
                -- LIVE-source AND blob-stream rows carry no precomputed match spans (an eager pass over the
                -- whole result set was O(all results) per keystroke); light up the query chars HERE, for the
                -- visible rows only. Result items are fresh tables per delivery, so `_match_done` never carries
                -- a stale query's spans.
                if (opts.source or state.blob) and not it._match_done then
                    local q = state.live_query
                    if q and q ~= "" then
                        it.match = utils.match_indices(q, it.text)
                    end
                    it._match_done = true
                end
                -- Auto ft devicon for items that name a file (file lists / lsp locations / quickfix / …),
                -- resolved HERE — for the visible rows only — because the lookup is uncached ~3 µs/call and
                -- `normalize` runs over the whole candidate set (~2M rows on a huge tree). Memoised per grid
                -- item (`_icon_done`); grid items are fresh tables per filter delivery, so a re-resolve is at
                -- most one viewport per keystroke. An EXPLICIT item icon (e.g. a diagnostic severity glyph)
                -- arrives non-nil from normalize and is left untouched.
                if it.icon == nil and not it._icon_done then
                    it._icon_done = true
                    local s = it._src
                    if type(s) == "table" then
                        local p = s.path
                            or (s.bufnr and api.nvim_buf_is_valid(s.bufnr) and api.nvim_buf_get_name(s.bufnr))
                        if p and p ~= "" then
                            it.icon, it.icon_hl = source.devicon(p)
                        end
                    end
                end
                local row, spans, lead = list_row(it, marked, marker)
                lines[i] = row
                local odd = (li % 2) == 1 -- stripe parity by LOGICAL index (stable while scrolling)
                local sel = li == state.sel
                local stripe = sel
                        and (odd and hl("sel_odd", "LvimUiMsgAreaSelOdd") or hl("sel_even", "LvimUiMsgAreaSelEven"))
                    or (odd and hl("row_odd", "LvimUiMsgAreaRowOdd") or hl("row_even", "LvimUiMsgAreaRowEven"))
                hls[#hls + 1] = { i - 1, 0, -1, stripe, sel and 200 or 100 } -- full-row tint (eol)
                -- the mark dot in the front column (above the row tint) — the multi-select indicator
                if marked then
                    hls[#hls + 1] = { i - 1, 0, lead, hl("marker", "LvimUiPickerMarker"), 220 }
                end
                -- the leading glyph keeps its OWN colour (e.g. diagnostic severity signs) — above the row
                -- stripe (incl. the selected row's strong tint) so it shows through; the row is `<lead><icon> …`.
                if it.icon and it.icon ~= "" and it.icon_hl then
                    hls[#hls + 1] = { i - 1, lead, lead + #it.icon, it.icon_hl, 210 }
                end
                for _, ms in ipairs(spans) do
                    hls[#hls + 1] = { i - 1, ms.c0, ms.c1, hl("match", "LvimUiMsgAreaMatch"), 250 }
                end
            end
            -- No results: with a preview the `[no matches]` label lives in the PREVIEW panel (the list row
            -- stays blank under the prompt overlay); without a preview the list shows the tinted label itself.
            if #lines == 0 then
                if opts.preview then
                    lines = { "" }
                else
                    lines = { " " .. empty_text }
                    hls[1] = { 0, 0, -1, hl("preview_file", "LvimUiPeekFile"), 100 } -- a single yellow-tinted row
                end
            end
            return lines, hls
        end,
        keys = function(map, pan, st)
            state.list_pan, state.st = pan, st
            -- `list_wrap` soft-wraps long rows (so a match far to the right stays visible) — never with the
            -- "↳" continuation marker (tame_win sets showbreak=NONE for this window); default off = truncate.
            tame_win(pan.win, list_wrap)
            set_list_winbar()
            -- NORMAL-mode keys on the list (reached via <Esc> from the prompt): navigate + act without the
            -- query. `<C-l>`/`<C-h>` (panel nav) + the filter bar are owned by the surface chassis.
            if map then
                map({ "j", "<Down>" }, function()
                    move(1)
                end)
                map({ "k", "<Up>" }, function()
                    move(-1)
                end)
                map("<CR>", function()
                    confirm()
                end)
                map("<C-d>", function()
                    scroll_preview(1)
                end)
                map("<C-u>", function()
                    scroll_preview(-1)
                end)
                -- NOTE: <C-j>/<C-k> are the surface's SECTOR navigation (list → footer bar → … and, when
                -- hosted, on past the footer DOWN into the messages via `on_escape_below`). We do NOT bind
                -- them here — that would shadow the stack navigation.
                -- multi-select: the mark key toggles the row's mark + advances (same as the fzf backend); the
                -- quickfix key sends the marked rows (or the focused one) to the quickfix list. The mark key
                -- (Tab) is bound AFTER the chassis, so it overrides the list ⇄ preview toggle on the LIST (the
                -- preview is still reachable via `<C-l>`); both keys come from config.keys.
                map(keylist(kcfg.mark), mark)
                map(keylist(kcfg.quickfix), to_quickfix)
                -- (grep) Ctrl-g toggles GREP ⇄ FILTER mode from the normal-mode list too.
                if grep_toggle then
                    map(keylist(kcfg.grep_filter), grep_toggle)
                end
                -- Swap the finder's backend (tint ⇄ fzf) from the normal list — command finders only.
                if opts.reopen then
                    map(keylist(kcfg.swap_backend), function()
                        swap_backend("tint", opts)
                    end)
                end
                -- back to typing: `/` + <C-f> (NOT i/a — a consumer filter may own those, e.g. diagnostics).
                map({ "/", "<C-f>" }, focus_input)
                map({ "q", "<Esc>" }, cancel)
                for _, a in ipairs(opts.keys or {}) do
                    map(a.key, function()
                        act(a.run)
                    end)
                end
            end
        end,
    }

    -- preview panel (optional). Two flavours:
    --   • `opts.preview_file` — the REAL file buffer (lvim-ui.preview): fully EDITABLE, two-way in
    --     sync with the file, its own `<C-h>`/`<C-l>` nav when focused. Items must carry `path` (+ lnum/col).
    --   • `opts.preview(src)` — a read-only scratch buffer of the returned `lines` (+ filetype, focus line).
    local preview_provider
    if opts.preview_file then
        local up = preview.new({
            item = function()
                local it = state.filtered[state.sel]
                local s = it and it._src
                return (s and s.path and s.path ~= "") and { filename = s.path, lnum = s.lnum, col = s.col } or nil
            end,
            number = (opts.preview_numbers == false) and "none" or "normal",
            empty = empty_preview, -- the configurable "nothing to preview" placeholder text
        })
        preview_provider = {
            size = function()
                return math.max(40, math.floor(vim.o.columns * 0.5)), preview_panel_h() -- the PREVIEW's own height
            end,
            update = up.update,
            item = up.item, -- the focused location (lnum/col), so the dynamic peek can position its cursor
            reset = up.reset, -- so the dynamic peek float re-asserts the file winbar on a fresh window
            on_close = up.on_close,
            -- only capture the panel (for C-d/C-u scroll); the file buffer is editable, so we add NO keys
            -- that would shadow `i`/`a` — ui.preview binds the panel-nav keys itself on focus.
            keys = function(_, pan)
                state.preview_pan = pan
            end,
        }
    end
    preview_provider = preview_provider
        or (opts.preview or opts.preview_file_of)
            and {
                size = function()
                    -- Both panels share the CONTENT height (the taller of list/preview, capped) so the
                    -- container fits the bigger one; the preview lines live in `state.preview_lines` (filled by
                    -- the sync `fetch_preview` for in-memory finders, or ASYNC for file finders). With results
                    -- +1 for the winbar; with NO results a single tinted `[no matches]` row.
                    return math.max(40, math.floor(vim.o.columns * 0.5)), preview_panel_h() -- the PREVIEW's own height
                end,
                update = function(pan)
                    -- The winbar shows the file that is ACTUALLY displayed: `state.preview_loc` (the async
                    -- file-preview path sets which file landed — a row behind during a fast scroll), else the
                    -- current selection's own source. Keeps the panel body + title consistent.
                    set_preview_winbar(
                        pan,
                        state.preview_loc or (state.filtered[state.sel] and state.filtered[state.sel]._src) or nil
                    )
                    -- No results: a SINGLE styled "nothing to preview" row (no winbar, no number, no syntax) —
                    -- the same bar `ui.preview` paints for the editable file preview, so the two read identically.
                    if not has_results() then
                        if pan.win and api.nvim_win_is_valid(pan.win) then
                            vim.wo[pan.win].number = false
                        end
                        preview.set_syntax(pan.buf, nil)
                        preview.render_empty(pan.buf, NS, empty_preview)
                        return
                    end
                    if pan.win and api.nvim_win_is_valid(pan.win) then
                        vim.wo[pan.win].number = opts.preview_numbers ~= false -- restore line numbers
                    end
                    api.nvim_buf_clear_namespace(pan.buf, NS, 0, -1)
                    local lines = state.preview_lines or {}
                    vim.bo[pan.buf].modifiable = true
                    pcall(api.nvim_buf_set_lines, pan.buf, 0, -1, false, lines)
                    vim.bo[pan.buf].modifiable = false
                    preview.set_syntax(pan.buf, state.preview_ft) -- highlight WITHOUT a `filetype` (no LSP attach)
                    -- `focus` (a 1-based line) scrolls the preview to that row and centres it — used by grep
                    -- to jump the preview to the matched line.
                    local focus = state.preview_focus
                    if focus and pan.win and api.nvim_win_is_valid(pan.win) then
                        pcall(api.nvim_win_set_cursor, pan.win, { math.max(1, math.min(focus, #lines)), 0 })
                        api.nvim_win_call(pan.win, function()
                            vim.cmd("normal! zz")
                        end)
                    end
                end,
                keys = function(map, pan)
                    state.preview_pan = pan
                    tame_win(pan.win, opts.preview_wrap == true) -- no "↳" marker; wrap off unless opted in
                    if pan.win and api.nvim_win_is_valid(pan.win) then
                        vim.wo[pan.win].number = opts.preview_numbers ~= false -- line numbers in the preview
                    end
                    -- NORMAL-mode keys on the preview (focused via <Tab>): the buffer is read-only, so a stray
                    -- `i`/`a` would error E21 — map them (and `/`) back to typing; `q`/<Esc> close, `<CR>` opens
                    -- the focused item. (`j`/`k` scroll the file; <Tab> toggles back to the list via the chassis.)
                    if map then
                        map({ "i", "a", "/", "<C-f>" }, focus_input)
                        map({ "q", "<Esc>" }, cancel)
                        map("<CR>", function()
                            confirm()
                        end)
                    end
                end,
            }
        or nil

    local function set_list_cursor()
        local p = state.list_pan
        if p and p.win and api.nvim_win_is_valid(p.win) then
            -- Map the LOGICAL selection to its buffer line in the rendered viewport slice (the render just
            -- clamped `view_top`, so the selection is always inside the slice; clamp to the buffer anyway).
            local row = state.sel - (state.view_top or 1) + 1
            local nbuf = api.nvim_buf_line_count(p.buf)
            pcall(api.nvim_win_set_cursor, p.win, { math.max(1, math.min(nbuf, row)), 0 })
        end
    end
    --- Fetch the CURRENT selection's SYNCHRONOUS in-memory preview (lsp / diagnostics / buffers — cheap, no
    --- disk). File-based previews (`opts.preview_file_of`) are read ASYNC below and must NOT be touched here
    --- (this runs on every rerender and would wipe the async-loaded lines). No preview / no selection ⇒ empty.
    local function fetch_preview()
        if opts.preview_file_of then
            return -- the async file-preview path owns state.preview_lines
        end
        if opts.preview_file or not opts.preview then
            -- the editable file preview owns its buffer (ui.preview); no scratch lines to cache
            state.preview_lines, state.preview_ft, state.preview_focus = {}, nil, nil
            return
        end
        local it = state.filtered[state.sel]
        if not it then
            state.preview_lines, state.preview_ft, state.preview_focus = {}, nil, nil
            return
        end
        local lines, ft, focus = opts.preview(it._src)
        state.preview_lines = (type(lines) == "table" and lines) or (lines and { tostring(lines) }) or {}
        state.preview_ft, state.preview_focus = ft, focus
    end
    -- Re-fit the surface to the CONTENT height (the taller of list/preview, capped) — only when it actually
    -- changes, so navigating within the same height doesn't reflow the windows.
    local last_h
    local function refit()
        local h = content_h()
        if h ~= last_h and state.st and state.st.relayout then
            last_h = h
            state.st.relayout()
        end
    end

    -- ── ASYNC FILE PREVIEW (opts.preview_file_of) ─────────────────────────────
    -- For finders whose preview is a FILE on disk (grep / files), the read runs OFF the main thread
    -- (source.read_preview_async) so the preview can FOLLOW THE CURSOR while you hold `j` — a synchronous
    -- readfile of a deep-line big file was the scroll freeze, and a settle-debounce only updated it on release.
    -- An LRU cache keyed by PATH makes re-visiting a file instant (scrolling within one grep file, or back over
    -- rows), and a SINGLE in-flight read that always re-targets the LATEST selection keeps the preview
    -- converging on the current row like fzf (never a pile of parallel reads, never a stale frame kept).
    local preview_cache = {} ---@type table<string, { lines: string[], ft: string }>
    local preview_lru = {} ---@type string[]  MRU-ordered paths (index 1 = most recently used)
    local preview_inflight = false
    ---@type { sel: integer, path: string, lnum: integer?, ft: string?, max: integer }?
    local preview_want
    --- Look a file up in the LRU cache, promoting it to most-recent on a hit.
    ---@param path string
    ---@return { lines: string[], ft: string }?
    local function cache_get(path)
        local e = preview_cache[path]
        if e then
            for i, p in ipairs(preview_lru) do
                if p == path then
                    table.remove(preview_lru, i)
                    break
                end
            end
            table.insert(preview_lru, 1, path)
        end
        return e
    end
    --- Insert a file's preview lines into the LRU cache, evicting the least-recently-used beyond the configured
    --- size so a long session never accumulates unbounded preview buffers.
    ---@param path string
    ---@param lines string[]
    ---@param ft string
    local function cache_put(path, lines, ft)
        if not preview_cache[path] then
            table.insert(preview_lru, 1, path)
        end
        preview_cache[path] = { lines = lines, ft = ft }
        local cap = (config or {}).preview_cache or 32
        while #preview_lru > cap do
            local old = table.remove(preview_lru)
            preview_cache[old] = nil
        end
    end
    --- Show `entry`'s lines in the preview, focused on `want.lnum`. `state.preview_loc` records WHICH file is
    --- shown (the render's winbar reads it), so the panel body + title stay consistent even when a read lands a
    --- row or two behind a fast scroll (it converges as the pump reads the current selection next).
    ---@param want { path: string, lnum: integer?, ft: string? }
    ---@param entry { lines: string[], ft: string }
    local function apply_async_preview(want, entry)
        state.preview_lines = entry.lines
        state.preview_ft = want.ft or entry.ft
        state.preview_focus = want.lnum and math.max(1, math.min(want.lnum, #entry.lines)) or nil
        state.preview_loc = { path = want.path, lnum = want.lnum }
        refit() -- the preview height is capped at max_rows, so this relayouts only on the FIRST load, then holds
        if state.preview_pan and state.preview_pan.refresh then
            state.preview_pan.refresh()
        end
        set_list_winbar()
    end
    --- Drain the pending preview request: a cache hit applies instantly; a miss starts ONE async read (marking
    --- `preview_inflight`) whose completion applies it, caches it, and pumps again — so the newest `preview_want`
    --- is always what gets read next.
    local function pump_preview()
        if preview_inflight or not preview_want then
            return
        end
        local want = preview_want
        preview_want = nil
        local hit = cache_get(want.path)
        if hit then
            apply_async_preview(want, hit)
            return pump_preview() -- a newer selection may already be waiting
        end
        preview_inflight = true
        source.read_preview_async(want.path, want.max, function(lines, ft)
            preview_inflight = false
            if state.closed then
                return
            end
            cache_put(want.path, lines, ft)
            apply_async_preview(want, { lines = lines, ft = ft })
            pump_preview()
        end)
    end
    --- Request the async preview for the CURRENT selection (the file `opts.preview_file_of` maps it to). No
    --- file (e.g. a scratch/[No Name] item) ⇒ clear the preview.
    local function request_preview()
        local it = state.filtered[state.sel]
        local loc = (it and it._src and opts.preview_file_of and opts.preview_file_of(it._src)) or nil
        if not (loc and loc.path and loc.path ~= "") then
            state.preview_lines, state.preview_ft, state.preview_focus, state.preview_loc = {}, nil, nil, nil
            refit()
            if state.preview_pan and state.preview_pan.refresh then
                state.preview_pan.refresh()
            end
            return
        end
        -- Read up to `lnum + context` lines (so the match is on-screen), hard-capped at `preview_max_lines` so a
        -- match DEEP in a huge file never materialises tens of thousands of lines on the main thread.
        local span = math.max(500, (loc.lnum or 0) + 200)
        local maxl = math.min(span, (config or {}).preview_max_lines or 2000)
        preview_want = { sel = state.sel, path = loc.path, lnum = loc.lnum, ft = loc.ft, max = maxl }
        pump_preview()
    end

    --- Re-render after a result / selection change. `light` (the frequent re-renders WHILE a tree streams in,
    --- and every scroll MOVE) does the LIST + chrome only — O(viewport), no preview work, no relayout churn —
    --- so it is always a couple ms. A FULL re-render (`light` nil) also drives the preview: the async file read
    --- (opts.preview_file_of) or the synchronous in-memory fetch (opts.preview). The preview height is capped at
    --- max_rows, so once it is loaded `refit()` is a no-op and scrolling never relayouts.
    ---@param light boolean?
    local function rerender(light)
        if not light then
            fetch_preview()
        end
        refit()
        if state.list_pan and state.list_pan.refresh then
            state.list_pan.refresh()
        end
        if not light then
            if opts.preview_file_of then
                request_preview() -- async: fills state.preview_lines + refreshes the panel on completion
            elseif state.preview_pan and state.preview_pan.refresh then
                state.preview_pan.refresh()
            end
        end
        set_list_winbar() -- the result count in the winbar follows the list
        set_list_cursor() -- scroll the window to keep the selection in view
        refresh_count() -- re-apply the live match count to the chassis border / overlay counter
    end
    -- SYNC-preview debounce (small in-memory finders — lsp / diagnostics / the editable file preview). Their
    -- preview is cheap but a per-move relayout is still wasteful; debounce it to the settle. FILE finders do NOT
    -- use this — their preview is async (request_preview) and follows the cursor on every move.
    local preview_gen = 0
    local function schedule_preview()
        if opts.preview_file_of or not (opts.preview or opts.preview_file) then
            return
        end
        preview_gen = preview_gen + 1
        local mygen = preview_gen
        vim.defer_fn(function()
            if mygen ~= preview_gen or state.closed then
                return
            end
            fetch_preview()
            refit()
            if state.preview_pan and state.preview_pan.refresh then
                state.preview_pan.refresh()
            end
            set_list_winbar()
        end, (config or {}).preview_debounce_ms or 60)
    end
    move = function(d)
        if #state.filtered == 0 then
            return
        end
        state.sel = math.max(1, math.min(#state.filtered, state.sel + d))
        rerender(true) -- LIGHT: move the selection stripe + list cursor + count now (a couple ms, never blocks)
        if opts.preview_file_of then
            request_preview() -- async file preview — follows the cursor while holding `j` (fzf-like)
        else
            schedule_preview() -- debounced sync preview for the small in-memory finders
        end
    end
    --- Apply a new result list (from the fuzzy filter or a live source) to the UI. `light` forwards to
    --- `rerender` — set for the high-frequency refreshes while a tree is still streaming (count + rows only).
    --- POSITION: a QUERY CHANGE (`state.reset_pos`, set in `refilter`) jumps back to the top (sel=1, view_top=1)
    --- — a new search starts at the best match. A same-query APPEND (a streaming refresh / a progressive grep
    --- batch, where results only grow at the tail) PRESERVES the selection + viewport, clamped to the new
    --- bounds — so browsing while results pour in stays put like fzf, instead of being yanked back to the top.
    ---@param list table[]
    ---@param light boolean?
    local function apply(list, light)
        if state.closed then
            return
        end
        state.filtered = list
        -- Reset the scroll to the top only when the QUERY actually CHANGED since the last applied list — a new
        -- search starts at the best match. Progressive/streaming refreshes of the SAME query (a live-grep batch,
        -- a files stream tick — possibly MANY per one `refilter`) keep the selection + viewport, clamped to the
        -- grown list, so browsing while results pour in stays put like fzf.
        if state.query ~= state.rendered_query then
            state.sel, state.view_top = 1, 1
        else
            local n = math.max(1, #list)
            state.sel = math.max(1, math.min(state.sel or 1, n))
            state.view_top = math.max(1, math.min(state.view_top or 1, n))
        end
        state.rendered_query = state.query
        rerender(light)
    end
    --- (blob stream) Turn `fuzzy.blob_filter` results (`{ idx, text }`, `idx` = the 1-based NATIVE candidate
    --- index) into grid rows. The `_src` item is DERIVED from the text via `opts.blob_item` and CACHED by
    --- native index in `state.src_cache`, so the SAME candidate always yields the SAME `_src` table — a stable
    --- identity across refilters that multi-select marks (keyed by `_src`) rely on. Text is carried on the row;
    --- the icon (from `_src.path`) and the match spans are resolved lazily in the render, for visible rows only.
    ---@param list { idx: integer, text: string }[]
    ---@return table[]
    local function blob_rows(list)
        local cache = state.src_cache
        local out = {}
        for i, r in ipairs(list) do
            local src = cache[r.idx]
            if not src then
                src = opts.blob_item(r.text)
                cache[r.idx] = src
            end
            out[i] = { text = r.text, _src = src, idx = r.idx }
        end
        return out
    end
    -- A generation guard so a slow async source/filter callback for an OLD query can't overwrite a newer one.
    local refilter_gen = 0
    --- Re-run the filter (static list) or live source for query `q`, then push the ranked results to the UI.
    --- `light` is set by the stream feed for the many-per-second refreshes while a tree loads → a cheap re-render
    --- (count + rows, no preview / relayout); user-driven refilters leave it nil for a full re-render.
    ---@param q string?
    ---@param light boolean?
    local function refilter(q, light)
        state.query = q or ""
        refilter_gen = refilter_gen + 1
        local mygen = refilter_gen
        local function guarded(list)
            if mygen == refilter_gen then
                -- A live source returns raw items (no fuzzy step), so the query is highlighted in each result
                -- text ourselves — but LAZILY, in the list render, for the VISIBLE rows only (an eager pass
                -- here was O(all results) per keystroke). `live_query` records which query produced THIS
                -- result set (gen-guarded), so the render decorates against the right needle.
                state.live_query = state.query
                -- `source_raw`: the source already delivers grid items (a live grep appends into ONE growing
                -- list — see the progressive delivery), so DON'T re-normalise the whole (up to grep_max) list on
                -- every progressive batch — that O(n) re-wrap per delivery was the live-grep stutter. Otherwise
                -- normalise the raw items once here.
                apply(opts.source_raw and list or normalize(list, opts.format), light)
            end
        end
        if opts.grep then
            -- GREP CONTROLLER (Variant B). The blob holds ALL rg matches; the MODE decides what the typed query
            -- does. GREP mode: the query DRIVES rg (re-grep into a fresh blob on a real change), and the blob is
            -- rendered in SOURCE ORDER (blob_filter "") — every match browsable, the counter the true rg total.
            -- FILTER mode (Ctrl-g froze rg): the query FUZZY-FILTERS the loaded blob (blob_filter `query`), the
            -- counter `matched/loaded`. `live_query` is the typed text either way, so the render lights up the
            -- needle (grep) / the fuzzy term (filter) in the VISIBLE rows only.
            if state.grep_mode == "grep" then
                local q = state.query
                if #q < (opts.grep.min_chars or 2) then
                    grep_stop() -- too short to grep a huge tree → clear the list + counter, wait for more chars
                    state.grep_query, state.grep_total = q, 0
                    apply({}, light)
                    return
                end
                if q ~= state.grep_query then
                    -- A NEW query → (re)grep into a FRESH (empty) blob; its paced stream ticks call `refilter`
                    -- again (same query) as matches arrive, and THAT is what renders. Do NOT render the empty
                    -- fresh blob here — keep the CURRENT rows on screen until the new results stream in, so
                    -- re-typing a live grep never flashes an empty list between keystrokes (fzf keeps its rows the
                    -- same way while it reloads). Without this, every keystroke cleared the list → the flicker.
                    grep_start(q)
                    return
                end
                -- Same query = a stream tick (or a manual refresh): render the (growing) blob in source order.
                state.live_query = q
                if state.blob then
                    fuzzy.blob_filter(state.blob, "", function(list, total)
                        if mygen == refilter_gen then
                            -- Do NOT blank the list while a fresh (re)grep is still streaming its first matches:
                            -- an EMPTY pass with an empty pool and rg not yet done = "results are coming", not
                            -- "no matches". Keep the CURRENT rows until real matches arrive (or rg finishes
                            -- empty). This is what makes a Ctrl-g FILTER→GREP return smooth — no empty flash.
                            if #list == 0 and (state.pool_n or 0) == 0 and not state.grep_done then
                                return
                            end
                            state.match_total = total
                            apply(blob_rows(list), light)
                        end
                    end)
                end
                return
            end
            -- FILTER mode: fuzzy-filter the FROZEN blob (rg not re-run).
            state.live_query = state.query
            if state.blob then
                fuzzy.blob_filter(state.blob, state.query, function(list, total)
                    if mygen == refilter_gen then
                        state.match_total = total
                        apply(blob_rows(list), light)
                    end
                end)
            end
            return
        end
        if state.blob then
            -- BLOB STREAM (GAP-5): the candidate POOL lives entirely in the native matcher — there is no Lua
            -- `items` array to fuzzy over. Rank the native pool and materialise ONLY the ranked top-K rows
            -- (their text pulled from the blob by index). `live_query` records which query produced this set so
            -- the render lights up the query chars for the VISIBLE rows only (like the live-source path).
            state.live_query = state.query
            fuzzy.blob_filter(state.blob, state.query, function(list, total)
                if mygen == refilter_gen then
                    state.match_total = total -- the TRUE matched count (before max_results) → the live counter
                    apply(blob_rows(list), light)
                end
            end)
        elseif opts.source then
            -- LIVE source: the query drives the results (e.g. ripgrep) — no fuzzy over a static list.
            opts.source(state.query, guarded)
        else
            -- STATIC list: narrow by the active filter bars FIRST, then fuzzy-filter the survivors.
            local pool = items
            if filters then
                -- The narrowed pool depends ONLY on the item set + which filter buttons are active, NEVER on the
                -- query. Rebuilding it (a NEW table) on every keystroke invalidated the reference-keyed candidate
                -- caches (`_texts_cache` here + fuzzy's file cache) → a full fzf temp-file rewrite per keypress.
                -- Cache it keyed by the item set (ref + length, so a refresh/stream growth rebuilds) and the
                -- active-button ids, so a pure query change REUSES the same pool table (caches stay warm).
                local parts = {}
                for _, g in ipairs(filters) do
                    parts[#parts + 1] = tostring(g.active)
                end
                local key = table.concat(parts, "|")
                if
                    state.filter_pool
                    and state.filter_pool_src == items
                    and state.filter_pool_len == #items
                    and state.filter_pool_key == key
                then
                    pool = state.filter_pool
                else
                    pool = {}
                    for _, it in ipairs(items) do
                        if passes_filters(it._src) then
                            pool[#pool + 1] = it
                        end
                    end
                    state.filter_pool, state.filter_pool_src, state.filter_pool_len, state.filter_pool_key =
                        pool, items, #items, key
                end
            end
            filter(pool, state.query, function(list)
                if mygen == refilter_gen then
                    apply(list, light)
                end
            end)
        end
    end
    -- ── GREP controller (Variant B: hold ALL rg matches in the native blob) ──────────────────────────────────
    -- Only assigned for a grep finder (opts.grep). The blob is RE-CREATED per grep query (a new needle = a new
    -- candidate set, so native indices restart at 1 and the src-cache must be cleared with it). rg streams into
    -- the blob paced + bounded: up to `config.grep_max` candidates are STORED and browsable; a broader-than-that
    -- query is still fully COUNTED (the tally in source.spawn_grep_blob) so the counter shows the real total
    -- without ever buffering past the ceiling. Killed on close / on a re-grep / on the Ctrl-g freeze.
    if opts.grep then
        ---@type fun()?  the in-flight rg's cancel (kills rg + drops its queued backlog)
        local grep_cancel
        grep_stop = function()
            if grep_cancel then
                pcall(grep_cancel)
                grep_cancel = nil
            end
        end
        --- (Re)start ripgrep for `query`: free the old blob, open a fresh one, and stream rg into it. A grep
        --- GENERATION guards the async feed/done/tick callbacks so a superseded run (a newer query, or close)
        --- can never touch the freed blob.
        ---@param query string
        grep_start = function(query)
            grep_stop()
            if state.blob then
                fuzzy.blob_free(state.blob) -- a new query = a new candidate set → reclaim the old pool eagerly
            end
            state.blob = fuzzy.blob_new()
            state.src_cache = {} -- native index → derived `_src` (indices restart at 1 for the fresh blob)
            state.pool_n, state.grep_total, state.grep_query = 0, 0, query
            state.grep_done = false -- a fresh (re)grep is streaming → don't blank the list on an empty early pass
            state.grep_gen = (state.grep_gen or 0) + 1
            local mygen = state.grep_gen
            local myblob = state.blob
            if not myblob then
                return -- blob_new failed (should not happen — opts.grep is only set when fuzzy.has_blob())
            end
            local counter = { total = 0 } -- rg's read callback tallies the TRUE match count in here (incl. overflow)
            local pending = false
            --- Push the growing pool + the live tally to the UI (a LIGHT refilter — count + rows only — while
            --- streaming; a FULL final pass fetches the preview + fits the surface).
            ---@param final boolean
            local function tick(final)
                if state.closed or mygen ~= state.grep_gen then
                    return -- superseded (a newer grep / close) → don't touch the (freed) blob
                end
                state.pool_n = fuzzy.blob_count(myblob)
                state.grep_total = counter.total
                refilter(state.query, not final)
            end
            local function feed_bytes(data)
                if state.closed or mygen ~= state.grep_gen or type(data) ~= "string" or #data == 0 then
                    return
                end
                fuzzy.blob_append(myblob, data)
                if not pending then
                    pending = true
                    vim.defer_fn(function()
                        pending = false
                        tick(false)
                    end, (config or {}).stream_refresh_ms or 50)
                end
            end
            local function done()
                if state.closed or mygen ~= state.grep_gen then
                    return
                end
                state.grep_done = true -- rg finished: an empty result is now REAL ("no matches"), so render it
                fuzzy.blob_flush(myblob) -- a final line without a trailing newline becomes a candidate
                tick(true)
            end
            local argv = source.grep_cmd(query, opts.grep.regex, opts.grep.file)
            grep_cancel = source.spawn_grep_blob(argv, feed_bytes, done, (config or {}).grep_max or 500000, counter)
        end
        --- Ctrl-g: flip GREP mode ⇄ FILTER mode (like fzf-lua's `<ctrl-g>`) — LIVE grep only. GREP→FILTER
        --- FREEZES rg at the current result set (the typed query then fuzzy-filters the loaded blob); FILTER→GREP
        --- resumes the live search (a re-grep is forced for the current query).
        grep_toggle = function()
            if not opts.grep.live then
                return -- a fixed-query grep is always in FILTER mode; there is no live search to toggle
            end
            --- Read / replace the query input line (so the mode swap can CLEAR it for a fresh filter and RESTORE
            --- the grep query when returning). Placing the cursor at the end keeps typing natural.
            local function input_text()
                return (state.input_buf and api.nvim_buf_is_valid(state.input_buf))
                        and (api.nvim_buf_get_lines(state.input_buf, 0, 1, false)[1] or "")
                    or ""
            end
            local function set_input(text)
                if state.input_buf and api.nvim_buf_is_valid(state.input_buf) then
                    api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { text })
                    local w = vim.fn.bufwinid(state.input_buf)
                    if w ~= -1 then
                        pcall(api.nvim_win_set_cursor, w, { 1, #text })
                    end
                end
            end
            if state.grep_mode == "grep" then
                state.grep_mode = "filter"
                grep_stop() -- freeze: stop driving rg; keep the blob as-is
                state.grep_saved_input = input_text() -- remember the grep query…
                set_input("") -- …and CLEAR the input for a fresh fuzzy filter over the loaded results
                state.query = ""
            else
                state.grep_mode = "grep"
                state.grep_query = nil -- force a re-grep of the restored query on the next refilter
                local restored = state.grep_saved_input or ""
                set_input(restored) -- RESTORE the grep query
                state.query = restored
                state.grep_saved_input = nil
            end
            if state.update_mode then
                state.update_mode() -- reflect the mode in the title indicator + the search-bar badge
            end
            refilter(state.query)
        end
        -- `grep_stop` is called from on_close too; expose it via state so the teardown reaches it.
        state.grep_stop = grep_stop
    end

    -- Query-driven refilter is DEBOUNCED: at huge pool sizes one match is ~100–165 ms, and running it
    -- synchronously on EVERY keystroke stacks up and freezes the UI while typing fast. Coalesce rapid
    -- keystrokes so the match runs once the user pauses (`config.debounce_ms`; 0 = off, for small/instant
    -- sets). `state.query` is recorded immediately so the prompt / gen stay in sync before the match runs.
    -- A generation guard lets superseded defer_fn timers fire as cheap no-ops (auto-closed) — no leak.
    local debounce_gen = 0
    local function refilter_debounced(q)
        state.query = q or ""
        local ms = (config or {}).debounce_ms or 50
        if ms <= 0 then
            refilter(state.query)
            return
        end
        debounce_gen = debounce_gen + 1
        local mygen = debounce_gen
        vim.defer_fn(function()
            if mygen == debounce_gen and not state.closed then
                refilter(state.query)
            end
        end, ms)
    end
    -- Activate filter button `id` in group `gi`: re-narrow + re-render, then re-sync the button specs' live
    -- `active` flags (so the header re-paints the NEW active button, not the build-time one) + counts.
    set_filter = function(gi, id)
        if not (filters and filters[gi]) then
            return
        end
        filters[gi].active = id
        if state.sync_filter then
            state.sync_filter()
        end
        refilter(state.query)
        if state.st and state.st.refresh_chrome then
            state.st.refresh_chrome()
        end
    end
    scroll_preview = function(dir)
        local p = state.preview_pan
        if p and p.win and api.nvim_win_is_valid(p.win) then
            api.nvim_win_call(p.win, function()
                vim.cmd("normal! " .. api.nvim_replace_termcodes(dir > 0 and "<C-d>" or "<C-u>", true, false, true))
            end)
        end
    end
    confirm = function()
        local it = state.filtered[state.sel]
        state.handled = true -- we own the outcome → on_close must not also fire on_cancel
        if state.st then
            state.st.close()
        end
        if it and opts.on_confirm then
            opts.on_confirm(it._src)
        end
    end
    -- Dismiss the finder (no choice). Shared by the prompt (<C-c>) and NORMAL-mode list (q / <Esc>).
    cancel = function()
        vim.cmd("stopinsert")
        state.handled = true -- deliver on_cancel HERE (not again from on_close)
        if state.st then
            state.st.close()
        end
        if opts.on_cancel then
            opts.on_cancel()
        end
    end
    -- MODE-AWARE footer legend. The move keys differ by focus — in the PROMPT (insert) `C-j`/`C-k` move the
    -- selection (`j`/`k` would type); in the NORMAL list `j`/`k` move and the filter hotkeys (`Tab` mark,
    -- `<C-q>` qf) activate directly. So the footer is rebuilt on every prompt⇄list switch via `set_footer`, and
    -- shows the keys that ACTUALLY work in the current context. `<C-f>` flips the two (→ list from the prompt,
    -- → typing from the list). Config-bound keys are labelled from their live `config.keys` value.
    local function klabel(k)
        if type(k) == "table" then
            k = k[1]
        end
        return (tostring(k or ""):gsub("^<(.-)>$", "%1"))
    end
    ---@param ctx "prompt"|"list"
    ---@return table[]  the footer item list for this focus context
    build_footer = function(ctx)
        local items
        if ctx == "list" then
            items = {
                { key = "<CR>", name = "open" },
                { key = "j/k", name = "move" },
                { key = klabel(kcfg.mark), name = "mark" },
                { key = klabel(kcfg.quickfix), name = "qf" },
            }
        else -- prompt (insert): C-j/k move the selection while you type
            items = {
                { key = "<CR>", name = "open" },
                { key = "C-j/k", name = "move" },
            }
        end
        if preview_provider then
            items[#items + 1] = { key = "C-d/u", name = "preview" }
        end
        for _, a in ipairs(opts.keys or {}) do
            if a.name then
                items[#items + 1] = { key = a.key, name = a.name }
            end
        end
        if opts.grep and opts.grep.live then
            items[#items + 1] = { key = klabel(kcfg.grep_filter), name = "grep⇄filter" }
        end
        items[#items + 1] = { key = "C-f", name = ctx == "list" and "type" or "list" } -- flip prompt⇄list
        items[#items + 1] = { key = "C-c", name = "close" }
        return items
    end
    local function set_footer_ctx(ctx)
        if state.st and state.st.set_footer then
            state.st.set_footer({ bars = { { items = build_footer(ctx) } } })
        end
    end
    -- Telescope-style modes: the prompt is INSERT (fuzzy type); <Esc> drops to NORMAL on the list (j/k move,
    -- <C-l>/<C-h> panel nav, the filter bar) — `focus_input` returns to typing, `focus_list` leaves insert.
    focus_input = function()
        local w = state.input_buf and vim.fn.bufwinid(state.input_buf) or -1
        if w ~= -1 then
            api.nvim_set_current_win(w)
            vim.cmd("startinsert!")
            set_footer_ctx("prompt") -- typing again → the prompt-context key hints
        end
    end
    local function focus_list()
        vim.cmd("stopinsert")
        if state.st and state.st.focus_block then
            state.st.focus_block("list")
        end
        set_footer_ctx("list") -- on the list → the normal-mode key hints (j/k move · Tab mark · C-q qf)
    end
    -- Run a consumer `opts.keys` action on the SELECTED item: it gets the item's source value, a `close`
    -- callback (dismiss the finder, or keep it open), and the MARKED source values (the multi-select, in mark
    -- order — empty when nothing is marked) so an action can operate on the whole selection. No selection ⇒ no-op.
    act = function(run)
        local it = state.filtered[state.sel]
        if not it then
            return
        end
        local marked = {}
        for _, s in ipairs(state.marked) do
            marked[#marked + 1] = s
        end
        run(it._src, function()
            state.handled = true -- the row action owns the outcome → on_close must not fire on_cancel
            if state.st then
                state.st.close()
            end
        end, marked)
    end

    -- layout: a centred float (default), a "bottom" dock that FLOATS over the bottom rows (statusline
    -- unaffected), or "area" — the Emacs-minibuffer model: it GROWS `cmdheight` like the msgarea cmdline
    -- zone, so a global statusline (heirline) rises ABOVE it. Both bottom/area dock full-width borderless.
    local bottom = opts.layout == "bottom"
    local area = opts.layout == "area"

    -- (HOSTED area) An `area` finder homes in the msgarea zone via the surface engine's auto-host provider
    -- (position="cmdline" + no explicit host): the zone reserves rows above the messages, the surface follows
    -- the rect, and the engine wires the descend (`on_escape_below`) + release. The picker never references
    -- msgarea; `area` alone gates the `C-j msgs` footer hint below.
    -- preview side: where the preview panel sits relative to the list. right/left → side-by-side; below/
    -- above → stacked (the surface grows its height — see ui.surface `direction = "vertical"`).
    local side = opts.preview_side or "right"
    local vertical = side == "below" or side == "above"
    -- BOTH data panels — the LIST and the PREVIEW — carry the single-source content ring (`surface.CONTENT_BORDER`,
    -- resolved live to `ui_config.content_border` at open time), so they read as two matching nested frames. The
    -- scoped INPUT prompt overlays the list's first (winbar) row but the surface places scoped bands INSIDE the
    -- panel border (`panel_content_rect`, at `row + top_inset`), so the prompt sits within the list ring — it does
    -- not land ON the top border. The NAV bands (footer, search) are bars, not blocks, so they stay borderless.
    local pbord = surface.CONTENT_BORDER
    -- The title is the chassis native centered border-title (built from this box); the match counter rides the
    -- border per `counter` (default the bottom-right border-footer). Styled via the picker's `hl` overrides.
    local title_box = (opts.title ~= nil and opts.title ~= "")
            and {
                icon = opts.icon,
                text = opts.title,
                style = {
                    icon = { hl = hl("title_icon", "LvimUiPeekTitleIcon") },
                    text = { hl = hl("title", "LvimUiPeekTitle") },
                },
            }
        or nil
    -- Prompt badge (shared `config.prompt`): an icon and/or label on the STRONG tint, then a gap on the LIGHT
    -- input tint before the typed text. Built HERE (before `update_mode`) so a live-grep <C-g> toggle can swap
    -- it — FILTER mode uses `filter_icon`/`filter_label` so the SEARCH BAR itself signals the mode.
    local prompt_hl = hl("prompt", "LvimUiPickerPrompt")
    local input_hl = hl("input", "LvimUiPickerInput")
    ---@param mode string?  "filter" swaps to the filter badge; anything else = the normal (grep/search) badge
    ---@return table  the prompt chunk list: `{ badge, prompt_hl }` + `{ gap, input_hl }`
    local function build_prompt(mode)
        local pcfg = (config or {}).prompt or {}
        local sp = string.rep
        local filter = mode == "filter"
        local icon = filter and (pcfg.filter_icon or pcfg.icon or "") or (pcfg.icon or "")
        local label = filter and (pcfg.filter_label or pcfg.label or "") or (pcfg.label or "")
        local has_icon = icon ~= ""
        local has_label = label ~= ""
        local badge = sp(" ", pcfg.pad_left or 1)
        if has_icon then
            badge = badge .. icon
        end
        if has_icon and has_label then
            badge = badge .. sp(" ", pcfg.icon_gap or 1)
        end
        if has_label then
            badge = badge .. label
        end
        badge = badge .. sp(" ", pcfg.pad_right or 1)
        return { { badge, prompt_hl }, { sp(" ", pcfg.input_gap or 1), input_hl } }
    end
    -- (grep, live only) the Ctrl-g MODE indicator: the TITLE gains "➤ filter" AND the SEARCH BAR badge swaps to
    -- the filter badge while rg is frozen (the query fuzzy-filters the loaded results). Applied live via
    -- `set_title` + `set_prompt` (an IN-PLACE repaint — the query text, cursor and on_change are untouched).
    if opts.grep and opts.grep.live then
        state.update_mode = function()
            if not (state.st and state.st.set_title) then
                return
            end
            local suffix = (state.grep_mode == "filter") and " ➤ Filter" or ""
            state.st.set_title({
                icon = opts.icon,
                text = (opts.title or "Grep") .. suffix,
                style = {
                    icon = { hl = hl("title_icon", "LvimUiPeekTitleIcon") },
                    text = { hl = hl("title", "LvimUiPeekTitle") },
                },
            })
            if state.st.set_prompt and not opts.prompt then -- swap the search-bar badge to match the mode
                state.st.set_prompt(build_prompt(state.grep_mode), prompt_hl, input_hl)
            end
        end
    end
    local list_block = {
        id = "list",
        provider = list_provider,
        border = pbord, -- the scoped prompt now sits INSIDE this border (surface panel_content_rect)
        -- 40% width side-by-side (horizontal); in a VERTICAL stack the height carries no weight, so it AUTO-fits
        -- the match count (the surface re-derives the weight per stack axis on rotation).
        size = { width = { fixed = 0.4 } },
        -- `shrink_first`: when a stacked (above/below) area can't hold both panels within the area height cap, the
        -- LIST gives up rows first (it scrolls to the focused line) so the PREVIEW keeps its content-fit height —
        -- PREVIEW PRIORITY (the file you're inspecting stays fully visible; the list scrolls).
        shrink_first = true,
    }
    local preview_block = preview_provider and { id = "preview", provider = preview_provider, border = pbord }
    local blocks
    if not preview_block then
        blocks = { list_block }
    elseif side == "left" or side == "above" then
        blocks = { preview_block, list_block }
    else
        blocks = { list_block, preview_block }
    end
    -- SLOT geometry (the float/area/bottom width + height) comes from the CENTRAL authority
    -- (lvim-utils.config.dock.geometry → dock.slot): the surface derives it when we pass NO `size`, so the
    -- picker no longer computes its own. `max_rows` still caps the LIST content height INSIDE the slot
    -- (consumer-internal — not a duplicate size), and the preview side still rotates (C-n/C-p) — only the total
    -- slot height is no longer picker-owned. FORCE — the effective per-layout anchored override: a per-call
    -- `opts.force[layout]` wins, else the plugin's own `config.dock.force[layout]` (empty {} = inherit the central
    -- geometry). Deep-copied so the `opts.height` rows-override (an EXPLICIT per-call size) can win on top. The
    -- resolved slot (`{ height?, width?, height_auto?, width_auto? }`) is passed to the surface as its `slot`
    -- override (wins over the shared geometry for this open only); its `backdrop` goes to the surface `backdrop`
    -- seam below. area/bottom ignore width (full-width), so a forced width there is a no-op — as documented.
    local eff_force = (opts.force and opts.force[opts.layout])
        or ((config or {}).dock and config.dock.force and config.dock.force[opts.layout])
    local slot_override = eff_force and vim.deepcopy(eff_force) or {}
    if opts.height then
        slot_override.height, slot_override.height_auto = opts.height, false
    end
    if not next(slot_override) then
        slot_override = nil
    end
    -- The prompt badge (built by `build_prompt` above, in the GREP/search variant): a per-call `opts.prompt`
    -- STRING overrides it; a live-grep <C-g> toggle later swaps to the FILTER badge via `state.st.set_prompt`.
    local prompt_text = opts.prompt or build_prompt("grep")
    -- The footer legend is MODE-AWARE (`build_footer`, defined near `focus_input`): the finder opens in the
    -- PROMPT, so it starts with the prompt-context hints; `focus_input`/`focus_list` swap it on every switch.
    local footer_items = build_footer("prompt")

    -- The header FILTER bar, built through the SHARED filter-group model (lvim-ui.filters) — identical to
    -- the one ui.tabs uses. The picker only supplies the SEMANTICS: the live count (items passing the OTHER
    -- groups AND this button's predicate) and the activation (set_filter). Colours default to LvimUiPeekFilter*.
    ---@return table  the header bar band spec handed to the surface
    local function build_filter_bar()
        local fb = ui_filters.bar(filters, {
            count = function(g, b)
                local n = 0
                for _, it in ipairs(items) do
                    if passes_filters(it._src, g) and (not b.predicate or b.predicate(it._src)) then
                        n = n + 1
                    end
                end
                return n
            end,
            on_select = set_filter,
        })
        state.sync_filter = fb.sync
        return fb.band
    end

    -- (HOSTED area) When the msgarea zone is enabled, a `position = "cmdline"` finder auto-homes in the zone —
    -- the surface ENGINE creates the reserve (priority 5, ABOVE the messages that compose below), owns the
    -- height (clamped to `max_height * rows`), wires the descend + reflow-follow, and bumps the zindex above the
    -- zone. We only ask for the cmdline dock; no `host` is passed. Zone off → the surface grows cmdheight itself.
    surface.open({
        mode = "float",
        -- "area" sits IN the cmdline region (grows cmdheight, heirline above) like the msgarea zone; "bottom"
        -- just floats over the bottom rows. When the msgarea zone is on, the engine re-homes us INSIDE it.
        position = area and "cmdline" or (bottom and "bottom") or nil,
        -- (HOSTED) <C-j> off the bottom sector descends INTO the messages composed below — wired by the surface
        -- auto-host provider (its `on_escape_below` = the zone's focus_messages); the picker no longer sets it.
        -- <C-k> off the TOP sector (the header/filter bar) leaves the finder UP to the editor it opened from,
        -- instead of wrapping down to the footer.
        on_escape_above = function()
            if opener and api.nvim_win_is_valid(opener) then
                api.nvim_set_current_win(opener)
            end
        end,
        -- HOSTED: float ABOVE the msgarea zone's own content panel (container 200 / panel 201) so our list /
        -- preview aren't covered by it — our panels land at 211, the prompt at 212, all clear of the messages
        -- that render in the zone panel BELOW us. Unhosted area stays in the cmdline layer at 200.
        -- Unhosted area sits in the cmdline layer at 200; when the engine auto-hosts (msgarea on) it FORCES
        -- 210 (above the zone's own panels), so this base only applies to the zone-off case.
        zindex = area and 200 or nil,
        header_air = false, -- no LEADING air row; the filter bar (or the input prompt) is the top content row
        direction = vertical and "vertical" or nil,
        preview_side = preview_provider and side or nil, -- so the surface can rotate the preview live (C-n/C-p)
        lock_keys = true, -- modal list: only the bound keys act; every other key is a no-op (the editable preview is exempt)
        title = title_box, -- the chassis native centered border-title
        title_line = opts.title_line, -- title placement: "row" (default) | "statusline" (chassis overlay) | "border" (opt-in)
        title_pos = opts.title_pos or config.title_pos, -- alignment — ONE config value for every layout
        count = count_fn, -- the live match / pool count → the chassis border counter (default bottom-right footer)
        counter = opts.counter, -- count placement: "footer" (default) | "title"
        -- The container border is CONFIG-DRIVEN on EVERY layout (float + docked) — `surface.FRAME_BORDER`
        -- resolves LIVE to `ui_config.border`, so there is NO hardcoded per-layout border. Each content block
        -- carries its OWN ring (CONTENT_BORDER); the chassis draws the configurable inter-panel divider
        -- (`ui_config.separator`) BETWEEN the list and preview — auto-oriented, only at the gap, so a SINGLE
        -- panel (preview hidden / no preview) shows none.
        border = surface.FRAME_BORDER,
        -- No `size`: the surface derives the slot from the central geometry (dock.slot) when none is passed.
        -- `slot` is the optional per-open anchored override (force + a rows `opts.height` for a docked layout).
        slot = slot_override,
        -- FORCE backdrop: the surface's own backdrop seam (merged over the central `dock.geometry.<layout>.backdrop`
        -- inside dock.slot). nil = inherit the central default; a `force[layout].backdrop` table/false wins here.
        backdrop = eff_force and eff_force.backdrop,
        header = {
            bars = (function()
                local hb = {}
                -- The title + counter are the chassis border-title / border-counter (no CONTENT title row). The
                -- header bars are the filter bar (when any) + the scoped input prompt.
                if filters then
                    hb[#hb + 1] = build_filter_bar() -- a real header row above the prompt
                    hb[#hb + 1] = { text = "" } -- 1 blank air row under the filter (button) bar
                end
                hb[#hb + 1] = {
                    input = true,
                    prompt = prompt_text,
                    prompt_hl = prompt_hl,
                    input_hl = input_hl,
                    filetype = "lvim-picker-prompt",
                    -- scope the prompt to the LIST panel (by id, so it tracks it through every preview rotation):
                    -- the input always sits just above the list, never over the preview.
                    scope_id = preview_provider and "list" or nil,
                    on_change = refilter_debounced,
                    keys = function(buf, st)
                        state.st = st
                        state.input_buf = buf -- so NORMAL-mode list can jump back to typing (focus_input)
                        -- the typed-text caret (config.caret) — same as the fzf finder. Through the
                        -- cursor module so it coexists with cursor-hiding; cleared on close.
                        pcall(require("lvim-utils.cursor").mark_cursor_buffer, buf, source.caret_fragment("i-ci-ve"))
                        local function imap(lhs, fn)
                            vim.keymap.set("i", lhs, fn, { buffer = buf, nowait = true, silent = true })
                        end
                        imap("<C-j>", function()
                            move(1)
                        end)
                        imap("<Down>", function()
                            move(1)
                        end)
                        imap("<C-k>", function()
                            move(-1)
                        end)
                        imap("<Up>", function()
                            move(-1)
                        end)
                        imap("<C-d>", function()
                            scroll_preview(1)
                        end)
                        imap("<C-u>", function()
                            scroll_preview(-1)
                        end)
                        imap("<CR>", function()
                            vim.cmd("stopinsert")
                            confirm()
                        end)
                        imap("<C-c>", cancel) -- hard cancel from the prompt
                        -- (grep) Ctrl-g: toggle GREP ⇄ FILTER mode (drive rg vs fuzzy-filter the loaded blob).
                        if grep_toggle then
                            for _, k in ipairs(keylist(kcfg.grep_filter)) do
                                imap(k, grep_toggle)
                            end
                        end
                        -- Swap the finder's backend (tint ⇄ fzf) while typing — command finders only.
                        if opts.reopen then
                            for _, k in ipairs(keylist(kcfg.swap_backend)) do
                                imap(k, function()
                                    swap_backend("tint", opts)
                                end)
                            end
                        end
                        -- Telescope-style: <Esc> / <C-f> drop to NORMAL on the list (where the filter hotkeys
                        -- activate directly — typing in INSERT would feed them to the query). <C-f> in normal
                        -- toggles back to typing.
                        imap("<Esc>", focus_list)
                        imap("<C-f>", focus_list)
                        -- consumer row actions: `opts.keys = { { key = lhs, run = fn(item, close) } }` — e.g.
                        -- open in a split, run a code action, yank. `run` gets the selected item + a close fn.
                        for _, a in ipairs(opts.keys or {}) do
                            imap(a.key, function()
                                vim.cmd("stopinsert")
                                act(a.run)
                            end)
                        end
                    end,
                }
                return hb
            end)(),
        },
        content = { blocks = blocks },
        footer = {
            bars = {
                {
                    items = footer_items,
                },
            },
        },
        close_keys = {}, -- the input owns <Esc>/<C-c>; the panels are not normally focused
        on_close = function()
            state.closed = true
            -- Dismissed externally (replaced by the next finder via the shared registry, or a surface-owned
            -- close) with no confirm / cancel / row action having run → treat it as a cancel so restore-on-cancel
            -- finders (e.g. colorschemes) are not silently skipped. `confirm`/`cancel`/`act` set `state.handled`.
            if not state.handled and opts.on_cancel then
                pcall(opts.on_cancel)
            end
            if opts.on_close then -- a finder's own teardown hook (e.g. live grep killing its in-flight rg)
                pcall(opts.on_close)
            end
            pcall(function()
                require("lvim-hud.overlay").clear()
            end) -- idempotent: drop the chrome-overlay title/counter if `title_line="statusline"` published it
            if state.stream_cancel then -- kill a still-running async producer (e.g. `fd` over a huge tree)
                pcall(state.stream_cancel)
                state.stream_cancel = nil
            end
            if state.count_cancel then -- kill the background grep file-count (fd) if still running
                pcall(state.count_cancel)
                state.count_cancel = nil
            end
            if state.grep_stop then -- kill an in-flight grep rg (the controller's live/fixed producer)
                pcall(state.grep_stop)
            end
            _texts_cache = nil -- drop the cached candidate texts (and the fuzzy prepared context) for this run
            fuzzy.release()
            if state.blob then -- free the native blob-stream pool (a huge tree's SoA reclaimed eagerly)
                fuzzy.blob_free(state.blob)
                state.blob = nil
                state.src_cache = nil
            end
            if state.input_buf then -- drop the custom blue caret registration (cursor module restores normal)
                pcall(require("lvim-utils.cursor").mark_cursor_buffer, state.input_buf, nil)
            end
            source.clear_active(active_entry) -- forget the current finder once it closes (only if it is still us)
            -- (the engine releases its own auto-host msgarea segment on surface close — nothing to do here)
            if state.live_augroup then
                pcall(api.nvim_del_augroup_by_id, state.live_augroup)
                state.live_augroup = nil
            end
            -- DOCK bookkeeping. A DOCK-DRIVEN teardown (`state.dock_teardown` — a park via `hide`, or a kill via
            -- `close`) is silent: it must NOT re-notify the dock (it drove this) and must NOT forget the opts (a
            -- park keeps them; `close` already cleared them). A SELF / EXTERNAL close (a confirm / cancel / `:q`)
            -- means the finder is DONE — forget it and tell the dock to DROP the entry (without revealing another;
            -- focus returns to the editor the finder opened from, so a confirm's own file-open lands there).
            if sk then
                if not state.dock_teardown then
                    -- PARK + REMEMBER: a self / external close (confirm / cancel / q / :q, or replaced by
                    -- another finder) KEEPS the remembered rebuild (`pending[sk]`) so the entry stays alive —
                    -- cyclable with <Leader>n/p and listed in the <Leader>m menu — and only COLLAPSES the layout
                    -- (no neighbour revealed, focus returns to the editor). Only `<Leader>x` (dock M.close →
                    -- consumer.close) truly forgets the rebuild + drops the entry from the stack. Pass the STORED
                    -- dock entry KEY (id, layout), not a reconstructed one.
                    local d = get_dock()
                    if d and entry_keys[sk] then
                        pcall(d.parked, entry_keys[sk])
                    end
                end
                if live[sk] == state then
                    live[sk] = nil
                end
            end
        end,
    })

    source.set_active(active_entry) -- track THIS finder as the open one (its surface is now live)
    if sk then
        live[sk] = state -- expose the live surface to the dock consumer (buffers / focus / is_current / re-show)
    end

    -- initial: show all, select the first, preview it (fetch + fit + render)
    rerender()

    -- LIVE refresh: re-fetch the static items on `opts.refresh_events` (e.g. "DiagnosticChanged") via
    -- `opts.refresh()`, then re-narrow (filters) + re-fuzzy + re-render. Coalesce a burst into ONE reload.
    -- `opts.close_on_empty` dismisses the finder once nothing is left (e.g. all diagnostics fixed). Torn
    -- down in on_close.
    if opts.refresh and opts.refresh_events and not opts.source then
        state.live_augroup =
            api.nvim_create_augroup("LvimPickerLive_" .. tostring(state.st and state.st.container_buf or 0), {})
        local scheduled = false
        api.nvim_create_autocmd(opts.refresh_events, {
            group = state.live_augroup,
            callback = function(ev)
                -- ignore the echo from our OWN preview buffers (mirroring would loop)
                if state.preview_pan and state.preview_pan.buf == ev.buf then
                    return
                end
                if scheduled or state.closed then
                    return
                end
                scheduled = true
                vim.schedule(function()
                    scheduled = false
                    if state.closed then
                        return
                    end
                    -- Do NOT rebuild while a multi-select is in progress: a refresh produces NEW item tables, so
                    -- the marks (keyed by source value) would vanish and the cursor jump to the top mid-marking
                    -- (and the stale-list re-render could even crash). Hold the live update until the marks clear.
                    if #state.marked > 0 then
                        return
                    end
                    local fresh = opts.refresh()
                    if type(fresh) ~= "table" then
                        return
                    end
                    if #fresh == 0 and opts.close_on_empty and state.st then
                        state.st.close()
                        return
                    end
                    items = normalize(fresh, opts.format)
                    refilter(state.query)
                end)
            end,
        })
    end

    -- (grep) BACKGROUND FILE COUNT: grep's counter is `matches / total files in the tree`, so — alongside rg —
    -- stream the SAME file list the `files` finder uses (`file_list_cmd`) purely to COUNT it (the bytes are
    -- discarded, only newlines are tallied; paced + 0%-blocked exactly like the files load). The count climbs to
    -- the tree's file total, which `count_fn` uses as the counter's denominator. Killed in on_close.
    if opts.count_files then
        state.file_total = 0
        local pending_c = false
        state.count_cancel = spawn_stream_raw(file_list_cmd(), function(data)
            local _, n = data:gsub("\n", "\n")
            state.file_total = state.file_total + n
            if not pending_c then -- coalesce the counter refresh (the number climbs smoothly, not per chunk)
                pending_c = true
                vim.defer_fn(function()
                    pending_c = false
                    if not state.closed then
                        refresh_count()
                    end
                end, (config or {}).stream_refresh_ms or 50)
            end
        end, function()
            if not state.closed then
                refresh_count()
            end
        end)
    end

    -- GREP CONTROLLER (Variant B): kick off the search. A LIVE grep waits for the user to type (>= min_chars) —
    -- refilter's on_change drives the first rg. A FIXED-query grep (cword / cWORD / selection / prompt / curbuf)
    -- runs rg ONCE now, into the blob, and starts in FILTER mode so the typed query fuzzy-narrows the results.
    -- Requires ABI ≥ 5 (M.grep only sets opts.grep on the blob path); the fallback uses opts.source / opts.stream.
    if opts.grep then
        state.grep_mode = opts.grep.live and "grep" or "filter"
        if not opts.grep.live then
            grep_start(opts.grep.query or "")
        end
        return
    end

    -- ASYNC BLOB STREAM (GAP-5): `opts.blob_stream(feed_bytes, done)` produces the listing incrementally, and
    -- `feed_bytes(raw)` hands the producer's RAW stdout bytes STRAIGHT to the native matcher (which splits on
    -- `\n` and stores each line as a candidate) — ZERO Lua per-row string/table work, so a ~2M-file tree loads
    -- without building (and interning + GC-ing) a multi-million-string Lua pool. The candidate pool IS the
    -- native context; `refilter` ranks it and materialises only the top-K rows. `opts.blob_item(text)` derives
    -- an item's `_src` from its path (files/dirs/git: `{ path = text }`). The producer is killed + the context
    -- freed in on_close. Requires ABI ≥ 5 (`fuzzy.has_blob()`); a finder falls back to `opts.stream` otherwise.
    -- Mutually exclusive with the per-query live `source` and the per-string `stream`.
    if opts.blob_stream and not opts.source then
        state.blob = fuzzy.blob_new()
    end
    if state.blob then
        state.src_cache = {} -- native index → derived `_src` item (stable identity for marks; see blob_rows)
        state.pool_n = 0
        local pending = false
        --- Ingest one raw stdout chunk into the native pool (no Lua per-row work), then schedule ONE coalesced
        --- light refilter so the count + visible rows track the growing pool.
        ---@param data string
        local function feed_bytes(data)
            if state.closed or type(data) ~= "string" or #data == 0 then
                return
            end
            state.pool_n = fuzzy.blob_append(state.blob, data)
            if not pending then
                pending = true
                vim.defer_fn(function()
                    pending = false
                    if not state.closed then
                        refilter(state.query, true) -- LIGHT: count + rows only (see rerender)
                    end
                end, (config or {}).stream_refresh_ms or 200)
            end
        end
        local function done()
            if state.closed then
                return
            end
            fuzzy.blob_flush(state.blob) -- a final line without a trailing newline becomes a candidate
            state.pool_n = fuzzy.blob_count(state.blob)
            refilter(state.query) -- FULL final pass: fetch the preview + fit the surface to the result
        end
        state.stream_cancel = opts.blob_stream(feed_bytes, done)
        return
    end

    -- ASYNC STREAM source: `opts.stream(feed, done)` produces candidates incrementally (a spawned `fd` / `rg`
    -- streamed in via `spawn_stream`), so the open NEVER blocks on a huge tree. `feed(raw)` appends the batch
    -- to the candidate pool and schedules ONE coalesced refilter (fuzzy is already async); `done()` does a
    -- final pass. The producer is killed in on_close. Mutually exclusive with the per-query live `source`. This
    -- is the FALLBACK path (an older .so without blob ingestion) — the blob path above supersedes it when ABI≥5.
    if opts.stream and not opts.source then
        local pending = false
        local function feed(raw)
            if state.closed or type(raw) ~= "table" or #raw == 0 then
                return
            end
            local n = #items -- one length probe per batch, not one per row (this loop runs ~2M times on ~/)
            for _, it in ipairs(normalize(raw, opts.format)) do
                n = n + 1
                items[n] = it
            end
            if not pending then
                pending = true
                -- Coalesce a burst of stream chunks into one re-render. Long enough (config.stream_refresh_ms)
                -- that the async query match SETTLES between refreshes instead of being superseded every time
                -- (which would show nothing until the stream ended), and it thins the per-refresh ensure_ctx
                -- append while files pour in.
                vim.defer_fn(function()
                    pending = false
                    if not state.closed then
                        refilter(state.query, true) -- LIGHT: count + rows only, no preview / relayout (see rerender)
                    end
                end, (config or {}).stream_refresh_ms or 200)
            end
        end
        local function done()
            if not state.closed then
                refilter(state.query) -- FULL final pass: now fetch the preview + fit the surface to the result
            end
        end
        state.stream_cancel = opts.stream(feed, done)
    end
end

--- Route a finder-KIND open through the dock stack. MANAGED (the caller already resolved: dock manager present
--- AND a stable key AND the effective `dock_stack` flag): remember the `rebuild` closure (the dock's `is_alive`
--- reads it), refresh the consumer's live name / icon / layout / anchored `slot` (force) override, and
--- SHOW-OR-CREATE it through the dock — which dedups by id and enforces one-visible-per-layout (parking any
--- OTHER visible consumer there), then calls the consumer's `show`, which runs the rebuild. UN-MANAGED (no
--- manager / no key / `dock_stack = false`): just run `rebuild()` (the classic replace-in-place). ONE layer for
--- BOTH backends — only the rebuild differs (`build(opts, key)` for the tint list, `fzf.open(fzf_opts)` for the
--- fzf TUI).
---@param managed boolean  route through the dock stack (dock present AND `kind` AND the effective `dock_stack`)
---@param kind string?    the dock kind (nil ⇒ un-managed)
---@param layout string  the dock layout this kind occupies ("area"|"bottom"|"float")
---@param meta { title?: string, icon?: string }  entry display name / glyph source (falls back to KIND_META)
---@param rebuild fun()  (re)materialises this (kind, layout) slot's surface from its remembered opts (backend-specific)
---@param slot? table  the consumer's anchored geometry (force) override for `dock.slot` (nil = inherit central)
local function route(managed, kind, layout, meta, rebuild, slot)
    local d = get_dock()
    if managed and d and kind then
        -- FILE the rebuild + open under the (kind, layout) slot key — so opening the SAME kind in another layout
        -- is a SEPARATE entry with its own consumer / surface, and STORE the dock's returned entry key to pass
        -- back to the lifecycle APIs.
        local sk = slot_key(kind, layout)
        pending[sk] = rebuild
        local c = get_consumer(kind, layout) -- one consumer per (kind, layout); its `layout` is fixed at creation
        local km = KIND_META[kind]
        c.name = (meta and meta.title) or (km and km.name) or kind
        c.icon = (meta and meta.icon) or (km and km.icon) or "󰍉"
        c.slot = slot -- ANCHORED force override → do_show feeds it to dock.slot as ctx.rect
        entry_keys[sk] = d.open(c) -- STORE the returned (id, layout) entry key for parked/refresh_leader/dropped
    else
        rebuild()
    end
end

--- Open a fuzzy finder: a centred float with a query input on top, a results list and (with `preview`) a
--- scrollable preview beside it. INSERT prompt: type to filter (fzf), `<C-j>/<C-k>` move, `<C-d>/<C-u>`
--- scroll the preview, `<CR>` confirms, `<C-c>` cancels, `<Esc>`/`<C-f>` → NORMAL. NORMAL list: `j`/`k`
--- move, `<C-d>/<C-u>` scroll preview, `<C-l>`/`<C-h>` panel nav, filter hotkeys, `q` close, `/` → typing.
---
--- Participates in the shared DOCK STACK (lvim-utils.dock) when present: each finder KIND is its own entry
--- (`id = "lvim-picker:<kind>"`, keyed by `opts.key` — else a slug of the title), one visible per layout,
--- cyclable with `<Leader>n`/`<Leader>p`, killable with `<Leader>x`, listed in the `<Leader>m` menu. Opening
--- another kind in the same layout PARKS this one (restorable); re-opening a live kind rebuilds it fresh in
--- place. Without the dock (or a resolvable key) it falls back to the classic replace-in-place open.
---@param opts LvimPickerOpts
function M.open(opts)
    opts = opts or {}
    opts.layout = opts.layout or (config or {}).layout or "area"
    local key = resolve_key(opts)
    -- Effective dock_stack: a per-call `opts.dock_stack` OVERRIDES the plugin's own `config.dock.dock_stack` for
    -- THIS open (a caller plugin opening THROUGH the picker controls docking for its entry). nil ⇒ inherit config.
    local stack = opts.dock_stack
    if stack == nil then
        stack = (config or {}).dock and config.dock.dock_stack
    end
    -- MANAGED only when the dock is present AND a key resolves AND the effective dock_stack is on — the rebuild
    -- then passes that key to `build` (managed: skip close_active, register `live`, do the on_close dock
    -- bookkeeping); un-managed passes nil (the classic `source.close_active` replace-in-place).
    local managed = get_dock() ~= nil and key ~= nil and stack ~= false
    -- The consumer's anchored force override for the stack path: per-call `opts.force[layout]` wins, else own
    -- `config.dock.force[layout]` (empty {} = inherit). build recomputes the SAME for its surface slot either way.
    local eff_force = (opts.force and opts.force[opts.layout])
        or ((config or {}).dock and config.dock.force and config.dock.force[opts.layout])
    route(managed, key, opts.layout, { title = opts.title, icon = opts.icon }, function()
        build(opts, managed and key or nil)
    end, eff_force)
end

--- Open a finder through the fzf-TUI backend MANAGED by the dock stack, exactly as `M.open` manages the tint
--- list — so `:LvimPicker files` / `grep` / … participate in the dock stack under the DEFAULT `fzf_tui = true`
--- config, not only the tint fallback. When managed it injects the dock hooks the fzf backend calls back
--- through (register the live fzf surface on open; re-arm the leader owner after a keep-open restart;
--- PARK+REMEMBER on a self/external close) and routes with a rebuild that re-invokes `fzf.open`. Un-managed (no
--- manager / no key) it opens fzf in place (fzf's own `source.close_active` replace). ONE dock layer — the
--- consumer contract is NOT duplicated into fzf.lua; the backend only reports its live state + self-close.
---@param b table              the fzf backend (`require("lvim-picker.fzf")`)
---@param fzf_opts LvimFzfOpts  the fully-built fzf finder spec (carries `key` + `title`)
open_fzf = function(b, fzf_opts)
    fzf_opts.layout = fzf_opts.layout or (config or {}).layout or "area"
    local key = resolve_key(fzf_opts)
    -- Effective dock_stack: a per-call `fzf_opts.dock_stack` overrides the plugin's own `config.dock.dock_stack`.
    local stack = fzf_opts.dock_stack
    if stack == nil then
        stack = (config or {}).dock and config.dock.dock_stack
    end
    local managed = get_dock() ~= nil and key ~= nil and stack ~= false
    if managed then
        ---@cast key string  `managed` implies `key ~= nil` (LS can't narrow it across the `and` on its own)
        -- The (kind, layout) slot this fzf open files its live state / dock bookkeeping under — so `files` in
        -- float and `files` in bottom are two independent fzf surfaces / dock entries.
        local sk = slot_key(key, fzf_opts.layout)
        -- The dock hooks fzf.open calls back through: `on_open` hands us the live surface `state` (so the
        -- consumer's buffers / focus / is_current read it, and `hide` can park it) + wires its `dock_focus`
        -- (re-enter the fzf terminal list); `on_restart` re-installs the leader owner (by the STORED entry key)
        -- after a keep-open restart swaps the terminal buffer; `on_close` (run inside fzf's surface on_close)
        -- MIRRORS the tint bookkeeping — a dock-driven teardown (park/close, flagged `dock_teardown`) is silent,
        -- a self/external close (confirm/cancel/:q) PARKS + REMEMBERS the entry (keeps `pending[sk]`,
        -- `d.parked`s it by the stored key → stays alive / cyclable / in the menu, collapses the layout, focus
        -- returns to the editor). Only `<Leader>x` drops it.
        fzf_opts.dock = {
            on_open = function(state)
                state.dock_focus = function()
                    if state.st and state.st.focus_block then
                        pcall(state.st.focus_block, "list")
                    end
                end
                live[sk] = state
            end,
            on_restart = function()
                local d = get_dock()
                if d and d.refresh_leader and entry_keys[sk] then
                    d.refresh_leader(entry_keys[sk])
                end
            end,
            on_close = function(state)
                if not state.dock_teardown then
                    local d = get_dock()
                    if d and entry_keys[sk] then
                        pcall(d.parked, entry_keys[sk])
                    end
                end
                if live[sk] == state then
                    live[sk] = nil
                end
            end,
        }
    end
    local eff_force = (fzf_opts.force and fzf_opts.force[fzf_opts.layout])
        or ((config or {}).dock and config.dock.force and config.dock.force[fzf_opts.layout])
    route(managed, key, fzf_opts.layout, { title = fzf_opts.title, icon = fzf_opts.icon }, function()
        b.open(fzf_opts)
    end, eff_force)
end

--- A ready finder over the listed buffers; confirming switches to the chosen buffer, with a content preview.
---@param opts? table  forwarded to M.open
function M.buffers(opts)
    opts = opts or {}
    opts.key = opts.key or "buffers"
    with_backend_swap(opts) -- enable the C-] backend swap (tint ⇄ fzf) for this finder
    local items = {}
    for _, b in ipairs(api.nvim_list_bufs()) do
        if vim.bo[b].buflisted then
            local name = api.nvim_buf_get_name(b)
            name = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]"
            items[#items + 1] = { text = name, bufnr = b }
        end
    end
    --- Preview a listed buffer's content, with a filetype for syntax.
    ---@param bufnr integer
    ---@param name string
    ---@return string[] lines, string filetype
    local function buf_preview(bufnr, name)
        local ft = (bufnr and api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype) or ""
        if ft == "" and name ~= "" and name ~= "[No Name]" then
            ft = vim.filetype.match({ filename = name }) or ""
        end
        if bufnr and api.nvim_buf_is_loaded(bufnr) then
            return api.nvim_buf_get_lines(bufnr, 0, 500, false), ft
        end
        if name ~= "" and name ~= "[No Name]" and vim.fn.filereadable(name) == 1 then
            return vim.fn.readfile(name, "", 500), ft
        end
        return { "[no preview]" }, ""
    end
    local fb = fzf_backend(opts)
    if fb then
        -- Encode each entry as `bufnr\tname`; fzf shows/matches only field 2 (the name) via
        -- `--delimiter`/`--with-nth`, but hands back the whole line so we recover the bufnr.
        local contents = {}
        for _, it in ipairs(items) do
            contents[#contents + 1] = ("%d\t%s%s"):format(it.bufnr, source.file_icon(it.text), it.text)
        end
        open_fzf(
            fb,
            vim.tbl_extend("force", {
                title = "Buffers",
                contents = contents,
                fzf_args = { "--delimiter=\t", "--with-nth=2" },
                parse = function(line)
                    local bufnr, name = line:match("^(%d+)\t(.*)$")
                    name = name and source.strip_icon(name) or line -- drop the leading coloured ft icon
                    bufnr = tonumber(bufnr)
                    -- The display `name` is the `:~:.` form, which is NOT a usable path (`~` is unexpanded, and it
                    -- is cwd-relative) — so preview/quickfix must carry the ABSOLUTE path, resolved from the buffer
                    -- (like oldfiles does). "[No Name]" buffers stay text-only.
                    local abs = (bufnr and api.nvim_buf_is_valid(bufnr)) and api.nvim_buf_get_name(bufnr) or ""
                    if abs == "" and name ~= "[No Name]" then
                        abs = vim.fn.fnamemodify(name, ":p")
                    end
                    return { bufnr = bufnr, text = name, path = (abs ~= "") and abs or nil }
                end,
                preview = function(it)
                    return buf_preview(it.bufnr, it.path or it.text or "")
                end,
                on_confirm = function(it)
                    if it and it.bufnr and api.nvim_buf_is_valid(it.bufnr) then
                        api.nvim_set_current_buf(it.bufnr)
                    end
                end,
            }, opts)
        )
        return
    end
    M.open(vim.tbl_extend("force", {
        title = "Buffers",
        items = items,
        on_confirm = function(it)
            if it and api.nvim_buf_is_valid(it.bufnr) then
                api.nvim_set_current_buf(it.bufnr)
            end
        end,
        preview = function(it)
            local b = it.bufnr
            local name = b and api.nvim_buf_get_name(b) or ""
            -- the filetype drives the preview's syntax: a loaded buffer's own ft, else match by filename
            local ft = (b and api.nvim_buf_is_loaded(b) and vim.bo[b].filetype) or ""
            if ft == "" and name ~= "" then
                ft = vim.filetype.match({ filename = name }) or ""
            end
            if b and api.nvim_buf_is_loaded(b) then
                return api.nvim_buf_get_lines(b, 0, 500, false), ft
            end
            if name ~= "" and vim.fn.filereadable(name) == 1 then
                return vim.fn.readfile(name, "", 500), ft
            end
            return { "[no preview]" }, ""
        end,
    }, opts or {}))
end

-- ── file / directory / grep finders ────────────────────────────────────────────
-- The listing commands (file_list_cmd / dir_list_cmd), the preview reader (read_preview) and the async
-- streamer (spawn_stream) are aliased from picker.source at the top of the file, so this tint backend and
-- the fzf-TUI backend share one source layer.

--- Configure `spec` (a tint finder whose candidates ARE their paths — files / directories / git_files) to
--- STREAM `list_cmd` into the pool. GAP-5: when the native matcher supports blob ingestion (ABI ≥ 5) the raw
--- stdout bytes go straight to the native context (`blob_stream` + `blob_item` — no Lua per-row work, so a
--- multi-million-file tree never builds a Lua string pool); otherwise it falls back to the per-string line
--- stream (`stream`). `text == path` for these finders, so `_src` is `{ path = text }` either way.
---@param spec table  the finder spec passed to M.open (mutated in place)
---@param list_cmd string[]  the listing command (argv)
local function stream_paths(spec, list_cmd)
    if fuzzy.has_blob() then
        spec.blob_stream = function(feed_bytes, done)
            return spawn_stream_raw(list_cmd, feed_bytes, done)
        end
        spec.blob_item = function(text)
            return { path = text }
        end
    else
        spec.stream = function(feed, done)
            return spawn_stream(list_cmd, function(lines)
                local batch = {}
                for _, p in ipairs(lines) do
                    if p ~= "" then
                        batch[#batch + 1] = { text = p, path = p }
                    end
                end
                feed(batch)
            end, done)
        end
    end
end

--- Parse one ripgrep `--vimgrep` line (`path:lnum:col:text`) into a location item. Shared by the grep blob
--- path (as `blob_item`, deriving `_src` from the candidate text on demand) and the fallback item stream.
--- Returns nil for a line that is not a location (so the caller can decide the fallback).
---@param line string
---@return { path: string, lnum: integer, col: integer, text: string }?
local function grep_item(line)
    local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
    if file then
        return { path = file, lnum = tonumber(lnum), col = tonumber(col), text = text or "" }
    end
end

--- A BOUNDED line streamer for a grep argv, building location ITEMS (the fallback when the native library
--- predates the blob API, ABI < 5). Same `config.grep_max` cap (enforced in the read callback) + async
--- streaming as the blob path — never floods the queue, never blocks. Returns a producer for `opts.stream`.
---@param argv string[]
---@return fun(feed: fun(raw: table[]), done: fun()): fun()
local function grep_item_stream(argv)
    return function(feed, done)
        return spawn_stream(argv, function(lines)
            local batch = {}
            for _, ln in ipairs(lines) do
                local it = grep_item(ln)
                if it then
                    it.text = ("%s:%s  %s"):format(it.path, it.lnum, it.text) -- display; _src keeps path/lnum/col
                    batch[#batch + 1] = it
                end
            end
            if #batch > 0 then
                feed(batch)
            end
        end, done, (config or {}).grep_max or 500000)
    end
end

--- Fuzzy file finder under cwd; confirming edits the file, with a content preview. `opts` forwarded to open.
---@param opts? table
function M.files(opts)
    opts = opts or {}
    opts.key = opts.key or "files" -- dock kind key (tint/managed path); the fzf backend ignores it
    with_backend_swap(opts) -- enable the C-] backend swap (tint ⇄ fzf) for this finder
    local b = fzf_backend(opts)
    if b then
        -- fzf runs `file_list_cmd()` as its producer (FZF_DEFAULT_COMMAND) and owns the list; we keep the
        -- real-Neovim preview + the open action.
        open_fzf(
            b,
            vim.tbl_extend("force", {
                title = "Files",
                cmd = source.with_icons(file_list_cmd()),
                parse = function(line)
                    return { path = source.strip_icon(line) }
                end,
                fzf_args = { "--nth", "2.." }, -- fuzzy-match the path, not the leading coloured icon
                preview = function(it)
                    return read_preview(it.path)
                end,
                on_confirm = function(it)
                    if it and it.path then
                        vim.cmd.edit(vim.fn.fnameescape(it.path))
                    end
                end,
            }, opts)
        )
        return
    end
    local spec = {
        title = "Files",
        on_confirm = function(it)
            if it and it.path then
                vim.cmd.edit(vim.fn.fnameescape(it.path))
            end
        end,
        -- ASYNC file preview (read off the main thread, LRU-cached) so it follows the cursor while scrolling.
        preview_file_of = function(s)
            return s.path and s.path ~= "" and { path = s.path } or nil
        end,
    }
    stream_paths(spec, file_list_cmd())
    M.open(vim.tbl_extend("force", spec, opts or {}))
end

--- Fuzzy directory finder under cwd; confirming `:cd`s into the chosen directory. `opts` forwarded to open.
---@param opts? table
function M.directories(opts)
    opts = opts or {}
    opts.key = opts.key or "directories"
    with_backend_swap(opts) -- enable the C-] backend swap (tint ⇄ fzf) for this finder
    local b = fzf_backend(opts)
    if b then
        open_fzf(
            b,
            vim.tbl_extend("force", {
                title = "Directories",
                cmd = source.with_dir_icon(dir_list_cmd()),
                parse = function(line)
                    return { path = source.strip_icon(line) }
                end,
                fzf_args = { "--nth", "2.." }, -- match the path, not the leading folder icon
                preview = function(it)
                    return run_lines({ "ls", "-A", it.path }), ""
                end,
                on_confirm = function(it)
                    if it and it.path then
                        vim.cmd.cd(vim.fn.fnameescape(it.path))
                    end
                end,
            }, opts)
        )
        return
    end
    local spec = {
        title = "Directories",
        on_confirm = function(it)
            if it and it.path then
                vim.cmd.cd(vim.fn.fnameescape(it.path))
            end
        end,
        preview = function(it)
            return run_lines({ "ls", "-A", it.path }), ""
        end,
    }
    stream_paths(spec, dir_list_cmd())
    M.open(vim.tbl_extend("force", spec, opts or {}))
end

--- LIVE grep (ripgrep) under cwd: each query re-runs `rg`, the matches ARE the results, with a preview that
--- jumps to the matched line; confirming opens the file at that line. `opts` forwarded to open.
---@param opts? table
function M.grep(opts)
    opts = opts or {}
    opts.key = opts.key or "grep" -- a fixed-query variant (cword / …) sets its own key BEFORE calling here
    with_backend_swap(opts) -- enable the C-] backend swap (tint ⇄ fzf) for this finder
    if not has("rg") then
        vim.notify("lvim-picker.grep needs ripgrep (rg)", vim.log.levels.WARN)
        return
    end
    -- Parse a ripgrep `--vimgrep` line into a location item. The col is followed by `:text` in the 1-row
    -- layout and by `\n    text` in the fzf-lua 2-row layout, so the match stops right after the col number.
    local function parse_grep(line)
        line = source.strip_icon(line) -- drop the leading coloured ft icon (+ any ANSI) before parsing
        -- The record is either the 1-row `path:lnum:col:text` or the fzf-lua 2-row `path:lnum:col\n    text`.
        -- Split off the second row FIRST so its embedded newline (and indent) never reach the quickfix text;
        -- parse the location from the header, and keep the matched text as the trimmed remainder.
        local head, tail = line:match("^([^\n]*)\n%s*(.*)$")
        head = head or line
        local file, lnum, col, rest = head:match("^(.-):(%d+):(%d+):?(.*)$")
        if file then
            return { path = file, lnum = tonumber(lnum), col = tonumber(col), text = tail or rest or "" }
        end
        return { path = line, text = line }
    end
    local b = fzf_backend(opts)
    if b then
        -- fzf live mode: each keystroke RELOADS ripgrep with the query — fzf re-renders the matches
        -- continuously. fzf does no fuzzy ranking of its own (`--disabled`); rg IS the search.
        local backend = {
            title = opts.title or "Grep",
            parse = parse_grep,
            multiline = source.fzf_multiline(), -- fzf-lua 2-row layout (location row + indented text row)
            preview = function(it)
                local lines, ft = read_preview(it.path, preview_span(it.lnum))
                return lines, ft, it.lnum -- focus the matched line
            end,
            on_confirm = function(it)
                if it and it.path then
                    vim.cmd.edit(vim.fn.fnameescape(it.path))
                    pcall(api.nvim_win_set_cursor, 0, { it.lnum or 1, (it.col or 1) - 1 })
                    vim.cmd("normal! zz")
                end
            end,
        }
        if opts.query and opts.query ~= "" then
            -- fixed-query grep (cword / cWORD / selection / prompt): rg runs ONCE, fzf fuzzy-filters the matches
            backend.cmd = source.grep_static_cmd(opts.query, opts.regex)
            backend.fzf_args = { "--nth", "2.." } -- match the path/text, not the leading coloured icon
        else
            backend.reload = source.grep_reload(opts.regex, opts.file) -- live grep (opts.file → curbuf only)
        end
        open_fzf(b, vim.tbl_extend("force", backend, opts))
        return
    end
    local fixed = opts.query ~= nil and opts.query ~= "" -- a fixed-query grep (cword / cWORD / selection / …)
    local tint = {
        title = "Grep",
        -- ASYNC file preview, focused on the matched line — read off the main thread + LRU-cached, so scrolling
        -- grep results (every row a different file:line) follows the cursor instead of a per-move disk read.
        preview_file_of = function(s)
            return s.path and s.path ~= "" and { path = s.path, lnum = s.lnum } or nil
        end,
        on_confirm = function(it)
            if it and it.path then
                vim.cmd.edit(vim.fn.fnameescape(it.path))
                pcall(api.nvim_win_set_cursor, 0, { it.lnum or 1, (it.col or 1) - 1 })
                vim.cmd("normal! zz")
            end
        end,
    }
    if fuzzy.has_blob() then
        -- VARIANT B — the GREP CONTROLLER holds EVERY rg match in the native blob (like fzf keeps them in its
        -- own process), so there is NO browse cap and the counter climbs to the REAL total (e.g. 403127) as rg
        -- streams. LIVE grep (no fixed query): the typed query drives rg, re-grepping into a fresh blob per
        -- change; Ctrl-g freezes rg and fuzzy-filters the loaded results. FIXED-query grep: rg runs ONCE, then
        -- the typed query fuzzy-narrows the blob. `config.grep_max` is the native STORE ceiling (a broader query
        -- is still fully counted, never stored — no OOM). `blob_item` re-derives path/lnum/col from each line.
        tint.grep = {
            live = not fixed,
            query = opts.query,
            regex = opts.regex,
            file = opts.file,
        }
        tint.blob_item = function(text)
            return grep_item(text) or { path = text, text = text }
        end
    else
        -- FALLBACK (native library predates ABI 5 / the Lua matcher): the bounded source/stream path with the
        -- `matches / total-files` counter. rg's stdout is capped at `config.grep_max` in the read callback (rg
        -- killed at the cap) so a broad query never floods the queue. No Ctrl-g / uncapped browse on this path.
        tint.count_files = true -- counter = `matches found / TOTAL FILES in the tree` (background fd count)
        if fixed then
            -- rg runs ONCE for the fixed query; its bounded item stream feeds the matcher, then you fuzzy-filter.
            tint.stream = grep_item_stream(source.grep_cmd(opts.query, opts.regex, opts.file))
        else
            -- LIVE grep: each typed query re-runs `rg` (rg IS the search). rg's stdout is STREAMED in chunks and
            -- capped at `config.grep_max`; the previous rg is killed before the next spawns (and on close).
            local grep_cancel ---@type fun()?
            local function kill_grep()
                if grep_cancel then
                    pcall(grep_cancel) -- kills rg + drops any queued backlog (spawn_stream cancel)
                    grep_cancel = nil
                end
            end
            --- One raw vimgrep line → a GRID item, or nil for a non-location line. Built directly (not via
            --- `normalize`) so the progressive live stream can APPEND to one growing list — `source_raw` tells
            --- the finder to skip re-normalising it per batch.
            ---@param line string
            ---@return table?
            local function live_item(line)
                local it = grep_item(line)
                if it then
                    return { text = ("%s:%s  %s"):format(it.path, it.lnum, it.text), _src = it }
                end
            end
            tint.source_raw = true -- `out` already holds grid items; skip re-normalising per delivery
            tint.source = function(query, cb)
                kill_grep() -- cancel the previous query's rg before starting a new one (no pile-up)
                if query == nil or #query < 2 then -- wait for a couple of chars (rg over a huge tree is heavy)
                    cb({})
                    return
                end
                local out, pending = {}, false
                local function deliver() -- coalesce a burst of drains into one re-render; keep the count live
                    if pending then
                        return
                    end
                    pending = true
                    vim.defer_fn(function()
                        pending = false
                        cb(out)
                    end, (config or {}).stream_refresh_ms or 50)
                end
                grep_cancel = spawn_stream(source.grep_cmd(query, opts.regex, opts.file), function(lines)
                    for _, ln in ipairs(lines) do
                        local it = live_item(ln)
                        if it then
                            out[#out + 1] = it
                        end
                    end
                    deliver()
                end, function() -- rg exited: one FINAL delivery with the complete (bounded) match set
                    cb(out)
                end, (config or {}).grep_max or 500000) -- cap enforced in the read callback (no queue flood)
            end
            tint.on_close = kill_grep -- kill any in-flight rg when the finder closes
        end
    end
    M.open(vim.tbl_extend("force", tint, opts))
end

--- Grep the word under the cursor (`<cword>`), then fuzzy-filter the matches.
---@param opts? table
function M.grep_cword(opts)
    opts = opts or {}
    opts.key = opts.key or "grep_cword"
    opts.query = opts.query or vim.fn.expand("<cword>")
    opts.title = opts.title or ("Grep: " .. opts.query)
    return M.grep(opts)
end

--- Grep the WORD under the cursor (`<cWORD>` — includes punctuation), then fuzzy-filter the matches.
---@param opts? table
function M.grep_cWORD(opts)
    opts = opts or {}
    opts.key = opts.key or "grep_cWORD"
    opts.query = opts.query or vim.fn.expand("<cWORD>")
    opts.title = opts.title or ("Grep: " .. opts.query)
    return M.grep(opts)
end

--- Grep the last visual selection (`'<`..`'>`), then fuzzy-filter the matches.
---@param opts? table
function M.grep_visual(opts)
    opts = opts or {}
    opts.key = opts.key or "grep_visual"
    local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    local lines = vim.fn.getline(s[2], e[2])
    if #lines > 0 then
        lines[#lines] = lines[#lines]:sub(1, e[3])
        lines[1] = lines[1]:sub(s[3])
    end
    opts.query = (table.concat(lines, " "):gsub("%s+", " "))
    opts.title = "Grep: " .. opts.query
    return M.grep(opts)
end

--- Prompt for a search string, then grep it (fixed) and fuzzy-filter the matches.
---@param opts? table
function M.grep_word(opts)
    opts = opts or {}
    opts.key = opts.key or "grep_word"
    require("lvim-ui").input({
        prompt = "Grep",
        callback = function(confirmed, q)
            if confirmed == true and q and q ~= "" then
                opts.query, opts.title = q, "Grep: " .. q
                M.grep(opts)
            end
        end,
    })
end

--- Live-grep the CURRENT file only.
---@param opts? table
function M.grep_curbuf(opts)
    opts = opts or {}
    opts.key = opts.key or "grep_curbuf"
    local file = api.nvim_buf_get_name(0)
    if file == "" or vim.fn.filereadable(file) ~= 1 then
        vim.notify("lvim-picker.grep_curbuf: current buffer has no file on disk", vim.log.levels.WARN)
        return
    end
    opts.file = file
    opts.title = "Grep (buf): " .. vim.fn.fnamemodify(file, ":t")
    return M.grep(opts)
end

--- Fuzzy finder over RECENT files (`v:oldfiles`, readable only), newest first; confirming edits the file.
---@param opts? table
function M.oldfiles(opts)
    opts = opts or {}
    opts.key = opts.key or "oldfiles"
    local items, seen = {}, {}
    for _, p in ipairs(vim.v.oldfiles or {}) do
        if not seen[p] and vim.fn.filereadable(p) == 1 then
            seen[p] = true
            items[#items + 1] = { text = vim.fn.fnamemodify(p, ":~:."), path = p }
        end
    end
    pick_items({
        title = "Recent",
        items = items,
        icon = true, -- coloured ft devicon per recent file
        opts = opts,
        on_confirm = function(it)
            if it and it.path then
                vim.cmd.edit(vim.fn.fnameescape(it.path))
            end
        end,
        preview = function(it)
            return read_preview(it.path)
        end,
    })
end

--- Fuzzy finder over HELP tags; confirming opens that help topic.
---@param opts? table
function M.help_tags(opts)
    opts = opts or {}
    opts.key = opts.key or "help_tags"
    local items = {}
    for _, t in ipairs(vim.fn.getcompletion("", "help")) do
        items[#items + 1] = { text = t, tag = t }
    end
    pick_items({
        title = "Help",
        items = items,
        opts = opts,
        on_confirm = function(it)
            if it and it.tag then
                pcall(vim.cmd.help, it.tag)
            end
        end,
    })
end

--- Fuzzy finder over GIT-tracked files (`git ls-files`); confirming edits the file, with a content preview.
--- No-op outside a git work tree.
---@param opts? table
function M.git_files(opts)
    opts = opts or {}
    opts.key = opts.key or "git_files"
    with_backend_swap(opts) -- enable the C-] backend swap (tint ⇄ fzf) for this finder
    local inside = run_lines({ "git", "rev-parse", "--is-inside-work-tree" })[1]
    if inside ~= "true" then
        vim.notify("lvim-picker.git_files: not inside a git work tree", vim.log.levels.WARN)
        return
    end
    local b = fzf_backend(opts)
    if b then
        open_fzf(
            b,
            vim.tbl_extend("force", {
                title = "Git files",
                cmd = source.with_icons({ "git", "ls-files" }),
                parse = function(line)
                    return { path = source.strip_icon(line) }
                end,
                fzf_args = { "--nth", "2.." }, -- fuzzy-match the path, not the leading coloured icon
                preview = function(it)
                    return read_preview(it.path)
                end,
                on_confirm = function(it)
                    if it and it.path then
                        vim.cmd.edit(vim.fn.fnameescape(it.path))
                    end
                end,
            }, opts)
        )
        return
    end
    local spec = {
        title = "Git files",
        on_confirm = function(it)
            if it and it.path then
                vim.cmd.edit(vim.fn.fnameescape(it.path))
            end
        end,
        preview = function(it)
            return read_preview(it.path)
        end,
    }
    stream_paths(spec, { "git", "ls-files" }) -- the rev-parse guard above is a quick check
    M.open(vim.tbl_extend("force", spec, opts or {}))
end

--- Fuzzy finder over installed COLORSCHEMES; confirming applies it (`:colorscheme`). Restores the current
--- scheme on cancel so browsing is non-destructive.
---@param opts? table
function M.colorschemes(opts)
    opts = opts or {}
    opts.key = opts.key or "colorschemes"
    local current = vim.g.colors_name
    local items = {}
    for _, c in ipairs(vim.fn.getcompletion("", "color")) do
        items[#items + 1] = { text = c, name = c }
    end
    pick_items({
        title = "Colorschemes",
        items = items,
        opts = opts,
        on_confirm = function(it)
            if it and it.name then
                pcall(vim.cmd.colorscheme, it.name)
            end
        end,
        on_cancel = function()
            if current then
                pcall(vim.cmd.colorscheme, current)
            end
        end,
    })
end

--- Fuzzy finder over EX commands; confirming drops `:<cmd> ` into the command line (so args can be added)
--- rather than running it blindly.
---@param opts? table
function M.commands(opts)
    opts = opts or {}
    opts.key = opts.key or "commands"
    local items = {}
    for _, c in ipairs(vim.fn.getcompletion("", "command")) do
        items[#items + 1] = { text = c, cmd = c }
    end
    pick_items({
        title = "Commands",
        items = items,
        opts = opts,
        on_confirm = function(it)
            if it and it.cmd then
                vim.api.nvim_feedkeys(":" .. it.cmd .. " ", "n", false)
            end
        end,
    })
end

--- Jump to a `[file] lnum:col  text` location item: open its file (if any) and place the cursor. Shared by
--- the marks / quickfix / jumplist finders, which all produce `{ path?, bufnr?, lnum, col, text }`.
---@param it table
local function jump_to(it)
    if not it then
        return
    end
    if it.path and it.path ~= "" then
        vim.cmd.edit(vim.fn.fnameescape(it.path))
    elseif it.bufnr and api.nvim_buf_is_valid(it.bufnr) then
        api.nvim_set_current_buf(it.bufnr)
    end
    pcall(api.nvim_win_set_cursor, 0, { it.lnum or 1, math.max(0, (it.col or 1) - 1) })
    vim.cmd("normal! zz")
end

--- Preview a location item: the file/buffer content with a focus on the target line.
---@param it table
---@return string[] lines, string filetype, integer? focus
local function preview_location(it)
    if it.path and it.path ~= "" then
        local lines, ft = read_preview(it.path, preview_span(it.lnum))
        return lines, ft, it.lnum
    end
    if it.bufnr and api.nvim_buf_is_loaded(it.bufnr) then
        return api.nvim_buf_get_lines(it.bufnr, 0, preview_span(it.lnum), false), vim.bo[it.bufnr].filetype, it.lnum
    end
    return { "[no preview]" }, "", nil
end

--- Fuzzy finder over MARKS (`:marks`); confirming jumps to the mark, with a preview at its line.
---@param opts? table
function M.marks(opts)
    opts = opts or {}
    opts.key = opts.key or "marks"
    local items = {}
    for _, m in ipairs(vim.fn.getmarklist()) do -- global marks (A–Z, 0–9, …)
        local p = vim.fn.fnamemodify(m.file or "", ":~:.")
        items[#items + 1] = {
            text = ("%s  %s:%d"):format(m.mark, p, m.pos[2]),
            path = m.file,
            lnum = m.pos[2],
            col = m.pos[3],
        }
    end
    for _, m in ipairs(vim.fn.getmarklist(api.nvim_get_current_buf())) do -- buffer-local marks (a–z)
        items[#items + 1] = {
            text = ("%s  :%d"):format(m.mark, m.pos[2]),
            bufnr = api.nvim_get_current_buf(),
            lnum = m.pos[2],
            col = m.pos[3],
        }
    end
    pick_items({
        title = "Marks",
        items = items,
        opts = opts,
        on_confirm = jump_to,
        preview = preview_location,
    })
end

--- Fuzzy finder over KEYMAPS (all modes); confirming feeds the mapping's lhs. The preview shows its rhs /
--- description.
---@param opts? table
function M.keymaps(opts)
    opts = opts or {}
    opts.key = opts.key or "keymaps"
    local items = {}
    for _, mode in ipairs({ "n", "i", "v", "x", "o", "c", "t" }) do
        for _, k in ipairs(vim.api.nvim_get_keymap(mode)) do
            items[#items + 1] = {
                text = ("%s  %s  %s"):format(mode, k.lhs, (k.desc or k.rhs or ""):gsub("%s+", " ")),
                mode = mode,
                lhs = k.lhs,
                detail = k.desc or k.rhs or "",
            }
        end
    end
    pick_items({
        title = "Keymaps",
        items = items,
        opts = opts,
        on_confirm = function(it)
            if it and it.lhs and it.mode == "n" then
                api.nvim_feedkeys(api.nvim_replace_termcodes(it.lhs, true, false, true), "m", false)
            end
        end,
        preview = function(it)
            return { it.mode .. "  " .. it.lhs, "", it.detail }, ""
        end,
    })
end

--- Fuzzy finder over the QUICKFIX list; confirming jumps to the entry, with a preview at its line.
---@param opts? table
function M.quickfix(opts)
    opts = opts or {}
    opts.key = opts.key or "quickfix"
    local items = {}
    for _, e in ipairs(vim.fn.getqflist()) do
        local p = e.bufnr ~= 0 and vim.fn.fnamemodify(api.nvim_buf_get_name(e.bufnr), ":~:.") or ""
        items[#items + 1] = {
            text = ("%s:%d  %s"):format(p, e.lnum, (e.text or ""):gsub("^%s+", "")),
            bufnr = e.bufnr ~= 0 and e.bufnr or nil,
            lnum = e.lnum,
            col = e.col,
        }
    end
    pick_items({
        title = "Quickfix",
        items = items,
        opts = opts,
        on_confirm = jump_to,
        preview = preview_location,
    })
end

--- Fuzzy finder over the JUMPLIST (newest first); confirming jumps to the location, with a preview.
---@param opts? table
function M.jumplist(opts)
    opts = opts or {}
    opts.key = opts.key or "jumplist"
    local jumps = vim.fn.getjumplist()[1] or {}
    local items = {}
    for i = #jumps, 1, -1 do -- newest first
        local j = jumps[i]
        if api.nvim_buf_is_valid(j.bufnr) then
            local p = vim.fn.fnamemodify(api.nvim_buf_get_name(j.bufnr), ":~:.")
            items[#items + 1] = {
                text = ("%s:%d"):format(p ~= "" and p or "[No Name]", j.lnum),
                bufnr = j.bufnr,
                lnum = j.lnum,
                col = (j.col or 0) + 1,
            }
        end
    end
    pick_items({
        title = "Jumplist",
        items = items,
        opts = opts,
        on_confirm = jump_to,
        preview = preview_location,
    })
end

-- ── unified command ───────────────────────────────────────────────────────────
-- `:LvimPicker <finder> [layout]` — one entry point for every finder above. The 2nd arg ("area"|"float"|
-- "bottom") overrides `config.layout` for this call; bare = the configured default.
local FINDERS = {
    "files",
    "grep",
    "grep_cword",
    "grep_cWORD",
    "grep_word",
    "grep_visual",
    "grep_curbuf",
    "buffers",
    "oldfiles",
    "git_files",
    "directories",
    "help_tags",
    "commands",
    "keymaps",
    "marks",
    "quickfix",
    "jumplist",
    "colorschemes",
}
local LAYOUTS = { "area", "float", "bottom" }

--- Configure lvim-picker: merge `opts` into the live picker config in place (a nested `fuzzy` subtable merges
--- into the fuzzy engine's config), then register the `:LvimPicker` command. Optional — the defaults work
--- without it; every reader `require("lvim-picker.config")` sees the effective values.
---@param opts? table  see lvim-picker.config (+ an optional `fuzzy` subtable → lvim-picker.fuzzy.config)
function M.setup(opts)
    opts = opts and vim.tbl_extend("force", {}, opts) or {}
    if opts.fuzzy ~= nil then
        utils.merge(require("lvim-picker.fuzzy.config"), opts.fuzzy)
        opts.fuzzy = nil
    end
    utils.merge(config, opts)
    M.setup_command()
end

--- Register the `:LvimPicker <finder> [layout]` user command (one finder per `M.<finder>` above).
function M.setup_command()
    vim.api.nvim_create_user_command("LvimPicker", function(o)
        local finder = o.fargs[1]
        local fn = M[finder]
        if type(fn) ~= "function" then
            vim.notify("LvimPicker: unknown finder '" .. tostring(finder) .. "'", vim.log.levels.ERROR)
            return
        end
        fn(o.fargs[2] and { layout = o.fargs[2] } or nil)
    end, {
        nargs = "+",
        complete = function(arg_lead, cmd_line, _)
            local parts = vim.split(cmd_line, "%s+")
            if #parts <= 2 then
                return vim.tbl_filter(function(n)
                    return n:find(arg_lead, 1, true) == 1
                end, FINDERS)
            elseif #parts == 3 then
                return vim.tbl_filter(function(l)
                    return l:find(arg_lead, 1, true) == 1
                end, LAYOUTS)
            end
            return {}
        end,
        desc = "LvimPicker — open a finder (:LvimPicker <finder> [area|float|bottom])",
    })
end

return M
