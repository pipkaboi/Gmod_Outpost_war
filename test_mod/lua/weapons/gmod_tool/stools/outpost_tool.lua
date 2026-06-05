-- lua/weapons/gmod_tool/stools/outpost_tool.lua

TOOL.Category = "NPC Control"
TOOL.Name = "Outpost Creator"
TOOL.Command = nil

if CLIENT then
    language.Add("tool.outpost_tool.name", "Аванпост")
    language.Add("tool.outpost_tool.desc", "Создает аванпост, который спавнит NPC")
    language.Add("tool.outpost_tool.0", "ЛКМ: создать аванпост, ПКМ: удалить")
    
    function TOOL.BuildCPanel(pnl)
        -- Поле для ввода номера команды
        local teNum = vgui.Create("DNumberWang", pnl)
        teNum:SetMinMax(1, 100)
        teNum:SetValue(1)
        teNum:SetLabelText("Номер команды")
        teNum:SetConVar("outpost_team")
        pnl:AddPanel(teNum)
        
        -- Поле для максимального количества NPC
        local maxNPCs = vgui.Create("DNumberWang", pnl)
        maxNPCs:SetMinMax(1, 20)
        maxNPCs:SetValue(5)
        maxNPCs:SetLabelText("Макс. NPC")
        maxNPCs:SetConVar("outpost_max_npcs")
        pnl:AddPanel(maxNPCs)
        
        -- Задержка спавна
        local spawnDelay = vgui.Create("DNumberWang", pnl)
        spawnDelay:SetMinMax(1, 60)
        spawnDelay:SetValue(10)
        spawnDelay:SetLabelText("Задержка спавна (сек)")
        spawnDelay:SetConVar("outpost_spawn_delay")
        pnl:AddPanel(spawnDelay)
        
        -- Максимальное HP
        local maxHealth = vgui.Create("DNumberWang", pnl)
        maxHealth:SetMinMax(50, 500)
        maxHealth:SetValue(100)
        maxHealth:SetLabelText("Макс. HP")
        maxHealth:SetConVar("outpost_max_health")
        pnl:AddPanel(maxHealth)
        
        -- Тип NPC
        pnl:AddControl("ComboBox", {
            Label = "Тип NPC",
            Options = {
                ["Метрополицейский"] = { outpost_npc_class = "npc_metropolice" },
                ["Комбайн"] = { outpost_npc_class = "npc_combine_s" },
                ["Зомби"] = { outpost_npc_class = "npc_zombie" },
                ["Повстанец"] = { outpost_npc_class = "npc_rebel" }
            }
        })
    end
end

function TOOL:LeftClick(tr)
    if CLIENT then return true end
    
    if not tr.Hit then 
        return false 
    end
    
    local pos = tr.HitPos
    local owner = self:GetOwner()
    
    local outpost = ents.Create("sent_outpost")
    if not outpost then 
        return false 
    end
    
    outpost:SetPos(pos)
    outpost.Team = self:GetClientNumber("outpost_team") or 1
    outpost.MaxNPCs = self:GetClientNumber("outpost_max_npcs") or 5
    outpost.SpawnDelay = self:GetClientNumber("outpost_spawn_delay") or 10
    outpost.MaxHealth = self:GetClientNumber("outpost_max_health") or 100
    outpost.Health = outpost.MaxHealth
    outpost.Owner = owner
    outpost:Spawn()
    outpost:Activate()
    
    undo.Create("Outpost")
        undo.AddEntity(outpost)
        undo.SetPlayer(owner)
    undo.Finish()
    
    return true
end

function TOOL:RightClick(tr)
    if CLIENT then return true end
    
    if not tr.Entity or not tr.Entity:IsValid() then
        return false
    end
    
    if tr.Entity:GetClass() == "sent_outpost" then
        tr.Entity:Remove()
        return true
    end
    
    return false
end