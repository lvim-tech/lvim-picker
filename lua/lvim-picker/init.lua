-- lvim-picker: the native fuzzy-finder — the tint-striped Lua list backend plus the ready-made finders.
-- A native fuzzy finder built on the lvim-ui.surface chassis: a centred float with a typed query
-- INPUT band on top (a surface header input), a results LIST panel on the left and a scrollable PREVIEW
-- panel on the right — the diagnostics-peek layout, but fuzzy. The MATCHING ENGINE is the native `fzf`
-- binary in --filter mode (no TUI): candidates go in on stdin, fzf returns them matched + ranked by score,
-- and the surface renders the result. So ranking is fzf's exactly while WE own the view (engine vs view,
-- like the blink integration). Without fzf it falls back to a Lua subsequence matcher
-- (lvim-utils.utils.match_indices). Highlight positions are always computed locally (fzf's --filter does
-- not emit them), so the matched characters light up in the list.
--
---@module "lvim-picker"

local api = vim.api
local config = require("lvim-picker.config")
local ui_config = require("lvim-ui.config")
local fuzzy = require("lvim-picker.fuzzy")
local utils = require("lvim-utils.utils")
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

--- The fzf-TUI backend for the heavy / command-driven finders (files / grep / git_files / directories /
--- buffers), or nil when it is disabled (`config.fzf_tui == false`) or unavailable (no fzf / mkfifo).
--- When present, those finders let the real fzf TUI own the list (instant over huge trees, continuous live
--- updates); the structured finders (lsp / diagnostics / …) always use the tint-striped list below.
---@return table?
local function fzf_backend()
    if (config or {}).fzf_tui == false then
        return nil
    end
    local ok, b = pcall(require, "lvim-picker.fzf")
    return (ok and b.available() and b) or nil
end

local M = {}

--- Route a Lua-ITEM finder through the fzf-TUI backend when available, else the tint list — so EVERY finder
--- shares one backend (only the structured lsp/diagnostics lists stay tint). Each item is encoded as
--- `idx\ttext`; fzf shows/matches only the text (`--with-nth`), and the idx recovers the full item on
--- selection, so the finder keeps its own `preview` / `on_confirm` / `on_cancel` for BOTH backends.
---@param spec { title: string, items: table[], preview?: function, on_confirm?: function, on_cancel?: function, opts?: table }
local function pick_items(spec)
    local items = spec.items or {}
    local b = fzf_backend()
    if b then
        local contents = {}
        for i, it in ipairs(items) do
            -- `spec.icon` → prefix the coloured ft devicon (display only; the parse recovers the item by INDEX,
            -- so the icon never has to be stripped). Keyed on the file path when present, else the text.
            local icon = spec.icon and source.file_icon(it.path or it.text) or ""
            contents[i] = i .. "\t" .. icon .. ((it.text or ""):gsub("[\t\n]", " "))
        end
        b.open(vim.tbl_extend("force", {
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
        }, spec.opts or {}))
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
            out[i] = { text = it, _src = it }
        else
            local item = {
                text = (format and format(it)) or it.text or tostring(it),
                icon = it.icon,
                icon_hl = it.icon_hl,
                _src = it,
            }
            -- auto ft devicon for items that name a file (lsp locations / diagnostics / quickfix / jumplist /
            -- file lists) on the tint backend — drawn as a coloured extmark; the fzf backend gets the ANSI icon.
            if not item.icon then
                local p = it.path or (it.bufnr and api.nvim_buf_is_valid(it.bufnr) and api.nvim_buf_get_name(it.bufnr))
                if p and p ~= "" then
                    item.icon, item.icon_hl = source.devicon(p)
                end
            end
            out[i] = item
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
    local text = (it.text or ""):gsub("[\r\n]+", " ")
    local row = lead .. icon .. text
    local spans = {}
    if it.match and #it.match > 0 then
        local base = #lead + #icon -- byte offset of the label within `row`
        local nch = vim.fn.strchars(text)
        for _, ci in ipairs(it.match) do
            if ci >= 0 and ci < nch then
                spans[#spans + 1] =
                    { c0 = base + vim.str_byteindex(text, ci), c1 = base + vim.str_byteindex(text, ci + 1) }
            end
        end
    end
    return row, spans, #lead
end

---@class LvimPickerOpts
---@field items? any[]  STATIC candidates (strings, or tables — see `format`), fuzzy-filtered as you type
---@field source? fun(query: string, cb: fun(items: any[]))  a LIVE source: each query produces the results (e.g. ripgrep); use instead of `items`
---@field stream? fun(feed: fun(raw: any[]), done: fun()): fun()  an ASYNC streaming producer (e.g. `fd`): feeds candidates in incrementally; returns a cancel fn
---@field on_confirm fun(item: any)  called with the chosen item's source value
---@field on_cancel? fun()  called when the finder is dismissed without a choice
---@field format? fun(item: any): string  display text for a table item (default: `item.text`)
---@field preview? fun(item: any): string[], string?, integer?  preview lines (+ a filetype, + a 1-based focus line) per selection
---@field preview_file? boolean  preview the item's REAL file buffer (EDITABLE, 2-way synced) instead of `preview` lines; items need `path` (+ lnum/col)
---@field preview_side? "right"|"left"|"below"|"above"|"dynamic"|"hide"  where the preview sits (default "right"); below/above stack; `dynamic` = full-width list + a peek float above (native-qf style); `hide` = no preview (toggle with <C-e>)
---@field preview_heights? table  managed dock heights `{ horizontal, vertical }`
---@field preview_numbers? boolean  show line numbers in the preview (default true)
---@field preview_wrap? boolean  soft-wrap the preview (default false)
---@field list_wrap? boolean  soft-wrap the list rows (no "↳" marker) so far-right matches stay visible (default false)
---@field empty_text? string  shown when there are no results (list body + preview winbar)
---@field empty_preview? string  the "nothing to preview" placeholder bar text (default "Nothing to preview")
---@field title? string  the finder title — the chassis native centered border-title
---@field icon? string  an optional leading glyph fronting the title
---@field title_line? string  title placement: "row" (a top content row, default) | "statusline" (the centralized chrome overlay) | "border" (opt-in native border-title)
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

--- Open a fuzzy finder: a centred float with a query input on top, a results list and (with `preview`) a
--- scrollable preview beside it. INSERT prompt: type to filter (fzf), `<C-j>/<C-k>` move, `<C-d>/<C-u>`
--- scroll the preview, `<CR>` confirms, `<C-c>` cancels, `<Esc>`/`<C-f>` → NORMAL. NORMAL list: `j`/`k`
--- move, `<C-d>/<C-u>` scroll preview, `<C-l>`/`<C-h>` panel nav, filter hotkeys, `q` close, `/` → typing.
---@param opts LvimPickerOpts
function M.open(opts)
    opts = opts or {}
    -- Default the LAYOUT from `config.layout` (default "area") when the caller gave none — so every
    -- finder + `:LvimPicker <finder>` lands in the configured layout unless overridden per call.
    opts.layout = opts.layout or (config or {}).layout or "area"
    -- A finder already open (EITHER backend)? Close it FIRST via the shared registry so this open() replaces
    -- it in place — its docked area is released, instead of a new finder stacking above the old one.
    source.close_active()
    local surface = require("lvim-ui.surface")
    local items = normalize(opts.items, opts.format)
    local maxr = opts.max_rows or 15
    local state = {
        filtered = items,
        sel = 1,
        list_pan = nil,
        preview_pan = nil,
        st = nil,
        closed = false,
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
    local function count_fn()
        return { current = state.filtered and #state.filtered or 0, total = #items }
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
            -- the file's devicon (when nvim-web-devicons is present and `preview.show_icon`)
            local icon = ""
            if prevcfg.show_icon ~= false then
                local ok_dev, dev = pcall(require, "nvim-web-devicons")
                if ok_dev then
                    local gl = dev.get_icon(tail, vim.fn.fnamemodify(tail, ":e"), { default = true })
                    icon = gl and (gl .. " ") or ""
                end
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
            for i, it in ipairs(state.filtered) do
                local marked = is_marked(it._src)
                local row, spans, lead = list_row(it, marked, marker)
                lines[i] = row
                local odd = (i % 2) == 1
                local sel = i == state.sel
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
        or opts.preview
            and {
                size = function()
                    -- Both panels share the CONTENT height (the taller of list/preview, capped) so the
                    -- container fits the bigger one; the preview lines are cached in `state.preview_lines`
                    -- (fetched on selection — see `fetch_preview`). With results +1 for the winbar; with NO
                    -- results a single tinted `[no matches]` row.
                    return math.max(40, math.floor(vim.o.columns * 0.5)), preview_panel_h() -- the PREVIEW's own height
                end,
                update = function(pan)
                    set_preview_winbar(pan, state.filtered[state.sel] and state.filtered[state.sel]._src or nil)
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
            pcall(api.nvim_win_set_cursor, p.win, { math.max(1, math.min(#state.filtered, state.sel)), 0 })
        end
    end
    --- Fetch the CURRENT selection's preview content into the cache (so `content_h`/`size` know its line
    --- count before relayout, and `update` writes it). No preview, or no selection ⇒ empty.
    local function fetch_preview()
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
    --- Re-render everything after a selection or result change: refresh the preview cache, re-fit the height,
    --- then re-render both panels + the chrome.
    local function rerender()
        fetch_preview()
        refit()
        if state.list_pan and state.list_pan.refresh then
            state.list_pan.refresh()
        end
        if state.preview_pan and state.preview_pan.refresh then
            state.preview_pan.refresh()
        end
        set_list_winbar() -- the result count in the winbar follows the list
        set_list_cursor() -- scroll the window to keep the selection in view
        refresh_count() -- re-apply the live match count to the chassis border / overlay counter
    end
    move = function(d)
        if #state.filtered == 0 then
            return
        end
        state.sel = math.max(1, math.min(#state.filtered, state.sel + d))
        rerender() -- the preview (and so the height) changes with the selection
    end
    --- Apply a new result list (from the fuzzy filter or a live source) to the UI.
    ---@param list table[]
    local function apply(list)
        if state.closed then
            return
        end
        state.filtered, state.sel = list, 1
        rerender()
    end
    -- A generation guard so a slow async source/filter callback for an OLD query can't overwrite a newer one.
    local refilter_gen = 0
    --- Re-run the filter (static list) or live source for query `q`, then push the ranked results to the UI.
    ---@param q string?
    local function refilter(q)
        state.query = q or ""
        refilter_gen = refilter_gen + 1
        local mygen = refilter_gen
        local function guarded(list)
            if mygen == refilter_gen then
                -- A live source returns raw items (no fuzzy step), so highlight the query in each result text
                -- ourselves (the matched chars light up like the static path).
                local norm = normalize(list, opts.format)
                if state.query ~= "" then
                    for _, it in ipairs(norm) do
                        it.match = utils.match_indices(state.query, it.text)
                    end
                end
                apply(norm)
            end
        end
        if opts.source then
            -- LIVE source: the query drives the results (e.g. ripgrep) — no fuzzy over a static list.
            opts.source(state.query, guarded)
        else
            -- STATIC list: narrow by the active filter bars FIRST, then fuzzy-filter the survivors.
            local pool = items
            if filters then
                pool = {}
                for _, it in ipairs(items) do
                    if passes_filters(it._src) then
                        pool[#pool + 1] = it
                    end
                end
            end
            filter(pool, state.query, function(list)
                if mygen == refilter_gen then
                    apply(list)
                end
            end)
        end
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
        if state.st then
            state.st.close()
        end
        if opts.on_cancel then
            opts.on_cancel()
        end
    end
    -- Telescope-style modes: the prompt is INSERT (fuzzy type); <Esc> drops to NORMAL on the list (j/k move,
    -- <C-l>/<C-h> panel nav, the filter bar) — `focus_input` returns to typing, `focus_list` leaves insert.
    focus_input = function()
        local w = state.input_buf and vim.fn.bufwinid(state.input_buf) or -1
        if w ~= -1 then
            api.nvim_set_current_win(w)
            vim.cmd("startinsert!")
        end
    end
    local function focus_list()
        vim.cmd("stopinsert")
        if state.st and state.st.focus_block then
            state.st.focus_block("list")
        end
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
    local docked = bottom or area

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
    -- Size by layout × preview side. Docked: a list-only height, or a TALLER one when the preview is stacked
    -- below/above (it grows up). Float: a wide two-pane, or a taller stacked one.
    -- Docked layouts AUTO-fit their height to the result count (intelligent shrink/grow), capped so a huge
    -- result set doesn't take the whole screen. Floats keep a fixed comfortable size.
    local size
    if docked then
        -- The CONTENT (list/preview) is already capped at `max_rows`; the container cap adds the chrome
        -- overhead (winbar + footer + air ≈ 4 rows) so the content can actually reach `max_rows`. The
        -- area's own cmdheight clamp keeps it within the room available between the splits.
        local cap = opts.height or (maxr + 4)
        size = vertical and { height = { auto = true, max = 0.85 } } or { height = { auto = true, max = cap } }
    else
        -- FLOAT: honour `ui_config.size.float` (width / height fractions + their `*_auto` "fit-to-content"
        -- flags) — no hardcoded per-orientation size, so the configured Float width/height are respected.
        local f = (ui_config.size or {}).float or {}
        local function axis(frac, auto)
            frac = frac or 0.8
            return auto and { auto = true, max = frac } or { fixed = frac }
        end
        size = { width = axis(f.width, f.width_auto), height = axis(f.height, f.height_auto) }
    end
    -- Prompt badge (shared `config.prompt`): an icon and/or label on the STRONG tint, then a gap on
    -- the LIGHT input tint before the typed text. Two virt_text chunks so the badge and the gap carry their
    -- own backgrounds. A per-call `opts.prompt` STRING overrides it (a single badge-tint chunk).
    local pcfg = (config or {}).prompt or {}
    local prompt_hl = hl("prompt", "LvimUiPickerPrompt")
    local input_hl = hl("input", "LvimUiPickerInput")
    local prompt_text
    if opts.prompt then
        prompt_text = opts.prompt -- a literal override
    else
        local sp = string.rep
        local has_icon = (pcfg.icon or "") ~= ""
        local has_label = (pcfg.label or "") ~= ""
        local badge = sp(" ", pcfg.pad_left or 1)
        if has_icon then
            badge = badge .. pcfg.icon
        end
        if has_icon and has_label then
            badge = badge .. sp(" ", pcfg.icon_gap or 1) -- the gap between the icon and the label
        end
        if has_label then
            badge = badge .. pcfg.label
        end
        badge = badge .. sp(" ", pcfg.pad_right or 1)
        -- chunk list: badge (strong tint) + a gap on the input tint before the typed text
        prompt_text = { { badge, prompt_hl }, { sp(" ", pcfg.input_gap or 1), input_hl } }
    end

    -- Footer hints: the standard actions + any consumer `opts.keys` that carry a `name`. `<Esc>` drops to
    -- NORMAL on the list (j/k move, <C-l> preview, the filter bar); `i` returns to typing, `<C-c>` cancels.
    local footer_items = {
        { key = "<CR>", name = "open" },
        { key = "C-j/k", name = "move" },
    }
    for _, a in ipairs(opts.keys or {}) do
        if a.name then
            footer_items[#footer_items + 1] = { key = a.key, name = a.name }
        end
    end
    footer_items[#footer_items + 1] = { key = "Esc", name = "normal" }
    if area then -- (HOSTED area) NORMAL-mode <C-j> descends into the messages composed below the finder
        footer_items[#footer_items + 1] = { key = "C-j", name = "msgs" }
    end
    footer_items[#footer_items + 1] = { key = "C-c", name = "close" }

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
        preview_heights = preview_provider and (opts.preview_heights or pkcfg.preview_heights) or nil, -- { horizontal, vertical }
        lock_keys = true, -- modal list: only the bound keys act; every other key is a no-op (the editable preview is exempt)
        title = title_box, -- the chassis native centered border-title
        title_line = opts.title_line, -- title placement: "row" (default) | "statusline" (chassis overlay) | "border" (opt-in)
        count = count_fn, -- the live match / pool count → the chassis border counter (default bottom-right footer)
        counter = opts.counter, -- count placement: "footer" (default) | "title"
        -- The container border is CONFIG-DRIVEN on EVERY layout (float + docked) — `surface.FRAME_BORDER`
        -- resolves LIVE to `ui_config.border`, so there is NO hardcoded per-layout border. Each content block
        -- carries its OWN ring (CONTENT_BORDER); the chassis draws the configurable inter-panel divider
        -- (`ui_config.separator`) BETWEEN the list and preview — auto-oriented, only at the gap, so a SINGLE
        -- panel (preview hidden / no preview) shows none.
        border = surface.FRAME_BORDER,
        size = size,
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
                    on_change = refilter,
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
            pcall(function()
                require("lvim-hud.overlay").clear()
            end) -- idempotent: drop the chrome-overlay title/counter if `title_line="statusline"` published it
            if state.stream_cancel then -- kill a still-running async producer (e.g. `fd` over a huge tree)
                pcall(state.stream_cancel)
                state.stream_cancel = nil
            end
            _texts_cache = nil -- drop the cached candidate texts (and let fuzzy drop its temp file) for this run
            fuzzy.release()
            if state.input_buf then -- drop the custom blue caret registration (cursor module restores normal)
                pcall(require("lvim-utils.cursor").mark_cursor_buffer, state.input_buf, nil)
            end
            source.clear_active(active_entry) -- forget the current finder once it closes (only if it is still us)
            -- (the engine releases its own auto-host msgarea segment on surface close — nothing to do here)
            if state.live_augroup then
                pcall(api.nvim_del_augroup_by_id, state.live_augroup)
                state.live_augroup = nil
            end
        end,
    })

    source.set_active(active_entry) -- track THIS finder as the open one (its surface is now live)

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

    -- ASYNC STREAM source: `opts.stream(feed, done)` produces candidates incrementally (a spawned `fd` / `rg`
    -- streamed in via `spawn_stream`), so the open NEVER blocks on a huge tree. `feed(raw)` appends the batch
    -- to the candidate pool and schedules ONE coalesced refilter (fuzzy is already async); `done()` does a
    -- final pass. The producer is killed in on_close. Mutually exclusive with the per-query live `source`.
    if opts.stream and not opts.source then
        local pending = false
        local function feed(raw)
            if state.closed or type(raw) ~= "table" or #raw == 0 then
                return
            end
            for _, it in ipairs(normalize(raw, opts.format)) do
                items[#items + 1] = it
            end
            if not pending then
                pending = true
                vim.defer_fn(function()
                    pending = false
                    if not state.closed then
                        refilter(state.query)
                    end
                end, 60) -- coalesce a burst of chunks into one re-render
            end
        end
        local function done()
            if not state.closed then
                refilter(state.query)
            end
        end
        state.stream_cancel = opts.stream(feed, done)
    end
end

--- A ready finder over the listed buffers; confirming switches to the chosen buffer, with a content preview.
---@param opts? table  forwarded to M.open
function M.buffers(opts)
    opts = opts or {}
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
    local fb = fzf_backend()
    if fb then
        -- Encode each entry as `bufnr\tname`; fzf shows/matches only field 2 (the name) via
        -- `--delimiter`/`--with-nth`, but hands back the whole line so we recover the bufnr.
        local contents = {}
        for _, it in ipairs(items) do
            contents[#contents + 1] = ("%d\t%s%s"):format(it.bufnr, source.file_icon(it.text), it.text)
        end
        fb.open(vim.tbl_extend("force", {
            title = "Buffers",
            contents = contents,
            fzf_args = { "--delimiter=\t", "--with-nth=2" },
            parse = function(line)
                local bufnr, name = line:match("^(%d+)\t(.*)$")
                name = name and source.strip_icon(name) or line -- drop the leading coloured ft icon
                -- a real file name doubles as the preview `path` (drives the devicon winbar); "[No Name]" stays
                -- text-only.
                local path = (name ~= "[No Name]") and name or nil
                return { bufnr = tonumber(bufnr), text = name, path = path }
            end,
            preview = function(it)
                return buf_preview(it.bufnr, it.text or "")
            end,
            on_confirm = function(it)
                if it and it.bufnr and api.nvim_buf_is_valid(it.bufnr) then
                    api.nvim_set_current_buf(it.bufnr)
                end
            end,
        }, opts))
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

--- Fuzzy file finder under cwd; confirming edits the file, with a content preview. `opts` forwarded to open.
---@param opts? table
function M.files(opts)
    opts = opts or {}
    local b = fzf_backend()
    if b then
        -- fzf runs `file_list_cmd()` as its producer (FZF_DEFAULT_COMMAND) and owns the list; we keep the
        -- real-Neovim preview + the open action.
        b.open(vim.tbl_extend("force", {
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
        }, opts))
        return
    end
    M.open(vim.tbl_extend("force", {
        title = "Files",
        -- Stream `fd`/`find` async so opening in a huge tree (e.g. `~/`) does not freeze the editor; results
        -- fill in as they arrive and fuzzy-match live.
        stream = function(feed, done)
            return spawn_stream(file_list_cmd(), function(lines)
                local batch = {}
                for _, p in ipairs(lines) do
                    if p ~= "" then
                        batch[#batch + 1] = { text = p, path = p }
                    end
                end
                feed(batch)
            end, done)
        end,
        on_confirm = function(it)
            if it and it.path then
                vim.cmd.edit(vim.fn.fnameescape(it.path))
            end
        end,
        preview = function(it)
            return read_preview(it.path)
        end,
    }, opts or {}))
end

--- Fuzzy directory finder under cwd; confirming `:cd`s into the chosen directory. `opts` forwarded to open.
---@param opts? table
function M.directories(opts)
    opts = opts or {}
    local b = fzf_backend()
    if b then
        b.open(vim.tbl_extend("force", {
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
        }, opts))
        return
    end
    M.open(vim.tbl_extend("force", {
        title = "Directories",
        stream = function(feed, done) -- async, so a huge tree never freezes the open
            return spawn_stream(dir_list_cmd(), function(lines)
                local batch = {}
                for _, p in ipairs(lines) do
                    if p ~= "" then
                        batch[#batch + 1] = { text = p, path = p }
                    end
                end
                feed(batch)
            end, done)
        end,
        on_confirm = function(it)
            if it and it.path then
                vim.cmd.cd(vim.fn.fnameescape(it.path))
            end
        end,
        preview = function(it)
            return run_lines({ "ls", "-A", it.path }), ""
        end,
    }, opts or {}))
end

--- LIVE grep (ripgrep) under cwd: each query re-runs `rg`, the matches ARE the results, with a preview that
--- jumps to the matched line; confirming opens the file at that line. `opts` forwarded to open.
---@param opts? table
function M.grep(opts)
    opts = opts or {}
    if not has("rg") then
        vim.notify("lvim-picker.grep needs ripgrep (rg)", vim.log.levels.WARN)
        return
    end
    -- Parse a ripgrep `--vimgrep` line into a location item. The col is followed by `:text` in the 1-row
    -- layout and by `\n    text` in the fzf-lua 2-row layout, so the match stops right after the col number.
    local function parse_grep(line)
        line = source.strip_icon(line) -- drop the leading coloured ft icon (+ any ANSI) before parsing
        local file, lnum, col = line:match("^(.-):(%d+):(%d+)")
        if file then
            return { path = file, lnum = tonumber(lnum), col = tonumber(col), text = line }
        end
        return { path = line, text = line }
    end
    local b = fzf_backend()
    if b then
        -- fzf live mode: each keystroke RELOADS ripgrep with the query — fzf re-renders the matches
        -- continuously. fzf does no fuzzy ranking of its own (`--disabled`); rg IS the search.
        local backend = {
            title = opts.title or "Grep",
            parse = parse_grep,
            multiline = source.fzf_multiline(), -- fzf-lua 2-row layout (location row + indented text row)
            preview = function(it)
                local lines, ft = read_preview(it.path)
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
        b.open(vim.tbl_extend("force", backend, opts))
        return
    end
    M.open(vim.tbl_extend("force", {
        title = "Grep",
        source = function(query, cb)
            if query == nil or #query < 2 then -- wait for a couple of chars (rg over a huge tree is heavy)
                cb({})
                return
            end
            -- ripgrep argv from the shared source layer: matches the query LITERALLY unless `opts.regex`, and
            -- shares the file-source config so CONTENT search matches what `files` LISTS (hidden / .gitignore /
            -- the excluded dirs).
            local rg = source.grep_cmd(query, opts.regex)
            vim.system(rg, { text = true }, function(res)
                vim.schedule(function()
                    local out = {}
                    for line in (res.stdout or ""):gmatch("[^\n]+") do
                        local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
                        if file then
                            out[#out + 1] = {
                                text = ("%s:%s  %s"):format(file, lnum, text),
                                path = file,
                                lnum = tonumber(lnum),
                                col = tonumber(col),
                            }
                        end
                    end
                    cb(out)
                end)
            end)
        end,
        preview = function(it)
            local lines, ft = read_preview(it.path)
            return lines, ft, it.lnum -- focus the preview on the matched line
        end,
        on_confirm = function(it)
            if it and it.path then
                vim.cmd.edit(vim.fn.fnameescape(it.path))
                pcall(api.nvim_win_set_cursor, 0, { it.lnum or 1, (it.col or 1) - 1 })
                vim.cmd("normal! zz")
            end
        end,
    }, opts or {}))
end

--- Grep the word under the cursor (`<cword>`), then fuzzy-filter the matches.
---@param opts? table
function M.grep_cword(opts)
    opts = opts or {}
    opts.query = opts.query or vim.fn.expand("<cword>")
    opts.title = opts.title or ("Grep: " .. opts.query)
    return M.grep(opts)
end

--- Grep the WORD under the cursor (`<cWORD>` — includes punctuation), then fuzzy-filter the matches.
---@param opts? table
function M.grep_cWORD(opts)
    opts = opts or {}
    opts.query = opts.query or vim.fn.expand("<cWORD>")
    opts.title = opts.title or ("Grep: " .. opts.query)
    return M.grep(opts)
end

--- Grep the last visual selection (`'<`..`'>`), then fuzzy-filter the matches.
---@param opts? table
function M.grep_visual(opts)
    opts = opts or {}
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
    vim.ui.input({ prompt = "Grep: " }, function(q)
        if q and q ~= "" then
            opts.query, opts.title = q, "Grep: " .. q
            M.grep(opts)
        end
    end)
end

--- Live-grep the CURRENT file only.
---@param opts? table
function M.grep_curbuf(opts)
    opts = opts or {}
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
    local inside = run_lines({ "git", "rev-parse", "--is-inside-work-tree" })[1]
    if inside ~= "true" then
        vim.notify("lvim-picker.git_files: not inside a git work tree", vim.log.levels.WARN)
        return
    end
    local b = fzf_backend()
    if b then
        b.open(vim.tbl_extend("force", {
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
        }, opts))
        return
    end
    M.open(vim.tbl_extend("force", {
        title = "Git files",
        stream = function(feed, done) -- stream `git ls-files` async (the rev-parse guard above is a quick check)
            return spawn_stream({ "git", "ls-files" }, function(lines)
                local batch = {}
                for _, p in ipairs(lines) do
                    if p ~= "" then
                        batch[#batch + 1] = { text = p, path = p }
                    end
                end
                feed(batch)
            end, done)
        end,
        on_confirm = function(it)
            if it and it.path then
                vim.cmd.edit(vim.fn.fnameescape(it.path))
            end
        end,
        preview = function(it)
            return read_preview(it.path)
        end,
    }, opts or {}))
end

--- Fuzzy finder over installed COLORSCHEMES; confirming applies it (`:colorscheme`). Restores the current
--- scheme on cancel so browsing is non-destructive.
---@param opts? table
function M.colorschemes(opts)
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
        local lines, ft = read_preview(it.path)
        return lines, ft, it.lnum
    end
    if it.bufnr and api.nvim_buf_is_loaded(it.bufnr) then
        return api.nvim_buf_get_lines(it.bufnr, 0, 500, false), vim.bo[it.bufnr].filetype, it.lnum
    end
    return { "[no preview]" }, "", nil
end

--- Fuzzy finder over MARKS (`:marks`); confirming jumps to the mark, with a preview at its line.
---@param opts? table
function M.marks(opts)
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
