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

    -- FILENAME BIAS — how much the FILE NAME (the segment after the last "/") outweighs the directory path
    -- when ranking path candidates (files / directories). Fuzzy matching is a subsequence match against the
    -- WHOLE path, so a query like `vgit.lua` also matches every `.lua` file under a `…-git/` dir (the `git`
    -- comes from the directory, `.lua` from the extension). This biases the result toward the NAME instead:
    --   "boost"  — (DEFAULT) rows whose NAME matches the query rank ABOVE rows that only match via the path;
    --              the path-only matches still appear, below. A "name match" = every query term is a
    --              subsequence of the basename (tested on its own, so the name counts even when the engine
    --              aligned across the directory). Its highlight is redrawn on the name (not a path scatter).
    --   "strict" — ONLY rows whose NAME matches are kept; the directory path is used solely as a tiebreak.
    --   "off"    — no bias: whole-path fuzzy (exact fzf parity — matches spread across dir + extension show).
    -- Applies to the tint-list backend only (the fzf-TUI backend uses fzf's own matcher).
    filename_match = "boost",

    -- Hard cap on how many ranked results are BUILT + handed back per query. The lvim-fuzzy engine still
    -- searches the WHOLE candidate set — this only limits how many of the top matches we materialise +
    -- render, so a broad / empty query over a huge tree (e.g. `~/`) stays instant instead of building hundreds
    -- of thousands of rows on every keystroke. Raise it for a deeper scrollable list. (lvim-fuzzy applies its
    -- own `max_results` too — the effective cap is the smaller of the two, so raise both past 1000.)
    max_results = 1000,
}
