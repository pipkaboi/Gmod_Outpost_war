-- lua/autorun/server/sv_outpost_players.lua
-- Игроки в войне аванпостов: выбор команды, отношения с NPC, отряд игрока,
-- появление на своём аванпосте.

OutpostWar = OutpostWar or {}
local OW = OutpostWar
if not OW.CVars then include("autorun/sh_outpost_war.lua") end

function OW.PlayerTeam(ply)
    return IsValid(ply) and ply:GetNWInt("OW_Team", 0) or 0
end

---------------------------------------------------------------------------
-- Отношения NPC <-> игрок
---------------------------------------------------------------------------
function OW.RelatePlayer(npc, ply)
    if not (IsValid(npc) and npc:IsNPC() and IsValid(ply)) then return end
    -- запоминаем "родное" отношение NPC к игроку, чтобы вернуть его при выходе из войны
    npc.OW_PlyDefault = npc.OW_PlyDefault or {}
    if npc.OW_PlyDefault[ply] == nil then npc.OW_PlyDefault[ply] = npc:Disposition(ply) end

    local t = OW.PlayerTeam(ply)
    local disp
    if t > 0 then
        disp = (npc.OW_Team == t) and D_LI or D_HT
    elseif OW.CVars.ignore_players:GetBool() then
        disp = D_NU
    else
        disp = npc.OW_PlyDefault[ply]
    end
    npc:AddEntityRelationship(ply, disp, 99)
    -- если игрок больше не враг — NPC сразу забывает про него, а не после смены цели
    if disp ~= D_HT and disp ~= D_FR then
        if npc:GetEnemy() == ply then npc:SetEnemy(NULL) end
        if npc.ClearEnemyMemory then npc:ClearEnemyMemory(ply) end
    end
end


local function RelateAll(ply)
    for npc in pairs(OW.NPCs) do OW.RelatePlayer(npc, ply) end
end

-- Галочка "NPC не трогают игроков" применяется сразу ко всем NPC, а не только к новым
cvars.AddChangeCallback("outpost_war_ignore_players", function()
    for _, ply in ipairs(player.GetAll()) do RelateAll(ply) end
end, "OutpostWar_IgnorePlayers")

---------------------------------------------------------------------------
-- Вступление в команду
---------------------------------------------------------------------------
function OW.SetPlayerTeam(ply, t)
    t = math.Clamp(math.floor(tonumber(t) or 0), 0, 99)
    if ply.OW_Squad then OW.DisbandSquad(ply.OW_Squad, OW.FindHome(OW.PlayerTeam(ply), ply:GetPos())) end
    ply:SetNWInt("OW_Team", t)
    ply:SetNWInt("OW_SquadCount", 0)

    if t > 0 then
        ply.OW_OldColor = ply.OW_OldColor or ply:GetPlayerColor()
        local c = OW.TeamColor(t)
        ply:SetPlayerColor(Vector(c.r / 255, c.g / 255, c.b / 255))
    elseif ply.OW_OldColor then
        ply:SetPlayerColor(ply.OW_OldColor)
        ply.OW_OldColor = nil
    end

    RelateAll(ply)
    OW.Notify(t > 0 and "msg_joined" or "msg_left", ply:Nick(), { team = t })
end

concommand.Add("outpost_war_join", function(ply, _, args)
    if not IsValid(ply) then return end
    OW.SetPlayerTeam(ply, args[1])
end)

concommand.Add("outpost_war_squad_dismiss", function(ply)
    if IsValid(ply) and ply.OW_Squad then
        ply.OW_NoRecruitUntil = CurTime() + 30   -- чтобы распущенные не вернулись сразу же
        OW.DisbandSquad(ply.OW_Squad, OW.FindHome(OW.PlayerTeam(ply), ply:GetPos()))
    end
end)

hook.Add("PlayerDisconnected", "OutpostWar_Players", function(ply)
    if ply.OW_Squad then OW.DisbandSquad(ply.OW_Squad, OW.FindHome(OW.PlayerTeam(ply), ply:GetPos())) end
end)

-- Появление на своём аванпосте
hook.Add("PlayerSpawn", "OutpostWar_Players", function(ply)
    timer.Simple(0, function()
        if not IsValid(ply) or not OW.CVars.spawn_at_outpost:GetBool() then return end
        local t = OW.PlayerTeam(ply)
        if t <= 0 then return end
        local home = OW.FindHome(t, ply:GetPos())
        if IsValid(home) then
            ply:SetPos(OW.RandomPointNear(home:GetPos(), home:GetCapRadius() * 0.5) + Vector(0, 0, 8))
        end
        -- после смерти игрока цвет сбрасывается — возвращаем цвет команды
        local c = OW.TeamColor(t)
        ply:SetPlayerColor(Vector(c.r / 255, c.g / 255, c.b / 255))
    end)
end)

---------------------------------------------------------------------------
-- Отряд игрока: свободные NPC его команды рядом с ним вступают в отряд
---------------------------------------------------------------------------
local RECRUIT_DIST = 1500

function OW.PlayersTick()
    local cap = OW.CVars.player_squad:GetInt()
    for _, ply in ipairs(player.GetAll()) do
        local t = OW.PlayerTeam(ply)
        if t > 0 and ply:Alive() and cap > 0 and CurTime() >= (ply.OW_NoRecruitUntil or 0) then
            local sq = ply.OW_Squad
            local have = sq and #sq.members or 0
            if have < cap then
                local ppos = ply:GetPos()
                for npc in pairs(OW.NPCs) do
                    if have >= cap then break end
                    -- свободные: резерв аванпоста (не охрана и не в отряде)
                    if npc.OW_Team == t and not npc.OW_Squad and npc.OW_Role == "reserve"
                       and OW.IsAlive(npc) and npc:GetPos():DistToSqr(ppos) < RECRUIT_DIST ^ 2 then
                        if not sq then
                            sq = OW.CreateSquad(t, {}, nil, nil)
                            sq.player, sq.state = ply, "follow"
                            ply.OW_Squad = sq
                        end
                        npc.OW_Squad, npc.OW_Role, npc.OW_AssaultGoal = sq, "squad", nil
                        if npc.SetSquad then npc:SetSquad("ow_squad_" .. sq.id) end
                        table.insert(sq.members, npc)
                        have = have + 1
                    end
                end
            end
            ply:SetNWInt("OW_SquadCount", sq and #sq.members or 0)
        end
    end
end

function OW.PlayerSquadTick(sq)
    local ply = sq.player
    if not IsValid(ply) or OW.PlayerTeam(ply) ~= sq.team then
        OW.DisbandSquad(sq, OW.FindHome(sq.team, sq.members[1]:GetPos()))
        return
    end
    ply:SetNWInt("OW_SquadCount", #sq.members)

    local n = #sq.members + 1
    for i, m in ipairs(sq.members) do
        if OW.IsFighting(m) then
            OW.Engage(m)
        elseif ply:Alive() then
            -- держимся рядом с игроком (точка строя проверяется: пол, без стен)
            if m:GetPos():DistToSqr(ply:GetPos()) > 220 * 220 then
                local goal = OW.SafeFormationPoint(ply, OW.FormationOffset(i + 1, n, ply))
                OW.MoveTo(m, goal, 150)
            end
        end
        -- если игрок погиб — отряд остаётся на месте и дерётся, пока он не вернётся
    end
end
