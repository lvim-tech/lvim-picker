-- lvim-picker.fuzzy: shared fuzzy MATCHING engine: rank a list of strings against a query. The engine is the native `fzf`
-- binary in `--filter` mode (no TUI) — candidates go in on stdin, fzf returns them matched + ranked by its
-- score; without fzf it falls back to a pure-Lua subsequence matcher. fzf's `--filter` does NOT emit match
-- positions, so they are computed locally (utils.match_indices) for highlighting. Used by the picker and by
-- the native cmdline-completion integration, so both share one engine/ranking.
--
---@module "lvim-picker.fuzzy"

local utils = require("lvim-utils.utils")
local config = require("lvim-picker.fuzzy.config")

local M = {}

-- ─── result ordering (config.sort) ──────────────────────────────────────
-- A composable sort applied AFTER the fuzzy ranking. Each criterion compares two items
-- `{ text, is_dir, ext, rank }` and returns a number (<0 = a first, 0 = equal). `sort` (in config)
-- is a single preset name, a LIST of names applied in priority order, or a custom boolean comparator. The
-- fuzzy `rank` is always the final tiebreak, so the order is total + deterministic.

---@type table<string, fun(a: table, b: table): integer>
local CRITERIA = {
    score = function(a, b)
        return a.rank - b.rank
    end,
    dirs_first = function(a, b)
        return (a.is_dir and 0 or 1) - (b.is_dir and 0 or 1)
    end,
    files_first = function(a, b)
        return (a.is_dir and 1 or 0) - (b.is_dir and 1 or 0)
    end,
    ext = function(a, b)
        return a.ext < b.ext and -1 or (a.ext > b.ext and 1 or 0)
    end,
    length = function(a, b)
        return #a.text - #b.text
    end,
    alpha = function(a, b)
        return a.text < b.text and -1 or (a.text > b.text and 1 or 0)
    end,
}

--- Build a `table.sort` boolean comparator from the `sort` spec (a name, a list of names, or a function).
---@param spec string|string[]|fun(a: table, b: table): boolean|nil
---@return fun(a: table, b: table): boolean
local function comparator(spec)
    if type(spec) == "function" then
        return spec
    end
    local names = type(spec) == "table" and spec or { spec or "score" }
    local fns = {}
    for _, n in ipairs(names) do
        if CRITERIA[n] then
            fns[#fns + 1] = CRITERIA[n]
        end
    end
    return function(a, b)
        for _, f in ipairs(fns) do
            local r = f(a, b)
            if r ~= 0 then
                return r < 0
            end
        end
        return a.rank < b.rank -- deterministic final tiebreak
    end
end

--- Reorder `ranked` (`{ idx, match? }`, in fuzzy order) per `config.sort`. Decorates each entry with
--- `text`/`is_dir`/`ext`/`rank` for the criteria, sorts, and returns the reordered list (idx/match kept).
---@param ranked { idx: integer, match?: integer[] }[]
---@param texts string[]
---@return { idx: integer, match?: integer[] }[]
local function apply_sort(ranked, texts)
    local spec = (config or {}).sort or "score"
    if spec == "score" then
        return ranked -- already in best-match order
    end
    local decorated = {}
    for rank, r in ipairs(ranked) do
        local t = texts[r.idx]
        decorated[rank] = {
            idx = r.idx,
            match = r.match,
            text = t,
            rank = rank,
            is_dir = t:sub(-1) == "/",
            ext = t:match("%.([%w_%-]+)/?$") or "",
        }
    end
    table.sort(decorated, comparator(spec))
    return decorated
end

---@type string?  cached fzf binary path ("" once probed-and-absent)
local fzf_bin

--- The fzf binary path, or nil when fzf is not installed.
---@return string?
local function fzf_path()
    if fzf_bin == nil then
        fzf_bin = vim.fn.exepath("fzf")
    end
    return (fzf_bin ~= "" and fzf_bin) or nil
end

--- Pure-Lua fallback: subsequence match + a simple score (earlier and tighter matches rank higher).
---@param texts string[]
---@param query string
---@return { idx: integer, match: integer[] }[]
local function lua_rank(texts, query)
    local scored = {}
    for i, t in ipairs(texts) do
        local m = utils.match_indices(query, t)
        if m then
            scored[#scored + 1] = { idx = i, match = m, score = m[1] * 1000 + (m[#m] - m[1]) }
        end
    end
    table.sort(scored, function(a, b)
        return a.score < b.score
    end)
    return scored
end

-- File-backed candidate cache. fzf reads its input from a TEMP FILE rather than us re-piping the whole
-- `idx\ttext` block (hundreds of MB at ~/ scale) on every keystroke — passing that from Lua was the real
-- per-query cost (`fzf --filter q < file` over 1.6M takes ~0.3s; piping the same via stdin took ~2.7s). The
-- file is written INCREMENTALLY: the picker extends the `texts` array in place as a stream feeds, so we only
-- APPEND the new candidates (keyed by the array reference + last-written length), and the open pre-warms it.
---@type { texts: string[], len: integer, path: string, fh: file*? }?
local _file_cache

--- Ensure a temp file holding `idx\ttext` for every candidate in `texts` exists and is up to date; return its
--- path. Same array reference + grown length ⇒ APPEND only the new tail (cheap); a new reference ⇒ a fresh
--- file (the previous one is removed). Lines are `idx\ttext` so fzf (matching field 2) can hand back indices.
---@param texts string[]
---@return string?
local function ensure_file(texts)
    if _file_cache and _file_cache.texts == texts then
        if _file_cache.len < #texts and _file_cache.fh then
            local buf = {}
            for i = _file_cache.len + 1, #texts do
                buf[#buf + 1] = i .. "\t" .. (texts[i]:gsub("[\t\n]", " "))
            end
            _file_cache.fh:write(table.concat(buf, "\n") .. "\n")
            _file_cache.fh:flush()
            _file_cache.len = #texts
        end
        return _file_cache.path
    end
    if _file_cache then
        if _file_cache.fh then
            pcall(function()
                _file_cache.fh:close()
            end)
        end
        os.remove(_file_cache.path)
    end
    local path = vim.fn.tempname()
    local fh = io.open(path, "w")
    if not fh then
        _file_cache = nil
        return nil
    end
    local buf = {}
    for i, t in ipairs(texts) do
        buf[#buf + 1] = i .. "\t" .. (t:gsub("[\t\n]", " "))
    end
    fh:write(table.concat(buf, "\n"))
    if #texts > 0 then
        fh:write("\n")
    end
    fh:flush()
    _file_cache = { texts = texts, len = #texts, path = path, fh = fh }
    return path
end

-- The in-flight fzf process; a newer query kills it so fast typing over a huge candidate set does not pile up
-- a stack of `fzf` scans (only the latest query matters — the picker drops stale results anyway).
local _running

--- Rank `texts` against `query`, async. `cb` receives a list of `{ idx, match? }` in ranked order — `idx`
--- is the 1-based index into `texts`, `match` the 0-based matched-char indices (for highlighting; absent on
--- an empty query). Empty query = all, source order, no match. fzf when present (async via vim.system),
--- else the Lua fallback (synchronous, but `cb` is still called the same way).
---@param texts string[]
---@param query string
---@param cb fun(ranked: { idx: integer, match?: integer[] }[])
function M.filter(texts, query, cb)
    -- Hard cap on materialised results (config.max_results): fzf still searches ALL candidates, but we
    -- only hand back the top `max`, so a broad / empty query over a huge tree never builds hundreds of
    -- thousands of rows on a keystroke (the per-keystroke freeze).
    local max = (config or {}).max_results or 1000
    -- Keep the candidate temp file warm (incrementally) on EVERY call — including the empty-query path used
    -- while a stream feeds — so a real query reads a READY file instead of paying to build it then.
    local path = ensure_file(texts)
    -- every path delivers through here so the config sort (dirs_first / ext / …) is applied uniformly
    local function deliver(ranked)
        cb(apply_sort(ranked, texts))
    end
    if query == "" then
        local out = {}
        for i = 1, math.min(#texts, max) do -- first `max` in source order (fzf is not involved on empty query)
            out[i] = { idx = i }
        end
        deliver(out)
        return
    end
    local bin = fzf_path()
    if not bin or type(vim.system) ~= "function" or not path then
        deliver(lua_rank(texts, query))
        return
    end
    if _running then
        pcall(function()
            _running:kill("sigterm")
        end)
    end
    -- `fzf --filter` reads the temp FILE (not a re-piped stdin — that was the per-query cost), capped to `max`
    -- via `head` so fzf stops at the top matches. The query is $1 (shell-safe, never interpolated); the path is
    -- shell-escaped. fzf matches field 2 (the text) of each `idx\ttext` line; we read the indices back.
    local cmd = ("fzf --filter \"$1\" --delimiter '\\t' --nth 2 < %s | head -n %d"):format(
        vim.fn.shellescape(path),
        max
    )
    _running = vim.system({ "sh", "-c", cmd, "sh", query }, { text = true }, function(res)
        vim.schedule(function()
            local out = {}
            for line in (res.stdout or ""):gmatch("[^\n]+") do
                local idx = tonumber(line:match("^(%d+)\t"))
                if idx and texts[idx] then
                    out[#out + 1] = { idx = idx, match = utils.match_indices(query, texts[idx]) }
                end
            end
            deliver(out)
        end)
    end)
end

--- Drop the candidate temp file + kill any in-flight fzf. A finder calls this on close so a large (~hundreds
--- of MB) candidate file does not linger until the next search replaces it.
function M.release()
    if _running then
        pcall(function()
            _running:kill("sigterm")
        end)
        _running = nil
    end
    if _file_cache then
        if _file_cache.fh then
            pcall(function()
                _file_cache.fh:close()
            end)
        end
        os.remove(_file_cache.path)
        _file_cache = nil
    end
end

return M
