-- lvim-picker.fzf: the fzf-TUI finder backend (the real fzf binary hosted in the surface chassis).
-- The fzf-TUI finder backend — the SAME surface chassis as the tint picker (picker/init.lua), but the LIST is
-- the real `fzf` binary running as a TUI inside a terminal panel, the way fzf-lua does it. This is the only
-- way to match fzf-lua's productivity over huge candidate sets (e.g. ~/, 1.6M files): fzf (C) owns parsing,
-- matching, ranking AND rendering — Neovim does NOTHING per keystroke — and the producer (fd/rg) streams
-- DIRECTLY into fzf, so the list fills + re-ranks CONTINUOUSLY while you type, never blocking the editor.
--
-- What stays ours (the unified chassis): the surface (area / float / bottom, the msgarea host, the statusline
-- title, the footer hint bar, close/escape) and a REAL Neovim PREVIEW window (treesitter + the devicon
-- winbar). The preview follows fzf's selection via fzf's `focus` event, which writes the focused line into a
-- fifo we read (the fzf-lua "builtin previewer" model: `--preview-window=hidden` + a focus bind that calls
-- back into the editor). The fzf TUI is themed from the live lvim palette through `--color` + the window's
-- `winhl`, so it matches the theme even though fzf — not us — paints the rows.
--
-- Used by the heavy / command-driven finders (files, grep, git_files, directories, buffers). The structured,
-- in-memory finders (lsp locations, diagnostics, …) keep the tint-striped Lua list in picker/init.lua.
--
---@module "lvim-picker.fzf"

local api = vim.api
local uv = vim.uv
local config = require("lvim-picker.config")
local colors = require("lvim-utils.colors")
local highlight = require("lvim-utils.highlight")
local cursor = require("lvim-utils.cursor")
local iconlib = require("lvim-utils.icons")
local surface = require("lvim-ui.surface")
local source = require("lvim-picker.source")
local preview = require("lvim-ui.preview")

local NS = api.nvim_create_namespace("lvim-utils-fzf-preview")

local M = {}

-- The MINIMUM fzf version (major*100+min) this backend's fixed flag set needs to run: `--gutter=` landed in
-- fzf 0.64 (`--input-border` ~0.59, `--highlight-line` 0.53 are older). On anything below, fzf exits with
-- "unknown option" (code 2), which reads as a silent cancel — so `available()` gates on it and callers fall
-- back to the tint backend instead of flashing an empty picker open and dying.
local MIN_FZF = 64

--- True when this backend can run: the `fzf` binary is on PATH and NEW ENOUGH for its flag set (>= 0.64),
--- and `mkfifo` is available (the focus→preview channel). Callers fall back to the tint picker otherwise.
---@return boolean
function M.available()
    return source.has("fzf") and source.fzf_version() >= MIN_FZF and source.has("mkfifo")
end

-- ─── theming: the live palette → fzf `--color` ────────────────────────────────
-- fzf paints the list itself, so we cannot apply Neovim highlight GROUPS to its rows — we EXTRACT the colors
-- from the live palette and hand fzf its fixed set of color roles (the fzf-lua model). `bg:-1` keeps the list
-- background TRANSPARENT so it inherits the panel's `Normal` (LvimUiPeekNormal via the window `winhl`), so the
-- fzf bg always matches the surrounding chassis. The selected line echoes the tint canon: a STRONG blue tint.

--- A "#rrggbb" hex of `attr` ("fg"/"bg") from highlight group `group`, or `fallback` when unset — so the fzf
--- TUI input colours track the SAME groups the tint finder uses (configurable via config.hl), not
--- baked-in palette constants.
---@param group string
---@param attr "fg"|"bg"
---@param fallback string
---@return string
local function hl_hex(group, attr, fallback)
    local h = vim.api.nvim_get_hl(0, { name = group, link = false })
    local v = h and h[attr]
    return (type(v) == "number") and ("#%06x"):format(v) or fallback
end

--- The configured highlight-group NAMES for the input field (`config.hl.input` / `.prompt`).
---@return string input_group, string prompt_group
local function input_groups()
    local phl = (config or {}).hl or {}
    return phl.input or "LvimUiPickerInput", phl.prompt or "LvimUiPickerPrompt"
end

--- Build fzf's `--color` value. The INPUT field (query text + field tint) reads the `hl.input` group so it is
--- configurable + consistent with the tint finder; the rest tracks the live palette. Recomputed per open.
---@return string
local function fzf_colors()
    local c = colors
    local blend = highlight.blend
    local sel_bg = blend(c.blue, c.bg, 0.20) -- the active (current) row: a blue tint 0.2, full-width (--highlight-line)
    -- The diagnostics finder's two-tone search, kept to ONE row: a STRONG-tint badge box (done in fzf_prompt
    -- via ANSI) + a LIGHT-tint typed FIELD (`input-bg`). fzf only paints `input-bg` on a BORDERED input
    -- section, so the caller adds `--input-border=right` — a RIGHT border is a COLUMN, not an extra row, so the
    -- search stays a single row; we colour that border to the SAME field tint so it dissolves (invisible).
    local input_g = input_groups()
    local input_fg = hl_hex(input_g, "fg", c.blue) -- the typed text colour (= the tint finder's input fg)
    local input_bg = hl_hex(input_g, "bg", blend(c.blue, c.bg, 0.10)) -- the typed FIELD tint
    local spec = {
        "fg:" .. c.fg,
        "bg:-1", -- transparent → inherits the panel Normal (themed via winhl)
        "hl:" .. c.red, -- matched characters (the LvimUiMsgAreaMatch red)
        "fg+:" .. c.fg,
        "bg+:" .. sel_bg, -- the selected line
        "hl+:" .. c.red,
        "info:" .. c.comment,
        "border:" .. c.comment,
        "query:" .. input_fg,
        "input-bg:" .. input_bg,
        "input-border:" .. input_bg, -- dissolved into the field (no visible rule)
        "pointer:" .. c.blue,
        "marker:" .. c.red, -- the multi-select mark dot (●) — red
        "spinner:" .. c.yellow,
        "header:" .. c.comment,
    }
    return table.concat(spec, ",")
end

--- A "#rrggbb" hex colour as the "R;G;B" decimal triplet an ANSI truecolor escape needs.
---@param hex string
---@return string
local function hexrgb(hex)
    local r, g, b = hex:match("#(%x%x)(%x%x)(%x%x)")
    return ("%d;%d;%d"):format(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
end

--- The fzf `--prompt` string: the shared `config.prompt` badge (icon + label with the same pads as the
--- tint finder), wrapped in ANSI so it renders as the STRONG-tint badge box of the diagnostics finder —
--- LvimUiPickerPrompt: blue fg, bold, on a `mtint(blue, 0.3)` bg. fzf paints ANSI in `--prompt`, so the badge
--- gets its OWN background even though fzf has no `prompt-bg` colour role; after the reset the typed query
--- runs on the light `input-bg` field (see fzf_colors). Ends with `input_gap` spaces on that field.
---@return string
local function fzf_prompt()
    local c = colors
    local blend = highlight.blend
    local pcfg = (config or {}).prompt or {}
    local sp = string.rep
    local icon, label = pcfg.icon or "", pcfg.label or ""
    local badge = sp(" ", pcfg.pad_left or 1)
    if icon ~= "" then
        badge = badge .. icon
    end
    if icon ~= "" and label ~= "" then
        badge = badge .. sp(" ", pcfg.icon_gap or 1)
    end
    if label ~= "" then
        badge = badge .. label
    end
    badge = badge .. sp(" ", pcfg.pad_right or 1)
    -- the badge box colours come from the `hl.prompt` group (LvimUiPickerPrompt) — configurable + consistent
    -- with the tint finder's badge — extracted to ANSI (fzf has no prompt-bg colour role).
    local _, prompt_g = input_groups()
    local fg = hl_hex(prompt_g, "fg", c.blue)
    local bg = hl_hex(prompt_g, "bg", blend(c.blue, c.bg, 0.30))
    local ESC = string.char(27)
    local style = ESC .. "[1m" .. ESC .. "[38;2;" .. hexrgb(fg) .. "m" .. ESC .. "[48;2;" .. hexrgb(bg) .. "m"
    return style .. badge .. ESC .. "[0m" .. sp(" ", pcfg.input_gap or 1)
end

-- ─── fzf → editor channels (fifos) ────────────────────────────────────────────
-- fzf events (`focus`, `result`/`load`) write a line into a fifo via `execute-silent`; we read it async and
-- drive the editor — the preview window (focused line) and the title-bar stats (match/total counts). This is
-- the editor-side of fzf-lua's builtin-previewer model, minus a second process: the MAIN editor is the
-- reader, no RPC server needed.

--- Create a fifo and start reading lines from it. `on_line(line)` fires (scheduled) with the LATEST line in
--- each read. Returns `{ path, close }` — `path` goes into the fzf bind; `close` stops the reader and removes
--- the fifo. Returns nil when a fifo cannot be made (caller then runs without that channel).
---@param on_line fun(line: string)
---@return { path: string, close: fun() }?
local function make_fifo(on_line)
    local path = vim.fn.tempname()
    vim.fn.system({ "mkfifo", path })
    if vim.v.shell_error ~= 0 then
        return nil
    end
    -- O_RDWR ("r+") so the open returns immediately instead of blocking until fzf opens the write end.
    local fd = uv.fs_open(path, "r+", tonumber("0666", 8))
    if not fd then
        os.remove(path)
        return nil
    end
    local pipe = uv.new_pipe(false)
    pipe:open(fd)
    local buf = ""
    pipe:read_start(function(err, data)
        if err or not data then
            return
        end
        buf = buf .. data
        local latest
        while true do
            local nl = buf:find("\n", 1, true)
            if not nl then
                break
            end
            latest = buf:sub(1, nl - 1)
            buf = buf:sub(nl + 1)
        end
        if latest then
            vim.schedule(function()
                on_line(latest)
            end)
        end
    end)
    return {
        path = path,
        close = function()
            pcall(function()
                pipe:read_stop()
            end)
            pcall(function()
                pipe:close()
            end) -- closes fd
            os.remove(path)
        end,
    }
end

-- ─── preview (a real Neovim window) ───────────────────────────────────────────

--- Set the preview panel's winbar to the selected file (devicon + name + dimmed dir), the lvim-lsp peek look —
--- the same bar the tint picker draws, so both backends share one preview chrome.
---@param pan table
---@param item table?
local function set_preview_winbar(pan, item)
    if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
        return
    end
    local function esc(s)
        return (tostring(s or ""):gsub("%%", "%%%%"))
    end
    local FILE, DIR, BAR = "LvimUiPeekFile", "LvimUiPickerPreviewDir", "LvimUiPeekFileBar"
    local path = item and item.path
    if path and path ~= "" then
        local rel = vim.fn.fnamemodify(path, ":~:.")
        local tail = vim.fn.fnamemodify(rel, ":t")
        local dir = vim.fn.fnamemodify(rel, ":h")
        dir = (dir == "." or dir == "") and "" or (dir .. "/")
        local gl = iconlib.get(tail, { provider = config.icon_provider, color_mode = config.icon_color_mode }).glyph
        local icon = (gl and gl ~= "") and (gl .. " ") or ""
        vim.wo[pan.win].winbar = ("%%#%s# %s%s %%#%s# %s %%#%s#%%="):format(
            FILE,
            esc(icon),
            esc(tail),
            DIR,
            esc(dir),
            BAR
        )
    else
        -- a focused result with no path → its text (the no-item case is handled in `render_preview`)
        vim.wo[pan.win].winbar = ("%%#%s# %s %%#%s#%%="):format(FILE, esc(item and item.text or ""), BAR)
    end
end

-- ─── open ─────────────────────────────────────────────────────────────────────

---@class LvimFzfOpts
---@field title? string  the finder title — the chassis native centered border-title
---@field icon? string  an optional leading glyph fronting the title
---@field title_line? string  title placement: "row" (a top content row, default) | "statusline" (the centralized chrome overlay) | "border" (opt-in native border-title)
---@field title_pos? "left"|"center"|"right"  title alignment override for THIS open (default: `config.title_pos`, layout-independent)
---@field counter? string  match-count placement: "footer" (default — the bottom-right border) | "title" (folded into the border-title)
---@field preview_side? string  where the preview panel sits: "right" (default) | "left" | "above" | "below"
---@field cmd? string[]  the producer argv (FZF_DEFAULT_COMMAND): fzf runs + streams it (files / dirs / git)
---@field contents? string[]  a STATIC candidate list (e.g. buffers) — fed to fzf via a temp file
---@field reload? string  a shell command with a literal `{q}` placeholder (grep): fzf RE-RUNS it per keystroke
---@field fzf_args? string[]  extra raw fzf flags for this finder (e.g. `--delimiter` / `--with-nth`)
---@field multiline? integer  grep 2-row layout level (0/nil = off); adds `--read0`/`--print0` (+`--gap` if 2)
---@field parse? fun(line: string): table  turn a selected/focused fzf line into an item (default `{ path = line }`)
---@field preview? fun(item: table): string[], string?, integer?  preview lines (+ filetype, + focus line)
---@field on_confirm fun(item: table)  called with the chosen item
---@field on_cancel? fun()  called when dismissed without a choice
---@field reopen? fun(backend: "fzf"|"tint")  installed by the finder (with_backend_swap); the C-] swap key exits fzf and `finish` calls it to reopen the finder in the tint list
---@field keys? { key: string, name?: string, mode?: "t"|"n", run: fun(item: table, close: fun()) }[]  per-call ROW ACTIONS on the focused item (e.g. open in a split); `mode` limits the key to insert ("t") / NORMAL ("n"), default both; `close` dismisses the picker
---@field empty_preview? string  the "nothing to preview" placeholder bar text (default "Nothing to preview")
---@field layout? "float"|"bottom"|"area"
---@field height? integer  rows for the docked layouts
---@field max_rows? integer  list/preview height (default 15)
---@field key? string  the dock KIND key — this finder's stable identity in the dock stack (id = "lvim-picker:"..key); nil ⇒ derived from the title, else un-managed
---@field dock_stack? boolean  PER-CALL override of `config.dock.dock_stack` (managed stack consumer vs geometry-only standalone); nil ⇒ inherit config
---@field force? { float?: table, area?: table, bottom?: table }  PER-CALL anchored geometry override (per layout), deep-merged over the central geometry AND `config.dock.force`; `opts.height` still wins as an explicit rows size
---@field dock? { on_open: fun(state: table), on_close: fun(state: table), on_restart?: fun() }  dock-stack hooks set by the picker when this open is MANAGED by lvim-utils.dock: `on_open` hands the live surface `state` to the manager (so it can park / focus / read its buffers); `on_close` (run in the surface on_close) does the manager's bookkeeping (silent for a dock-driven park/close via `dock_teardown`, PARK+REMEMBER for a self/external close); `on_restart` re-arms the leader owner after a keep-open restart swaps the terminal buffer. Absent ⇒ un-managed (fzf owns `source.close_active` replace-in-place).

--- Open the fzf-TUI finder.
---@param opts LvimFzfOpts
function M.open(opts)
    opts = opts or {}
    opts.layout = opts.layout or (config or {}).layout or "area"
    -- The editor window the finder opened FROM — captured BEFORE `close_active()` below, which tears down any
    -- docked finder still open and hands focus to some OTHER window (e.g. the first one). Capturing it after that
    -- made "open in split" split the wrong window (the reported bug); the invoking window is the current one now.
    local opener = api.nvim_get_current_win()
    -- MANAGED by the dock stack (`opts.dock` present)? The dock enforces one-visible-per-layout and has already
    -- PARKED the previous consumer (kept restorable), so we must NOT close_active (destroy) it — mirroring the
    -- tint backend's managed path. UN-MANAGED: close whatever finder is open (EITHER backend, via the shared
    -- registry) so this one replaces it in place — its docked area is released first, instead of stacking above.
    local managed = opts.dock ~= nil
    if not managed then
        source.close_active()
    end

    -- List/preview row cap. DOCKED (area/bottom) stays compact (15). FLOAT sizes the cap to the CONFIGURED
    -- float height so a full result set fills it up to `ui_config.size.float.height` — a fixed 15 left an
    -- auto-fit (height_auto) float capped at ~20 rows, never reaching the 0.9 the user asked for. The cap is
    -- `target - 5`: content_h = title+air (2) + footer air+bar (2) + the fzf prompt row (1) + match rows, and
    -- the side-only content border adds no vertical rows — so at `maxr = target - 5` a full list makes
    -- content_h reach exactly `target`. Auto-fit still shrinks for few results; the surface clamps any
    -- overshoot at the height cap (fzf scrolls the remainder). `opts.max_rows` overrides either way.
    local maxr
    if opts.max_rows then
        maxr = opts.max_rows
    elseif opts.layout == "float" then
        -- Fill the list up to the CENTRAL float slot height (config.dock.geometry.float.height via dock.slot),
        -- so a full result set reaches the configured float height. The slot is already resolved to rows.
        local target = require("lvim-utils.dock").slot("float").height
        maxr = math.max(5, target - 5)
    else
        maxr = 15
    end
    local empty_preview = opts.empty_preview or (config or {}).empty_preview or "Nothing to preview"
    local parse = opts.parse
        or function(line)
            return { path = line } -- a plain file line: the path IS the location, no separate message text
        end

    local state = {
        closed = false,
        -- The outcome was already delivered (a confirm/cancel via `finish`, or a per-call row action owns it):
        -- on_close must NOT then ALSO fire on_cancel. When it is still false at close time the finder was
        -- dismissed EXTERNALLY (replaced by the next finder via the shared registry, or a surface-owned close)
        -- with no choice — which counts as a cancel, so on_close delivers on_cancel (e.g. colorschemes restores).
        handled = false,
        normal = false, -- NORMAL mode on the list: <Esc> left fzf's input, j/k drive fzf via chansend
        st = nil,
        list_pan = nil,
        preview_pan = nil,
        term_buf = nil,
        term_chan = nil,
        cur_item = nil,
        outfile = vim.fn.tempname(),
        fifo = nil, ---@type { path: string, close: fun() }?
        count_fifo = nil, ---@type { path: string, close: fun() }?
        counts = { match = 0, total = 0, seen = false }, -- fed live from fzf ($FZF_MATCH_COUNT / $FZF_TOTAL_COUNT); seen = a count has arrived
    }
    -- this finder's entry in the shared "open finder" registry (so the next open closes us first)
    local active_entry = {
        close = function()
            if not state.closed and state.st then
                pcall(state.st.close)
            end
        end,
    }

    -- The title + match counter flow through the chassis (the single title path): a native centered
    -- border-title + the count in the border (default the bottom-right border-footer, per `counter`), OR — when
    -- `title_line="statusline"` — the centralized chrome-overlay title (the chassis owns that publish). fzf's
    -- OWN info counter stays hidden (--info=hidden); the live `match/total` stats come from fzf (the count fifo,
    -- $FZF_MATCH_COUNT / $FZF_TOTAL_COUNT) and feed `count_fn`, which `refresh_count` re-applies to the live
    -- border / overlay as they climb during the stream and narrow as you filter.
    local title_box = (opts.title ~= nil and opts.title ~= "") and { icon = opts.icon, text = opts.title } or nil
    local function count_fn()
        return { current = state.counts.match or 0, total = state.counts.total or 0 }
    end
    local function refresh_count()
        if state.st and state.st.set_counter then
            state.st.set_counter(count_fn)
        end
    end
    -- panel CONTENT heights (mirror the tint picker): the LIST fits the live match count, the PREVIEW fits the
    -- focused file's line count — both capped at `max_rows`. `refit` relayouts when either changes, so the
    -- panels + the auto-fit area track the content live.
    local function list_rows()
        -- BEFORE the first count arrives (fzf streams its producer asynchronously), assume a FULL list (`maxr`):
        -- the finder then opens at its full height at once — in the area zone it docks at the same height as the
        -- panel it replaced, so there is no open-empty-then-grow flicker. Once a count is seen, use it: the MATCH
        -- rows only (the search/prompt row is the provider's separate "+1"); 0 on an empty result collapses the
        -- list to the single prompt row so the panels + the divider match the visible content height.
        if not state.counts.seen then
            return maxr
        end
        return math.min(state.counts.match or 0, maxr)
    end
    local function file_rows()
        local it = state.cur_item
        if it and it.path and it.path ~= "" then
            -- Reuse the line count `render_preview` already computed for THIS path (it reads the file to build
            -- the preview) — the focused file was otherwise read twice per focus event (once here for the panel
            -- height, once in render_preview for the content).
            if state.preview_cache and state.preview_cache.path == it.path then
                return math.max(1, math.min(state.preview_cache.count, maxr))
            end
            if vim.fn.filereadable(it.path) == 1 then
                -- No cached preview yet (a size query before the first render) → count lines with `readfile`
                -- (first `maxr` only). NEVER `bufadd`+`bufload`: loading the real file buffer fires its FileType
                -- autocmds → the LSP attaches to every focused file → "install missing server" prompts, spurious
                -- diagnostics, and the autocmd cascade that pops the quickfix open. The row count needs no buffer.
                local ok, lines = pcall(vim.fn.readfile, it.path, "", maxr)
                return ok and math.max(1, #lines) or 1
            end
        end
        return 1
    end
    -- The preview panel's CONTENT height when a file is focused: the file rows + 1 for the file WINBAR, floored
    -- at PREVIEW_MIN. Neovim does NOT paint a window's winbar once the window gets too short (empirically a panel
    -- shorter than 4 rows drops it), so a 1- or 2-line file would otherwise show its content with NO name winbar
    -- — the floor keeps the panel tall enough that the winbar always renders. With nothing focused: a single row.
    local PREVIEW_MIN = 4
    local function preview_rows()
        return state.cur_item and math.max(file_rows() + 1, PREVIEW_MIN) or 1
    end
    local last_fit
    local function refit()
        -- Key on the actual PANEL footprints (list = matches + fzf prompt row; preview = preview_rows, which
        -- already floors at the winbar minimum) so the key tracks the real area height.
        local lr, fr = list_rows() + 1, preview_rows()
        -- The auto-fit AREA height is driven by the panel STACK, not the raw pair: side-by-side (right/left) →
        -- the TALLER panel (max); stacked (above/below) → their SUM. Key on THAT, so moving onto a file whose
        -- row count changes but does NOT change the area height (a long list dwarfing a shorter preview → max
        -- unchanged) does NOT relayout — which is what made the whole panel flicker on J/K. The preview CONTENT
        -- still updates via render_preview (on_focus); only the needless relayout is skipped.
        local side = (state.st and state.st.preview_side) or opts.preview_side or "right"
        local vertical = side == "above" or side == "below"
        local key = vertical and (lr + fr) or math.max(lr, fr)
        if key ~= last_fit and state.st and state.st.relayout then
            last_fit = key
            state.st.relayout()
        end
    end
    local render_preview -- forward decl: update_counts clears the preview when the result count hits 0 (below)
    --- Apply fzf's live match/total to the title bar (statusline or the header band).
    ---@param match integer
    ---@param total integer
    local function update_counts(match, total)
        state.counts.match, state.counts.total, state.counts.seen = match, total, true
        if state.closed then
            return
        end
        -- 0 matches ⇒ nothing is focused. fzf does NOT emit a focus event for a list that empties as you type, so
        -- the preview would otherwise linger on the last focused file — clear it to the placeholder here (the
        -- match count is the reliable signal). Only when something WAS shown, to avoid redundant re-renders.
        if match == 0 and state.cur_item ~= nil then
            state.cur_item = nil
            render_preview(state.preview_pan, nil)
        end
        refresh_count() -- re-apply the live match/total to the chassis border / overlay counter
        refit() -- the match count changed → re-fit the list panel + the auto area
    end

    -- ── park / return (leave fzf for the editor, keep the finder open) ──
    -- PARK: leave fzf's input + focus the editor (the finder stays open, fzf keeps running). A transient
    -- normal-mode map on the SAME key returns. RETURN: focus the fzf terminal → its WinEnter autocmd
    -- re-enters terminal-mode (back in fzf, exactly where you left it) and clears the parked state + map.
    -- ── keys (ALL configurable, config.keys) ──
    local kcfg = (config or {}).keys or {}
    --- A config key value (a single key, a list, or ""/{}) → a flat list of vim-notation keys.
    ---@param v string|string[]|nil
    ---@return string[]
    local function keylist(v)
        if type(v) == "table" then
            return v
        end
        return (type(v) == "string" and v ~= "") and { v } or {}
    end
    --- vim key notation → fzf key notation: "<Tab>"→"tab", "<C-q>"→"ctrl-q", "<CR>"→"enter", "<Esc>"→"esc".
    ---@param k string
    ---@return string
    local function fzfkey(k)
        local s = (k or ""):gsub("^<(.+)>$", "%1"):lower()
        s = s:gsub("^c%-", "ctrl-"):gsub("^[ma]%-", "alt-")
        return ({ cr = "enter", ["return"] = "enter", esc = "esc", tab = "tab", space = "space", bs = "bspace" })[s]
            or s
    end
    local park_key = keylist(kcfg.park)[1] or ""
    local qf_key = keylist(kcfg.quickfix)[1] -- the one key that accepts-into-quickfix (via fzf --expect)
    --- Drop the transient return-map (idempotent) and RESTORE whatever global normal-mode mapping the park key
    --- had before park shadowed it (snapshotted in `park`), so a user's own `<C-o>` (or whatever the park key is)
    --- survives a park/return cycle instead of being deleted for the session.
    local function clear_park_map()
        if state.parked and park_key ~= "" then
            pcall(vim.keymap.del, "n", park_key)
            if state.saved_park_map and not vim.tbl_isempty(state.saved_park_map) then
                pcall(vim.fn.mapset, "n", false, state.saved_park_map)
            end
            state.saved_park_map = nil
        end
        state.parked = false
    end
    --- Return focus to the fzf terminal (the WinEnter autocmd does startinsert + clear_park_map).
    local function unpark()
        if state.list_pan and state.list_pan.win and api.nvim_win_is_valid(state.list_pan.win) then
            api.nvim_set_current_win(state.list_pan.win)
        end
    end
    --- Leave fzf's input for the editor, keeping the finder open; arm the return-map.
    local function park()
        if state.closed or not (opener and api.nvim_win_is_valid(opener)) then
            return
        end
        state.parked = true
        vim.cmd("stopinsert")
        api.nvim_set_current_win(opener)
        if park_key ~= "" then
            -- snapshot the user's own global mapping on the park key (a dict, `{}` when none) so clear_park_map
            -- can restore it after the return, rather than leaving the key stripped.
            state.saved_park_map = vim.fn.maparg(park_key, "n", false, true)
            vim.keymap.set("n", park_key, unpark, { nowait = true, silent = true, desc = "Return to the finder" })
        end
    end

    -- ── preview rendering (the real Neovim window) ──
    -- The preview window's options, asserted on every render so the preview stays consistent across files:
    -- plain line numbers, no sign / fold / statuscolumn gutter, the blue cursorline.
    local function apply_preview_opts(win)
        if not (win and api.nvim_win_is_valid(win)) then
            return
        end
        vim.wo[win].wrap = false
        vim.wo[win].number = true
        vim.wo[win].relativenumber = false
        vim.wo[win].signcolumn = "no"
        vim.wo[win].foldcolumn = "0"
        vim.wo[win].statuscolumn = ""
        vim.wo[win].cursorline = true
        -- keep FloatBorder mapped to the tinted peek-border group — else the preview block's content ring
        -- (ui_config.content_border) renders its glyphs UNtinted and blends into the bg, reading as "no border".
        vim.wo[win].winhighlight = "Normal:LvimUiPeekNormal,CursorLine:LvimUiCursorLine,FloatBorder:LvimUiPeekBorder"
    end

    render_preview = function(pan, item)
        if not (pan and pan.win and api.nvim_win_is_valid(pan.win) and pan.buf and api.nvim_buf_is_valid(pan.buf)) then
            return
        end
        if not item then
            -- NOTHING focused → the single styled "nothing to preview" bar (no winbar → no empty body row).
            -- It is a placeholder, NOT file content, so drop the line-number gutter too (else it reads "1  Nothing
            -- to preview"); apply_preview_opts turns numbers back on for a real preview.
            vim.wo[pan.win].winbar = ""
            vim.wo[pan.win].number = false
            preview.render_empty(pan.buf, NS, empty_preview)
            return
        end
        api.nvim_buf_clear_namespace(pan.buf, NS, 0, -1) -- drop any prior empty-bar tint before the real preview
        ---@type string[], string?, integer?
        local lines, ft, focus = { "" }, "", nil
        if opts.preview then
            local pl, pf, fo = opts.preview(item)
            lines = (type(pl) == "table" and pl) or (pl and { tostring(pl) }) or { "" }
            ft, focus = pf, fo
        end
        -- Cache the line count for THIS path so `file_rows` (the panel-height query, fired right after via
        -- refit) reuses it instead of re-reading the file.
        if item.path and item.path ~= "" then
            state.preview_cache = { path = item.path, count = #lines }
        end
        -- Fresh buffer per previewed file so the treesitter highlighter can switch languages as you scroll
        -- (a reused buffer caches one parser/language). Still WITHOUT a `filetype` → no FileType → no LSP
        -- attach / install offers.
        preview.render_file(pan, lines, ft)
        apply_preview_opts(pan.win)
        -- Set the file winbar (icon · name · dir) AFTER render_file: `nvim_win_set_buf` (the buffer swap inside
        -- render_file) clears the window-local winbar, so setting it before would be wiped (the no-winbar bug).
        set_preview_winbar(pan, item)
        if focus then
            pcall(api.nvim_win_set_cursor, pan.win, { math.max(1, math.min(focus, #lines)), 0 })
            api.nvim_win_call(pan.win, function()
                vim.cmd("normal! zz")
            end)
        end
    end

    -- fzf focus → update the preview to the focused line's item. An EMPTY line means nothing is focused (a
    -- no-match list): clear the preview to the placeholder instead of leaving the last file's content stranded.
    local function on_focus(line)
        if state.closed then
            return
        end
        state.cur_item = (line ~= "" and parse(line)) or nil
        render_preview(state.preview_pan, state.cur_item)
        refit() -- the focused file changed → re-fit the preview panel + the auto area
    end

    -- Scroll the PREVIEW window (a real nvim window) from the fzf terminal — half a page down/up, like the
    -- tint finder's <C-d>/<C-u>. `nvim_win_call` runs the scroll IN the preview window; focus stays in fzf.
    -- `zz` after each scroll keeps the cursor (and so the cursorline) CENTERED in the preview.
    ---@param dir 1|-1
    local function scroll_preview(dir)
        local p = state.preview_pan
        if not (p and p.win and api.nvim_win_is_valid(p.win)) then
            return
        end
        api.nvim_win_call(p.win, function()
            vim.cmd("normal! " .. api.nvim_replace_termcodes(dir > 0 and "<C-d>" or "<C-u>", true, false, true))
            vim.cmd("normal! zz")
        end)
    end

    -- ── close / confirm / cancel ──
    --- Send the selected rows to the quickfix list (each parsed into a file/buffer + line/col + text).
    ---@param items string[]  the raw selected fzf lines
    local function to_quickfix(items)
        local qf = {}
        for _, line in ipairs(items) do
            local it = parse(line)
            if it then
                qf[#qf + 1] = {
                    filename = it.path,
                    bufnr = (not it.path) and it.bufnr or nil,
                    -- 0 (not 1) when the entry has no real position (a plain file pick), so consumers can tell a
                    -- file list from a grep/diagnostic one; vim still jumps to the file's top.
                    lnum = it.lnum or 0,
                    col = it.col or 0,
                    -- No parsed message? A FILE pick (it has a `path`) has none — the location IS the row, so
                    -- leave it EMPTY (else the browser renders "path  path", the path twice). Only a finder whose
                    -- line is itself the display text (no path) falls back to the raw line.
                    text = it.text or (it.path and "" or line),
                }
            end
        end
        if #qf > 0 then
            vim.fn.setqflist({}, " ", { title = opts.title or "Picker", items = qf })
            vim.cmd("botright copen")
        end
    end

    -- Open-method routing (config.keys.open_methods): each method carries a NORMAL key (`n`) and an INSERT
    -- key (`i`). The i-keys of vsplit/hsplit/tabedit go through fzf `--expect`, so fzf prints the pressed key on
    -- exit and `finish` routes it; `edit` is the plain accept (no --expect key → fzf prints ""). The normal keys
    -- are bound (below) to FEED the matching i-key to fzf, so both modes funnel through the same --expect.
    local om = kcfg.open_methods or {}
    local method_of = {} -- fzf-key string → method name ("vsplit" | "hsplit")
    local expect_methods = {} -- fzf-key strings to add to --expect
    for _, m in ipairs({ "vsplit", "hsplit" }) do
        local sp = om[m]
        if type(sp) == "table" and type(sp.i) == "string" and sp.i ~= "" then
            local fk = fzfkey(sp.i)
            method_of[fk] = m
            expect_methods[#expect_methods + 1] = fk
        end
    end
    -- Backend SWAP key (C-]): reopen this finder in the tint list. fzf `--expect`s it so it exits + prints the
    -- key, and `finish` routes it to `opts.reopen` (installed by the finder). Only when the finder supports it.
    local swap_key = keylist(kcfg.swap_backend or {})[1]
    local swap_fk = (opts.reopen and swap_key and swap_key ~= "") and fzfkey(swap_key) or nil
    -- `start_fzf` is defined further down; forward-declared so `finish` (above it) can restart it IN PLACE for a
    -- keep-open dock (open a file without tearing the frame down → no flicker).
    local start_fzf
    -- `footer_bands(mode)` is defined further down (it needs `opts`); forward-declared so the terminal's mode
    -- switches (to_insert / <Esc>) inside `start_fzf` can re-render the footer for the new mode via `set_footer`.
    local footer_bands

    local confirmed = false
    --- Run `fn` as a single ZONE HANDOFF when this finder is area-docked: the picker's teardown (release its
    --- zone reserve) and whatever the consumer does in its callback (e.g. lvim-space re-opening a panel —
    --- reserve a segment) coalesce into ONE reflow, instead of the zone collapsing then growing (a flicker on
    --- the way back). Routed through `surface.zone_handoff` (the zone registers the coalescer) so the picker
    --- never requires msgarea. Off the area zone there is nothing to coalesce, so just run it.
    local function with_handoff(fn)
        if opts.layout == "area" then
            surface.zone_handoff(fn)
        else
            fn()
        end
    end
    --- `lines` = every line fzf wrote to the outfile. With `--expect` (a quickfix key configured), line 1 is
    --- the pressed key ("" for plain accept) and the rest are the selected/marked rows; without it, all lines
    --- are the selection. The quickfix key routes to to_quickfix; anything else opens the first row.
    ---@param code integer
    ---@param lines string[]?
    local function finish(code, lines)
        if state.closed then
            return
        end
        state.handled = true -- finish OWNS the outcome (it fires on_confirm or on_cancel itself below)
        -- Remember the MODE the file was opened FROM (normal-on-list vs insert query), so a keep-open dock returns
        -- to the SAME mode after the restart instead of always dropping into insert.
        local was_normal = state.normal
        -- Parse the selection FIRST (no zone ops). `--expect` prints the pressed key as line 1 whenever ANY expect
        -- key is registered (the quickfix key OR an open-method key); a plain accept prints "".
        local has_expect = qf_key ~= nil or #expect_methods > 0 or swap_fk ~= nil
        local key, items = "", {}
        if code == 0 and lines and #lines > 0 then
            local start = 1
            if has_expect then
                key = lines[1] or ""
                start = 2
            end
            for i = start, #lines do
                if lines[i] ~= "" then
                    items[#items + 1] = lines[i]
                end
            end
        end
        -- BACKEND SWAP (C-]): the finder is being reopened in the tint list — don't open/close normally; hand off
        -- to `opts.reopen("tint")`, which routes through the dock and REPLACES this fzf entry in place. Scheduled
        -- so it runs after this exit callback unwinds.
        if swap_fk and key == swap_fk and opts.reopen then
            vim.schedule(function()
                opts.reopen("tint")
            end)
            return
        end
        -- Route the accept key → a method: the quickfix key → the quickfix list; a --expect open-method key →
        -- vsplit / hsplit / tab; anything else (incl. the plain "") → edit in the opener.
        local method = "edit"
        if qf_key and key == fzfkey(qf_key) then
            method = "qf"
        elseif method_of[key] then
            method = method_of[key]
        end
        -- Open the focused item: focus the OPENER, PREPARE the target window for a split/tab, then let the
        -- consumer's on_confirm place the file in the (now current) window.
        local function do_open()
            if opener and api.nvim_win_is_valid(opener) then
                api.nvim_set_current_win(opener)
            end
            if method == "vsplit" then
                vim.cmd("vsplit")
            elseif method == "hsplit" then
                vim.cmd("split")
            end
            if opts.on_confirm then
                opts.on_confirm(parse(items[1]))
            end
        end
        -- KEEP-OPEN docks: an area/bottom finder whose layout is not `auto_hide` STAYS open on a file open — do
        -- not close the frame; open the file, then restart fzf IN PLACE (the frame + its reserved zone segment
        -- never close → no flicker) and keep or drop focus per `keep_focus`. A cancel or the quickfix key falls
        -- through to the normal close path.
        local lay = opts.layout
        -- `auto_hide` / `keep_focus` come from the CENTRAL geometry (config.dock.geometry.<layout> via dock.slot).
        local lslot = require("lvim-utils.dock").slot(lay)
        local keep_open = (lay == "area" or lay == "bottom") and not lslot.auto_hide and #items > 0 and method ~= "qf"
        if keep_open then
            do_open()
            local pan = state.list_pan
            if pan and pan.win and api.nvim_win_is_valid(pan.win) then
                if state.outfile then -- clear it so a subsequent abort can't re-read this pick
                    local f = io.open(state.outfile, "w")
                    if f then
                        f:close()
                    end
                end
                -- Restart fzf in the SAME panel window. `start_fzf` swaps a FRESH buffer into the window; only
                -- AFTER that do we wipe the exited fzf's old buffer. Deleting it FIRST would close the window (it
                -- is the buffer on display) → start_fzf no-ops on an invalid window and the dock is stranded.
                local old_buf = state.term_buf
                state.term_started = false
                state.term_chan = nil
                start_fzf(pan)
                if old_buf and old_buf ~= state.term_buf and api.nvim_buf_is_valid(old_buf) then
                    pcall(api.nvim_buf_delete, old_buf, { force = true })
                end
                -- Restore the pre-open MODE so the fresh fzf's WinEnter honours it (normal → no startinsert).
                state.normal = was_normal
                if lslot.keep_focus ~= false and api.nvim_win_is_valid(pan.win) then
                    api.nvim_set_current_win(pan.win)
                    if was_normal then
                        -- opened FROM normal-on-list → stay there: cursor hidden (fzf selection is the focus), j/k
                        -- drive the list. WinEnter skipped startinsert (state.normal), so we are already in normal.
                        pcall(cursor.mark_hide_buffer, state.term_buf, true)
                    else
                        vim.cmd("startinsert")
                    end
                end
                -- MANAGED: the restart swapped the fzf terminal buffer (the old one was deleted above), so
                -- re-install the dock leader owner on the fresh buffer set — otherwise <Leader>n/p/x/m would
                -- silently stop working in the kept-open finder.
                if managed and opts.dock.on_restart then
                    pcall(opts.dock.on_restart)
                end
            end
            return
        end
        -- Normal close path: close + route inside ONE handoff, so a consumer re-opening a panel in its callback
        -- (the search step-back) coalesces with the teardown into a single zone reflow (no flicker).
        with_handoff(function()
            if state.st then
                pcall(state.st.close) -- triggers surface on_close → resource cleanup below
            end
            if #items == 0 then
                if opts.on_cancel then
                    opts.on_cancel()
                end
                return
            end
            confirmed = true
            if method == "qf" then
                to_quickfix(items)
            else
                do_open()
            end
        end)
    end

    -- ── the fzf command (run in the terminal panel) ──
    -- Build the shell command line: `fzf <args> > outfile`. fzf draws its TUI on the tty (the pty of the
    -- panel window) and writes the SELECTED line to stdout, which we redirect to `outfile` and read on exit
    -- (the fzf-lua selection protocol). `FZF_DEFAULT_COMMAND` (the producer) is passed via the job env.
    local function shellesc(s)
        return vim.fn.shellescape(s)
    end
    local function build_fzf_cmdline()
        local args = {
            "fzf",
            "--ansi",
            "--layout=reverse",
            "--info=hidden", -- hide fzf's own counter — the match/total stats live in OUR title bar instead
            "--no-separator", -- no rule under the prompt → the list sits DIRECTLY below the search row
            "--no-scrollbar", -- no scrollbar column (the thin `▌` bar down the left/right of the list)
            "--highlight-line", -- the active row's tint covers the WHOLE row, not just the text
            "--multi", -- Tab marks/unmarks rows (multi-select); the mark dot shows in the blank front column
            "--marker=" .. ((config or {}).marker or "●"),
            "--prompt=" .. fzf_prompt(),
            "--pointer=", -- no active-row arrow (the row is shown by --highlight-line); also shifts the item
            -- text one column left so it starts directly UNDER the prompt's search glyph

            "--gutter= ", -- blank the gutter column (fzf's default gutter char is a `▌` — the thin left bar)
            "--input-border=right", -- bordered input section → fzf paints the light field tint (input-bg); a
            -- LEFT border is a COLUMN (not an extra row), so the search stays ONE row tall, dissolved into the tint
            "--color=" .. fzf_colors(),
            "--preview-window=hidden", -- we drive our OWN Neovim preview, not fzf's
        }
        -- the focus → preview fifo bind (only when a preview + fifo are live)
        if opts.preview and state.fifo then
            -- 2-row grep: `{}` is the whole record (location row + `\n` + indented text row); the preview only
            -- needs the LOCATION row, so emit just its first line — else the fifo reader sees the text row and
            -- `parse` fails (preview shows "[unreadable]"). `printf '%s\n'` (not `echo`) so a `\` in a path is
            -- emitted VERBATIM — dash's `echo` interprets backslash escapes and would mangle such filenames.
            local emit = (opts.multiline and opts.multiline > 0) and "printf '%s\\n' {} | head -n1"
                or "printf '%s\\n' {}"
            local w = ("%s > %s"):format(emit, shellesc(state.fifo.path))
            args[#args + 1] = "--bind=focus:execute-silent(" .. w .. ")"
        end
        -- the match/total → title-bar stats: fzf sets $FZF_MATCH_COUNT / $FZF_TOTAL_COUNT for bind children;
        -- `result` fires after every filter (incl. each streamed batch), `load` at the final count. `zero` fires
        -- when a query/reload leaves NO matches — without it an empty grep reload never re-emits the count, so the
        -- title/border count FREEZES at the last non-zero value; the `zero` bind writes the fresh (0) count.
        if state.count_fifo then
            local cw = ('printf "%%s %%s\\n" "$FZF_MATCH_COUNT" "$FZF_TOTAL_COUNT" > %s'):format(
                shellesc(state.count_fifo.path)
            )
            args[#args + 1] = "--bind=result:execute-silent(" .. cw .. ")"
            args[#args + 1] = "--bind=load:execute-silent(" .. cw .. ")"
            args[#args + 1] = "--bind=zero:execute-silent(" .. cw .. ")"
        end
        -- LIVE mode (grep): fzf does NO fuzzy filtering of its own (`--disabled`); each query RELOADS the
        -- producer (`{q}` = the shell-quoted query fzf substitutes), so fzf re-renders the new results
        -- continuously while you type. The reload string is NOT shell-escaped (it IS a shell command).
        if opts.reload then
            args[#args + 1] = "--disabled"
            args[#args + 1] = "--bind=change:reload(" .. opts.reload .. ")"
            args[#args + 1] = "--bind=start:reload(" .. opts.reload .. ")"
        end
        -- mark / unmark with the configured key, then advance to the next row (multi-select toggle+down)
        for _, k in ipairs(keylist(kcfg.mark)) do
            args[#args + 1] = "--bind=" .. fzfkey(k) .. ":toggle+down"
        end
        -- `--expect`: fzf prints the pressed key as the first output line, so on exit `finish` knows how the
        -- selection was accepted — the quickfix key (→ quickfix list) or an open-METHOD key (→ vsplit / hsplit /
        -- tab). A plain accept prints "" (→ edit in the opener).
        local expect = {}
        if qf_key then
            expect[#expect + 1] = fzfkey(qf_key)
        end
        for _, fk in ipairs(expect_methods) do
            expect[#expect + 1] = fk
        end
        if swap_fk then -- the backend-swap key (C-]) → fzf exits, `finish` reopens the tint list
            expect[#expect + 1] = swap_fk
        end
        if #expect > 0 then
            args[#args + 1] = "--expect=" .. table.concat(expect, ",")
        end
        -- extra per-finder fzf flags (e.g. buffers: `--delimiter` / `--with-nth` to hide the bufnr field)
        for _, a in ipairs(opts.fzf_args or {}) do
            args[#args + 1] = a
        end
        -- fzf-lua 2-row grep: read/print records NUL-separated so each entry's embedded `\n` (location row +
        -- indented text row) is part of ONE record, not a row split. `--gap` adds a blank line between results
        -- (only when multiline == 2). Gated by source.fzf_multiline() to fzf >= 0.53.
        if opts.multiline and opts.multiline > 0 then
            args[#args + 1] = "--read0"
            args[#args + 1] = "--print0"
            if opts.multiline > 1 then
                args[#args + 1] = "--gap"
                args[#args + 1] = tostring(opts.multiline - 1)
            end
        end
        local parts = {}
        for _, a in ipairs(args) do
            parts[#parts + 1] = shellesc(a)
        end
        -- The INPUT caret SHAPE is the embedded terminal's (libvterm) cursor, NOT `guicursor` (which only
        -- gives the colour here) — fzf emits no cursor-shape escape, so libvterm keeps its block default.
        -- Emit a DECSCUSR "steady bar" (`ESC [ 6 q`) into the terminal BEFORE fzf so the caret is a thin bar.
        return "printf '\\033[6 q'; " .. table.concat(parts, " ") .. " > " .. shellesc(state.outfile)
    end

    -- the producer env (FZF_DEFAULT_COMMAND): the static list command, or `cat` of a contents temp file.
    local function producer_env()
        if opts.cmd then
            local parts = {}
            for _, a in ipairs(opts.cmd) do
                parts[#parts + 1] = shellesc(a)
            end
            return table.concat(parts, " ")
        elseif opts.contents then
            -- A keep-open dock RESTARTS fzf in place, re-running producer_env each time; remove the PREVIOUS
            -- contents temp file before minting a new one so a long-lived docked finder does not leak one per
            -- restart (on_close only ever deletes the last).
            if state.contents_file then
                os.remove(state.contents_file)
            end
            local f = vim.fn.tempname()
            local fh = io.open(f, "w")
            if fh then
                fh:write(table.concat(opts.contents, "\n"))
                if #opts.contents > 0 then
                    fh:write("\n")
                end
                fh:close()
            end
            state.contents_file = f
            return "cat " .. shellesc(f)
        end
        -- reload (grep) mode: an EMPTY initial producer (`true`) so fzf does not fall back to its built-in
        -- file walker; `start:reload` / `change:reload` provide the results once the user types.
        return "true"
    end

    -- ── the terminal LIST provider (hosts fzf) ──
    start_fzf = function(pan)
        if state.term_started or not (pan.win and api.nvim_win_is_valid(pan.win)) then
            return
        end
        state.term_started = true
        -- the fzf→editor fifos must exist before the cmdline references their paths
        if opts.preview and not state.fifo then
            state.fifo = make_fifo(on_focus)
        end
        if not state.count_fifo then
            -- each line is "match total"; drive the title bar's stats from it
            state.count_fifo = make_fifo(function(line)
                local m, t = tonumber((line:match("^(%d+)%s"))), tonumber((line:match("%s(%d+)%s*$")))
                if m and t then
                    update_counts(math.floor(m), math.floor(t))
                end
            end)
        end
        local tbuf = api.nvim_create_buf(false, true)
        state.term_buf = tbuf
        api.nvim_win_set_buf(pan.win, tbuf)
        -- The terminal panel is fzf's TUI ONLY: strip EVERY editor chrome the user's global config draws in the
        -- window gutter (winbar, number, sign / fold / STATUSCOLUMN columns — e.g. a `▌` cursorline rule down
        -- the left edge), so fzf's search band sits at the very top and the list runs edge to edge. Must run
        -- AFTER `termopen` (its TermOpen autocmd re-applies the user's window options) and be re-asserted on
        -- WinEnter, so it sticks instead of being overwritten back.
        local function strip_chrome()
            if pan.win and api.nvim_win_is_valid(pan.win) then
                vim.wo[pan.win].winbar = ""
                vim.wo[pan.win].number = false
                vim.wo[pan.win].relativenumber = false
                vim.wo[pan.win].signcolumn = "no"
                vim.wo[pan.win].foldcolumn = "0"
                vim.wo[pan.win].statuscolumn = ""
                vim.wo[pan.win].cursorline = false
            end
        end
        local env = { FZF_DEFAULT_OPTS = "" } -- neutralise the user's global opts; we pass our own
        local prod = producer_env()
        if prod then
            env.FZF_DEFAULT_COMMAND = prod
        end
        local cmdline = build_fzf_cmdline()
        api.nvim_win_call(pan.win, function()
            -- `jobstart(..., { term = true })` — the 0.12 replacement for the deprecated `termopen`; identical
            -- semantics (the current buffer, `tbuf`, becomes the terminal) run inside this `nvim_win_call`.
            state.term_chan = vim.fn.jobstart({ "sh", "-c", cmdline }, {
                term = true,
                env = env,
                on_exit = function(_, code)
                    local lines = {}
                    local f = io.open(state.outfile)
                    if f then
                        if opts.multiline and opts.multiline > 0 then
                            -- --print0 → NUL-separated records (each may contain a `\n`); split on NUL and drop
                            -- the trailing empty the final NUL leaves. An `--expect` key stays as record 1.
                            lines = vim.split(f:read("*a") or "", "\0", { plain = true })
                            if lines[#lines] == "" then
                                lines[#lines] = nil
                            end
                        else
                            for line in f:lines() do
                                lines[#lines + 1] = line
                            end
                        end
                        f:close()
                    end
                    vim.schedule(function()
                        finish(code, lines)
                    end)
                end,
            })
        end)
        vim.bo[tbuf].filetype = "lvim-picker-fzf"
        -- the fzf INPUT caret (config.caret), through the cursor module so it coexists with
        -- cursor-hiding instead of being clobbered by it. The query text colour is the input group's fg.
        pcall(cursor.mark_cursor_buffer, tbuf, source.caret_fragment("t"))
        strip_chrome() -- after termopen + filetype, so the TermOpen/FileType chrome is overwritten, not us
        vim.schedule(strip_chrome) -- and once more next tick, beating any deferred chrome the user applies
        -- Keep the terminal in TERMINAL-mode whenever its window is entered, so fzf always receives the
        -- keystrokes (a stray focus bounce — LSP attach, msgarea reflow — must not leave keys going to the
        -- editor behind us). The single source of truth for "the fzf list has focus → fzf reads the keys".
        state.term_augroup = api.nvim_create_augroup("LvimFzfTerm_" .. tbuf, { clear = true })
        api.nvim_create_autocmd("WinEnter", {
            group = state.term_augroup,
            buffer = tbuf,
            callback = function()
                if not state.closed and state.term_chan then
                    clear_park_map() -- returning to the finder (however we got here) ends the parked state
                    strip_chrome() -- re-assert in case entering re-applied the user's gutter chrome
                    if not state.normal then -- in NORMAL mode we deliberately stay out of terminal-mode (j/k overlay)
                        vim.cmd("startinsert")
                    end
                end
            end,
        })
        -- Leaving the fzf terminal for a window OUTSIDE the picker (a raw window switch to the editor — e.g. the
        -- user's own <C-w>k, which bypasses the picker's park) ENDS the normal-mode-on-list state: the user has
        -- left the finder, so returning (<C-w>j / any refocus) should resume the INPUT with its caret, not drop
        -- back into the cursor-hidden normal overlay. An INTERNAL hop to the preview panel is not a leave.
        api.nvim_create_autocmd("WinLeave", {
            group = state.term_augroup,
            buffer = tbuf,
            callback = function()
                if not state.normal then
                    return
                end
                vim.schedule(function()
                    if state.closed then
                        return
                    end
                    local cur = api.nvim_get_current_win()
                    local inside = (state.list_pan and state.list_pan.win == cur)
                        or (state.preview_pan and state.preview_pan.win == cur)
                    if not inside then
                        state.normal = false
                        pcall(cursor.mark_hide_buffer, tbuf, false) -- re-arm the input caret for the return
                    end
                end)
            end,
        })
        local kopts = { buffer = tbuf, nowait = true, silent = true }
        -- park: leave fzf's input for the editor, keeping the finder open (terminal-mode, not passed to fzf)
        if park_key ~= "" then
            vim.keymap.set("t", park_key, park, kopts)
        end
        -- fzf owns these keys: pass the configured control keys it relies on STRAIGHT through to the terminal,
        -- overriding any inherited terminal-mode mapping (a user / plugin TermOpen often binds `<Esc>` to leave
        -- terminal-mode — that would swallow fzf's abort and strand the picker in normal mode). Buffer-local,
        -- so it only affects THIS fzf terminal and dies with the buffer. accept (→ open), mark (→ toggle),
        -- quickfix (→ accept-into-qf via --expect), abort (→ cancel), and nav all keep fzf's own bindings.
        for _, group in ipairs({ kcfg.accept, kcfg.mark, kcfg.quickfix, kcfg.abort, kcfg.nav }) do
            for _, lhs in ipairs(keylist(group)) do
                if lhs ~= "<Esc>" then -- <Esc> drops to NORMAL on the list (below), not passed to fzf as abort
                    vim.keymap.set("t", lhs, lhs, kopts)
                end
            end
        end
        -- NORMAL mode on the list (Telescope-style): <Esc> leaves fzf's input WITHOUT closing — fzf keeps
        -- running, and a normal-mode overlay drives it. `j`/`k` chansend Down/Up into the fzf PTY (so it moves
        -- the selection + the preview follows via the focus fifo); `i`/`a` return to typing; `<CR>` accepts;
        -- `q`/`<Esc>` close (send fzf its abort). The surface keys (rotate, panel nav) are also live here.
        local function feed(keys)
            if state.term_chan then
                pcall(vim.fn.chansend, state.term_chan, keys)
            end
        end
        -- Re-render the footer for `mode` in place (the buttons that ACTUALLY act differ insert vs normal).
        local function sync_footer(mode)
            if footer_bands and state.st and state.st.set_footer then
                pcall(state.st.set_footer, footer_bands(mode))
            end
        end
        local function to_insert()
            state.normal = false
            pcall(cursor.mark_hide_buffer, tbuf, false) -- restore the input caret (terminal mode shows it again)
            vim.cmd("startinsert")
            sync_footer("i")
        end
        vim.keymap.set("t", "<Esc>", function()
            state.normal = true
            -- NORMAL mode on the list: the REAL focus is fzf's own selection (down in the list), so HIDE the
            -- hardware cursor — otherwise it lingers on the (now-inactive) prompt row, visible and movable. The
            -- caret returns on `i`/`a` (to_insert). Horizontal motion is also disabled below so it can't wander.
            pcall(cursor.mark_hide_buffer, tbuf, true)
            -- LEAVE terminal-mode (stopinsert does NOT exit it) → NORMAL on the terminal buffer; fzf keeps running
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true), "n", false)
            sync_footer("n")
        end, kopts)
        vim.keymap.set("n", "j", function()
            feed("\27[B")
        end, kopts)
        vim.keymap.set("n", "k", function()
            feed("\27[A")
        end, kopts)
        -- NORMAL: the chassis' sector-cycle keys step the frame SECTORS (down to the footer button bar, up toward
        -- the editor). The chassis binds these on its own scratch buffer, so a hosted terminal rebinds them on ITS
        -- buffer — reading the SAME keys from the surface (`sector_next`/`sector_prev`) instead of hardcoding, so
        -- they track config. Without this they fall through to the user's global window-nav and never reach the
        -- footer. (In terminal mode the same keys stay fzf's list nav via the `kcfg.nav` passthrough.)
        for _, sk in ipairs({ { "sector_next", 1 }, { "sector_prev", -1 } }) do
            local dir = sk[2]
            for _, lhs in ipairs(keylist(surface.key(sk[1]))) do
                vim.keymap.set("n", lhs, function()
                    if state.st and state.st.sector then
                        state.st.sector(dir)
                    end
                end, kopts)
            end
        end
        vim.keymap.set("n", "i", to_insert, kopts)
        vim.keymap.set("n", "a", to_insert, kopts)
        vim.keymap.set("n", "<CR>", function()
            feed("\r")
        end, kopts)
        -- open-method NORMAL keys (v / x): feed the method's INSERT key to fzf, so it exits via --expect and
        -- `finish` routes it to vsplit / hsplit exactly like the insert chord — one code path for both modes.
        for _, m in ipairs({ "vsplit", "hsplit" }) do
            local sp = om[m]
            if
                type(sp) == "table"
                and type(sp.n) == "string"
                and sp.n ~= ""
                and type(sp.i) == "string"
                and sp.i ~= ""
            then
                vim.keymap.set("n", sp.n, function()
                    feed(api.nvim_replace_termcodes(sp.i, true, false, true))
                end, kopts)
            end
        end
        for _, lhs in ipairs({ "q", "<Esc>" }) do
            vim.keymap.set("n", lhs, function()
                feed("\27") -- fzf abort → on_exit → the finder closes
            end, kopts)
        end
        for _, r in ipairs({ { "<C-n>", 1 }, { "<C-p>", -1 } }) do
            vim.keymap.set("n", r[1], function()
                if state.st and state.st.rotate_preview then
                    state.st.rotate_preview(r[2])
                end
            end, kopts)
        end
        -- forward the fzf-owned actions (mark / quickfix) to the PTY in NORMAL too, so <Tab> marks + <C-q> sends
        -- to the quickfix exactly like in insert (chansend the raw key bytes fzf is bound to)
        for _, group in ipairs({ kcfg.mark, kcfg.quickfix }) do
            for _, lhs in ipairs(keylist(group)) do
                vim.keymap.set("n", lhs, function()
                    feed(api.nvim_replace_termcodes(lhs, true, false, true))
                end, kopts)
            end
        end
        -- Per-call ROW ACTIONS (`opts.keys`): extra keys that act on the FOCUSED row. `action.mode` picks where
        -- the key is live — "t" (insert query only), "n" (NORMAL only), or nil (both). Chords like <C-v> are safe
        -- in both; a plain key that also edits the query (e.g. <BS>) must be "n" so insert-mode typing is intact.
        -- Each runs `action.run(item, close)` with the focused item; `close` tears the picker down WITHOUT firing
        -- on_cancel/on_confirm — the action owns the outcome (e.g. open in a split, or step back to a panel).
        for _, action in ipairs(opts.keys or {}) do
            if action.key and action.run then
                local function fire()
                    -- run the row action inside a zone HANDOFF: its `close` (release this finder's segment) +
                    -- whatever it does next (the search step-back re-opens a panel — reserve a segment) coalesce
                    -- into one reflow, so dismissing back to the panel does not flicker the zone.
                    with_handoff(function()
                        action.run(state.cur_item, function()
                            state.closed = true -- the impending fzf on_exit finish() then no-ops (no on_cancel)
                            state.handled = true -- the action owns the outcome → on_close must not fire on_cancel
                            if state.st then
                                pcall(state.st.close)
                            end
                        end)
                    end)
                end
                if action.mode ~= "n" then
                    vim.keymap.set("t", action.key, fire, kopts)
                end
                if action.mode ~= "t" then
                    vim.keymap.set("n", action.key, fire, kopts)
                end
            end
        end
        -- NORMAL: <C-d>/<C-u> scroll the PREVIEW (as in insert); every OTHER Neovim scroll/page motion is blocked
        -- so it can't scroll the fzf terminal render under us (which would move the cursor + corrupt the display).
        if opts.preview then
            for _, lhs in ipairs(keylist(kcfg.preview_down)) do
                vim.keymap.set("n", lhs, function()
                    scroll_preview(1)
                end, kopts)
            end
            for _, lhs in ipairs(keylist(kcfg.preview_up)) do
                vim.keymap.set("n", lhs, function()
                    scroll_preview(-1)
                end, kopts)
            end
        end
        for _, lhs in ipairs({
            "<C-f>",
            "<C-b>",
            "<C-e>",
            "<C-y>",
            "<PageDown>",
            "<PageUp>",
            -- the JUMPLIST would load a previous location's buffer INTO the fzf list window (emptying the panel /
            -- showing a stray file), so block it in normal mode. (<C-i>/<Tab> is left alone — it is the fzf mark key.)
            "<C-o>",
            "gg",
            "G",
            "H",
            "M",
            "L",
            -- block CURSOR MOTION too: the cursor is hidden in NORMAL mode (the fzf selection is the real focus),
            -- so it must not wander off the prompt row — disable horizontal + word + line motions. (`v`/`x` are NOT
            -- here: they are the vsplit / hsplit open-method keys, bound above.)
            "h",
            "l",
            "<Left>",
            "<Right>",
            "0",
            "$",
            "^",
            "w",
            "b",
            "e",
            "W",
            "B",
            "E",
            "<Home>",
            "<End>",
            "f",
            "F",
            "t",
            "T",
        }) do
            vim.keymap.set("n", lhs, "<Nop>", kopts)
        end
        -- the preview-scroll keys scroll the PREVIEW (a real nvim window) instead of going to fzf — matching
        -- the tint finder. (fzf's own scroll/query editing on these keys is given up here.)
        if opts.preview then
            for _, lhs in ipairs(keylist(kcfg.preview_down)) do
                vim.keymap.set("t", lhs, function()
                    scroll_preview(1)
                end, kopts)
            end
            for _, lhs in ipairs(keylist(kcfg.preview_up)) do
                vim.keymap.set("t", lhs, function()
                    scroll_preview(-1)
                end, kopts)
            end
        end
    end

    local list_provider = {
        size = function()
            return math.max(30, math.floor(vim.o.columns * 0.36)), list_rows() + 1 -- the LIST: matches + fzf's prompt row
        end,
        update = function(pan)
            state.list_pan = pan
            start_fzf(pan)
        end,
        keys = function(_, pan, st)
            state.list_pan, state.st = pan, st
        end,
    }

    -- ── the preview provider (real Neovim window) ──
    local preview_provider = opts.preview
            and {
                size = function()
                    -- with a focus: file lines + winbar (floored so the winbar always paints — see preview_rows);
                    -- nothing focused: a SINGLE styled "nothing to preview" row
                    return math.max(40, math.floor(vim.o.columns * 0.5)), preview_rows()
                end,
                update = function(pan)
                    state.preview_pan = pan
                    apply_preview_opts(pan.win) -- render_preview re-asserts these after the ft too
                    render_preview(pan, state.cur_item)
                end,
                keys = function(_, pan)
                    state.preview_pan = pan
                end,
            }
        or nil

    -- ── layout (mirror the tint picker's surface wiring) ──
    local bottom = opts.layout == "bottom"
    local area = opts.layout == "area"

    -- BOTH data panels — the LIST and the PREVIEW — carry the single-source content ring (`surface.CONTENT_BORDER`,
    -- resolved live to `ui_config.content_border`), matching the tint backend so the two look identical. The fzf
    -- TUI terminal renders INSIDE the list's ring — its own info line is hidden (--info=hidden), so the surface
    -- ring is the only frame around it. The search / footer bands are bars, not blocks, so they stay borderless.
    local pbord = surface.CONTENT_BORDER
    local list_block = {
        id = "list",
        provider = list_provider,
        border = pbord,
        size = { width = { fixed = 0.4 } },
        -- PREVIEW PRIORITY: in a stacked (above/below) area that can't hold both within the area height cap, the
        -- LIST gives up rows first (scrolls to the selection) so the preview keeps its content-fit height.
        shrink_first = true,
    }
    local preview_block = preview_provider and { id = "preview", provider = preview_provider, border = pbord }
    local blocks = preview_block and { list_block, preview_block } or { list_block }

    -- SLOT geometry (float/area/bottom width + height) comes from the CENTRAL authority
    -- (lvim-utils.config.dock.geometry → dock.slot): the surface derives it when we pass NO `size`. `max_rows`
    -- still caps the list content INSIDE the slot. FORCE — the effective per-layout anchored override: a per-call
    -- `opts.force[layout]` wins, else the plugin's own `config.dock.force[layout]` (empty {} = inherit). Deep-copied so
    -- the `opts.height` rows-override (an EXPLICIT per-call size) can win on top; its `backdrop` goes to the
    -- surface `backdrop` seam below. area/bottom ignore width (full-width), so a forced width there is a no-op.
    local eff_force = (opts.force and opts.force[opts.layout])
        or ((config or {}).dock and config.dock.force and config.dock.force[opts.layout])
    local slot_override = eff_force and vim.deepcopy(eff_force) or {}
    if opts.height then
        slot_override.height, slot_override.height_auto = opts.height, false
    end
    if not next(slot_override) then
        slot_override = nil
    end

    -- footer — MODE-AWARE + grouped, generated from the CONFIGURED keys (never hardcoded), so it always shows
    -- the keys that actually act in the CURRENT mode: NORMAL (plain v/x, j/k, q) vs INSERT (the Ctrl chords).
    -- Groups: open-methods · list-actions (+ preview/park/per-call) · core frame-nav (by id, from the chassis).
    -- A `●` (config.footer_separator, `LvimUiFooterSep`) divides non-empty groups. Re-rendered on every
    -- mode switch via `set_footer` (see `to_insert` / `<Esc>`).
    local function klabel(v)
        return (keylist(v)[1] or ""):gsub("[<>]", "")
    end
    local sep_glyph = (config or {}).footer_separator or "●"
    local navlist = keylist(kcfg.nav)
    local move_i = ((navlist[1] or "<C-j>"):gsub("[<>]", "")) .. "/" .. ((navlist[2] or "<C-k>"):gsub("[<>]", ""))
    -- The picker's OWN action registry: id → per-mode key LABELS + name. `key` = the same label in BOTH modes;
    -- `n`/`i` = mode-specific. Labels track `config.keys`, so the footer never drifts from the real
    -- bindings. CORE ids (sectors / preview / panel / select) are NOT here — they resolve via
    -- `surface.core_footer_item`. A per-call row action (`opts.keys`) registers under its own `name`.
    local REG = {
        open = { key = klabel(kcfg.accept), name = "open" },
        move = { n = "j/k", i = move_i, name = "move" },
        mark = { key = klabel(kcfg.mark), name = "mark" },
        qf = { key = klabel(kcfg.quickfix), name = "qf" },
        close = { n = klabel(kcfg.abort) .. "/q", i = klabel(kcfg.abort), name = "close" },
    }
    -- open-method entries only when the method is a real `{ n, i }` table (a user may disable one by
    -- overriding it to false / a string) — indexing `om.vsplit.n` unconditionally crashed on such overrides,
    -- exactly the guard the binding loop above already applies.
    for _, m in ipairs({ "vsplit", "hsplit" }) do
        local sp = om[m]
        if type(sp) == "table" then
            REG[m] = { n = klabel(sp.n), i = klabel(sp.i), name = m }
        end
    end
    if opts.preview then
        REG.preview = { key = klabel(kcfg.preview_down) .. "/u", name = "preview" }
    end
    if park_key ~= "" then
        REG.buffer = { key = klabel(kcfg.park), name = "buffer" }
    end
    for _, action in ipairs(opts.keys or {}) do
        if action.key and action.name then
            REG[action.name] = { key = (action.key):gsub("[<>]", ""), name = action.name }
        end
    end
    ---@param mode string  "n" (normal-on-list) | "i" (insert/terminal query)
    ---@return table  a `{ bars = { { items } } }` footer resolved from `config.footer[normal|insert]`
    footer_bands = function(mode)
        local spec = (config or {}).footer or {}
        local groups = (mode == "n" and spec.normal or spec.insert) or {}
        return { bars = { surface.bar(groups, REG, { mode = mode, separator = sep_glyph }) } }
    end

    -- (HOSTED area) A `position="cmdline"` finder homes in the msgarea zone via the surface engine's auto-host
    -- provider (no explicit host): the zone reserves rows above the messages, the surface follows the rect via
    -- its own state (preview_side → row count, reposition), the fzf list's WinEnter autocmd re-enters insert on
    -- descend, and the engine releases the reserve on close. The picker never references msgarea.
    surface.open({
        mode = "float",
        position = area and "cmdline" or (bottom and "bottom") or nil,
        on_escape_above = function()
            if opener and api.nvim_win_is_valid(opener) then
                api.nvim_set_current_win(opener)
            end
        end,
        zindex = (area and 200) or nil, -- the surface bumps a hosted area dock to 210 in its auto-host block
        header_air = false,
        title = title_box, -- the chassis native centered border-title
        title_line = opts.title_line, -- title placement: "row" (default) | "statusline" (chassis overlay) | "border" (opt-in)
        title_pos = opts.title_pos or config.title_pos, -- alignment — ONE config value for every layout
        count = count_fn, -- the live fzf match / total count → the chassis border counter (default footer)
        counter = opts.counter, -- count placement: "footer" (default) | "title"
        -- The container border is CONFIG-DRIVEN on EVERY layout (float + docked) — `surface.FRAME_BORDER`
        -- resolves LIVE to `ui_config.border`; NO hardcoded per-layout border. Each content block carries its
        -- own CONTENT_BORDER ring; the chassis draws the configurable inter-panel divider (`ui_config.separator`)
        -- BETWEEN the list and preview — auto-oriented, only at the gap, so a SINGLE panel shows none.
        border = surface.FRAME_BORDER,
        -- No `size`: the surface derives the slot from the central geometry (dock.slot) when none is passed.
        -- `slot` is the optional per-open anchored override (force + a rows `opts.height` for a docked layout).
        slot = slot_override,
        -- FORCE backdrop: the surface's own backdrop seam (merged over the central geometry backdrop in dock.slot).
        -- nil = inherit the central default; a `force[layout].backdrop` table/false wins here.
        backdrop = eff_force and eff_force.backdrop,
        -- so the surface can rotate the preview (C-n/C-p) — the POSITION rotates; the total slot height is
        -- central now, no longer per-preview-orientation.
        preview_side = preview_provider and (opts.preview_side or "right") or nil,
        -- No CONTENT title row — the title + counter are the chassis border-title / border-counter now; the
        -- fzf terminal panel IS the prompt, so there are no header bands.
        content = { blocks = blocks },
        footer = footer_bands("i"), -- the finder OPENS in insert (fzf query); mode switches re-render via set_footer
        close_keys = {},
        on_close = function()
            state.closed = true
            -- Dismissed externally (replaced by the next finder, or a surface-owned close) with no confirm /
            -- cancel / row action having run → treat it as a cancel so restore-on-cancel finders (colorschemes)
            -- are not silently skipped.
            if not state.handled and opts.on_cancel then
                pcall(opts.on_cancel)
            end
            clear_park_map() -- drop the transient return-map if the finder closed while parked
            if state.term_buf then -- drop the custom input caret registration (the cursor module restores normal)
                pcall(cursor.mark_cursor_buffer, state.term_buf, nil)
            end
            if state.term_augroup then
                pcall(api.nvim_del_augroup_by_id, state.term_augroup)
                state.term_augroup = nil
            end
            -- kill fzf if it is still running (the surface was closed some other way)
            if state.term_chan then
                pcall(vim.fn.jobstop, state.term_chan)
                state.term_chan = nil
            end
            if state.fifo then
                pcall(state.fifo.close)
                state.fifo = nil
            end
            if state.count_fifo then
                pcall(state.count_fifo.close)
                state.count_fifo = nil
            end
            if state.outfile then
                os.remove(state.outfile)
            end
            if state.contents_file then
                os.remove(state.contents_file)
            end
            pcall(function()
                require("lvim-hud.overlay").clear()
            end) -- idempotent: drop the chrome-overlay title/counter if `title_line="statusline"` published it
            -- (the surface engine releases its own auto-host msgarea reserve on close — nothing to do here)
            source.clear_active(active_entry)
            -- MANAGED: dock bookkeeping (mirrors the tint backend). A dock-driven teardown (a park via `hide` or
            -- a kill via `close`, flagged `state.dock_teardown`) is silent — it must NOT re-notify the dock. A
            -- self / external close (a confirm / cancel / `:q`) PARKS + REMEMBERS the entry (keeps its rebuild →
            -- stays cyclable / in the menu) and only collapses the layout so focus returns to the editor.
            if managed and opts.dock.on_close then
                pcall(opts.dock.on_close, state)
            end
        end,
    })

    source.set_active(active_entry)

    -- MANAGED: hand the live surface `state` to the dock manager (so the consumer's buffers / focus /
    -- is_current read it, and `hide` can park it). Done AFTER surface.open, so `state.st` + the panels (and the
    -- terminal buffer created by the list provider's `update`) are already wired onto `state`.
    if managed and opts.dock.on_open then
        pcall(opts.dock.on_open, state)
    end

    -- Focus the fzf list (terminal) through the chassis' own focus API, so it grabs focus the same way the
    -- tint picker's input band does; the WinEnter autocmd then enters terminal-mode. Scheduled so the surface
    -- has finished placing + focusing the panels first.
    vim.schedule(function()
        if state.closed then
            return
        end
        if state.st and state.st.focus_block then
            state.st.focus_block("list")
        elseif state.list_pan and state.list_pan.win and api.nvim_win_is_valid(state.list_pan.win) then
            api.nvim_set_current_win(state.list_pan.win)
        end
        if state.list_pan and state.list_pan.win and api.nvim_get_current_win() == state.list_pan.win then
            vim.cmd("startinsert")
        end
    end)
end

return M
