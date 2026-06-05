-- lua/entities/sent_outpost.lua
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Аванпост"
ENT.Category = "NPC Control"
ENT.Model = "models/props_c17/oildrum001_explosive.mdl"

-- Цвета для команд
local TeamColors = {
    [1] = Color(255, 50, 50),   -- красный
    [2] = Color(50, 50, 255),   -- синий
    [3] = Color(50, 255, 50),   -- зеленый
    [4] = Color(255, 255, 50),  -- желтый
    [5] = Color(255, 50, 255),  -- розовый
    [6] = Color(50, 255, 255),  -- голубой
    [7] = Color(255, 128, 50),  -- оранжевый
    [8] = Color(150, 50, 255),  -- фиолетовый
    [9] = Color(100, 100, 100), -- серый
    [10] = Color(255, 100, 150) -- салатовый
}

function GetTeamColor(team)
    if TeamColors[team] then
        return TeamColors[team]
    end
    return Color(math.random(50, 255), math.random(50, 255), math.random(50, 255))
end

function ENT:Initialize()
    self.AliveNPCs = 0
    self.Active = true
    self.Team = self.Team or 1
    self.MaxNPCs = 5
    self.SpawnDelay = 10
    self.Owner = self.Owner or NULL
    self.Health = self.Health or 100
    self.MaxHealth = self.MaxHealth or 100
    
    -- Создаем модель бочки
    self:SetModel(self.Model)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    
    local phys = self:GetPhysicsObject()
    if phys:IsValid() then
        phys:EnableMotion(false) -- бочка не двигается
    end
    
    -- Красим бочку в цвет команды
    self:SetColor(GetTeamColor(self.Team))
    
    -- Создаем текст над бочкой (HP)
    self:CreateText()
    
    -- Запускаем спавн NPC
    timer.Simple(2, function()
        if self:IsValid() then
            self:SpawnNPC()
        end
    end)
end

-- Создание текста с HP
function ENT:CreateText()
    if self.TextEntity and self.TextEntity:IsValid() then
        self.TextEntity:Remove()
    end
    
    self.TextEntity = ents.Create("env_text")
    if not self.TextEntity:IsValid() then return end
    
    self.TextEntity:SetKeyValue("text", string.format("HP: %.0f / %.0f", self.Health, self.MaxHealth))
    self.TextEntity:SetKeyValue("color", "255 255 255")
    self.TextEntity:SetPos(self:GetPos() + Vector(0, 0, 40))
    self.TextEntity:SetParent(self)
    self.TextEntity:Spawn()
    self.TextEntity:Activate()
end

-- Обновление текста HP
function ENT:UpdateHealthText()
    if self.TextEntity and self.TextEntity:IsValid() then
        self.TextEntity:SetKeyValue("text", string.format("HP: %.0f / %.0f", self.Health, self.MaxHealth))
    end
end

-- Урон по аванпосту
function ENT:TakeDamage(damage)
    self.Health = self.Health - damage
    self:UpdateHealthText()
    
    if self.Health <= 0 then
        self:Destroy()
    end
end

-- Уничтожение аванпоста
function ENT:Destroy()
    -- Уведомляем всех NPC, что аванпост уничтожен
    for _, npc in ipairs(ents.GetAll()) do
        if npc.Outpost == self and npc:IsValid() then
            npc:SetSchedule(SCHED_WANDER) -- идут бродить
            npc.Outpost = nil
        end
    end
    
    self:Remove()
end

-- Спавн NPC
function ENT:SpawnNPC()
    if not self.Active then return end
    if self.AliveNPCs >= self.MaxNPCs then return end
    
    -- Выбираем тип NPC в зависимости от команды (можно расширить)
    local npcClass = "npc_metropolice"
    
    local npc = ents.Create(npcClass)
    if not npc:IsValid() then return end
    
    -- Спавним вокруг бочки (радиус 100)
    local angle = math.random(0, 360)
    local radius = 100
    local spawnPos = self:GetPos() + Vector(math.cos(angle) * radius, math.sin(angle) * radius, 20)
    
    npc:SetPos(spawnPos)
    npc:Spawn()
    npc:Activate()
    
    -- Красим NPC в цвет команды (опционально)
    npc:SetColor(GetTeamColor(self.Team))
    
    npc.Outpost = self
    npc.Team = self.Team
    
    self.AliveNPCs = self.AliveNPCs + 1
    self:GiveOrder(npc)
    
    -- Планируем следующего NPC
    timer.Simple(self.SpawnDelay, function()
        if self:IsValid() then
            self:SpawnNPC()
        end
    end)
end

-- Команда NPC: атаковать вражеские аванпосты
function ENT:GiveOrder(npc)
    timer.Simple(0.5, function()
        if not npc:IsValid() then return end
        
        local nearest = nil
        local nearestDist = math.huge
        
        for _, outpost in ipairs(ents.FindByClass("sent_outpost")) do
            if outpost:IsValid() and outpost ~= self and outpost.Team ~= self.Team then
                local dist = npc:GetPos():Distance(outpost:GetPos())
                if dist < nearestDist then
                    nearestDist = dist
                    nearest = outpost
                end
            end
        end
        
        if nearest then
            npc:SetLastPosition(nearest:GetPos())
            npc:SetSchedule(SCHED_FORCED_GO_RUN)
            
            local timerName = "npc_check_" .. npc:EntIndex()
            timer.Create(timerName, 1, 0, function()
                if not npc:IsValid() then
                    timer.Remove(timerName)
                    return
                end
                if nearest:IsValid() and npc:GetPos():Distance(nearest:GetPos()) < 150 then
                    timer.Remove(timerName)
                    nearest:OnNPCArrived(npc)
                end
            end)
        end
    end)
end

-- Когда NPC дошел до вражеского аванпоста
function ENT:OnNPCArrived(npc)
    if not self:IsValid() then return end
    
    npc:SetSchedule(SCHED_WAIT)
    
    timer.Simple(2, function()
        if not self:IsValid() then return end
        
        -- Наносим урон аванпосту
        self:TakeDamage(25)
        
        -- Если аванпост еще жив
        if self:IsValid() and self.Health > 0 then
            -- NPC убегает или атакует дальше
            if npc:IsValid() then
                npc:SetSchedule(SCHED_WANDER)
            end
        end
    end)
end

-- При удалении аванпоста
function ENT:OnRemove()
    for _, npc in ipairs(ents.GetAll()) do
        if npc.Outpost == self and npc:IsValid() then
            npc.Outpost = nil
        end
    end
    
    if self.TextEntity and self.TextEntity:IsValid() then
        self.TextEntity:Remove()
    end
end