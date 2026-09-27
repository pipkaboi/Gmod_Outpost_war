-- lua/entities/sent_outpost.lua
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Аванпост"
ENT.Category = "Outpost War"
ENT.Spawnable = false          -- ставится через инструмент "Аванпост"
ENT.RenderGroup = RENDERGROUP_BOTH

ENT.Model = "models/props_c17/oildrum001.mdl"

function ENT:SetupDataTables()
    self:NetworkVar("Int", 0, "OPTeam")
    self:NetworkVar("Int", 1, "CapTeam")
    self:NetworkVar("Int", 2, "MaxNPCs")
    self:NetworkVar("Int", 3, "SquadSize")
    self:NetworkVar("Int", 4, "Garrison")
    self:NetworkVar("Float", 0, "CapProgress")
    self:NetworkVar("Float", 1, "CapRadius")
    self:NetworkVar("Float", 2, "SpawnDelay")
    self:NetworkVar("String", 0, "NPCClass")
    self:NetworkVar("String", 1, "NPCWeapon")
end

if SERVER then
    local OW = OutpostWar

    local DEFAULTS = {
        team = 1, npc = "npc_combine_s", weapon = "default",
        max_npcs = 10, spawn_delay = 15, squad_size = 4, garrison = 2, radius = 300,
    }

    function ENT:Initialize()
        self:SetModel(self.Model)
        self:PhysicsInit(SOLID_VPHYSICS)
        self:SetMoveType(MOVETYPE_VPHYSICS)
        self:SetSolid(SOLID_VPHYSICS)
        local phys = self:GetPhysicsObject()
        if IsValid(phys) then phys:EnableMotion(false) end

        self:ApplySettings(self.OW_Settings or {})
        self.OW_NextWave = CurTime() + 2
    end

    -- Применить настройки (вызывается при создании и по R инструмента)
    function ENT:ApplySettings(s)
        local function get(k) if s[k] ~= nil then return s[k] end return DEFAULTS[k] end
        self:SetOPTeam(math.max(0, math.floor(get("team"))))
        self:SetNPCClass(get("npc"))
        self:SetNPCWeapon(get("weapon"))
        self:SetMaxNPCs(math.Clamp(math.floor(get("max_npcs")), 1, 60))
        self:SetSpawnDelay(math.Clamp(get("spawn_delay"), 2, 600))
        self:SetSquadSize(math.Clamp(math.floor(get("squad_size")), 1, 20))
        self:SetGarrison(math.Clamp(math.floor(get("garrison")), 0, 20))
        self:SetCapRadius(math.Clamp(get("radius"), 100, 2000))
        self:UpdateColor()
    end

    function ENT:UpdateColor()
        self:SetColor(OW.TeamColor(self:GetOPTeam()))
    end

    ------------------------------------------------------------------
    -- Спавн
    ------------------------------------------------------------------
    function ENT:FindSpawnPos()
        local base = self:GetPos()
        local maxD = math.max(120, self:GetCapRadius() * 0.6)
        for _ = 1, 15 do
            local a = math.Rand(0, math.pi * 2)
            local d = math.Rand(70, maxD)
            local p = base + Vector(math.cos(a) * d, math.sin(a) * d, 0)

            local vis = util.TraceLine({
                start = base + Vector(0, 0, 40), endpos = p + Vector(0, 0, 40),
                mask = MASK_SOLID_BRUSHONLY,
            })
            if not vis.Hit then
                local tr = util.TraceLine({
                    start = p + Vector(0, 0, 64), endpos = p - Vector(0, 0, 256),
                    mask = MASK_NPCSOLID_BRUSHONLY,
                })
                if tr.Hit and not tr.StartSolid then
                    local pos = tr.HitPos + Vector(0, 0, 4)
                    local hull = util.TraceHull({
                        start = pos, endpos = pos,
                        mins = Vector(-18, -18, 0), maxs = Vector(18, 18, 72),
                        mask = MASK_NPCSOLID,
                    })
                    if not hull.Hit then return pos end
                end
            end
        end
    end

    function ENT:SpawnOneNPC()
        local team = self:GetOPTeam()
        if team == 0 then return end

        local key = self:GetNPCClass()
        local data = list.Get("NPC")[key]
        local class = data and data.Class or key

        local pos = self:FindSpawnPos()
        if not pos then return end

        local npc = ents.Create(class)
        if not IsValid(npc) then return end

        npc:SetPos(pos)
        npc:SetAngles(Angle(0, math.random(0, 359), 0))

        if data then
            if data.Model then npc:SetModel(data.Model) end
            if data.Material then npc:SetMaterial(data.Material) end
            if data.Skin then npc:SetSkin(data.Skin) end
            if data.KeyValues then
                for k, v in pairs(data.KeyValues) do npc:SetKeyValue(k, v) end
            end
        end

        local flags = bit.bor(SF_NPC_FADE_CORPSE, SF_NPC_ALWAYSTHINK, SF_NPC_NO_WEAPON_DROP or 8192)
        if data and data.SpawnFlags then flags = bit.bor(flags, data.SpawnFlags) end
        if data and data.TotalSpawnFlags then flags = data.TotalSpawnFlags end
        npc:SetKeyValue("spawnflags", flags)
        npc:SetKeyValue("squadname", "ow_home_" .. self:EntIndex())

        -- Оружие
        local wep = self:GetNPCWeapon()
        if wep == "default" or wep == "" then
            if data and data.Weapons and #data.Weapons > 0 then
                npc:SetKeyValue("additionalequipment", table.Random(data.Weapons))
            end
        elseif wep ~= "none" then
            npc:SetKeyValue("additionalequipment", wep)
        end

        npc:Spawn()
        npc:Activate()

        if data and data.Health then
            npc:SetHealth(data.Health)
            npc:SetMaxHealth(data.Health)
        end
        if npc.SetCurrentWeaponProficiency then
            npc:SetCurrentWeaponProficiency(WEAPON_PROFICIENCY_GOOD)
        end
        if OW.TintEnabled() then npc:SetColor(OW.TeamColor(team)) end

        if IsValid(self.OW_Owner) then cleanup.Add(self.OW_Owner, "npcs", npc) end

        OW.Register(npc, self)
        return npc
    end

    ------------------------------------------------------------------
    -- Логика аванпоста (вызывается раз в секунду из sv_outpost_war)
    ------------------------------------------------------------------
    function ENT:IsThreatened()
        local pos, r = self:GetPos(), self:GetCapRadius() * 1.5
        local team = self:GetOPTeam()
        for npc in pairs(OW.NPCs) do
            if npc.OW_Team ~= team and OW.IsAlive(npc)
               and npc:GetPos():DistToSqr(pos) < r * r then
                return true
            end
        end
        return false
    end

    function ENT:BrainTick()
        local team = self:GetOPTeam()
        if team == 0 then return end

        local guards, reserves, total = {}, {}, 0
        for npc in pairs(OW.NPCs) do
            if npc.OW_Home == self and npc.OW_Team == team and OW.IsAlive(npc) then
                total = total + 1
                if not npc.OW_Squad then
                    if npc.OW_Role == "guard" then
                        table.insert(guards, npc)
                    else
                        table.insert(reserves, npc)
                    end
                end
            end
        end

        local threatened = self:IsThreatened()

        -- Под атакой и гарнизона мало -> возвращаем свои отряды, которые ещё недалеко
        if threatened and #guards < self:GetGarrison() then
            for _, sq in pairs(OW.Squads) do
                if sq.origin == self and sq.state == "march" and IsValid(sq.members[1])
                   and sq.members[1]:GetPos():DistToSqr(self:GetPos()) < 1500 * 1500 then
                    for _, m in ipairs(sq.members) do table.insert(reserves, m) end
                    OW.DisbandSquad(sq, self)
                end
            end
        end

        -- 1) Сначала заполняем гарнизон
        while #guards < self:GetGarrison() and #reserves > 0 do
            local n = table.remove(reserves, 1)
            n.OW_Role = "guard"
            table.insert(guards, n)
        end

        -- 2) Из резерва собираем отряд и отправляем в атаку
        local sqSize = self:GetSquadSize()
        local full = total >= self:GetMaxNPCs()
        if not threatened and #reserves > 0 and (#reserves >= sqSize or full) then
            local target = OW.FindTarget(team, self:GetPos(), self)
            if target then
                local members = {}
                for i = 1, math.min(sqSize, #reserves) do members[i] = reserves[i] end
                OW.CreateSquad(team, members, target, self)
            end
        end

        -- 3) Спавн волнами (по размеру отряда)
        if not full and CurTime() >= (self.OW_NextWave or 0) then
            self.OW_NextWave = CurTime() + self:GetSpawnDelay()
            local n = math.min(sqSize, self:GetMaxNPCs() - total)
            for i = 1, n do
                timer.Simple((i - 1) * 0.4, function()
                    if IsValid(self) and self:GetOPTeam() == team then self:SpawnOneNPC() end
                end)
            end
        end
    end

    ------------------------------------------------------------------
    -- Захват
    ------------------------------------------------------------------
    function ENT:Think()
        local now = CurTime()
        local dt = now - (self.OW_LastThink or now)
        self.OW_LastThink = now
        self:UpdateCapture(dt)
        self:NextThink(now + 0.5)
        return true
    end

    function ENT:UpdateCapture(dt)
        local pos = self:GetPos()
        local r2 = self:GetCapRadius() ^ 2
        local counts, sample = {}, {}

        for npc in pairs(OW.NPCs) do
            if OW.IsAlive(npc) and npc:GetPos():DistToSqr(pos) <= r2 then
                local t = npc.OW_Team
                counts[t] = (counts[t] or 0) + 1
                sample[t] = sample[t] or npc
            end
        end

        local my = self:GetOPTeam()
        local defenders = counts[my] or 0
        local attTeam, attCount, teams = nil, 0, 0
        for t, c in pairs(counts) do
            if t ~= my then teams = teams + 1 attTeam, attCount = t, c end
        end

        local capTime = OW.CaptureTime()
        local prog, capT = self:GetCapProgress(), self:GetCapTeam()

        if defenders > 0 or teams == 0 then
            prog = math.max(0, prog - dt / capTime)          -- защитники отбивают
        elseif teams == 1 then
            if capT ~= 0 and capT ~= attTeam then
                prog = math.max(0, prog - dt * 2 / capTime)  -- сначала сбиваем чужой прогресс
            else
                capT = attTeam
                local speed = 1 + 0.5 * (math.min(attCount, 5) - 1)
                prog = prog + dt * speed / capTime
                if prog >= 1 then
                    self:Captured(attTeam, sample[attTeam])
                    return
                end
            end
        end
        -- teams > 1 без защитников: точка оспаривается, прогресс замирает

        if prog <= 0 then capT = 0 end
        self:SetCapProgress(prog)
        self:SetCapTeam(capT)
    end

    function ENT:Captured(team, byNPC)
        local old = self:GetOPTeam()
        self:SetOPTeam(team)
        if IsValid(byNPC) and byNPC.OW_SpawnClass then
            self:SetNPCClass(byNPC.OW_SpawnClass)
            self:SetNPCWeapon(byNPC.OW_SpawnWeapon or "default")
        end
        self:SetCapProgress(0)
        self:SetCapTeam(0)
        self:UpdateColor()
        self.OW_NextWave = CurTime() + self:GetSpawnDelay()
        PrintMessage(HUD_PRINTTALK, string.format("[Аванпосты] %s захватила аванпост (%s)",
            OW.TeamName(team), OW.TeamName(old)))
    end
end

if CLIENT then
    local OW = OutpostWar

    function ENT:Draw()
        self:DrawModel()
    end

    function ENT:Think()
        local r = self:GetCapRadius()
        if self.OW_LastR ~= r then
            self.OW_LastR = r
            self:SetRenderBounds(Vector(-r, -r, -10), Vector(r, r, 120))
        end
    end

    function ENT:DrawTranslucent()
        local pos = self:GetPos()
        if EyePos():DistToSqr(pos) > 4000 * 4000 then return end

        local team = self:GetOPTeam()
        local col = OW.TeamColor(team)
        local r = self:GetCapRadius()

        -- Круг зоны захвата
        cam.Start3D2D(pos + Vector(0, 0, 3), Angle(0, 0, 0), 1)
            surface.DrawCircle(0, 0, r, col.r, col.g, col.b, 220)
            surface.DrawCircle(0, 0, r - 2, col.r, col.g, col.b, 120)
        cam.End3D2D()

        -- Подпись над аванпостом
        local ang = Angle(0, EyeAngles().y - 90, 90)
        cam.Start3D2D(pos + Vector(0, 0, 75), ang, 0.12)
            draw.SimpleTextOutlined(OW.TeamName(team), "OutpostWar_Big", 0, 0, col,
                TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 2, color_black)

            local prog = self:GetCapProgress()
            if prog > 0 then
                local capCol = OW.TeamColor(self:GetCapTeam())
                local w, h = 320, 26
                surface.SetDrawColor(0, 0, 0, 200)
                surface.DrawRect(-w / 2, 8, w, h)
                surface.SetDrawColor(capCol.r, capCol.g, capCol.b, 255)
                surface.DrawRect(-w / 2 + 2, 10, (w - 4) * math.Clamp(prog, 0, 1), h - 4)
                draw.SimpleTextOutlined(string.format("Захват: %d%%", prog * 100), "OutpostWar_Small",
                    0, 8 + h + 4, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 2, color_black)
            end
        cam.End3D2D()
    end
end
