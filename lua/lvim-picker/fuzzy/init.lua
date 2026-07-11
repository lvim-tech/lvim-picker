-- lvim-picker.fuzzy: shared fuzzy MATCHING engine: rank a list of strings against a query. The engine is
-- lvim-fuzzy — the shared native matcher of the lvim-tech set (in-process Rust FFI, with its own
-- byte-identical pure-Lua fallback when the .so is absent, so this module never branches on availability).
-- The candidate set is PREPARED once per pool (one packed upload, cached by array reference + length);
-- every keystroke is then a single match call that is O(matched), not O(candidates) — this replaced the
-- per-keystroke `fzf --filter` subprocess that re-scanned the whole set (76–790 ms at 200k–1.5M).
-- lvim-fuzzy returns indices + scores only, so match POSITIONS for highlighting are computed locally
-- (utils.match_indices) — but only for the top `max_results` rows actually returned, never the whole set.
-- Used by the picker and by the native cmdline-completion integration (lvim-msgarea), so both share one
-- engine/ranking.
--
---@module "lvim-picker.fuzzy"

local utils = require("lvim-utils.utils")
local config = require("lvim-picker.fuzzy.config")
local engine = require("lvim-fuzzy")

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

-- Single-slot cache of the PREPARED lvim-fuzzy context, keyed by the candidate array reference + its length
-- (the exact contract of the picker's `_texts_cache`: the query changes on every keystroke but the candidate
-- set does NOT, so the context is rebuilt only when the pool actually changes — appended by a stream feed
-- (same reference, grown length), replaced by a refresh, or narrowed by a filter (new reference)). Over a
-- stable pool a keystroke is therefore ONE match call against the ready context, never a re-upload.
-- NOTE: lvim-fuzzy has no incremental append yet, so a pool that GREW re-prepares over the whole array (one
-- packed upload — tens of ms at 1.5M) rather than feeding just the tail; the context is built lazily on the
-- first real query, so a stream that finishes before typing pays it exactly once.
---@type { texts: string[], len: integer, ctx: LvimFuzzyContext }?
local _ctx_cache

--- The prepared lvim-fuzzy context for `texts`, building (and caching) it when the pool is new or changed.
---@param texts string[]
---@return LvimFuzzyContext
local function ensure_ctx(texts)
    if _ctx_cache and _ctx_cache.texts == texts and _ctx_cache.len == #texts then
        return _ctx_cache.ctx
    end
    local ctx = engine.prepare(texts)
    _ctx_cache = { texts = texts, len = #texts, ctx = ctx }
    return ctx
end

--- Rank `texts` against `query`. `cb` receives a list of `{ idx, match? }` in ranked order — `idx` is the
--- 1-based index into `texts`, `match` the 0-based matched-char indices (for highlighting; absent on an
--- empty query). Empty query = the first `max_results` in source order, no match. The match itself is a
--- single in-process lvim-fuzzy call, so `cb` is invoked synchronously (the callback signature is kept for
--- the callers wired to the old async engine).
---@param texts string[]
---@param query string
---@param cb fun(ranked: { idx: integer, match?: integer[] }[])
function M.filter(texts, query, cb)
    -- Hard cap on materialised results (config.max_results): the engine still SEARCHES all candidates, but
    -- only the top `max` are handed back, so a broad / empty query over a huge tree never builds hundreds of
    -- thousands of rows on a keystroke. (lvim-fuzzy applies its own `max_results` too — the effective cap is
    -- the smaller of the two.)
    local max = (config or {}).max_results or 1000
    -- every path delivers through here so the config sort (dirs_first / ext / …) is applied uniformly
    local function deliver(ranked)
        cb(apply_sort(ranked, texts))
    end
    if query == "" then
        local out = {}
        for i = 1, math.min(#texts, max) do -- first `max` in source order (no matching on an empty query)
            out[i] = { idx = i }
        end
        deliver(out)
        return
    end
    local results = engine.match(query, ensure_ctx(texts))
    local out = {}
    for k = 1, math.min(#results, max) do
        local idx = results[k].index
        -- lvim-fuzzy emits index+score only; compute the highlight positions locally, for the returned
        -- top rows ONLY (~max_results — cheap), never over the whole candidate set.
        out[k] = { idx = idx, match = utils.match_indices(query, texts[idx]) }
    end
    deliver(out)
end

--- Drop the cached prepared context. A finder calls this on close so the packed candidate blob (large at
--- huge-tree scale) does not linger in this module until the next search replaces it.
function M.release()
    _ctx_cache = nil
end

return M
