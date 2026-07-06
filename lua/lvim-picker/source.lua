-- lvim-picker.source: the shared SOURCE layer for both finder backends.
-- Shared SOURCE layer for the finder: the LISTING commands (files / directories), the content PREVIEW
-- reader, and the async line STREAMER. Both picker backends use it so they list and ignore IDENTICALLY:
--   • the tint backend (picker/init.lua) — streams the lines into the Lua-rendered list;
--   • the fzf-TUI backend (picker/fzf.lua) — runs the same command as fzf's `FZF_DEFAULT_COMMAND`.
-- The engine and what it ignores are user-configurable via `config.source` (engine / exclude /
-- hidden / follow / respect_gitignore / file_types), so a project's fd / rg / fzf-lua setup is matched.
--
---@module "lvim-picker.source"

local config = require("lvim-picker.config")

local M = {}

-- ─── the single OPEN finder (shared across both backends) ─────────────────────
-- Opening ANY finder must first FULLY close the one already open — releasing its docked area — so the new
-- finder REPLACES it in place instead of stacking above it. The two backends (the tint picker/init.lua and
-- the fzf picker/fzf.lua) reserve DIFFERENT msgarea host segments, so neither closes the other on its own;
-- this one shared registry does. Each finder registers an `entry = { close = fn }` after it opens and clears
-- it on close; opening calls `close_active()` first.
---@type { close: fun() }?
M._active = nil

--- Close whatever finder is currently open (either backend), if any.
function M.close_active()
    local a = M._active
    M._active = nil
    if a and a.close then
        pcall(a.close)
    end
end

--- Register `entry` ({ close }) as the open finder.
---@param entry { close: fun() }
function M.set_active(entry)
    M._active = entry
end

--- Clear the registry if `entry` is still the open finder (called from a finder's own close).
---@param entry { close: fun() }
function M.clear_active(entry)
    if M._active == entry then
        M._active = nil
    end
end

--- The `guicursor` fragment for the finder INPUT caret, from `config.caret` ({ hl, shape }). `modes`
--- is the guicursor mode-list to apply it to — "t" for the fzf terminal input, "i-ci-ve" for the tint
--- finder's insert prompt. Shared so both backends build it identically.
---@param modes string
---@return string
function M.caret_fragment(modes)
    local caret = (config or {}).caret or {}
    return modes .. ":" .. (caret.shape or "ver25") .. "-" .. (caret.hl or "LvimUiPickerCursor")
end

--- True when `bin` is an executable on PATH.
---@param bin string
---@return boolean
function M.has(bin)
    return vim.fn.executable(bin) == 1
end

--- Build the LIST command (argv) for `kind` ("files" | "dirs") from `config.source` — the engine and
--- what it ignores are user-configurable (`engine` / `exclude` / `hidden` / `follow` / `respect_gitignore` /
--- `file_types`). `engine = "auto"` picks the first available (fd → fdfind → rg → find); `rg` can only list
--- files, so a `dirs` request with rg falls back to fd/find. `find` has no ignore-file support (it always
--- lists everything but the excluded paths).
---@param kind "files"|"dirs"
---@return string[]
function M.build_list_cmd(kind)
    local cfg = (config or {}).source or {}
    local hidden = cfg.hidden ~= false
    local follow = cfg.follow == true
    local no_ignore = cfg.respect_gitignore == false
    local exclude = cfg.exclude or {}
    local want = cfg.engine or "auto"
    local order = want == "auto" and { "fd", "fdfind", "rg", "find" } or { want }
    local eng
    for _, c in ipairs(order) do
        if M.has(c) then
            eng = c
            break
        end
    end
    eng = eng or "find"
    if kind == "dirs" and eng == "rg" then -- rg lists files only
        eng = (M.has("fd") and "fd") or (M.has("fdfind") and "fdfind") or "find"
    end

    if eng == "fd" or eng == "fdfind" then
        local argv = { eng, "--color", "never", "--strip-cwd-prefix" }
        if kind == "dirs" then
            argv[#argv + 1], argv[#argv + 2] = "--type", "d"
        else
            for _, t in ipairs(cfg.file_types or { "f" }) do
                argv[#argv + 1], argv[#argv + 2] = "--type", t
            end
        end
        if hidden then
            argv[#argv + 1] = "--hidden"
        end
        if follow then
            argv[#argv + 1] = "--follow"
        end
        if no_ignore then
            argv[#argv + 1] = "--no-ignore"
        end
        for _, x in ipairs(exclude) do
            argv[#argv + 1], argv[#argv + 2] = "--exclude", x
        end
        return argv
    elseif eng == "rg" then -- files only
        local argv = { "rg", "--color", "never", "--files" }
        if hidden then
            argv[#argv + 1] = "--hidden"
        end
        if follow then
            argv[#argv + 1] = "--follow"
        end
        if no_ignore then
            argv[#argv + 1] = "--no-ignore"
        end
        for _, x in ipairs(exclude) do
            argv[#argv + 1], argv[#argv + 2] = "-g", "!" .. x
        end
        return argv
    end
    -- find: no gitignore support, just exclude the named paths
    local argv = { "find", ".", "-type", kind == "dirs" and "d" or "f" }
    for _, x in ipairs(exclude) do
        argv[#argv + 1], argv[#argv + 2], argv[#argv + 3] = "-not", "-path", "*/" .. x .. "/*"
    end
    return argv
end

--- The command (argv) to LIST files under cwd, from config.source.
---@return string[]
function M.file_list_cmd()
    return M.build_list_cmd("files")
end

--- The command (argv) to LIST directories under cwd, from config.source.
---@return string[]
function M.dir_list_cmd()
    return M.build_list_cmd("dirs")
end

-- ─── fzf-lua-style coloured ft icons ─────────────────────────────────────────
-- Each listed path is prefixed with its devicon (glyph + REAL colour as a 24-bit ANSI escape) so the fzf list
-- shows coloured filetype icons (rendered via `--ansi`). Following fzf-lua: the ext/name → coloured-glyph
-- table is precomputed ONCE into a temp file and a tiny awk transformer prefixes it inside the shell pipe
-- (fast, no per-line Lua); `strip_icon` removes it when a selected line is parsed back.
---@type { map: string, default: string }|false|nil
local icon_state

-- awk: load the map (ext/name → coloured glyph), then prefix each path by its basename's name, else extension,
-- else the default. `%s` = shell-escaped MAP file and DEFAULT glyph.
local ICON_AWK = [=[awk -v MAP=%s -v DEF=%s ]=]
    .. [=['BEGIN{FS="\t";while((getline l<MAP)>0){split(l,a,FS);ic[a[1]]=a[2]}}]=]
    .. [=[{n=$0;sub(/.*\//,"",n);e=n;sub(/.*\./,"",e);i=ic[n];if(i=="")i=ic[e];if(i=="")i=DEF;print i" "$0}']=]

-- grep variant: the row is `file:lnum:col:text` (rg --color=always → ANSI codes embedded). Read the PATH from
-- an ANSI-stripped copy (before the first colon), look up its icon, then prefix the ORIGINAL coloured row.
local GREP_ICON_AWK = [=[awk -v MAP=%s -v DEF=%s ]=]
    .. [=['BEGIN{FS="\t";while((getline l<MAP)>0){split(l,a,FS);ic[a[1]]=a[2]}}]=]
    .. [=[{p=$0;gsub(/\033\[[0-9;]*m/,"",p);sub(/:.*/,"",p);n=p;sub(/.*\//,"",n);e=n;sub(/.*\./,"",e);]=]
    .. [=[i=ic[n];if(i=="")i=ic[e];if(i=="")i=DEF;print i" "$0}']=]

-- grep MULTILINE variant (fzf-lua "2-line" layout): per rg row emit a NUL-terminated TWO-line record so fzf
-- (>= 0.53, with `--read0`/`--print0`) renders the location on row 1 and the matched text indented on row 2.
-- The icon `i` is computed exactly as in GREP_ICON_AWK; the row is then split at the 3rd LITERAL colon — rg's
-- ANSI escapes use `;` (never `:`) as their separator, so the only colons up to the text are the path/lnum/col
-- delimiters. `h` = `path:lnum:col` (3rd colon dropped), `t` = the matched text; `printf … %c,0` ends the
-- record with a NUL byte. The body carries printf `%s`/`%c` literals, so it is kept OUT of a Lua format
-- string (the `awk -v MAP=… DEF=…` prefix is concatenated at the call site instead — see `grep_awk`).
-- The 3 colons are written out LITERALLY (not `([^:]*:){3}`): this awk is also spliced into an fzf
-- `reload(...)`, and fzf would expand `{3}` as a FIELD placeholder there, corrupting the program.
local GREP_ICON_AWK_ML_BODY = [=['BEGIN{FS="\t";while((getline l<MAP)>0){split(l,a,FS);ic[a[1]]=a[2]}}]=]
    .. [=[{p=$0;gsub(/\033\[[0-9;]*m/,"",p);sub(/:.*/,"",p);n=p;sub(/.*\//,"",n);e=n;sub(/.*\./,"",e);]=]
    .. [=[i=ic[n];if(i=="")i=ic[e];if(i=="")i=DEF;]=]
    .. [=[if(match($0,/^[^:]*:[^:]*:[^:]*:/)){h=substr($0,1,RLENGTH-1);t=substr($0,RLENGTH+1);]=]
    .. [=[printf "%s %s\n    %s%c",i,h,t,0}else{printf "%s %s%c",i,$0,0}}']=]

-- grep MULTILINE, icons OFF: the same 3rd-colon split + NUL-terminated 2-line record, with no leading devicon
-- (the awk is still REQUIRED under multiline — it inserts the `\n    ` and the NUL terminator `--read0` needs).
-- No MAP/DEF, so no `awk -v` prefix and no Lua format placeholders.
local GREP_AWK_ML = [=[awk '{if(match($0,/^[^:]*:[^:]*:[^:]*:/)){h=substr($0,1,RLENGTH-1);t=substr($0,RLENGTH+1);]=]
    .. [=[printf "%s\n    %s%c",h,t,0}else{printf "%s%c",$0,0}}']=]

--- Build (once) the icon lookup, or false when nvim-web-devicons is absent.
---@return { map: string, default: string }|false
local function icons()
    if icon_state ~= nil then
        return icon_state
    end
    local ok, dev = pcall(require, "nvim-web-devicons")
    if not ok then
        icon_state = false
        return icon_state
    end
    local function ansi(glyph, color)
        local r, g, b = (color or ""):match("^#(%x%x)(%x%x)(%x%x)$")
        if not r then
            return glyph
        end
        return ("\27[38;2;%d;%d;%dm%s\27[0m"):format(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16), glyph)
    end
    local lines = {}
    for key, def in pairs(dev.get_icons() or {}) do
        if def.icon then
            lines[#lines + 1] = key .. "\t" .. ansi(def.icon, def.color)
        end
    end
    local dglyph, dhl = dev.get_icon("", "", { default = true })
    local dfg = dhl and (vim.api.nvim_get_hl(0, { name = dhl, link = false }) or {}).fg
    local f = vim.fn.tempname()
    pcall(vim.fn.writefile, lines, f)
    icon_state = { map = f, default = ansi(dglyph or "", dfg and ("#%06x"):format(dfg) or nil) }
    return icon_state
end

--- Wrap a LIST argv so its output is piped through the awk icon transformer (each path → `<ansi-icon> path`).
--- Returns `{ "sh", "-c", "<argv> | awk …" }`, or the original argv when icons are off/unavailable.
---@param argv string[]
---@return string[]
function M.with_icons(argv)
    if (config or {}).show_icons == false then
        return argv
    end
    local ic = icons()
    if not ic then
        return argv
    end
    local parts = {}
    for _, a in ipairs(argv) do
        parts[#parts + 1] = vim.fn.shellescape(a)
    end
    local awk = ICON_AWK:format(vim.fn.shellescape(ic.map), vim.fn.shellescape(ic.default))
    return { "sh", "-c", table.concat(parts, " ") .. " | " .. awk }
end

--- Like `with_icons`, but a single (theme-blue) FOLDER glyph for every entry — the `directories` finder
--- (folders have no per-ft devicon). `strip_icon` recovers the path.
---@param argv string[]
---@return string[]
function M.with_dir_icon(argv)
    if (config or {}).show_icons == false then
        return argv
    end
    local glyph = (config.icons or {}).directory or ""
    if glyph == "" then
        return argv
    end
    local cok, c = pcall(require, "lvim-utils.colors")
    local r, g, b = (cok and type(c) == "table" and c.blue or ""):match("#(%x%x)(%x%x)(%x%x)")
    local icon = r and ("\27[38;2;%d;%d;%dm%s\27[0m"):format(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16), glyph)
        or glyph
    local parts = {}
    for _, a in ipairs(argv) do
        parts[#parts + 1] = vim.fn.shellescape(a)
    end
    return {
        "sh",
        "-c",
        table.concat(parts, " ") .. " | awk -v I=" .. vim.fn.shellescape(icon) .. " '{print I\" \"$0}'",
    }
end

--- Strip the leading coloured icon (and any ANSI) a `with_icons` line carries, recovering the raw entry.
--- A real path / grep row never starts with a PUA codepoint, so this is a clean no-op when icons are off
--- (and it must NOT greedily eat the first word — grep rows are `file:lnum:col:text` with spaces in the text).
---@param line string
---@return string
function M.strip_icon(line)
    line = line:gsub("\27%[[%d;]*m", "") -- ANSI colour codes (fzf already strips them; belt-and-braces)
    if vim.fn.strgetchar(line, 0) >= 0xE000 then -- a Nerd/PUA icon glyph leads → drop it + its separator space
        return (vim.fn.strcharpart(line, 1):gsub("^ ", ""))
    end
    return line
end

local lua_icon_cache = {}

--- The coloured ft icon (a 24-bit ANSI escape) + a trailing space for `name`, or "" when icons are
--- off/unavailable. For Lua-built lists (buffers / oldfiles) fed to the fzf backend, which renders the ANSI
--- via `--ansi`. (The shell `with_icons` awk does the same for streamed cmd output.)
---@param name string
---@return string
function M.file_icon(name)
    if (config or {}).show_icons == false then
        return ""
    end
    local ok, dev = pcall(require, "nvim-web-devicons")
    if not ok then
        return ""
    end
    local base = name:match("[^/]+$") or name
    local ext = base:match("%.([^.]+)$") or ""
    local key = ext ~= "" and ext or base
    if lua_icon_cache[key] ~= nil then
        return lua_icon_cache[key]
    end
    local glyph, hl = dev.get_icon(base, ext, { default = true })
    local fg = hl and (vim.api.nvim_get_hl(0, { name = hl, link = false }) or {}).fg
    local s = glyph or ""
    if fg and s ~= "" then
        s = ("\27[38;2;%d;%d;%dm%s\27[0m"):format(math.floor(fg / 65536) % 256, math.floor(fg / 256) % 256, fg % 256, s)
    end
    s = s ~= "" and (s .. " ") or ""
    lua_icon_cache[key] = s
    return s
end

--- The ft devicon glyph + its highlight-group NAME for `name` (e.g. `"", "DevIconLua"`), or nil when icons
--- are off / unavailable. For the TINT (lua-list) backend, which draws the glyph via an extmark coloured by the
--- (nvim-web-devicons-defined) DevIcon* group — no ANSI.
---@param name string
---@return string? glyph, string? hl
function M.devicon(name)
    if (config or {}).show_icons == false then
        return nil
    end
    local ok, dev = pcall(require, "nvim-web-devicons")
    if not ok then
        return nil
    end
    local base = name:match("[^/]+$") or name
    return dev.get_icon(base, base:match("%.([^.]+)$") or "", { default = true })
end

--- Build the ripgrep argv for a LIVE content search of `query`, sharing the file-source config so CONTENT
--- search matches what `files` LISTS (hidden / .gitignore / excluded dirs). `regex = false` (the default)
--- matches the query literally (`--fixed-strings`); `regex = true` treats it as a pattern.
---@param query string
---@param regex? boolean
---@return string[]
function M.grep_cmd(query, regex)
    local rg = { "rg", "--vimgrep", "--smart-case", "--color=never" }
    local src = (config or {}).source or {}
    if src.hidden ~= false then
        rg[#rg + 1] = "--hidden"
    end
    if src.follow == true then
        rg[#rg + 1] = "--follow"
    end
    if src.respect_gitignore == false then
        rg[#rg + 1] = "--no-ignore"
    end
    for _, x in ipairs(src.exclude or {}) do
        rg[#rg + 1] = "-g"
        rg[#rg + 1] = "!" .. x
    end
    if not regex then
        rg[#rg + 1] = "--fixed-strings"
    end
    rg[#rg + 1] = "--"
    rg[#rg + 1] = query
    return rg
end

-- Theme-matched rg `--colors` (truecolor `R,G,B`; rg's `0x` form is unsupported), read LIVE so the grep
-- colours track the colourscheme.
---@return string[]
local function rg_color_flags()
    local ok, c = pcall(require, "lvim-utils.colors")
    if not ok or type(c) ~= "table" then
        return {}
    end
    local function rgb(hex)
        local r, g, b = tostring(hex):match("#?(%x%x)(%x%x)(%x%x)$")
        return r and ("%d,%d,%d"):format(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)) or nil
    end
    local flags = {}
    local function add(kind, hex, bold)
        local v = rgb(hex)
        if v then
            flags[#flags + 1], flags[#flags + 2] = "--colors", ("%s:fg:%s"):format(kind, v)
            if bold then
                flags[#flags + 1], flags[#flags + 2] = "--colors", ("%s:style:bold"):format(kind)
            end
        end
    end
    add("match", c.orange, true) -- matched text: warm + bold
    add("path", c.blue) -- file path
    add("line", c.green) -- line number
    add("column", c.cyan) -- column number
    return flags
end

---@type integer? cached effective grep multiline level
local fzf_ml

--- The EFFECTIVE grep multiline level (0 = off): `config.grep_multiline` capped to what fzf supports —
--- the fzf-lua 2-row grep layout uses `--read0`/`--print0`/`--gap`, which need fzf >= 0.53, so on older fzf it
--- silently falls back to the 1-row grep. Probed (and cached) once.
---@return integer
function M.fzf_multiline()
    if fzf_ml ~= nil then
        return fzf_ml
    end
    local want = tonumber((config or {}).grep_multiline) or 0
    if want <= 0 then
        fzf_ml = 0
        return fzf_ml
    end
    local ok, ver = pcall(vim.fn.systemlist, { "fzf", "--version" })
    local maj, min = ((ok and ver[1]) or ""):match("(%d+)%.(%d+)")
    fzf_ml = (maj and tonumber(maj) * 100 + tonumber(min) >= 53) and want or 0
    return fzf_ml
end

-- Colour a grep argv for the fzf backend (--color=always + theme `--colors`; ONLY the fzf backend renders ANSI
-- — the tint backend keeps `grep_cmd` plain) and return the shell `rg` string + its icon-awk pipe (or nil).
-- Shared by the LIVE reload and the STATIC (cword / selection / prompt) greps.
---@param argv string[]
---@return string rg, string|nil awk
local function grep_shell(argv)
    for i, a in ipairs(argv) do
        if a == "--color=never" then
            argv[i] = "--color=always"
        end
    end
    local cflags = rg_color_flags() -- splice the theme colours right after `rg`
    for j = #cflags, 1, -1 do
        table.insert(argv, 2, cflags[j])
    end
    local parts = {}
    for _, a in ipairs(argv) do
        parts[#parts + 1] = vim.fn.shellescape(a)
    end
    local ic = (config or {}).show_icons ~= false and icons()
    local awk
    if M.fzf_multiline() > 0 then
        -- 2-row layout: the awk splits at the 3rd colon, inserts the `\n    `, and NUL-terminates each record
        -- (`--read0` needs it). With devicons we prepend the `awk -v MAP=… DEF=…` to the icon body; without,
        -- the no-icon multiline awk (still required — only it inserts the newline + NUL) is used as-is.
        awk = ic
                and (("awk -v MAP=%s -v DEF=%s "):format(vim.fn.shellescape(ic.map), vim.fn.shellescape(ic.default)) .. GREP_ICON_AWK_ML_BODY)
            or GREP_AWK_ML
    else
        awk = ic and GREP_ICON_AWK:format(vim.fn.shellescape(ic.map), vim.fn.shellescape(ic.default)) or nil
    end
    return table.concat(parts, " "), awk
end

--- The fzf live-grep reload shell string. `file` (optional) restricts the search to one path (grep_curbuf).
---@param regex? boolean
---@param file? string
---@return string
function M.grep_reload(regex, file)
    local argv = M.grep_cmd("", regex) -- flags + a trailing "" placeholder we drop
    argv[#argv] = nil -- remove the empty query
    local rg, awk = grep_shell(argv)
    local target = file and (" " .. vim.fn.shellescape(file)) or ""
    if awk then
        return ("[ -n {q} ] && %s {q}%s | %s || true"):format(rg, target, awk)
    end
    return ("[ -n {q} ] && %s {q}%s || true"):format(rg, target)
end

--- A STATIC colour+icon grep command (argv) for a FIXED query (cword / selection / prompt); fzf then fuzzy-
--- filters the matches rather than re-running rg per keystroke.
---@param query string
---@param regex? boolean
---@return string[]
function M.grep_static_cmd(query, regex)
    local rg, awk = grep_shell(M.grep_cmd(query, regex))
    return { "sh", "-c", awk and (rg .. " | " .. awk) or rg }
end

--- Read up to `n` lines of `path` for a preview, with a filetype guessed from the name.
---@param path string
---@param n? integer
---@return string[] lines, string filetype
function M.read_preview(path, n)
    local ft = vim.filetype.match({ filename = path }) or ""
    if vim.fn.filereadable(path) == 1 then
        return vim.fn.readfile(path, "", n or 500), ft
    end
    return { "[unreadable]" }, ""
end

--- Run an argv synchronously and return its stdout lines (empty on failure).
---@param argv string[]
---@return string[]
function M.run_lines(argv)
    local ok, res = pcall(vim.fn.systemlist, argv)
    if not ok or vim.v.shell_error ~= 0 then
        return type(res) == "table" and res or {}
    end
    return res or {}
end

--- Spawn `argv` and stream its stdout LINES asynchronously — `on_lines(lines)` is called (on the main loop)
--- for each batch of complete lines as they arrive, `on_done()` once at exit. NEVER blocks the editor (unlike
--- `run_lines`), so a huge tree (e.g. `~/`) lists incrementally instead of a multi-second freeze. Returns a
--- cancel function that kills the producer. Falls back to a one-shot sync read when `vim.system` is missing.
---@param argv string[]
---@param on_lines fun(lines: string[])
---@param on_done fun()
---@return fun() cancel
function M.spawn_stream(argv, on_lines, on_done)
    if type(vim.system) ~= "function" then
        local lines = M.run_lines(argv)
        vim.schedule(function()
            on_lines(lines)
            on_done()
        end)
        return function() end
    end
    local rest = "" -- partial trailing line carried between chunks
    local function emit(data, final)
        rest = rest .. data
        local lines, start = {}, 1
        while true do
            local nl = rest:find("\n", start, true)
            if not nl then
                break
            end
            lines[#lines + 1] = rest:sub(start, nl - 1)
            start = nl + 1
        end
        rest = rest:sub(start)
        if final and rest ~= "" then
            lines[#lines + 1] = rest
            rest = ""
        end
        if #lines > 0 then
            vim.schedule(function()
                on_lines(lines)
            end)
        end
    end
    local ok, sys = pcall(vim.system, argv, {
        text = true,
        stdout = function(err, data) -- libuv fast-event ctx; only string ops here, UI work is scheduled in emit
            if err or not data then
                return
            end
            emit(data, false)
        end,
    }, function()
        emit("", true) -- flush the final partial line, then signal done
        vim.schedule(on_done)
    end)
    if not ok then
        vim.schedule(on_done)
        return function() end
    end
    return function()
        pcall(function()
            sys:kill("sigterm")
        end)
    end
end

return M
