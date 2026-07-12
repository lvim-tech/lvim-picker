-- lvim-picker.health: `:checkhealth lvim-picker` — reports that the finders are loadable, their required
-- deps (lvim-ui toolkit, lvim-utils base, the lvim-fuzzy matching engine, the fzf binary for the TUI
-- backend) are present, and which optional integrations exist (lvim-hud for the statusline title overlay,
-- lvim-msgarea for the area dock).
--
---@module "lvim-picker.health"

local M = {}

local health = vim.health
local start = health.start
local ok = health.ok
local warn = health.warn
local err = health.error
local info = health.info

---@param mod string
---@return boolean
local function has(mod)
    return (pcall(require, mod))
end

function M.check()
    start("lvim-picker")

    if vim.fn.has("nvim-0.12") == 1 then
        ok("Neovim >= 0.12")
    else
        err("Neovim >= 0.12 required")
    end

    if has("lvim-utils.utils") then
        ok("lvim-utils (base) is available")
    else
        err("lvim-utils not found — lvim-picker requires it")
    end

    if has("lvim-ui.surface") then
        ok("lvim-ui toolkit is available")
    else
        err("lvim-ui not found — lvim-picker builds its finders on it")
    end

    -- The matching engine of the tint (Lua-list) backend: prepared-context ranking through lvim-fuzzy.
    if has("lvim-fuzzy") then
        local lf = require("lvim-fuzzy")
        ok(("lvim-fuzzy engine is available (backend: %s)"):format(lf.backend()))
        -- Incremental append (ABI 2) keeps typing cheap WHILE a stream feeds a huge tree: each growth
        -- appends only the new tail. An ABI-1 .so still works but re-prepares the whole pool per growth.
        if lf.native_loaded() and not lf.has_append() then
            warn(
                "lvim-fuzzy .so is ABI 1 (no incremental append) — a stream-fed pool re-prepares on growth; "
                    .. "rebuild it with `sh native/build.sh` for append support"
            )
        end
        -- Blob ingestion (ABI 5) is the fast streaming path for files / directories / git_files: raw stdout
        -- goes straight to the matcher, so a multi-million-file tree never builds a Lua string pool (no GC
        -- pauses). Without it those finders still work via the per-string streaming path (paced, a bit slower).
        if lf.native_loaded() then
            if lf.has_blob and lf.has_blob() then
                ok("lvim-fuzzy blob ingestion (ABI ≥ 5) — huge streamed trees load without a Lua candidate pool")
            else
                info(
                    "lvim-fuzzy .so predates blob ingestion (ABI < 5) — streamed finders use the per-string path; "
                        .. "rebuild it with `sh native/build.sh` for the zero-Lua-pool streaming path"
                )
            end
        end
    else
        err("lvim-fuzzy not found — lvim-picker ranks every finder through it (install lvim-tech/lvim-fuzzy)")
    end

    if has("lvim-picker") and has("lvim-picker.fuzzy") then
        ok("lvim-picker loaded (finders + fuzzy engine)")
    else
        err("lvim-picker modules failed to load")
    end

    -- The fzf TUI backend needs the fzf binary.
    if vim.fn.executable("fzf") == 1 then
        ok("fzf binary found (the TUI finder backend)")
    else
        warn("fzf not on PATH — the fzf-TUI finder backend is unavailable (the tint backend still works)")
    end

    -- Optional integrations.
    if has("lvim-utils.dock") then
        ok(
            "lvim-utils.dock present — each finder KIND is a dock-stack entry, BOTH backends (fzf-TUI + tint); "
                .. "natural close parks+remembers (cycle <Leader>n/p, kill <Leader>x, menu <Leader>m)"
        )
        -- Report the picker's own docking mode + any per-layout force overrides (a caller can still override
        -- either per call via opts.dock_stack / opts.force).
        local cfg = require("lvim-picker.config")
        if cfg.dock.dock_stack == false then
            info("config.dock.dock_stack = false — finders open geometry-only (standalone), NOT in the dock stack")
        else
            ok("config.dock.dock_stack = true — finders join the managed dock stack")
        end
        for _, lay in ipairs({ "float", "area", "bottom" }) do
            local f = (cfg.dock.force or {})[lay]
            if type(f) == "table" and next(f) then
                info(
                    ("config.dock.force.%s set — anchored geometry override over the central dock geometry"):format(
                        lay
                    )
                )
            end
        end
    else
        info(
            "lvim-utils.dock not available — finders fall back to the classic one-open-at-a-time replace-in-place (optional)"
        )
    end
    if has("lvim-hud.overlay") then
        ok("lvim-hud present — a finder title can publish to the statusline overlay")
    else
        info("lvim-hud not installed — statusline title overlay is disabled (optional)")
    end
    if has("lvim-msgarea") then
        ok("lvim-msgarea present — the `area` layout docks in the message zone")
    else
        info("lvim-msgarea not installed — the `area` layout grows cmdheight on its own (optional)")
    end
end

return M
