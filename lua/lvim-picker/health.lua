-- lvim-picker.health: `:checkhealth lvim-picker` — reports that the finders are loadable, their required
-- deps (lvim-ui toolkit, lvim-utils base, the fzf binary for the TUI backend) are present, and which optional
-- integrations exist (lvim-hud for the statusline title overlay, lvim-msgarea for the area dock).
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
