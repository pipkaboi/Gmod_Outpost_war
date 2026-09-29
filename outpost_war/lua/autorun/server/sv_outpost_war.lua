-- lua/autorun/server/sv_outpost_war.lua
-- "Мозг" мода: реестр NPC, отношения между командами, отряды, охрана.
-- Логика движения — как в версии из коммита на GitHub (движок сам строит маршрут по
-- AI-нодам карты; если не смог — NPC идёт "шагами"). Поверх неё: VJ Base, двери, журнал.

OutpostWar = OutpostWar or {}
local OW = OutpostWar

OW.NPCs        = OW.NPCs or {}    -- [npc] = true
OW.Squads      = OW.Squads or {}  -- [id] = squad
OW.NextSquadID = OW.NextSquadID or 0

-- Консольные переменные создаются в sh_outpost_war.lua (общие, реплицируются клиентам)
if not OW.CVars then include("autorun/sh_outpost_war.lua") end
local cv_ignorePlayers = OW.CVars.ignore_players
local cv_tint = OW.CVars.tint
local cv_capTime = OW.CVars.capture_time

function OW.CaptureTime() return math.max(1, cv_capTime:GetFloat()) end
function OW.TintEnabled() return cv_tint:GetBool() end

---------------------------------------------------------------------------
-- Утилиты
---------------------------------------------------------------------------
function OW.IsAlive(npc)
    return IsValid(npc) and npc:Health() > 0
end

function OW.GetOutposts()
    return ents.FindByClass("sent_outpost")
end

-- Ближайший НЕ свой аванпост (вражеский или нейтральный)
OW.Unreachable = OW.Unreachable or {}

local function IsUnreachable(team, op)
    local t = OW.Unreachable[team] and OW.Unreachable[team][op]
    return t and CurTime() - t < 60
end

function OW.FindTarget(team, pos, exclude)
    local best, bestD
    for _, op in ipairs(OW.GetOutposts()) do
        if op ~= exclude and op:GetOPTeam() ~= team and not IsUnreachable(team, op) then
            local d = op:GetPos():DistToSqr(pos)
            if not bestD or d < bestD then best, bestD = op, d end
        end
    end
    return best
end

-- Ближайший свой аванпост
function OW.FindHome(team, pos)
    local best, bestD
    for _, op in ipairs(OW.GetOutposts()) do
        if op:GetOPTeam() == team then
            local d = op:GetPos():DistToSqr(pos)
            if not bestD or d < bestD then best, bestD = op, d end
        end
    end
    return best
end

-- Случайная точка на полу рядом с center
function OW.RandomPointNear(center, radius)
    for _ = 1, 8 do
        local a = math.Rand(0, math.pi * 2)
        local d = math.Rand(radius * 0.3, radius)
        local p = center + Vector(math.cos(a) * d, math.sin(a) * d, 0)
        local tr = util.TraceLine({
            start = p + Vector(0, 0, 64), endpos = p - Vector(0, 0, 256),
            mask = MASK_NPCSOLID_BRUSHONLY,
        })
        if tr.Hit and not tr.StartSolid then
            local vis = util.TraceLine({
                start = center + Vector(0, 0, 40), endpos = tr.HitPos + Vector(0, 0, 40),
                mask = MASK_SOLID_BRUSHONLY,
            })
            if not vis.Hit then return tr.HitPos + Vector(0, 0, 4) end
        end
    end
    return center
end

---------------------------------------------------------------------------
-- Движение / бой
---------------------------------------------------------------------------
local cv_debug = OW.CVars.debug

local function MoveSched(npc)
    return npc.OW_UseWalk and SCHED_FORCED_GO or SCHED_FORCED_GO_RUN
end

-- NPC из VJ Base: свой ИИ на Lua, двигать их нужно функциями VJ Base
local function IsVJ(npc)
    return npc.IsVJBaseSNPC == true
end

local function IsMoving(npc)
    if IsVJ(npc) then return npc.IsMoving and npc:IsMoving() or false end
    return npc:IsCurrentSchedule(SCHED_FORCED_GO_RUN) or npc:IsCurrentSchedule(SCHED_FORCED_GO)
end

local function IssueMove(npc, target)
    npc:SetLastPosition(target)
    if IsVJ(npc) then
        local task = npc.OW_UseWalk and "TASK_WALK_PATH" or "TASK_RUN_PATH"
        if npc.SCHEDULE_GOTO_POSITION then npc:SCHEDULE_GOTO_POSITION(task) return end
        if npc.VJ_TASK_GOTO_LASTPOS then npc:VJ_TASK_GOTO_LASTPOS(task) return end
    end
    npc:SetSchedule(MoveSched(npc))
end

local function StopMove(npc)
    if IsVJ(npc) then
        if npc.StopMoving then npc:StopMoving() end
        return
    end
    if npc.ClearSchedule then npc:ClearSchedule() else npc:SetSchedule(SCHED_IDLE_STAND) end
end

-- Журнал: outpost_war_debug 2 -> файл garrysmod/data/outpost_war_log.txt
local function Log(npc, msg)
    if cv_debug:GetInt() < 2 then return end
    local role = npc.OW_Squad and ("отряд " .. npc.OW_Squad.id .. (npc.OW_Squad.members[1] == npc and " лидер" or ""))
        or (npc.OW_Role or "?")
    local line = string.format("[%.1f] #%d %s (%s) act=%s sched=%s: %s\n", CurTime(), npc:EntIndex(),
        npc:GetClass(), role, tostring(npc:GetActivity()), tostring(npc:GetCurrentSchedule()), msg)
    file.Append("outpost_war_log.txt", line)
end
OW.Log = Log

concommand.Add("outpost_war_log_clear", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    file.Write("outpost_war_log.txt", "")
end)

local STEP = 220   -- по журналу: дальше ~200 юнитов движок часто не строит путь

local function FloorAt(p)
    local tr = util.TraceLine({
        start = p + Vector(0, 0, 40), endpos = p - Vector(0, 0, 200),
        mask = MASK_NPCSOLID_BRUSHONLY,
    })
    if tr.Hit and not tr.StartSolid then return tr.HitPos + Vector(0, 0, 4) end
end

-- Ближняя точка (до STEP юнитов) в сторону goal, в обход стен.
-- Нужна, когда движок не может построить длинный маршрут (нет AI-нод на карте и т.п.)
local function StepPoint(npc, goal, fails)
    local from = npc:GetPos()
    local dir = goal - from
    dir.z = 0
    if dir:Length() <= STEP then return goal end

    local baseYaw = dir:Angle().y
    local jitter = math.min(fails * 15, 90)
    local mins, maxs = Vector(-16, -16, 20), Vector(16, 16, 64) -- z от 20: ступеньки не мешают
    local best, bestScore

    for _, off in ipairs({ 0, 25, -25, 50, -50, 80, -80, 115, -115 }) do
        local yaw = baseYaw + off + math.Rand(-jitter, jitter)
        local fwd = Angle(0, yaw, 0):Forward()
        local tr = util.TraceHull({
            start = from, endpos = from + fwd * STEP,
            mins = mins, maxs = maxs, mask = MASK_NPCSOLID_BRUSHONLY, filter = npc,
        })
        local len = tr.Fraction * STEP
        if len > 120 then
            local p = FloorAt(from + fwd * (len - 32))
            if p then
                local score = len * math.cos(math.rad(yaw - baseYaw))
                if not bestScore or score > bestScore then best, bestScore = p, score end
                if off == 0 and len >= STEP * 0.9 then break end
            end
        end
    end
    return best or goal
end

-- Прямой приказ: маршрут строит движок; если не смог — идём "шагами".
-- Вызывается каждый тик; сам решает, надо ли перевыдавать приказ.
local function DirectMove(npc, pos, tolerance)
    tolerance = tolerance or 100
    local now = CurTime()
    local mypos = npc:GetPos()
    local running = IsMoving(npc)
    local sameGoal = npc.OW_Goal ~= nil and npc.OW_Goal:DistToSqr(pos) < tolerance * tolerance
    local failed = false

    if running then
        -- Застрял: бежит, но почти не двигается 4 секунды
        if not npc.OW_LastPos or mypos:DistToSqr(npc.OW_LastPos) > 30 * 30 then
            npc.OW_LastPos, npc.OW_LastMove = mypos, now
        elseif now - (npc.OW_LastMove or now) > 4 then
            failed = true
        end
    elseif npc.OW_Target then
        -- Приказ закончился, а до точки далеко -> маршрут не построился.
        -- (tolerance > 150 — например, точка строя: подойти "примерно" достаточно)
        local arrive = math.max(150, tolerance)
        if mypos:DistToSqr(npc.OW_Target) > arrive * arrive then
            failed = true
        else
            npc.OW_Fail = 0
        end
    end

    if running and sameGoal and not failed then
        -- В режиме шагов выдаём следующий шаг, когда почти дошли до текущего
        if not npc.OW_Stepping or mypos:DistToSqr(npc.OW_Target) > 90 * 90 then return end
    end

    if failed then
        Log(npc, string.format("провал #%d: running=%s, до точки %.0f", (npc.OW_Fail or 0) + 1,
            tostring(running), npc.OW_Target and mypos:Distance(npc.OW_Target) or -1))
        npc.OW_Fail = (npc.OW_Fail or 0) + 1
        npc.OW_StepUntil = now + 6                  -- 6 сек идём шагами
        if npc.OW_Fail % 4 == 0 then npc.OW_UseWalk = not npc.OW_UseWalk end
    end

    local target = pos
    npc.OW_Stepping = (npc.OW_StepUntil or 0) > now
    if npc.OW_Stepping then target = StepPoint(npc, pos, npc.OW_Fail or 0) end

    npc.OW_Goal, npc.OW_Target = pos, target
    npc.OW_LastPos, npc.OW_LastMove = mypos, now
    IssueMove(npc, target)
    Log(npc, string.format("приказ: до точки %.0f%s, running до этого=%s", mypos:Distance(target),
        npc.OW_Stepping and " (шаг)" or "", tostring(running)))
end

-- Отправить NPC к точке pos. Если далеко и на карте есть навмеш — идём по маршруту
-- по навмешу (sv_outpost_path.lua, белые линии в отладке), иначе — прямым приказом.
local PATH_MIN_DIST = 450

function OW.MoveTo(npc, pos, tolerance)
    local mypos = npc:GetPos()
    local P = OW.Path

    if not (P and P.Available()) or mypos:DistToSqr(pos) < PATH_MIN_DIST * PATH_MIN_DIST then
        npc.OW_Path, npc.OW_NoRoute = nil, nil
        return DirectMove(npc, pos, tolerance)
    end

    local now = CurTime()
    local path = npc.OW_Path
    local need = not path or path.failed or path.goal:DistToSqr(pos) > 300 * 300
        or (path.wps[path.idx] and mypos:DistToSqr(path.wps[path.idx]) > 900 * 900)

    if need and now >= (npc.OW_NextRepath or 0) then
        local status, res = P.Request(mypos, pos)
        if status == "pending" then
            npc.OW_NextRepath = now + 0.2
        elseif status == "ok" and #res > 0 then
            path = { goal = pos, wps = res, idx = 1 }
            npc.OW_Path, npc.OW_NoRoute, npc.OW_Fail = path, nil, 0
            npc.OW_NextRepath = now + 2
        else
            path = nil
            npc.OW_Path, npc.OW_NoRoute, npc.OW_NoRouteReason = nil, now, res
            npc.OW_NextRepath = now + 5
        end
    end

    if not path then
        if npc.OW_NoRoute and not npc.OW_Squad then return DirectMove(npc, pos, tolerance) end
        OW.Stop(npc)
        return
    end

    while path.idx < #path.wps do
        local wp = path.wps[path.idx]
        local d2 = mypos:DistToSqr(wp)
        -- следующую точку выдаём заранее (за 120 юнитов), чтобы NPC не останавливался
        if d2 < 120 * 120 or (d2 < 220 * 220 and P.ClearWalk(mypos, path.wps[path.idx + 1])) then
            path.idx = path.idx + 1
        else
            break
        end
    end

    local wp = path.idx == #path.wps and pos or path.wps[path.idx]
    DirectMove(npc, wp, 30)

    if (npc.OW_Fail or 0) >= 2 then path.failed = true end
end

-- Прервать наш приказ движения (чтобы NPC мог стрелять / стоять)
function OW.Stop(npc)
    if IsMoving(npc) then StopMove(npc) end
    npc.OW_Goal, npc.OW_Target = nil, nil
end

function OW.DebugDraw()
    if not cv_debug:GetBool() then return end
    for npc in pairs(OW.NPCs) do
        if IsValid(npc) then
            local col = OW.TeamColor(npc.OW_Team)
            local label = npc.OW_Role or "?"
            if npc.OW_Squad then
                local sq = npc.OW_Squad
                label = sq.player and ("отряд игрока " .. (IsValid(sq.player) and sq.player:Nick() or "?"))
                    or ("отряд " .. sq.id .. " " .. (sq.state or "") .. (sq.members[1] == npc and " [лидер]" or ""))
            end
            if IsVJ(npc) then label = "[VJ] " .. label end
            if npc.OW_Stepping then label = label .. " (шаги)" end
            if (npc.OW_Fail or 0) > 0 then label = label .. " fail:" .. npc.OW_Fail end
            if OW.IsFighting(npc) then label = label .. " БОЙ" end
            if npc.OW_Path then
                label = label .. " (маршрут " .. npc.OW_Path.idx .. "/" .. #npc.OW_Path.wps .. ")"
                local prev = npc:GetPos()
                for i = npc.OW_Path.idx, #npc.OW_Path.wps do
                    local w = npc.OW_Path.wps[i] + Vector(0, 0, 8)
                    debugoverlay.Line(prev, w, 0.55, Color(255, 255, 255), true)
                    prev = w
                end
            end
            if npc.OW_NoRoute then label = label .. " НЕТ МАРШРУТА: " .. tostring(npc.OW_NoRouteReason) end
            debugoverlay.Text(npc:EyePos() + Vector(0, 0, 12), label, 0.55, false)
            if npc.OW_Target then
                debugoverlay.Line(npc:EyePos(), npc.OW_Target, 0.55, col, true)
                debugoverlay.Cross(npc.OW_Target, 12, 0.55, col, true)
            end
        end
    end
end

-- Видит ли NPC живого врага поблизости
-- Боевая готовность: после того как враг пропал из виду, NPC ещё столько секунд
-- остаётся под управлением своего боевого ИИ (преследует, обходит, укрывается)
-- Дальше дистанции боя враг не считается: иначе NPC садятся в перестрелку через всю
-- улицу, почти не попадают и стоят бесконечно. Отряд продолжает сближаться.
local function FightingRaw(npc)
    local e = npc:GetEnemy()
    if not IsValid(e) then return false end
    if e.Health and e:Health() <= 0 then return false end
    local range = OW.CVars.engage_dist and OW.CVars.engage_dist:GetFloat() or 800
    local d = npc:GetPos():DistToSqr(e:GetPos())
    -- в NPC недавно попали — отвечает огнём на любой дистанции
    local hurt = npc.OW_HurtTime and CurTime() - npc.OW_HurtTime < 3
    if (d <= range * range or hurt) and (d < 600 * 600 or npc:Visible(e)) then
        npc.OW_LastCombat = CurTime()
        return true
    end
    local linger = OW.CVars.combat_linger and OW.CVars.combat_linger:GetFloat() or 0
    return npc.OW_LastCombat ~= nil and CurTime() - npc.OW_LastCombat < linger
        and d <= (range * 1.3) ^ 2
end

function OW.IsFighting(npc)
    local f = FightingRaw(npc)
    if f and not npc.OW_CombatSince then
        npc.OW_CombatSince = CurTime()
        local e = npc:GetEnemy()
        Log(npc, string.format("БОЙ начат: враг %s на %.0f, виден=%s", IsValid(e) and e:GetClass() or "?",
            IsValid(e) and npc:GetPos():Distance(e:GetPos()) or -1, tostring(IsValid(e) and npc:Visible(e))))
    elseif not f and npc.OW_CombatSince then
        Log(npc, string.format("БОЙ окончен через %.1f с", CurTime() - npc.OW_CombatSince))
        npc.OW_CombatSince, npc.OW_PushUntil = nil, nil
    end
    return f
end

-- Отдать NPC его собственному боевому ИИ. Если перестрелка затянулась на дистанции —
-- короткий рывок к врагу, чтобы не стоять друг напротив друга вечно.
function OW.Engage(npc)
    local now = CurTime()
    local e = npc:GetEnemy()
    if IsValid(e) and npc.OW_CombatSince and now - npc.OW_CombatSince > 5
       and npc:GetPos():DistToSqr(e:GetPos()) > 600 * 600 then
        if not npc.OW_PushUntil and now >= (npc.OW_NextPush or 0) then
            local dir = e:GetPos() - npc:GetPos()
            dir.z = 0
            dir:Normalize()
            npc.OW_PushTarget = FloorAt(npc:GetPos() + dir * 350) or (npc:GetPos() + dir * 350)
            npc.OW_PushUntil, npc.OW_NextPush = now + 3.5, now + 6
            Log(npc, string.format("рывок к врагу (до него %.0f)", npc:GetPos():Distance(e:GetPos())))
        end
        if npc.OW_PushUntil and now < npc.OW_PushUntil then
            OW.MoveTo(npc, npc.OW_PushTarget, 100)
            return
        end
        npc.OW_PushUntil = nil
    end
    OW.Stop(npc)
end

---------------------------------------------------------------------------
-- Регистрация и отношения
---------------------------------------------------------------------------
function OW.SetupRelationships(npc)
    for other in pairs(OW.NPCs) do
        if other ~= npc and IsValid(other) and other:IsNPC() then
            local disp = (other.OW_Team == npc.OW_Team) and D_LI or D_HT
            npc:AddEntityRelationship(other, disp, 99)
            other:AddEntityRelationship(npc, disp, 99)
        end
    end
    -- Отношения с игроками (команда игрока / нейтральность) — sv_outpost_players.lua
    for _, ply in ipairs(player.GetAll()) do
        if OW.RelatePlayer then OW.RelatePlayer(npc, ply) end
    end
end

function OW.Register(npc, outpost)
    if not (IsValid(npc) and npc:IsNPC()) then return end
    if IsVJ(npc) then
        -- VJ Base определяет своих/чужих по собственным классам
        npc.VJ_NPC_Class = { "CLASS_OUTPOST_TEAM_" .. outpost:GetOPTeam() }
        npc.DisableWandering = true
    end
    npc.OW_Team = outpost:GetOPTeam()
    npc.OW_Home = outpost
    npc.OW_Role = "reserve"
    npc.OW_ReserveSince = CurTime()
    npc.OW_SpawnClass = outpost:GetNPCClass()
    npc.OW_SpawnWeapon = outpost:GetNPCWeapon()
    npc:SetNWInt("OW_Team", npc.OW_Team)
    OW.TeamSpawn = OW.TeamSpawn or {}
    OW.TeamSpawn[npc.OW_Team] = { class = npc.OW_SpawnClass, weapon = npc.OW_SpawnWeapon }
    OW.SetupRelationships(npc)
    OW.NPCs[npc] = true
end

-- Запоминаем, когда в NPC попали (см. FightingRaw)
hook.Add("EntityTakeDamage", "OutpostWar_Hurt", function(ent, dmg)
    if ent.OW_Team and OW.NPCs[ent] then ent.OW_HurtTime = CurTime() end
end)

hook.Add("PlayerInitialSpawn", "OutpostWar_IgnorePlayers", function(ply)
    for npc in pairs(OW.NPCs) do
        if IsValid(npc) and OW.RelatePlayer then OW.RelatePlayer(npc, ply) end
    end
end)

---------------------------------------------------------------------------
-- Отряды
---------------------------------------------------------------------------
function OW.CreateSquad(team, members, target, origin)
    OW.NextSquadID = OW.NextSquadID + 1
    local sq = {
        id = OW.NextSquadID, team = team, members = {},
        target = target, origin = origin, state = "march",
    }
    for _, npc in ipairs(members) do
        npc.OW_Squad = sq
        npc.OW_Role = "squad"
        npc.OW_AssaultGoal = nil
        if npc.SetSquad then npc:SetSquad("ow_squad_" .. sq.id) end
        table.insert(sq.members, npc)
    end
    OW.Squads[sq.id] = sq
    return sq
end

-- Распустить отряд: все становятся резервом аванпоста home
function OW.DisbandSquad(sq, home)
    if IsValid(sq.leaderEnt) then sq.leaderEnt:SetNWBool("OW_Leader", false) end
    if IsValid(sq.player) then sq.player.OW_Squad = nil sq.player:SetNWInt("OW_SquadCount", 0) end
    for _, npc in ipairs(sq.members) do
        if IsValid(npc) then
            npc.OW_Squad = nil
            npc.OW_Role = "reserve"
            npc.OW_ReserveSince = CurTime()
            npc.OW_Home = home
            npc.OW_AssaultGoal = nil
            npc.OW_GuardPos = nil
        end
    end
    OW.Squads[sq.id] = nil
end

-- Точка строя, до которой реально можно дойти: есть пол и от лидера до неё нет стены.
-- Иначе уменьшаем смещение, а в крайнем случае — сам лидер.
local HULL_MINS, HULL_MAXS = Vector(-16, -16, 20), Vector(16, 16, 64)
local function SafeFormationPoint(leader, offset)
    local lpos = leader:GetPos()
    for _, k in ipairs({ 1, 0.5 }) do
        local p = lpos + offset * k
        local tr = util.TraceHull({
            start = lpos, endpos = p, mins = HULL_MINS, maxs = HULL_MAXS,
            mask = MASK_NPCSOLID_BRUSHONLY, filter = leader,
        })
        if not tr.Hit then
            local f = FloorAt(p)
            if f and math.abs(f.z - lpos.z) < 40 then return f end
        end
    end
    return lpos
end

local function FormationOffset(i, n)
    local count = math.max(n - 1, 1)
    local a = (i - 2) / count * math.pi * 2
    local r = 90 + (i % 2) * 40
    return Vector(math.cos(a) * r, math.sin(a) * r, 0)
end
OW.FormationOffset = FormationOffset
OW.SafeFormationPoint = SafeFormationPoint

function OW.SquadTick(sq)
    -- убираем мёртвых
    for i = #sq.members, 1, -1 do
        local n = sq.members[i]
        if not OW.IsAlive(n) or n.OW_Squad ~= sq then table.remove(sq.members, i) end
    end
    if #sq.members == 0 then
        if sq.player and IsValid(sq.player) then return end   -- отряд игрока ждёт новых бойцов
        OW.Squads[sq.id] = nil
        return
    end
    if sq.player then return OW.PlayerSquadTick(sq) end

    local leader = sq.members[1]
    local t = sq.target

    -- Звёздочка над лидером (рисует клиент)
    if sq.leaderEnt ~= leader then
        if IsValid(sq.leaderEnt) then sq.leaderEnt:SetNWBool("OW_Leader", false) end
        leader:SetNWBool("OW_Leader", true)
        sq.leaderEnt = leader
    end

    -- Цель уже наша -> отряд становится её гарнизоном
    if IsValid(t) and t:GetOPTeam() == sq.team then
        OW.DisbandSquad(sq, t)
        return
    end
    -- Цель пропала -> ищем новую, иначе домой
    if not IsValid(t) then
        sq.target = OW.FindTarget(sq.team, leader:GetPos())
        sq.state, sq.goal = "march", nil
        if not sq.target then
            OW.DisbandSquad(sq, OW.FindHome(sq.team, leader:GetPos()))
            return
        end
        t = sq.target
    end

    local tpos = t:GetPos()
    local r = t:GetCapRadius()
    sq.goal = sq.goal or OW.RandomPointNear(tpos, r * 0.5)

    if sq.state == "march" and leader:GetPos():DistToSqr(tpos) < (r + 250) ^ 2 then
        sq.state = "assault"
    end

    -- Маршрута к цели по навмешу нет -> цель недостижима на минуту, выбираем другую
    if sq.state == "march" and leader.OW_NoRoute then
        OW.Unreachable[sq.team] = OW.Unreachable[sq.team] or {}
        OW.Unreachable[sq.team][t] = CurTime()
        for _, m in ipairs(sq.members) do m.OW_NoRoute, m.OW_Path = nil, nil end
        sq.target, sq.goal = OW.FindTarget(sq.team, leader:GetPos()), nil
        if not sq.target then OW.DisbandSquad(sq, OW.FindHome(sq.team, leader:GetPos())) end
        return
    end

    if sq.state == "march" then
        -- Лидер ждёт отставших, чтобы отряд шёл вместе
        local spread = false
        for i = 2, #sq.members do
            local m = sq.members[i]
            if m:GetPos():DistToSqr(leader:GetPos()) > 600 * 600 and not OW.IsFighting(m) then
                spread = true
                break
            end
        end

        -- ...но не дольше 6 секунд, чтобы застрявший боец не держал весь отряд
        if spread then
            sq.waitSince = sq.waitSince or CurTime()
            if CurTime() - sq.waitSince > 6 then spread = false end
            if CurTime() - sq.waitSince > 12 then sq.waitSince = nil end
        else
            sq.waitSince = nil
        end

        if OW.IsFighting(leader) then
            OW.Engage(leader)
        elseif spread then
            OW.Stop(leader)
        else
            OW.MoveTo(leader, sq.goal)
        end

        local lpos = leader:GetPos()
        for i = 2, #sq.members do
            local m = sq.members[i]
            if OW.IsFighting(m) then
                OW.Engage(m)
            else
                local goal = SafeFormationPoint(leader, FormationOffset(i, #sq.members))
                if m:GetPos():DistToSqr(goal) > 140 * 140 then
                    OW.MoveTo(m, goal, 200)
                end
            end
        end
    else -- assault: заходим в зону захвата и держим её
        for _, m in ipairs(sq.members) do
            if OW.IsFighting(m) then
                OW.Engage(m)
            elseif m:GetPos():DistToSqr(tpos) > (r * 0.8) ^ 2 then
                m.OW_AssaultGoal = m.OW_AssaultGoal or OW.RandomPointNear(tpos, r * 0.6)
                OW.MoveTo(m, m.OW_AssaultGoal)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Охрана (гарнизон и резерв, не состоящие в отряде)
---------------------------------------------------------------------------
function OW.GuardTick(npc)
    local home = npc.OW_Home
    if not IsValid(home) or home:GetOPTeam() ~= npc.OW_Team then
        home = OW.FindHome(npc.OW_Team, npc:GetPos())
        npc.OW_Home, npc.OW_Role, npc.OW_GuardPos = home, "reserve", nil
        if not home then
            -- Своих аванпостов нет — идём в атаку
            local target = OW.FindTarget(npc.OW_Team, npc:GetPos())
            if target then OW.CreateSquad(npc.OW_Team, { npc }, target) end
            return
        end
    end

    if OW.IsFighting(npc) then OW.Engage(npc) return end

    local hpos = home:GetPos()
    local r = home:GetCapRadius()
    if npc:GetPos():DistToSqr(hpos) > (r * 0.9) ^ 2 then
        npc.OW_GuardPos = npc.OW_GuardPos or OW.RandomPointNear(hpos, r * 0.6)
        OW.MoveTo(npc, npc.OW_GuardPos)
    elseif npc.OW_GuardPos and npc:GetPos():DistToSqr(npc.OW_GuardPos) < 80 * 80 then
        npc.OW_GuardPos = nil
        OW.Stop(npc)
    end
end

---------------------------------------------------------------------------
-- Двери: NPC под нашим приказом сами двери не открывают — открываем за них
---------------------------------------------------------------------------
local DOOR_CLASSES = { prop_door_rotating = true, func_door = true, func_door_rotating = true }

local function DoorIsClosed(door)
    if door:GetClass() == "prop_door_rotating" then
        local st = door:GetInternalVariable("m_eDoorState")
        return st == 0 or st == 3
    end
    local st = door:GetInternalVariable("m_toggle_state")
    return st == 1 or st == 3
end

-- Стекло: навмеш (nav_generate) считает его проходимым, поэтому маршрут может
-- идти сквозь окно. Если NPC упирается в стекло — разбиваем его.
local GLASS_CLASSES = { func_breakable_surf = true, func_breakable = true }

local function BreakGlass(npc, dir)
    local start = npc:WorldSpaceCenter()
    local tr = util.TraceLine({ start = start, endpos = start + dir * 90, filter = npc })
    local ent = tr.Entity
    if not (IsValid(ent) and GLASS_CLASSES[ent:GetClass()]) then return end
    if ent.OW_Broken then return end
    ent.OW_Broken = true
    if ent:GetClass() == "func_breakable_surf" then
        ent:Fire("Shatter", "0.5 0.5 200")
    else
        ent:Fire("Break")
    end
    OW.Log(npc, "разбил стекло " .. ent:GetClass())
end

function OW.DoorTick()
    local doors = OW.CVars.open_doors and OW.CVars.open_doors:GetBool()
    local glass = OW.CVars.break_glass and OW.CVars.break_glass:GetBool()
    if not doors and not glass then return end
    local now = CurTime()
    for npc in pairs(OW.NPCs) do
        if IsValid(npc) and npc.OW_Target then
            local pos = npc:GetPos()
            local dir = npc.OW_Target - pos
            dir.z = 0
            if dir:LengthSqr() > 1 then
                dir:Normalize()
                if glass then BreakGlass(npc, dir) end
                if doors then
                for _, door in ipairs(ents.FindInSphere(pos + dir * 50 + Vector(0, 0, 40), 70)) do
                    if DOOR_CLASSES[door:GetClass()] and now >= (door.OW_NextOpen or 0) and DoorIsClosed(door) then
                        door.OW_NextOpen = now + 2
                        local locked = door:GetInternalVariable("m_bLocked")
                        if not locked or OW.CVars.unlock_doors:GetBool() then
                            if locked then door:Fire("Unlock") end
                            if door:GetClass() == "prop_door_rotating" then
                                if npc:GetName() == "" then npc:SetName("ow_npc_" .. npc:EntIndex()) end
                                door:Fire("OpenAwayFrom", npc:GetName())
                            else
                                door:Fire("Open")
                            end
                        end
                    end
                end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Главный цикл
---------------------------------------------------------------------------
function OW.Tick()
    for npc in pairs(OW.NPCs) do
        if not OW.IsAlive(npc) then OW.NPCs[npc] = nil end
    end

    if OW.PlayersTick then OW.PlayersTick() end   -- набор бойцов в отряды игроков

    for _, op in ipairs(OW.GetOutposts()) do
        if op.BrainTick then op:BrainTick() end
    end

    for _, sq in pairs(OW.Squads) do OW.SquadTick(sq) end

    for npc in pairs(OW.NPCs) do
        if not npc.OW_Squad then OW.GuardTick(npc) end
    end

    OW.DoorTick()
    OW.DebugDraw()
end

timer.Create("OutpostWar_Tick", 0.5, 0, function()
    local ok, err = pcall(OW.Tick)
    if not ok then ErrorNoHalt("[OutpostWar] " .. tostring(err) .. "\n") end
end)

concommand.Add("outpost_war_clear_npcs", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    for npc in pairs(OW.NPCs) do
        if IsValid(npc) then npc:Remove() end
    end
    OW.NPCs, OW.Squads = {}, {}
end)

MsgN("[Outpost War] sv_outpost_war.lua загружен — движение v12 (отрезки по 200)")
