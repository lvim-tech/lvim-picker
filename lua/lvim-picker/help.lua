-- lvim-picker.help: the finder's keymap CHEATSHEET — the rows both backends (the tint list and the fzf TUI)
-- share, built from the LIVE `config.keys` so a rebind is reflected and a disabled key ("" / {}) drops its
-- row. The window itself — the rows, the column alignment, the odd/even striping, the hidden cursor and the
-- colours — is the shared `lvim-ui.help` component's; nothing is themed or laid out here.
--
-- Every key it lists is a NORMAL-mode key (`<Esc>` off the query first): while you are typing, the query owns
-- the keyboard, so `g?` is a normal-mode chord like the picker's other plain keys (`v`, `x`, `q`).
--
---@module "lvim-picker.help"

local config = require("lvim-picker.config")

local M = {}

-- Key id (in `config.keys`) → description, in display order. An OPEN-METHOD row is keyed by its
-- `open_methods.<id>.n` (the normal-mode key of that method).
---@type { [1]: string, [2]: string, [3]: boolean? }[]
local HELP = {
    { "accept", "open the focused item" },
    { "vsplit", "open in a vertical split", true }, -- true = an open_methods entry (its `n` key)
    { "hsplit", "open in a horizontal split", true },
    { "mark", "toggle the row's mark (multi-select)" },
    { "quickfix", "send the marked rows to the quickfix list" },
    { "preview_down", "scroll the preview down" },
    { "preview_up", "scroll the preview up" },
    { "grep_filter", "live grep: toggle GREP ⇄ FILTER" },
    { "swap_backend", "swap the backend (list ⇄ fzf TUI)" },
    { "park", "park the finder (focus the editor, stay open)" },
    { "nav", "move the selection" },
    { "abort", "close the finder" },
}

--- A config key value (a single key or a LIST of keys) → the label shown in the cheatsheet; "" / {} (a
--- disabled action) → nil, so the row is dropped.
---@param v string|string[]|nil
---@return string?
local function label(v)
    if type(v) == "table" then
        local parts = {}
        for _, k in ipairs(v) do
            if type(k) == "string" and k ~= "" then
                parts[#parts + 1] = k
            end
        end
        return #parts > 0 and table.concat(parts, " / ") or nil
    end
    if type(v) == "string" and v ~= "" then
        return v
    end
    return nil
end

--- Open the finder's keymap cheatsheet (both backends). Only the LIVE, ENABLED keys appear.
---
--- `actions` are the CURRENT finder's per-call row actions (`opts.keys` — e.g. the LSP diagnostics list's
--- code-action / yank keys): they are as much a key of the open finder as the shared ones, so they get their
--- own rows (named after the action, which is also its footer chip's label). An unnamed action is skipped —
--- it has nothing to say in a sheet.
---@param actions? { key: string, name?: string }[]
function M.show(actions)
    local k = config.keys or {}
    local om = k.open_methods or {}
    local items = {}
    for _, e in ipairs(HELP) do
        local lhs = e[3] and (type(om[e[1]]) == "table" and om[e[1]].n or nil) or k[e[1]]
        local lbl = label(lhs)
        if lbl then
            items[#items + 1] = { lbl, e[2] }
        end
    end
    for _, a in ipairs(actions or {}) do
        local lbl = label(a.key)
        if lbl and a.name and a.name ~= "" then
            items[#items + 1] = { lbl, a.name .. " (this finder)" }
        end
    end
    local hl_key = label(k.help)
    if hl_key then
        items[#items + 1] = { hl_key, "this help" }
    end
    require("lvim-ui").help({
        title = "Picker keymaps",
        items = items,
        close_keys = { "q", "<Esc>", label(k.help) or "g?" },
    })
end

return M
