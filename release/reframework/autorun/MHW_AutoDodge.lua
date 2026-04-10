-- MHW_AutoDodge.lua
-- Auto Perfect Dodge (Bow) and Auto Perfect Guard (HBG) for Monster Hunter Wilds.
--
-- Mechanism:
--   Drawn  (Cat>=1): fire guard/dodge immediately via changeActionImmediate
--   Sheathed (Cat=0): send draw action (Cat=1 Idx=2), defer guard/dodge to
--                     BeginRendering once weapon is drawn (Cat>=1)
--
-- Action IDs (BaseActionController):
--   Cat=1 Idx=2    Draw from sheath
--   Cat=1 Idx=141  HBG Guard pre-state
--   Cat=1 Idx=146  HBG Perfect Guard
--   Cat=2 Idx=33   Bow Perfect Dodge  (pre: beginDodgeNoHit → Cat=2 Idx=9 → upgrade to 33)

local CONFIG_PATH = "MHW_AutoDodge.json"
local BOW         = 11
local HBG         = 12
local COOLDOWN    = 0.3

local character     = nil
local weaponType    = -1
local baseActionCat = 0    -- 0=sheathed, 1=drawn, 2=aiming
local lastHitAt     = 0

-- Deferred action: set when hit while sheathed, executed once weapon is drawn
local pending     = nil    -- "guard" | "dodge"
local pendingAt   = 0
local PENDING_MAX = 1.5    -- give up after 1.5s if weapon never draws

local dbg = { hookFired = 0, triggered = 0, cooldown = 0 }

local function defaultConfig()
    return {
        enabled      = true,
        evadeEnabled = true,
        evadeIframes = 0.5,
        guardEnabled = true,
        guardIframes = 0.25,
        bypassChecks = true,
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

local function sendAction(ctrl, cat, idx)
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
        pcall(function()
            local aid = makeAID(); if not aid then error() end
            ctrl:call("changeActionRequest(ace.ACTION_ID)", aid)
        end)
    end
end

-- Fire HBG perfect guard (requires weapon drawn, Cat>=1)
local function doGuard(ctrl)
    sendAction(ctrl, 1, 141)  -- guard pre-state
    sendAction(ctrl, 1, 146)  -- perfect guard
    pcall(function() character:call("startNoHitTimer(System.Single)", cfg.guardIframes) end)
    pcall(function() character:call("startNoHitTimer", cfg.guardIframes) end)
end

-- Fire Bow perfect dodge (requires weapon drawn, Cat>=1)
local function doDodge(ctrl)
    -- beginDodgeNoHit sets the pre-dodge state (Cat=2 Idx=9), then upgrade to perfect dodge
    local ok = pcall(function() character:call("beginDodgeNoHit(System.Boolean)", false) end)
    if not ok then pcall(function() character:call("beginDodgeNoHit(System.Single)", cfg.evadeIframes) end) end
    if not ok then pcall(function() character:call("beginDodgeNoHit(System.Int32)", 0) end) end
    sendAction(ctrl, 2, 33)  -- perfect dodge
    pcall(function() character:call("startNoHitTimer(System.Single)", cfg.evadeIframes) end)
    pcall(function() character:call("startNoHitTimer", cfg.evadeIframes) end)
end

-- Player update + deferred action processing
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
        pcall(function()
            local ctrl = char:call("get_BaseActionController")
            if ctrl then
                local id = ctrl:call("get_CurrentActionID")
                if id then baseActionCat = id:get_field("_Category") end
            end
        end)
    else
        character = nil; weaponType = -1; baseActionCat = 0; pending = nil
        return
    end

    -- Fire deferred guard/dodge once the weapon is drawn
    if pending then
        if baseActionCat >= 1 then
            local ctrl = safe(function() return character:call("get_BaseActionController") end)
            if ctrl then
                if pending == "guard" then
                    doGuard(ctrl)
                    log.info('[AD] deferred guard fired')
                else
                    doDodge(ctrl)
                    log.info('[AD] deferred dodge fired')
                end
            end
            pending = nil
        elseif (os.clock() - pendingAt) > PENDING_MAX then
            log.info('[AD] deferred action timed out (weapon never drawn)')
            pending = nil
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
                if not mine then pcall(function() mine = sdk.to_managed_object(args[2]) == character end) end
                if not mine then return end

                local enemy = false
                for _, i in ipairs({2, 3}) do
                    if enemy then break end
                    pcall(function()
                        local info = sdk.to_managed_object(args[i])
                        if not info then return end
                        local owner = info:get_AttackOwner()
                        if not owner then return end
                        local name = owner:get_name()
                        if name then enemy = name:find("Em") ~= nil or name:find("Gm") ~= nil end
                    end)
                end
                if not enemy then return end
            end

            -- Determine what to do
            local doingGuard = cfg.guardEnabled and weaponType == HBG
            local doingDodge = cfg.evadeEnabled and (weaponType == BOW or weaponType == HBG)
            if not doingGuard and not doingDodge then return end

            lastHitAt = now
            dbg.triggered = dbg.triggered + 1

            local ctrl = safe(function() return character:call("get_BaseActionController") end)

            log.info(string.format('[AD] HIT #%d  wt=%d  Cat=%d  guard=%s  dodge=%s',
                dbg.triggered, weaponType, baseActionCat,
                tostring(doingGuard), tostring(doingDodge)))

            if baseActionCat >= 1 then
                -- Weapon already drawn — fire immediately
                if ctrl then
                    if doingGuard then
                        doGuard(ctrl)
                        log.info('[AD] guard immediate')
                    else
                        doDodge(ctrl)
                        log.info('[AD] dodge immediate')
                    end
                end
            else
                -- Weapon sheathed — force draw, defer action to next frame
                if ctrl then
                    sendAction(ctrl, 1, 2)  -- draw from sheath (Cat=1 Idx=2)
                end
                pending   = doingGuard and "guard" or "dodge"
                pendingAt = now
                log.info('[AD] draw forced, pending=' .. pending)
            end

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
    imgui.text(string.format('Triggered:   %d', dbg.triggered))
    imgui.text(string.format('Cooldown:    %d', dbg.cooldown))
    imgui.text(string.format('Draw state:  Cat=%d  %s',
        baseActionCat, baseActionCat == 0 and '(sheathed)' or '(drawn)'))
    imgui.text(string.format('Pending:     %s', tostring(pending)))
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
