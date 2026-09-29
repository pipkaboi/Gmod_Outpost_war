-- lua/weapons/gmod_tool/stools/outpost_tool.lua

TOOL.Tab = "Outpost War"          -- своя вкладка (создаётся в cl_outpost_effects.lua)
TOOL.Category = "Outposts"
TOOL.Name = "#tool.outpost_tool.name"

-- Настройки инструмента (консольные переменные outpost_tool_*)
TOOL.ClientConVar = {
    team        = "1",
    npc         = "npc_combine_s",
    weapon      = "default",
    max_npcs    = "10",
    spawn_delay = "15",
    squad_size  = "4",
    garrison    = "2",
    radius      = "300",
    spawn_limit = "0",
}

TOOL.Information = {
    { name = "left" },
    { name = "right" },
    { name = "reload" },
}

-- Тексты инструмента — в resource/localization/<язык>/outpost_war.properties

function TOOL:GetSettings()
    local npc = self:GetClientInfo("npc")
    if not list.Get("NPC")[npc] then npc = "npc_combine_s" end

    local wep = self:GetClientInfo("weapon")
    if wep ~= "default" and wep ~= "none" and not string.StartWith(wep, "weapon_") then
        wep = "default"
    end

    return {
        team        = self:GetClientNumber("team", 1),
        npc         = npc,
        weapon      = wep,
        max_npcs    = self:GetClientNumber("max_npcs", 10),
        spawn_delay = self:GetClientNumber("spawn_delay", 15),
        squad_size  = self:GetClientNumber("squad_size", 4),
        garrison    = self:GetClientNumber("garrison", 2),
        radius      = self:GetClientNumber("radius", 300),
        spawn_limit = self:GetClientNumber("spawn_limit", 0),
    }
end

function TOOL:LeftClick(tr)
    if not tr.Hit then return false end
    if CLIENT then return true end

    local ply = self:GetOwner()
    local outpost = ents.Create("sent_outpost")
    if not IsValid(outpost) then return false end

    outpost:SetPos(tr.HitPos)
    outpost:SetAngles(Angle(0, ply:EyeAngles().y, 0))
    outpost.OW_Settings = self:GetSettings()
    outpost.OW_Owner = ply
    outpost:Spawn()
    outpost:Activate()

    undo.Create("Outpost")
        undo.AddEntity(outpost)
        undo.SetPlayer(ply)
    undo.Finish()
    cleanup.Add(ply, "outposts", outpost)


    return true
end

function TOOL:RightClick(tr)
    local ent = tr.Entity
    if not IsValid(ent) or ent:GetClass() ~= "sent_outpost" then return false end
    if CLIENT then return true end
    ent:Remove()
    return true
end

function TOOL:Reload(tr)
    local ent = tr.Entity
    if not IsValid(ent) or ent:GetClass() ~= "sent_outpost" then return false end
    if CLIENT then return true end
    ent:ApplySettings(self:GetSettings())
    return true
end

function TOOL.BuildCPanel(pnl)
    local L = OutpostWar.L
    pnl:Help(L("tool_help"))

    pnl:NumSlider(L("team"), "outpost_tool_team", 0, 10, 0)

    -- Выбор NPC из списка спавн-меню (включая NPC из других аддонов)
    local npcBox = pnl:ComboBox(L("npc_type"))
    npcBox:SetSortItems(false)
    local current = GetConVarString("outpost_tool_npc")
    local npcs = {}
    for key, data in pairs(list.Get("NPC")) do
        local name = language.GetPhrase(data.Name or key)
        table.insert(npcs, { key = key, label = name .. "  [" .. (data.Category or "Other") .. "]" })
    end
    table.SortByMember(npcs, "label", true)
    for _, v in ipairs(npcs) do
        npcBox:AddChoice(v.label, v.key, v.key == current)
    end

    -- Оружие. Первый пункт показывает, чем NPC вооружён по умолчанию
    local wepBox = pnl:ComboBox(L("weapon"))
    wepBox:SetSortItems(false)

    local function WeaponTitle(cls)
        for _, w in pairs(list.Get("NPCUsableWeapons")) do
            if w.class == cls then return language.GetPhrase(w.title or cls) end
        end
        return cls
    end

    local function FillWeapons(npcKey)
        local curWep = GetConVarString("outpost_tool_weapon")
        wepBox:Clear()

        local data = list.Get("NPC")[npcKey]
        local def = L("weapon_default")
        if data and data.Weapons and #data.Weapons > 0 then
            local names = {}
            for _, cls in ipairs(data.Weapons) do table.insert(names, WeaponTitle(cls)) end
            def = def .. ": " .. table.concat(names, " / ")
        else
            def = L("weapon_default_own")
        end
        wepBox:AddChoice(def, "default", curWep == "default" or curWep == "")
        wepBox:AddChoice(L("weapon_none"), "none", curWep == "none")

        local weps = {}
        for _, w in pairs(list.Get("NPCUsableWeapons")) do
            table.insert(weps, { cls = w.class, label = language.GetPhrase(w.title or w.class) })
        end
        table.SortByMember(weps, "label", true)
        for _, w in ipairs(weps) do
            wepBox:AddChoice(w.label, w.cls, w.cls == curWep)
        end
    end
    FillWeapons(current)

    npcBox.OnSelect = function(_, _, _, key)
        RunConsoleCommand("outpost_tool_npc", key)
        FillWeapons(key)
    end
    wepBox.OnSelect = function(_, _, _, cls) RunConsoleCommand("outpost_tool_weapon", cls) end

    pnl:NumSlider(L("max_npcs"), "outpost_tool_max_npcs", 1, 40, 0)
    pnl:NumSlider(L("squad_size"), "outpost_tool_squad_size", 1, 10, 0)
    pnl:NumSlider(L("garrison"), "outpost_tool_garrison", 0, 10, 0)
    pnl:NumSlider(L("spawn_delay"), "outpost_tool_spawn_delay", 2, 120, 0)
    pnl:NumSlider(L("radius"), "outpost_tool_radius", 100, 1000, 0)
    pnl:NumSlider(L("spawn_limit"), "outpost_tool_spawn_limit", 0, 200, 0)
    pnl:ControlHelp(L("spawn_limit_help"))

    pnl:Help(L("server_hint"))
end
