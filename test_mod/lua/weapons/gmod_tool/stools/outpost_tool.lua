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
}

TOOL.Information = {
    { name = "left" },
    { name = "right" },
    { name = "reload" },
}

if CLIENT then
    language.Add("tool.outpost_tool.name", "Outpost Creator")
    language.Add("tool.outpost_tool.desc", "Аванпост спавнит отряды NPC, которые захватывают чужие аванпосты")
    language.Add("tool.outpost_tool.left", "Поставить аванпост")
    language.Add("tool.outpost_tool.right", "Удалить аванпост")
    language.Add("tool.outpost_tool.reload", "Применить текущие настройки к аванпосту")
    language.Add("Undone_Outpost", "Аванпост отменён")
end

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
    pnl:Help("Аванпост спавнит NPC волнами. Сначала заполняется гарнизон (охрана), "
        .. "остальные собираются в отряд и идут захватывать ближайший чужой аванпост. "
        .. "Команда 0 = нейтральный аванпост (никого не спавнит, его можно захватить).")

    pnl:NumSlider("Команда", "outpost_tool_team", 0, 10, 0)

    -- Выбор NPC из списка спавн-меню (включая NPC из других аддонов)
    local npcBox = pnl:ComboBox("Тип NPC")
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
    npcBox.OnSelect = function(_, _, _, key) RunConsoleCommand("outpost_tool_npc", key) end

    -- Оружие
    local wepBox = pnl:ComboBox("Оружие")
    local curWep = GetConVarString("outpost_tool_weapon")
    wepBox:AddChoice("По умолчанию для NPC", "default", curWep == "default")
    wepBox:AddChoice("Без оружия", "none", curWep == "none")
    for _, w in pairs(list.Get("NPCUsableWeapons")) do
        wepBox:AddChoice(language.GetPhrase(w.title or w.class), w.class, w.class == curWep)
    end
    wepBox.OnSelect = function(_, _, _, cls) RunConsoleCommand("outpost_tool_weapon", cls) end

    pnl:NumSlider("Макс. NPC с аванпоста", "outpost_tool_max_npcs", 1, 40, 0)
    pnl:NumSlider("Размер отряда (и волны)", "outpost_tool_squad_size", 1, 10, 0)
    pnl:NumSlider("Гарнизон (охрана)", "outpost_tool_garrison", 0, 10, 0)
    pnl:NumSlider("Пауза между волнами (сек)", "outpost_tool_spawn_delay", 2, 120, 0)
    pnl:NumSlider("Радиус зоны захвата", "outpost_tool_radius", 100, 1000, 0)

    pnl:Help("Серверные настройки: вкладка Outpost War → Settings → Server Settings.")
end
