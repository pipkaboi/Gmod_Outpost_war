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
    mix         = "",    -- смесь NPC (рецепт): "класс,оружие,вес;..."; пусто = один тип выше
    mix_weight  = "1",   -- доля для следующей добавляемой строки
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
        mix         = self:GetClientInfo("mix"),
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

-- Значения по умолчанию всех настроек инструмента (для пресетов и кнопки "По умолчанию")
local ConVarsDefault = TOOL:BuildConVarList()

function TOOL.BuildCPanel(pnl)
    local L = OutpostWar.L
    pnl:Help("Outpost War v" .. (OutpostWar.VERSION or "?"))
    pnl:Help(L("tool_help"))

    -- Пресеты (рецепты аванпостов): стандартный список GMod с кнопками "+" (сохранить
    -- текущие настройки под именем) и "-" (удалить). Хранятся у игрока в
    -- garrysmod/settings/presets/outpost_tool.txt
    local presets = pnl:AddControl("ComboBox", {
        MenuButton = 1,
        Folder = "outpost_tool",
        Options = { ["#preset.default"] = ConVarsDefault },
        CVars = table.GetKeys(ConVarsDefault),
    })
    -- Пресет задаёт только те настройки, что в нём сохранены. В пресетах, сделанных до
    -- появления смеси, её нет — и смесь от прошлого пресета "прилипала" ко всем.
    -- Чего в пресете нет — берём по умолчанию (смесь пустая).
    if IsValid(presets) and presets.OnSelect then
        local orig = presets.OnSelect
        presets.OnSelect = function(self, index, value, data)
            if istable(data) then
                for cv, def in pairs(ConVarsDefault) do
                    if data[cv] == nil then RunConsoleCommand(cv, def) end
                end
            end
            return orig(self, index, value, data)
        end
    end
    pnl:ControlHelp(L("presets_help"))
    local reset = pnl:Button(L("reset_defaults"))
    reset.DoClick = function()
        for cv, val in pairs(ConVarsDefault) do RunConsoleCommand(cv, val) end
    end

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

    -- Пресет или "По умолчанию" меняют консольные переменные — списки NPC/оружия
    -- должны показать новый выбор (ползунки обновляются сами)
    local function SelectByData(box, val)
        for i, d in pairs(box.Data or {}) do
            if d == val then box:ChooseOptionID(i) return end
        end
    end
    cvars.AddChangeCallback("outpost_tool_npc", function(_, _, new)
        if not IsValid(npcBox) then return end
        SelectByData(npcBox, new)
        timer.Simple(0, function()   -- оружие могло смениться тем же пресетом
            if IsValid(wepBox) then FillWeapons(new) end
        end)
    end, "OutpostWar_NpcBox")
    cvars.AddChangeCallback("outpost_tool_weapon", function(_, _, new)
        if IsValid(wepBox) then SelectByData(wepBox, new) end
    end, "OutpostWar_WepBox")

    -- Смесь NPC: несколько строк "NPC + оружие + доля". Аванпост спавнит их вперемешку.
    -- Хранится в outpost_tool_mix и сохраняется в пресетах вместе с остальным.
    -- (до 8 строк: длина клиентской настройки ограничена движком)
    pnl:Help(L("mix_title"))
    pnl:NumSlider(L("mix_weight"), "outpost_tool_mix_weight", 1, 10, 0)
    local mixList = vgui.Create("DListView")
    mixList:SetTall(130)
    mixList:SetMultiSelect(false)
    mixList:AddColumn(L("npc_type"))
    mixList:AddColumn(L("weapon"))
    mixList:AddColumn(L("mix_share")):SetFixedWidth(50)
    pnl:AddItem(mixList)

    local function ReadMix()
        local t = {}
        for part in string.gmatch(GetConVarString("outpost_tool_mix"), "[^;]+") do
            local c, w, n = string.match(part, "^([^,]+),([^,]*),(%d+)$")
            if c then t[#t + 1] = { c, w, tonumber(n) } end
        end
        return t
    end
    local function WriteMix(t)
        local parts = {}
        for _, e in ipairs(t) do parts[#parts + 1] = e[1] .. "," .. e[2] .. "," .. e[3] end
        RunConsoleCommand("outpost_tool_mix", table.concat(parts, ";"))
    end
    local function NpcName(cls)
        local d = list.Get("NPC")[cls]
        return d and language.GetPhrase(d.Name or cls) or cls
    end
    local function RefreshMix()
        if not IsValid(mixList) then return end
        mixList:Clear()
        local t = ReadMix()
        local total = 0
        for _, e in ipairs(t) do total = total + e[3] end
        for i, e in ipairs(t) do
            local wname = e[2] == "default" and L("weapon_default") or e[2] == "none" and L("weapon_none") or e[2]
            local line = mixList:AddLine(NpcName(e[1]), wname, math.Round(e[3] / total * 100) .. "%")
            line.OW_Index = i
        end
    end
    RefreshMix()
    cvars.AddChangeCallback("outpost_tool_mix", function() timer.Simple(0, RefreshMix) end, "OutpostWar_MixList")

    -- двойной клик по строке — удалить её
    mixList.DoDoubleClick = function(_, _, line)
        local t = ReadMix()
        table.remove(t, line.OW_Index)
        WriteMix(t)
    end

    local add = pnl:Button(L("mix_add"))
    add.DoClick = function()
        local t = ReadMix()
        if #t >= 8 then return end
        t[#t + 1] = { GetConVarString("outpost_tool_npc"), GetConVarString("outpost_tool_weapon"),
            math.Clamp(math.floor(GetConVarNumber("outpost_tool_mix_weight")), 1, 10) }
        WriteMix(t)
    end
    local clear = pnl:Button(L("mix_clear"))
    clear.DoClick = function() RunConsoleCommand("outpost_tool_mix", "") end
    pnl:ControlHelp(L("mix_help"))

    pnl:NumSlider(L("max_npcs"), "outpost_tool_max_npcs", 1, 40, 0)
    pnl:NumSlider(L("squad_size"), "outpost_tool_squad_size", 1, 10, 0)
    pnl:NumSlider(L("garrison"), "outpost_tool_garrison", 0, 10, 0)
    pnl:NumSlider(L("spawn_delay"), "outpost_tool_spawn_delay", 2, 120, 0)
    pnl:NumSlider(L("radius"), "outpost_tool_radius", 100, 1000, 0)
    pnl:NumSlider(L("spawn_limit"), "outpost_tool_spawn_limit", 0, 200, 0)
    pnl:ControlHelp(L("spawn_limit_help"))

    pnl:Help(L("server_hint"))
end
