-- lua/autorun/server/sv_outpost_cleanup.lua
-- Уборка трупов и выпавшего оружия NPC аванпостов (иначе за долгий бой — сотни
-- ragdoll-ов и стволов на полу, и игра начинает тормозить).
-- Время — outpost_war_corpse_time (сек, 0 = не убирать).

OutpostWar = OutpostWar or {}
local OW = OutpostWar
if not OW.CVars then include("autorun/sh_outpost_war.lua") end

local function Delay()
    local cv = OW.CVars.corpse_time
    return cv and cv:GetFloat() or 20
end

-- Плавно убрать (если сущность это умеет), иначе — просто удалить
local function RemoveLater(ent, t)
    if not IsValid(ent) or ent.OW_Cleanup then return end
    ent.OW_Cleanup = true
    timer.Simple(t, function()
        if not IsValid(ent) then return end
        if ent:IsWeapon() and IsValid(ent:GetOwner()) then return end   -- кто-то подобрал
        if ent:GetClass() == "prop_ragdoll" then
            ent:Fire("FadeAndRemove", "", 0)
            timer.Simple(3, function() if IsValid(ent) then ent:Remove() end end)
        else
            ent:Remove()
        end
    end)
end

-- Недавние смерти NPC аванпостов: по ним узнаём "свои" трупы, созданные модами (VJ Base и т.п.)
local recent = {}

hook.Add("OnNPCKilled", "OutpostWar_Cleanup", function(npc)
    if not (IsValid(npc) and npc.OW_Team ~= nil) then return end
    local t = Delay()
    if t <= 0 then return end
    local wep = npc.GetActiveWeapon and npc:GetActiveWeapon()
    if IsValid(wep) then
        -- оружие выпадает чуть позже смерти
        timer.Simple(0.2, function() RemoveLater(wep, t) end)
    end
    recent[#recent + 1] = { pos = npc:GetPos(), time = CurTime() }
end)

-- Серверный ragdoll обычного NPC (ai_serverragdolls 1 / "Keep corpses")
hook.Add("CreateEntityRagdoll", "OutpostWar_Cleanup", function(owner, rag)
    if IsValid(owner) and owner.OW_Team ~= nil and Delay() > 0 then RemoveLater(rag, Delay()) end
end)

-- Трупы, которые создают сами NPC-моды (VJ Base): ragdoll рядом с только что убитым NPC
hook.Add("OnEntityCreated", "OutpostWar_Cleanup", function(ent)
    if #recent == 0 then return end
    timer.Simple(0, function()
        if not IsValid(ent) or ent.OW_Cleanup then return end
        local cls = ent:GetClass()
        if cls ~= "prop_ragdoll" and not cls:find("corpse") and not cls:find("gib") then return end
        local now, p = CurTime(), ent:GetPos()
        for i = #recent, 1, -1 do
            local r = recent[i]
            if now - r.time > 2 then
                table.remove(recent, i)
            elseif r.pos:DistToSqr(p) < 150 * 150 then
                RemoveLater(ent, Delay())
                return
            end
        end
    end)
end)
