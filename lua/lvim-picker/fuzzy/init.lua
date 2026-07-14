-- lvim-picker.fuzzy: shared fuzzy MATCHING engine: rank a list of strings against a query. The engine is
-- lvim-fuzzy — the shared native matcher of the lvim-tech set (in-process Rust FFI, with its own
-- byte-identical pure-Lua fallback when the .so is absent, so this module never branches on availability).
-- The candidate set is PREPARED once per pool (one packed upload, cached by array reference + length) and
-- a stream-grown pool APPENDS only its new tail into the live context (incremental, O(new) — never a whole
-- re-prepare); every keystroke is then a single match call that is O(matched), not O(candidates) — this
-- replaced the per-keystroke `fzf --filter` subprocess that re-scanned the whole set (76–790 ms at 200k–1.5M).
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

--- Reorder `ranked` (in fuzzy order) per `config.sort`. Decorates each entry with `text`/`is_dir`/`ext`/`rank`
--- for the criteria, sorts, and returns the reordered list (the original fields are carried through). `text_of`
--- yields each entry's candidate text — from a shared `texts[r.idx]` array (the static path) or an inline
--- `r.text` (the blob path).
---@generic T : { idx: integer }
---@param ranked T[]
---@param text_of fun(r: T): string
---@return T[]
local function apply_sort(ranked, text_of)
    local spec = (config or {}).sort or "score"
    if spec == "score" then
        return ranked -- already in best-match order
    end
    local decorated = {}
    for rank, r in ipairs(ranked) do
        local t = text_of(r)
        r.text = t
        r.rank = rank
        r.is_dir = t:sub(-1) == "/"
        r.ext = t:match("%.([%w_%-]+)/?$") or ""
        decorated[rank] = r
    end
    table.sort(decorated, comparator(spec))
    return decorated
end

-- Single-slot cache of the PREPARED lvim-fuzzy context, keyed by the candidate array reference + its length
-- (the exact contract of the picker's `_texts_cache`: the query changes on every keystroke but the candidate
-- set does NOT, so the context is rebuilt only when the pool actually changes — appended by a stream feed
-- (same reference, grown length), replaced by a refresh, or narrowed by a filter (new reference)). Over a
-- stable pool a keystroke is therefore ONE match call against the ready context, never a re-upload. A pool
-- that GREW in place feeds ONLY the new tail into the live context (`engine.append`, ABI 2 — O(new), sub-ms
-- even at 1.5M) instead of re-preparing the whole set (~130–200 ms per growth there); the context is still
-- built lazily on the first real query, so a stream that finishes before typing pays one prepare, and typing
-- WHILE it feeds pays only appends. Append is byte-identical to a whole prepare (lvim-fuzzy guarantee).
---@type { texts: string[], len: integer, ctx: LvimFuzzyContext }?
local _ctx_cache

local uv = vim.uv or vim.loop

-- BOUNDED MARSHALING. Feeding a streamed pool (up to ~2M paths) into the native matcher is O(pool) Lua↔C
-- string work — a single whole prepare / large append blocks the UI for 50–80 ms at scale (measured). So we
-- never marshal the whole outstanding tail in one call: `ensure_ctx` moves at most `marshal_cap` candidates
-- per call (a ≈5–8 ms slice) and a background timer keeps feeding the rest in equal slices across event-loop
-- ticks until the native context catches up to the pool, then runs ONE final match of the last query so the
-- results reflect the full set. The match always runs against whatever is marshaled so far (which grows), so
-- results appear and refine progressively during the stream instead of the UI freezing.
---@type uv.uv_timer_t?
local _marshal_timer
---@type string?
local _last_query -- last non-empty query + its callback, replayed once when the background marshal catches up
---@type fun(ranked: { idx: integer, match?: integer[] }[])?
local _last_cb

--- Stop and release the background catch-up timer (if running).
local function stop_marshal()
    if _marshal_timer then
        _marshal_timer:stop()
        if not _marshal_timer:is_closing() then
            _marshal_timer:close()
        end
        _marshal_timer = nil
    end
end

--- Marshal ONE bounded slice of the outstanding tail (`c.len+1 .. min(pool, c.len+cap)`) into the live native
--- context via `engine.append`, advancing `c.len`. Returns true once the context has caught up to the pool.
---@param c { texts: string[], len: integer, ctx: LvimFuzzyContext }
---@return boolean caught_up
local function marshal_slice(c)
    local n = #c.texts
    local cap = (config or {}).marshal_cap or 32768
    local upto = math.min(n, c.len + cap)
    local tail = {}
    for i = c.len + 1, upto do
        tail[i - c.len] = c.texts[i]
    end
    engine.append(c.ctx, tail)
    c.len = upto
    return c.len >= n
end

--- Arm the background catch-up: keep marshaling bounded slices into the native context, across event-loop
--- ticks (so it never blocks), until it reaches the pool. While the pool is still GROWING it only APPENDS —
--- it never re-runs the query (matching during the stream is driven by the 500 ms stream-refresh, which lets
--- each match complete; a match kicked off on every momentary catch-up would supersede the in-flight one
--- forever, so nothing would ever settle). Only once the pool holds STEADY for a couple of ticks — i.e. the
--- stream has finished — does it replay the last query ONCE, over the now-complete context, for full-set
--- results. Idempotent: a marshal already in flight keeps running against the (still growing) pool.
---@param texts string[]
local function arm_marshal(texts)
    if _marshal_timer then
        return
    end
    local settled = 0 -- consecutive ticks the context has fully covered a pool that stopped growing
    local timer = uv.new_timer()
    _marshal_timer = timer
    timer:start(
        40,
        40,
        vim.schedule_wrap(function()
            -- A blocked main thread can queue several ticks of this timer that then drain together; once the
            -- timer has been stopped (or replaced by a fresh arm), ignore those stale queued callbacks so they
            -- do not each kick off a match.
            if _marshal_timer ~= timer then
                return
            end
            local c = _ctx_cache
            if not (c and c.texts == texts) then -- pool replaced / released → abandon this catch-up
                stop_marshal()
                return
            end
            if c.len < #texts then
                marshal_slice(c) -- still behind the stream → feed one bounded slice, do NOT match
                settled = 0
                return
            end
            settled = settled + 1
            if settled >= 2 then -- pool has held steady ⇒ stream finished → one final full-context match
                stop_marshal()
                if _last_query and _last_query ~= "" and _last_cb then
                    M.filter(texts, _last_query, _last_cb)
                end
            end
        end)
    )
end

--- The prepared lvim-fuzzy context for `texts`, building (and caching) it when the pool is new or changed,
--- and APPENDING only the new tail when the same pool grew in place (the stream-feed contract). Marshaling is
--- BOUNDED (see above): a huge pool is prepared/appended a slice at a time, the background timer feeding the
--- rest, so this never blocks — the returned context may cover only the pool's head until the marshal catches
--- up (a growing prefix, which is exactly what a live-streaming finder should search).
---@param texts string[]
---@return LvimFuzzyContext
local function ensure_ctx(texts)
    local n = #texts
    local c = _ctx_cache
    if c and c.texts == texts then
        if c.len >= n then
            return c.ctx
        end
        -- The pool GREW in place (stream feed — same array ref, larger length): extend the live context with
        -- a bounded slice of the new tail now, and let the background timer feed the rest. Gated on real
        -- incrementality: the native ABI-2 append, or the pure-Lua backend (which keeps no per-candidate
        -- state, so growing the list IS the append). An ABI-1 .so would only defer a whole re-upload into the
        -- next match call, so it re-prepares below instead.
        if engine.has_append() or not engine.native_loaded() then
            if not marshal_slice(c) then
                arm_marshal(texts) -- tail remains → catch up in the background
            end
            return c.ctx
        end
        -- shrank (a new pool reused the array — not the stream contract) or no incremental append → rebuild
    end
    -- New / replaced pool: prepare only the first `marshal_cap` now (bounded — a whole prepare over millions
    -- would block); the background timer appends the rest. The context OWNS its candidate list (`engine.append`
    -- grows it in place), while `texts` is the picker's pool cache that ALSO grows in place — hand the engine
    -- its own shallow copy, never the shared array (sharing it would make the engine-side append double-write
    -- the tail into the picker's pool).
    stop_marshal()
    local cap = (config or {}).marshal_cap or 32768
    local upto = math.min(n, cap)
    local owned = {}
    for i = 1, upto do
        owned[i] = texts[i]
    end
    local ctx = engine.prepare(owned)
    _ctx_cache = { texts = texts, len = upto, ctx = ctx }
    if upto < n then
        arm_marshal(texts)
    end
    return ctx
end

--- Split a query into its whitespace-separated TERMS (fzf's AND semantics). A query with no whitespace is one
--- term; trailing / repeated spaces collapse, so "ini " is still the single term "ini" (typing a space mid-word
--- must not blank the list).
---@param query string
---@return string[]
local function query_terms(query)
    local out = {}
    for t in tostring(query or ""):gmatch("%S+") do
        out[#out + 1] = t
    end
    return out
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
        cb(apply_sort(ranked, function(r)
            return texts[r.idx]
        end))
    end
    if #query_terms(query) == 0 then
        -- "" or only spaces — the same thing: the whole pool, unranked
        _last_query, _last_cb = nil, nil -- an empty query needs no full-pool replay when the marshal catches up
        local out = {}
        for i = 1, math.min(#texts, max) do -- first `max` in source order (no matching on an empty query)
            out[i] = { idx = i }
        end
        deliver(out)
        return
    end
    -- Remember this query so the background marshal can replay it once the native context reaches the full pool
    -- (see arm_marshal) — otherwise a query typed mid-stream would keep showing head-only results until the
    -- next keystroke. `cb` is the finder's gen-guarded refilter callback, so a stale replay is dropped safely.
    _last_query, _last_cb = query, cb
    -- ASYNC: the match is driven in slices across event-loop ticks (lvim-fuzzy's chunked ABI-3 path), so a
    -- match over a HUGE pool never blocks typing — the editor redraws and handles input between slices, and a
    -- newer query SUPERSEDES an in-flight one engine-side. `cb` fires on a later tick (the finder's `refilter`
    -- is already gen-guarded, and the callers were wired for the original async engine). On an ABI < 3 / Lua
    -- backend it degrades to a scheduled synchronous match. Positions are computed for the returned top rows
    -- only (~max_results — cheap), never over the whole candidate set.
    -- WHITESPACE = AND (the fzf convention every picker user expects): "conf ui" means "matches `conf` AND
    -- matches `ui`", in any order — not the literal string "conf ui", which as a subsequence needs a real space
    -- in the path and therefore matched NOTHING (typing a space wiped the result list). The engine takes ONE
    -- needle, so the most SELECTIVE term (the longest) drives it and the rest AND-filter its rows here; the
    -- highlight is the union of every term's positions. Single-term queries take the plain path unchanged.
    local terms = query_terms(query)
    if #terms > 1 then
        local lead = terms[1]
        for _, t in ipairs(terms) do
            if #t > #lead then
                lead = t
            end
        end
        engine.match_async(lead, ensure_ctx(texts), function(results, cnt)
            local out = {}
            for k = 1, cnt do
                if #out >= max then
                    break
                end
                local idx = results[k].index
                local text = texts[idx]
                local hits, ok = {}, true
                for _, t in ipairs(terms) do
                    local m = utils.match_indices(t, text)
                    if not m then
                        ok = false
                        break
                    end
                    for _, ci in ipairs(m) do
                        hits[ci] = true
                    end
                end
                if ok then
                    local match = {}
                    for ci in pairs(hits) do
                        match[#match + 1] = ci
                    end
                    table.sort(match)
                    out[#out + 1] = { idx = idx, match = match }
                end
            end
            deliver(out)
        end)
        return
    end

    -- ONE term: the needle is the TERM, not the raw query — "ini " (a space typed mid-thought) must search for
    -- "ini", not for the literal "ini " (which no path contains, so the list went blank on the space).
    local needle = terms[1]
    engine.match_async(needle, ensure_ctx(texts), function(results, cnt)
        local out = {}
        for k = 1, math.min(cnt, max) do
            local idx = results[k].index
            out[k] = { idx = idx, match = utils.match_indices(needle, texts[idx]) }
        end
        deliver(out)
    end)
end

--- Drop the cached prepared context. A finder calls this on close so the packed candidate blob (large at
--- huge-tree scale) does not linger in this module until the next search replaces it — `engine.free` also
--- releases the NATIVE side eagerly (ABI 2), so ~60–100 MB of prepared context is reclaimed on close instead
--- of lingering until another search re-prepares.
function M.release()
    stop_marshal() -- cancel any background catch-up before the context it feeds is freed
    _last_query, _last_cb = nil, nil
    if _ctx_cache then
        engine.free(_ctx_cache.ctx)
        _ctx_cache = nil
    end
end

-- ─── blob-ingest streaming (GAP-5) ───────────────────────────────────────────
-- A streaming finder over a HUGE tree (millions of paths) hands the producer's raw stdout bytes straight to
-- the native matcher instead of materialising every path as a Lua string/table (which is what caused the
-- string-intern + GC pauses of a ~2M-candidate pool). The candidate POOL lives entirely native; only the
-- ranked top-K rows are ever materialised on the Lua side. These thin wrappers expose the engine's blob API
-- to the picker's `build()` and layer the config sort + result cap on top of the raw match — the blob analog
-- of `M.filter`. All gated on `M.has_blob()`; an older .so keeps the current per-string path.

--- Whether the native library supports blob ingestion (ABI ≥ 5). When false, the finders keep the per-string
--- streaming path.
---@return boolean
function M.has_blob()
    return engine.has_blob()
end

--- Create a blob-ingest context (nil when unavailable — the caller then uses the per-string path).
---@return LvimFuzzyBlob?
function M.blob_new()
    return engine.blob_new()
end

--- Ingest a raw stdout chunk into `blob`; returns the new candidate count.
---@param blob LvimFuzzyBlob
---@param data string
---@return integer
function M.blob_append(blob, data)
    return engine.blob_append(blob, data)
end

--- Flush the trailing partial line at end of stream; returns the candidate count.
---@param blob LvimFuzzyBlob
---@return integer
function M.blob_flush(blob)
    return engine.blob_flush(blob)
end

--- The current candidate count of `blob`.
---@param blob LvimFuzzyBlob
---@return integer
function M.blob_count(blob)
    return engine.blob_count(blob)
end

--- Free a blob context (native memory reclaimed).
---@param blob LvimFuzzyBlob?
function M.blob_free(blob)
    engine.blob_free(blob)
end

--- The matched-char indices of `text` for a (possibly multi-TERM) query — the union of every term's positions,
--- or nil when any term fails. The one place the picker's highlight and its filtering agree on what "matched"
--- means, so a space in the query lights up both words instead of nothing.
---@param query string
---@param text string
---@return integer[]|nil
function M.match_terms(query, text)
    local terms = query_terms(query)
    if #terms == 0 then
        return nil
    end
    if #terms == 1 then
        return utils.match_indices(terms[1], text)
    end
    local hits = {}
    for _, t in ipairs(terms) do
        local m = utils.match_indices(t, text)
        if not m then
            return nil
        end
        for _, ci in ipairs(m) do
            hits[ci] = true
        end
    end
    local out = {}
    for ci in pairs(hits) do
        out[#out + 1] = ci
    end
    table.sort(out)
    return out
end

--- Rank `blob` against `query` and hand the ranked results (`{ idx, text }`, `idx` = the 1-based NATIVE
--- candidate index, `text` materialised for rendering / sorting) to `cb`, plus `total` = the TRUE number of
--- candidates that matched (before the `max_results` cap; the whole pool for an empty query) so the finder can
--- show an accurate `matched/total` counter rather than the ≤`max_results` shown-row count. Applies
--- `config.max_results` and the config sort (dirs_first / ext / …). Match POSITIONS are NOT computed here — the
--- caller lights up the query chars for its VISIBLE rows only, so a broad query over a huge pool never builds
--- highlight spans for rows no one sees.
---@param blob LvimFuzzyBlob
---@param query string
---@param cb fun(list: { idx: integer, text: string }[], total: integer)
function M.blob_filter(blob, query, cb)
    local max = (config or {}).max_results or 1000
    -- Same AND semantics as the in-memory path (`M.filter`): whitespace separates TERMS. The blob matcher takes
    -- ONE needle, so the most selective term (the longest) drives the native match and the rest AND-filter its
    -- rows here. A single term is passed TRIMMED, so a trailing space cannot blank the list.
    local terms = query_terms(query)
    local needle = terms[1] or ""
    for _, t in ipairs(terms) do
        if #t > #needle then
            needle = t
        end
    end
    engine.blob_match(blob, needle, function(results, cnt, total)
        local ranked = {}
        for k = 1, cnt do
            if #ranked >= max then
                break
            end
            local idx = results[k].index
            local text = engine.blob_text(blob, idx) or ""
            local ok = true
            if #terms > 1 then
                for _, t in ipairs(terms) do
                    if not utils.match_indices(t, text) then
                        ok = false
                        break
                    end
                end
            end
            if ok then
                ranked[#ranked + 1] = { idx = idx, text = text }
            end
        end
        cb(
            apply_sort(ranked, function(r)
                return r.text
            end),
            (#terms > 1) and #ranked or (total or #ranked)
        )
    end)
end

return M
