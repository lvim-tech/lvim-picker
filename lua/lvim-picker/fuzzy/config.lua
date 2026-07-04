-- lvim-picker.fuzzy.config: live config for the shared fuzzy engine — applies to EVERY consumer (the picker /
-- navigator and the native cmdline completion). setup() merges user opts in place; readers do
-- `require("lvim-picker.fuzzy.config")`.
--
---@module "lvim-picker.fuzzy.config"

return {
    -- Result ORDERING after the fuzzy match — HIGHLY configurable. `sort` is ANY of:
    --   * a STRING preset (one criterion), or
    --   * a LIST of criteria applied in PRIORITY order (the first decides; the rest break ties), or
    --   * a custom `function(a, b) -> boolean` comparator (each item: `.text`, `.is_dir`, `.ext`,
    --     `.rank` = 1 for the best fuzzy match).
    -- Built-in criteria:
    --   "score"       — best fuzzy-match score first (the engine's ranking)
    --   "dirs_first"  — directories (text ending "/") before files
    --   "files_first" — files before directories
    --   "ext"         — group by file extension (A→Z)
    --   "length"      — shorter text first
    --   "alpha"       — text A→Z
    -- The fuzzy rank is ALWAYS the final tiebreak, so the order is deterministic. Examples:
    --   "score"  ·  { "dirs_first", "score" }  ·  { "score", "dirs_first" }  ·  { "ext", "alpha" }
    sort = "score",

    -- Hard cap on how many ranked results are BUILT + handed back per query. fzf still searches the WHOLE
    -- candidate set (its stdin has everything) — this only limits how many of the top matches we materialise +
    -- render, so a broad / empty query over a huge tree (e.g. `~/`) stays instant instead of building hundreds
    -- of thousands of rows on every keystroke. Raise it for a deeper scrollable list.
    max_results = 1000,
}
