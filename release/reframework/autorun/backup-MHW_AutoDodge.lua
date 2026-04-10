-- MHW_AutoDodge.lua
-- Auto Perfect Dodge (Bow) and Auto Perfect Guard (HBG) for Monster Hunter Wilds.
-- Hooks evHit_Damage: cancels damage and triggers the correct animation.
--
-- Bow:  beginDodgeNoHit(bool) → pre-dodge state → changeActionImmediate(Cat=2 Idx=33)
-- HBG:  changeActionImmediate(Cat=1 Idx=141) guard → changeActionImmediate(Cat=1 Idx=146) perfect guard

local CONFIG_PATH = "MHW_AutoDodge.json"
local BOW         = 11
local HBG         = 12
local COOLDOWN    = 0.3

local ACT = {
    DRAW_WEAPON       = { cat = 1, idx = 3   },  -- weapon draw transition (confirmed in logs)
    HBG_GUARD         = { cat = 1, idx = 141 },  -- pre-state for perfect guard
    HBG_PERFECT_GUARD = { cat = 1, idx = 146 },
    BOW_PERFECT_DODGE = { cat = 2, idx = 33  },
}

local character     = nil
local weaponType    = -1
local baseActionCat = -1   -- current BASE action category; Cat=0 = weapon sheathed
local lastHitAt     = 0
local pendingGuard  = false -- HBG guard deferred: weapon was sheathed when hit
local pendingAt     = 0
local PENDING_TIMEOUT = 0.8

local function defaultConfig()
    return {
        enabled      = true,
        evadeEnabled = true,
        evadeIframes = 0.5,
        guardEnabled = true,
        guardIframes = 0.25,
        bypassChecks = false,
    }
end

local cfg = defaultConfig()

local function loadConfig()
    if not json then return end
    local f = json.load_file(CONFIG_PATH)
    if not f then return end
    for k in pairs(cfg) do
        if f[k] ~= nil then cfg[k] = f[k] end
    end
end

local function saveConfig()
    if json then json.dump_file(CONFIG_PATH, cfg) end
end

loadConfig()

local function safe(fn)
    local ok, v = pcall(fn)
    return ok and v or nil
end

local function sendActionRequest(ctrl, cat, idx)
    local function makeAID()
        local td = sdk.find_type_definition("ace.ACTION_ID")
        if not td then return nil end
        local aid = ValueType.new(td)
        aid._Category = cat
        aid._Index    = idx
        return aid
    end
    local ok = pcall(function()
        local aid = makeAID(); if not aid then error() end
        ctrl:call("changeActionImmediate(ace.ACTION_ID)", aid)
    end)
    if not ok then
        ok = pcall(function()
            local aid = makeAID(); if not aid then error() end
            ctrl:call("changeActionRequest(ace.ACTION_ID)", aid)
        end)
    end
    if not ok then
        pcall(function() ctrl:call("changeActionImmediate(System.Int32,System.Int32)", cat, idx) end)
        pcall(function() ctrl:call("changeActionRequest(System.Int32,System.Int32)", cat, idx) end)
    end
end

-- Bow: beginDodgeNoHit handles weapon state internally (works even when sheathed).
-- We immediately override to perfect dodge after it runs.
local function triggerPerfectDodge(iframes)
    if not character then return end
    local base = safe(function() return character:call("get_BaseActionController") end)
    local ok = pcall(function() character:call("beginDodgeNoHit(System.Boolean)", false) end)
    if not ok then ok = pcall(function() character:call("beginDodgeNoHit(System.Single)", iframes) end) end
    if not ok then ok = pcall(function() character:call("beginDodgeNoHit(System.Int32)", 0) end) end
    if not ok then pcall(function() character:call("beginDodgeNoHit(System.Boolean,System.Single)", false, iframes) end) end
    if base then sendActionRequest(base, ACT.BOW_PERFECT_DODGE.cat, ACT.BOW_PERFECT_DODGE.idx) end
    pcall(function() character:call("startNoHitTimer(System.Single)", iframes) end)
    pcall(function() character:call("startNoHitTimer", iframes) end)
end

-- HBG: guard pre-state (141) then perfect guard (146).
-- SHEATHED: draw weapon now, defer the guard to BeginRendering once Cat>=1.
-- DRAWN: fire guard immediately.
local function triggerPerfectGuard(iframes)
    if not character then return end
    local base = safe(function() return character:call("get_BaseActionController") end)
    if not base then return end
    if baseActionCat == 0 then
        -- Weapon is sheathed — draw it and defer guard to next frame(s)
        sendActionRequest(base, ACT.DRAW_WEAPON.cat, ACT.DRAW_WEAPON.idx)
        pendingGuard = true
        pendingAt    = os.clock()
    else
        -- Weapon already drawn or aiming — guard immediately
        sendActionRequest(base, ACT.HBG_GUARD.cat,         ACT.HBG_GUARD.idx)
        sendActionRequest(base, ACT.HBG_PERFECT_GUARD.cat, ACT.HBG_PERFECT_GUARD.idx)
    end
    pcall(function() character:call("startNoHitTimer(System.Single)", iframes) end)
    pcall(function() character:call("startNoHitTimer", iframes) end)
end

-- Player update — tracks character, weapon type, drawn state, and deferred guard.
re.on_pre_application_entry('BeginRendering', function()
    local ok, char = pcall(function()
        local pm = sdk.get_managed_singleton('app.PlayerManager')
        if not pm then return nil end
        local mp = pm:getMasterPlayer()
        if not mp then return nil end
        return mp:get_Character()
    end)
    if ok and char then
        character = char
        local wok, wt = pcall(function() return char:get_WeaponType() end)
        weaponType = wok and wt or -1
        -- Track whether weapon is drawn: Cat=0 means sheathed
        pcall(function()
            local base = char:call("get_BaseActionController")
            if base then
                local id = base:call("get_CurrentActionID")
                if id then baseActionCat = id:get_field("_Category") end
            end
        end)
    else
        character     = nil
        weaponType    = -1
        baseActionCat = -1
        pendingGuard  = false
    end

    -- Deferred HBG guard: weapon was sheathed on hit, wait for draw to complete
    if pendingGuard then
        if not character or (os.clock() - pendingAt) > PENDING_TIMEOUT then
            pendingGuard = false  -- timed out or lost character
        elseif baseActionCat >= 1 then
            -- Weapon is now drawn — fire the guard
            local base = safe(function() return character:call("get_BaseActionController") end)
            if base then
                sendActionRequest(base, ACT.HBG_GUARD.cat,         ACT.HBG_GUARD.idx)
                sendActionRequest(base, ACT.HBG_PERFECT_GUARD.cat, ACT.HBG_PERFECT_GUARD.idx)
            end
            pendingGuard = false
        else
            -- Still sheathed — keep sending draw until Cat flips
            local base = safe(function() return character:call("get_BaseActionController") end)
            if base then
                sendActionRequest(base, ACT.DRAW_WEAPON.cat, ACT.DRAW_WEAPON.idx)
            end
        end
    end
end)

-- Hook
local hitMethod = sdk.find_type_definition('app.HunterCharacter') and
    sdk.find_type_definition('app.HunterCharacter'):get_method('evHit_Damage')

if hitMethod then
    sdk.hook(hitMethod,
        function(args)
            if not cfg.enabled then return end
            if not character then return end

            local now = os.clock()
            if (now - lastHitAt) < COOLDOWN then return end

            if not cfg.bypassChecks then
                -- Verify hit is on our character (args[1] = this ptr)
                local mine = false
                pcall(function() mine = sdk.to_managed_object(args[1]) == character end)
                if not mine then
                    pcall(function() mine = sdk.to_managed_object(args[2]) == character end)
                end
                if not mine then return end

                -- Verify hit is from an enemy (Em* or Gm* name prefix)
                local enemy = false
                for _, argIdx in ipairs({2, 3}) do
                    if enemy then break end
                    pcall(function()
                        local info = sdk.to_managed_object(args[argIdx])
                        if not info then return end
                        local owner = info:get_AttackOwner()
                        if not owner then return end
                        local name = owner:get_name()
                        if name then enemy = name:find("Em") ~= nil or name:find("Gm") ~= nil end
                    end)
                end
                if not enemy then return end
            end

            lastHitAt = now

            if cfg.guardEnabled and weaponType == HBG then
                triggerPerfectGuard(cfg.guardIframes)
                return sdk.PreHookResult.SKIP_ORIGINAL
            elseif cfg.evadeEnabled and (weaponType == BOW or weaponType == HBG) then
                triggerPerfectDodge(cfg.evadeIframes)
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end,
        function(retval) return retval end
    )
else
    log.warn('[MHW_AutoDodge] evHit_Damage not found — mod inactive.')
end

-- UI
local showWindow = false

re.on_draw_ui(function()
    if imgui.button('Auto Evade / Guard') then
        showWindow = not showWindow
        saveConfig()
    end
    if not showWindow then return end

    showWindow = imgui.begin_window('MHW Auto Evade / Guard', showWindow, 0)

    local changed = false
    local c

    c, cfg.enabled = imgui.checkbox('Enabled', cfg.enabled)
    changed = changed or c

    imgui.spacing()
    imgui.separator()
    imgui.spacing()

    imgui.begin_disabled(not cfg.enabled)

    imgui.text('Auto Perfect Dodge  (Bow)')
    imgui.indent(16)
    c, cfg.evadeEnabled = imgui.checkbox('Active##evade', cfg.evadeEnabled)
    changed = changed or c
    imgui.begin_disabled(not cfg.evadeEnabled)
    c, cfg.evadeIframes = imgui.slider_float('IFrames (s)##evade', cfg.evadeIframes, 0.1, 2.0)
    changed = changed or c
    imgui.end_disabled()
    imgui.unindent(16)

    imgui.spacing()

    imgui.text('Auto Perfect Guard  (HBG)')
    imgui.indent(16)
    c, cfg.guardEnabled = imgui.checkbox('Active##guard', cfg.guardEnabled)
    changed = changed or c
    imgui.begin_disabled(not cfg.guardEnabled)
    c, cfg.guardIframes = imgui.slider_float('IFrames (s)##guard', cfg.guardIframes, 0.1, 2.0)
    changed = changed or c
    imgui.end_disabled()
    imgui.unindent(16)

    imgui.end_disabled()

    imgui.spacing()
    imgui.separator()
    imgui.spacing()

    c, cfg.bypassChecks = imgui.checkbox('Bypass mine/enemy checks (enable if not triggering)', cfg.bypassChecks)
    changed = changed or c

    imgui.spacing()
    local weaponName = weaponType == HBG and 'HBG' or weaponType == BOW and 'Bow' or 'other'
    local drawnStr   = baseActionCat == 0 and 'sheathed' or baseActionCat > 0 and 'drawn' or 'unknown'
    imgui.text_colored(
        string.format('Weapon: %d (%s)  |  %s  (Basecat=%d)', weaponType, weaponName, drawnStr, baseActionCat),
        0xFFAAAAAA)

    imgui.spacing()
    if imgui.button('Reset to defaults') then
        cfg = defaultConfig()
        saveConfig()
    end
    if changed then saveConfig() end

    imgui.end_window()
end)
