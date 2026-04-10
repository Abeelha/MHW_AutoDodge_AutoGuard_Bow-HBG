-- MHW_AutoDodge.lua
-- Auto Evade and Auto Guard for Bow and Heavy Bowgun in Monster Hunter Wilds.
-- Restored from confirmed-working version (session log line 930).
--
-- Only change from the confirmed working version:
--   Bow: beginDodgeNoHit(System.Boolean, false) instead of no-arg (which failed silently),
--        giving the pre-dodge state (Cat=2 Idx=9) that upgrades to perfect dodge (Cat=2 Idx=33).
--   HBG: UNCHANGED from working version — grantIframes + changeActionRequest(1, 146).

local CONFIG_PATH = "MHW_AutoDodge.json"
local BOW         = 11
local HBG         = 12
local COOLDOWN    = 0.3

local ACT = {
    HBG_PERFECT_GUARD = { cat = 1, idx = 146 },
    HBG_DODGE         = { cat = 1, idx = 14  },
    BOW_PERFECT_DODGE = { cat = 2, idx = 33  },
}

local character  = nil
local weaponType = -1
local lastHitAt  = 0

local dbg = { hookFired = 0, skipped = 0, cooldown = 0 }

local function defaultConfig()
    return {
        enabled      = true,
        evadeEnabled = true,
        evadeIframes = 0.5,
        guardEnabled = true,
        guardIframes  = 0.25,
        bypassChecks = true,   -- true by default: ptr comparison is unreliable
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

local function getBaseCtrl()
    return safe(function() return character:call("get_BaseActionController") end)
end

-- Queue an action on BaseActionController (changeActionRequest, same as working version).
local function triggerAction(cat, idx)
    local ctrl = getBaseCtrl()
    if not ctrl then return end
    local ok = pcall(function()
        local td = sdk.find_type_definition("ace.ACTION_ID")
        if not td then return end
        local aid = ValueType.new(td)
        aid._Category = cat
        aid._Index    = idx
        ctrl:call("changeActionRequest(ace.ACTION_ID)", aid)
    end)
    if not ok then
        pcall(function()
            ctrl:call("changeActionRequest(System.Int32,System.Int32)", cat, idx)
        end)
    end
end

-- HBG: iframes via startNoHitTimer (beginDodgeNoHit is for dodge, not guard).
local function grantIframesHBG(iframes)
    if not character then return end
    pcall(function() character:call("startNoHitTimer(System.Single)", iframes) end)
    pcall(function() character:call("startNoHitTimer", iframes) end)
end

-- Bow: beginDodgeNoHit(System.Boolean, false) triggers pre-dodge state (Cat=2 Idx=9),
-- then changeActionRequest(2, 33) upgrades it to perfect dodge.
-- startNoHitTimer provides iframes throughout.
local function grantIframesBow(iframes)
    if not character then return end
    local ok = pcall(function() character:call("beginDodgeNoHit(System.Boolean)", false) end)
    if not ok then pcall(function() character:call("beginDodgeNoHit(System.Single)", iframes) end) end
    if not ok then pcall(function() character:call("beginDodgeNoHit(System.Int32)", 0) end) end
    if not ok then pcall(function() character:call("beginDodgeNoHit(System.Boolean,System.Single)", false, iframes) end) end
    pcall(function() character:call("startNoHitTimer(System.Single)", iframes) end)
    pcall(function() character:call("startNoHitTimer", iframes) end)
end

-- Player update
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
    else
        character  = nil
        weaponType = -1
    end
end)

-- Hook
local hitMethod = sdk.find_type_definition('app.HunterCharacter') and
    sdk.find_type_definition('app.HunterCharacter'):get_method('evHit_Damage')

if hitMethod then
    sdk.hook(hitMethod,
        function(args)
            if not cfg.enabled then return end

            dbg.hookFired = dbg.hookFired + 1

            local now = os.clock()
            if (now - lastHitAt) < COOLDOWN then
                dbg.cooldown = dbg.cooldown + 1
                return
            end

            if not cfg.bypassChecks then
                if not character then return end

                local mine = false
                pcall(function() mine = sdk.to_managed_object(args[1]) == character end)
                if not mine then
                    pcall(function() mine = sdk.to_managed_object(args[2]) == character end)
                end
                if not mine then return end

                local enemy = false
                pcall(function()
                    local info = sdk.to_managed_object(args[2])
                    if not info then return end
                    local owner = info:get_AttackOwner()
                    if not owner then return end
                    local name = owner:get_name()
                    if not name then return end
                    enemy = name:find("Em") ~= nil or name:find("Gm") ~= nil
                end)
                if not enemy then
                    pcall(function()
                        local info = sdk.to_managed_object(args[3])
                        if not info then return end
                        local owner = info:get_AttackOwner()
                        if not owner then return end
                        local name = owner:get_name()
                        if not name then return end
                        enemy = name:find("Em") ~= nil or name:find("Gm") ~= nil
                    end)
                end
                if not enemy then return end
            end

            lastHitAt = now
            dbg.skipped = dbg.skipped + 1

            log.info(string.format('[AD] HIT #%d  wt=%d  bypass=%s',
                dbg.skipped, weaponType, tostring(cfg.bypassChecks)))

            if cfg.guardEnabled and weaponType == HBG then
                grantIframesHBG(cfg.guardIframes)
                triggerAction(ACT.HBG_PERFECT_GUARD.cat, ACT.HBG_PERFECT_GUARD.idx)
                log.info('[AD] HBG guard triggered')
            elseif cfg.evadeEnabled and (weaponType == BOW or weaponType == HBG) then
                grantIframesBow(cfg.evadeIframes)
                triggerAction(ACT.BOW_PERFECT_DODGE.cat, ACT.BOW_PERFECT_DODGE.idx)
                log.info('[AD] bow perfect dodge triggered')
            else
                log.info('[AD] weapon inactive (' .. tostring(weaponType) .. ')')
            end

            -- Unconditional — block damage regardless of draw state
            return sdk.PreHookResult.SKIP_ORIGINAL
        end,
        function(retval) return retval end
    )
    log.info('[MHW_AutoDodge] hooked OK')
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

    imgui.text_colored('Debug', 0xFFFF8844)
    c, cfg.bypassChecks = imgui.checkbox('Bypass mine/enemy checks', cfg.bypassChecks)
    changed = changed or c
    imgui.text(string.format('Hook fired:  %d', dbg.hookFired))
    imgui.text(string.format('Triggered:   %d', dbg.skipped))
    imgui.text(string.format('Cooldown:    %d', dbg.cooldown))
    if imgui.button('Reset counters') then
        for k in pairs(dbg) do dbg[k] = 0 end
    end

    imgui.spacing()
    imgui.text_colored(
        string.format('Weapon: %d  (%s)', weaponType,
            weaponType == HBG and 'HBG' or weaponType == BOW and 'Bow' or 'other'),
        0xFFAAAAAA)

    imgui.spacing()
    if imgui.button('Reset to defaults') then cfg = defaultConfig(); saveConfig() end
    if changed then saveConfig() end

    imgui.end_window()
end)
