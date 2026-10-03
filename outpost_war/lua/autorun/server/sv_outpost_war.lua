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
-- Только на том же этаже, что и center: раньше точка у края балкона/площадки
-- (луч вниз на 256) могла попасть на пол этажом ниже — и отряд шёл под аванпост.
local function FloorZ(p)
    local tr = util.TraceLine({ start = p + Vector(0, 0, 40), endpos = p - Vector(0, 0, 256),
        mask = MASK_NPCSOLID_BRUSHONLY })
    return (tr.Hit and not tr.StartSolid) and tr.HitPos.z or p.z
end
OW.FloorZ = FloorZ

function OW.RandomPointNear(center, radius)
    local cz = FloorZ(center)
    for _ = 1, 12 do
        local a = math.Rand(0, math.pi * 2)
        local d = math.Rand(radius * 0.3, radius)
        local p = center + Vector(math.cos(a) * d, math.sin(a) * d, 0)
        local tr = util.TraceLine({
            start = p + Vector(0, 0, 64), endpos = p - Vector(0, 0, 256),
            mask = MASK_NPCSOLID_BRUSHONLY,
        })
        if tr.Hit and not tr.StartSolid and math.abs(tr.HitPos.z - cz) < math.max(48, d * 0.35) then  -- склон допустим, обрыв нет
            local vis = util.TraceHull({
                start = center + Vector(0, 0, 40), endpos = tr.HitPos + Vector(0, 0, 40),
                mins = Vector(-8, -8, -8), maxs = Vector(8, 8, 8),
                mask = MASK_NPCSOLID, filter = OW.WalkFilter,   -- заборы и пропы тоже мешают
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
    return (npc.OW_UseWalk or (npc.OW_SlowWalk and npc.OW_Squad)) and SCHED_FORCED_GO or SCHED_FORCED_GO_RUN
end

-- NPC из VJ Base: свой ИИ на Lua, двигать их нужно функциями VJ Base
local function IsVJ(npc)
    return npc.IsVJBaseSNPC == true
end

local function IsMoving(npc)
    if IsVJ(npc) then
        -- у VJ свои Lua-расписания: смотрим на реальное движение, и даём секунду на разгон
        if CurTime() - (npc.OW_IssueTime or 0) < 1 then return true end
        return (npc.IsMoving and npc:IsMoving()) or npc:GetVelocity():Length2DSqr() > 400
    end
    return npc:IsCurrentSchedule(SCHED_FORCED_GO_RUN) or npc:IsCurrentSchedule(SCHED_FORCED_GO)
end

-- VJ-NPC двигаем двумя способами по очереди: командой VJ Base и обычным приказом движка.
-- По журналу команда VJ у некоторых NPC (Soviet Spetsnaz) не срабатывает вообще —
-- после провала пробуем другой способ.
-- Возвращает true, если приказ обновлён "на ходу" (без перезапуска расписания).
-- По журналу: половина приказов выдавалась NPC, который уже бежал, и каждый SetSchedule
-- перезапускал движение — NPC на миг вставал (act=1) и снова разгонялся: ходьба рывками.
local function IssueMove(npc, target)
    npc:SetLastPosition(target)
    npc.OW_IssueTime = CurTime()
    if IsVJ(npc) and not npc.OW_VJEngine then
        local task = (npc.OW_UseWalk or (npc.OW_SlowWalk and npc.OW_Squad)) and "TASK_WALK_PATH" or "TASK_RUN_PATH"
        if npc.SCHEDULE_GOTO_POSITION then npc:SCHEDULE_GOTO_POSITION(task) return false end
        if npc.VJ_TASK_GOTO_LASTPOS then npc:VJ_TASK_GOTO_LASTPOS(task) return false end
    end
    local sched = MoveSched(npc)
    -- (v23-v24 пробовали менять цель "на ходу" через NavSetGoal — по журналу v24 это вело
    -- NPC к ближайшему AI-ноду карты, т.е. куда-то в сторону, иногда на сотни юнитов назад.
    -- Убрано.)
    npc:SetSchedule(sched)
    return false
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
    role = "к" .. tostring(npc.OW_Team) .. " " .. role
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
    -- Короткие шаги, если NPC "уходит от точки": по журналу v26 на карте с AI-нодами движок
    -- на 200+ юнитов часто ведёт NPC по нодам — сначала к ближайшему ноду, а он позади.
    -- NPC раз за разом убегал ровно в обратную сторону. На 90 юнитов движок идёт напрямую.
    local STEP = (npc.OW_AwayUntil or 0) > CurTime() and 90 or STEP
    if dir:Length() <= STEP then return goal end

    local baseYaw = dir:Angle().y
    -- раньше разброс доходил до 90° — NPC уходили вбок "без причины"
    local jitter = math.min(fails * 8, 40)
    local mins, maxs = Vector(-16, -16, 20), Vector(16, 16, 64) -- z от 20: ступеньки не мешают
    local best, bestScore

    for _, off in ipairs({ 0, 25, -25, 50, -50, 80, -80, 115, -115 }) do
        local yaw = baseYaw + off + math.Rand(-jitter, jitter) * (off == 0 and 0.3 or 1)
        local fwd = Angle(0, yaw, 0):Forward()
        local tr = util.TraceHull({
            start = from, endpos = from + fwd * STEP,
            mins = mins, maxs = maxs, mask = MASK_NPCSOLID, filter = OW.WalkFilter,
        })
        local len = tr.Fraction * STEP
        if len > STEP * 0.55 then
            local p = FloorAt(from + fwd * math.max(len - 32, len * 0.7))
            -- не спрыгивать этажом ниже (с балкона/площадки), если сама цель не ниже
            if p and p.z < from.z - 64 and goal.z > from.z - 64 then p = nil end
            if p then
                local score = len * math.cos(math.rad(yaw - baseYaw))
                if not bestScore or score > bestScore then best, bestScore = p, score end
                if off == 0 and len >= STEP * 0.9 then break end
            end
        end
    end
    return best or goal
end

-- "Дошёл до точки": близко по горизонтали И на том же уровне. Раньше считали просто
-- расстояние — и NPC этажом ниже "доходил" до точки над потолком (до неё всего ~100-150).
local function Reached(a, b, r)
    return math.abs(a.z - b.z) < 64 and (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 < r * r
end
OW.Reached = Reached

-- Прямой приказ: маршрут строит движок; если не смог — идём "шагами".
-- Впереди (в сторону target, ближе 90) стоит другой NPC или игрок?
-- По журналу: в толпе у лестницы/проёма движок сразу отказывается строить путь
-- (провал, running=false) — проход занят своими. Раньше на это включались "шаги" в
-- случайные стороны, и толпа расползалась (в т.ч. в соседние комнаты, линии "сквозь стену").
local function CrowdAhead(npc, target)
    local p = npc:GetPos()
    local dir = target - p
    dir.z = 0
    if dir:LengthSqr() < 1 then return false end
    dir:Normalize()
    for _, e in ipairs(ents.FindInSphere(p, 90)) do
        -- идущий впереди (движется) не помеха — за ним просто идём; ждём только стоящих
        if e ~= npc and (e:IsNPC() or e:IsPlayer()) and (not e.Health or e:Health() > 0)
           and e:GetVelocity():Length2DSqr() < 40 * 40 then
            local d = e:GetPos() - p
            d.z = 0
            if d:LengthSqr() > 1 then
                d:Normalize()
                if d:Dot(dir) > 0.3 then return true end
            end
        end
    end
    return false
end

-- Вызывается каждый тик; сам решает, надо ли перевыдавать приказ.
local function DirectMove(npc, pos, tolerance)
    tolerance = tolerance or 100
    local now = CurTime()
    local mypos = npc:GetPos()
    -- ждём своей очереди в толпе / уступили манёвр боевому ИИ
    if (npc.OW_WaitUntil or 0) > now then return end
    if (npc.OW_YieldUntil or 0) > now then
        npc.OW_SPos, npc.OW_STime = mypos, now   -- это не застревание
        return
    end
    local running = IsMoving(npc)
    local sameGoal = npc.OW_Goal ~= nil and npc.OW_Goal:DistToSqr(pos) < tolerance * tolerance
    local failed = false

    -- Куда NPC ведёт движок на самом деле. По журналу v27 лидер бежал от точки даже при
    -- шагах в 63 юнита — так не бывает при нашем приказе. Значит, цель движения подменяет
    -- кто-то ещё: другой мод на ИИ (они часто используют те же SetLastPosition +
    -- SCHED_FORCED_GO_RUN) или сам ИИ NPC. Проверяем цель навигации и пишем в журнал.
    local overridden = false
    if running and npc.OW_Target and npc.GetGoalPos and not IsVJ(npc) then
        local gp = npc:GetGoalPos()
        if gp and gp ~= vector_origin and gp:DistToSqr(npc.OW_Target) > 80 * 80 then
            overridden = true
            if (npc.OW_LastOverrideLog or 0) + 2 < now then
                npc.OW_LastOverrideLog = now
                Log(npc, string.format("ЦЕЛЬ ПОДМЕНЕНА: движок ведёт к [%d %d %d], а наша [%d %d %d]",
                    gp.x, gp.y, gp.z, npc.OW_Target.x, npc.OW_Target.y, npc.OW_Target.z))
            end
        end
    end
    -- Совместимость с модами на боевой ИИ (Combat Intelligence AI и т.п.): по журналу v28
    -- они 274 раза уводили NPC на свои манёвры (фланг, укрытие). Если рядом враг — это их
    -- тактика: уступаем на 6 с и не перебиваем. Без врага — возвращаем свой приказ.
    local en = npc.GetEnemy and npc:GetEnemy()
    local enemyNear = IsValid(en) and en:GetPos():DistToSqr(mypos) < 2500 * 2500
    if overridden and enemyNear then
        npc.OW_YieldUntil = now + 6
        Log(npc, "уступаю чужому боевому ИИ на 6 с")
        return
    end
    if overridden then
        -- выдаём свой приказ заново (без счёта провалов)
        npc.OW_LastPos, npc.OW_LastMove, npc.OW_BestD = mypos, now, nil
        IssueMove(npc, npc.OW_Target)
        return
    end

    if running and npc.OW_Target then
        -- Бежит, но УДАЛЯЕТСЯ от точки. По журналу v25: лидер с приказом "на 350 юнитов на юг"
        -- бежал на север (y 4049 -> 6181) — движок вёл его своим путём по AI-нодам карты
        -- в обход. Такое считаем провалом -> короткие "шаги" по прямой.
        local d = mypos:Distance(npc.OW_Target)
        npc.OW_BestD = math.min(npc.OW_BestD or d, d)
        if d > npc.OW_BestD + 120 then
            failed = true
            Log(npc, string.format("уходит от точки: было %.0f, стало %.0f", npc.OW_BestD, d))
            npc.OW_AwayUntil = now + 10     -- 10 с — короткие шаги по 90
        end
    end
    if running then
        -- Застрял: бежит, но почти не двигается 4 секунды
        if failed then
            -- уже провал (уходит от точки)
        elseif not npc.OW_LastPos or mypos:DistToSqr(npc.OW_LastPos) > 30 * 30 then
            npc.OW_LastPos, npc.OW_LastMove = mypos, now
        elseif now - (npc.OW_LastMove or now) > 4 then
            failed = true
        end
    elseif npc.OW_Target then
        -- Приказ закончился, а до точки далеко -> маршрут не построился.
        -- (tolerance > 150 — например, точка строя: подойти "примерно" достаточно)
        local arrive = math.max(150, tolerance)
        local en = npc.GetEnemy and npc:GetEnemy()
        if npc.OW_Retry then
            npc.OW_Retry = nil          -- после ожидания в толпе — просто новый приказ
        elseif not Reached(mypos, npc.OW_Target, arrive) and IsValid(en) and not IsVJ(npc) then
            -- По журналу v24: приказ сбивал собственный боевой ИИ NPC (видит врага дальше
            -- дистанции боя -> укрытие/перебежка, sched 51/92/97). Это не провал маршрута:
            -- раньше тут включались "шаги" и NPC уходил вбок. Просто выдаём приказ снова.
            if en:GetPos():DistToSqr(mypos) < 2500 * 2500 then
                -- враг близко: это манёвр ИИ NPC / мода на ИИ — не мешаем 6 с
                npc.OW_YieldUntil = now + 6
                npc.OW_Retry = true
                Log(npc, string.format("приказ сбит боевым ИИ (враг на %.0f) -> уступаю 6 с", mypos:Distance(en:GetPos())))
                return
            end
            if (npc.OW_LastInterruptLog or 0) + 3 < now then
                npc.OW_LastInterruptLog = now
                Log(npc, string.format("приказ сбит боевым ИИ (враг на %.0f) -> повтор", mypos:Distance(en:GetPos())))
            end
        elseif not Reached(mypos, npc.OW_Target, arrive) then
            failed = true
        else
            npc.OW_Fail = 0
            npc.OW_UseWalk = nil   -- дошли: снова бегом (раньше после 4 провалов NPC шёл шагом навсегда)
        end
    end

    if running and sameGoal and not failed then
        -- В режиме шагов выдаём следующий шаг, когда почти дошли до текущего
        local near = (npc.OW_AwayUntil or 0) > now and 45 or 90
        if not npc.OW_Stepping or mypos:DistToSqr(npc.OW_Target) > near * near then return end
    end

    -- Провал из-за толпы впереди — не провал маршрута: ждём секунду и пробуем снова
    if failed and npc.OW_Target and CrowdAhead(npc, npc.OW_Target) then
        npc.OW_WaitUntil = now + math.Rand(0.6, 1.4)
        npc.OW_LastWait = now
        npc.OW_Retry = true
        npc.OW_Goal, npc.OW_Target = pos, pos
        -- пока ждём — смотрим туда, куда идём (а не назад на толпу)
        if npc.SetIdealYawAndUpdate then
            npc:SetIdealYawAndUpdate((npc.OW_Target - mypos):Angle().y)
        end
        Log(npc, "жду: впереди свои")
        return
    end

    if failed then
        Log(npc, string.format("провал #%d: running=%s, до точки %.0f (по высоте %+.0f)", (npc.OW_Fail or 0) + 1,
            tostring(running), npc.OW_Target and mypos:Distance(npc.OW_Target) or -1,
            npc.OW_Target and (npc.OW_Target.z - mypos.z) or 0))
        npc.OW_Fail = (npc.OW_Fail or 0) + 1
        if IsVJ(npc) then npc.OW_VJEngine = not npc.OW_VJEngine end
        npc.OW_StepUntil = now + ((npc.OW_AwayUntil or 0) > now and 10 or 3)   -- сек идём шагами
        if npc.OW_Fail % 4 == 0 then npc.OW_UseWalk = not npc.OW_UseWalk end
    end

    local target = pos
    npc.OW_Stepping = (npc.OW_StepUntil or 0) > now
    if npc.OW_Stepping then target = StepPoint(npc, pos, npc.OW_Fail or 0) end

    npc.OW_Goal, npc.OW_Target = pos, target
    npc.OW_LastPos, npc.OW_LastMove = mypos, now
    npc.OW_BestD = nil
    local smooth = IssueMove(npc, target)
    Log(npc, string.format("приказ%s: до точки %.0f (по высоте %+.0f) [%d %d %d]%s%s, running до этого=%s, pos=%d %d %d",
        smooth and " на ходу" or "", mypos:Distance(target), target.z - mypos.z, target.x, target.y, target.z,
        npc.OW_Stepping and " (шаг)" or "", IsVJ(npc) and (npc.OW_VJEngine and " [движок]" or " [VJ]") or "",
        tostring(running), mypos.x, mypos.y, mypos.z))
end

-- Отправить NPC к точке pos. Если далеко и на карте есть навмеш — идём по маршруту
-- по навмешу (sv_outpost_path.lua, белые линии в отладке), иначе — прямым приказом.
local PATH_MIN_DIST = 450

-- Выход из тупика: если NPC 8 секунд почти не сдвигается, хотя получает приказы идти,
-- отводим его на пару метров в свободную сторону и перестраиваем маршрут.
local function Unstick(npc)
    local now, p = CurTime(), npc:GetPos()
    if npc.OW_UnstickUntil and now < npc.OW_UnstickUntil then return true end
    -- приказы шли с перерывом (NPC стоял по своей воле) — считаем заново
    local gap = now - (npc.OW_LastMoveCall or 0) > 1.5
    npc.OW_LastMoveCall = now
    if gap or not npc.OW_SPos or p:DistToSqr(npc.OW_SPos) > 60 * 60 then
        npc.OW_SPos, npc.OW_STime = p, now
        return false
    end
    -- в очереди (толпа впереди) терпим дольше, иначе отход разгоняет толпу по комнатам
    local limit = (now - (npc.OW_LastWait or -100) < 3) and 20 or 8
    if now - (npc.OW_STime or now) < limit then return false end
    npc.OW_STime = now
    for _ = 1, 10 do
        local dir = Angle(0, math.Rand(0, 360), 0):Forward()
        local tr = util.TraceHull({
            start = p + Vector(0, 0, 4), endpos = p + dir * 200 + Vector(0, 0, 4),
            mins = Vector(-16, -16, 18), maxs = Vector(16, 16, 64),
            mask = MASK_NPCSOLID, filter = OW.WalkFilter,
        })
        if tr.Fraction > 0.5 then
            local f = FloorAt(p + dir * 200 * tr.Fraction * 0.9)
            if f then
                Log(npc, string.format("застрял 8 с -> отход на %.0f", 200 * tr.Fraction * 0.9))
                if npc.OW_Path then npc.OW_Path.failed = true end
                npc.OW_NextRepath, npc.OW_Fail = 0, 0
                npc.OW_Goal, npc.OW_Target = nil, f
                npc.OW_UnstickUntil = now + 2.5
                IssueMove(npc, f)
                return true
            end
        end
    end
    return false
end

function OW.MoveTo(npc, pos, tolerance)
    if Unstick(npc) then return end
    local mypos = npc:GetPos()
    local P = OW.Path

    -- Близкую точку — напрямую; но если напрямую дважды не вышло (например, за забором
    -- и надо обойти через калитку), тоже строим маршрут по навмешу.
    -- Точка на другом этаже (над потолком, внизу под балконом) — всегда по навмешу:
    -- напрямую движок туда не дойдёт, а "шаги" идут прямо к ней — красная линия в потолок.
    local near = mypos:DistToSqr(pos) < PATH_MIN_DIST * PATH_MIN_DIST and (npc.OW_Fail or 0) < 2
        and math.abs(pos.z - mypos.z) < 48
        and not npc.OW_Path
    if not (P and P.Available()) or near then
        npc.OW_Path, npc.OW_NoRoute = nil, nil
        return DirectMove(npc, pos, tolerance)
    end

    local now = CurTime()
    local path = npc.OW_Path
    local need = not path or path.failed or path.goal:DistToSqr(pos) > 300 * 300
        or (path.wps[path.idx] and mypos:DistToSqr(path.wps[path.idx]) > 900 * 900)

    if need and now >= (npc.OW_NextRepath or 0) then
        -- своя полоса у каждого NPC (постоянная, по номеру сущности): -1, -0.5, 0, 0.5, 1
        npc.OW_Lane = npc.OW_Lane or ((npc:EntIndex() * 7) % 5 - 2) / 2
        local status, res = P.Request(mypos, pos, npc.OW_Lane)
        if status == "pending" then
            npc.OW_NextRepath = now + 0.2
        elseif status == "ok" and #res > 0 then
            path = { goal = pos, wps = res, idx = 1 }
            if cv_debug:GetInt() >= 2 then
                local zs = {}
                for i = 1, math.min(#res, 12) do zs[i] = string.format("%d", res[i].z) end
                Log(npc, string.format("маршрут: %d точек, я z=%d, цель z=%d, z точек: %s; области старт/цель z=%s/%s",
                    #res, mypos.z, pos.z, table.concat(zs, " "), tostring(P.LastStartZ), tostring(P.LastGoalZ)))
            end
            npc.OW_Path, npc.OW_NoRoute, npc.OW_Fail = path, nil, 0
            npc.OW_NextRepath = now + 2
        else
            path = nil
            if npc.OW_NoRouteReason ~= res then
                Log(npc, string.format("нет маршрута: %s (я %d %d %d, цель %d %d %d)", tostring(res),
                    mypos.x, mypos.y, mypos.z, pos.x, pos.y, pos.z))
            end
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
        if math.abs(wp.z - mypos.z) > 64 then d2 = math.huge end   -- точка этажом выше/ниже — не дошли
        -- следующую точку выдаём заранее (за 120 юнитов), чтобы NPC не останавливался
        -- 160 — не меньше порога "дошёл" (150) в DirectMove. Раньше было 120: у стены/угла NPC
        -- (особенно VJ) вставал в ~140 от точки, считал её достигнутой, а маршрут не шёл дальше.
        -- На лестнице (точки на разной высоте) заранее не переключаемся: иначе NPC срезает
        -- разворот лестницы и упирается в перила. Там — только когда реально дошёл
        -- (48), или прямая до следующей точки свободна, или NPC уже остановился у точки.
        local nxt = path.wps[path.idx + 1]
        local stairs = math.abs(nxt.z - wp.z) > 24 or math.abs(wp.z - mypos.z) > 24
        local clear = d2 < 220 * 220 and P.ClearWalk(mypos, nxt)
        if stairs and clear and P.MaxDeviation({ mypos, wp, nxt }, 1, 3) > 40 then clear = false end
        if d2 < 48 * 48 or clear or (d2 < 160 * 160 and (not stairs or not IsMoving(npc))) then
            path.idx = path.idx + 1
        else
            break
        end
    end

    local wp = path.idx == #path.wps and pos or path.wps[path.idx]
    if path.idx == #path.wps and Reached(mypos, pos, 150) then
        npc.OW_Path = nil   -- дошли: дальше снова напрямую
    end
    DirectMove(npc, wp, 30)

    if (npc.OW_Fail or 0) >= 2 then path.failed = true end
    -- 4 провала подряд у одной точки: там, видимо, проп (забор, ворота), который навмеш
    -- считает проходимым. Закрываем это место для маршрутов на минуту -> обход.
    -- Закрываем, только если путь к точке действительно перегораживает проп (а не толпа/стена).
    local blocker
    if (npc.OW_Fail or 0) >= 4 then
        local tr = util.TraceHull({
            start = mypos + Vector(0, 0, 4), endpos = wp + Vector(0, 0, 4),
            mins = Vector(-16, -16, 20), maxs = Vector(16, 16, 64),
            mask = MASK_NPCSOLID, filter = OW.WalkFilter,
        })
        blocker = tr.Hit and IsValid(tr.Entity) and not tr.Entity:IsWorld()
        if not blocker then npc.OW_Fail = 0 end
    end
    if blocker and P.BlockAt then
        P.BlockAt(wp, 48)
        npc.OW_Fail, npc.OW_NextRepath = 0, 0
        Log(npc, string.format("точка маршрута недостижима -> закрыта на 60 с (%d %d)", wp.x, wp.y))
    end
end

-- Прервать наш приказ движения (чтобы NPC мог стрелять / стоять)
function OW.Stop(npc)
    if IsMoving(npc) then StopMove(npc) end
    npc.OW_Goal, npc.OW_Target = nil, nil
    npc.OW_SPos, npc.OW_STime = npc:GetPos(), CurTime()   -- стоять по приказу — не застревание
end

function OW.DebugDraw()
    if not cv_debug:GetBool() then return end
    for npc in pairs(OW.NPCs) do
        if IsValid(npc) and not npc.OW_Passive then
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
            if OW.IsFighting(npc) then
                label = label .. " БОЙ"
            elseif npc.GetEnemy and IsValid(npc:GetEnemy()) then
                -- враг есть, но дальше дистанции боя: стреляет на ходу, марш не прерывает
                label = label .. string.format(" (враг %.0f)", npc:GetPos():Distance(npc:GetEnemy():GetPos()))
            end
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
    if not npc.GetEnemy then return false end
    local e = npc:GetEnemy()
    -- Врага больше нет (убит / потерян ИИ): боевая готовность ещё combat_linger секунд —
    -- NPC остаётся под своим ИИ (осматривается, добивает, ищет), марш не возобновляется.
    -- Раньше бой заканчивался сразу, как только ИИ сбрасывал врага.
    if not IsValid(e) or (e.Health and e:Health() <= 0) then
        local linger = OW.CVars.combat_linger and OW.CVars.combat_linger:GetFloat() or 0
        return npc.OW_LastCombat ~= nil and CurTime() - npc.OW_LastCombat < linger
    end
    local range = OW.CVars.engage_dist and OW.CVars.engage_dist:GetFloat() or 800
    local d = npc:GetPos():DistToSqr(e:GetPos())
    -- в NPC недавно попали — отвечает огнём на любой дистанции
    local hurt = npc.OW_HurtTime and CurTime() - npc.OW_HurtTime < 3
    -- Свой бой NPC: в бою, когда его собственный ИИ может стрелять по врагу (оружие достаёт,
    -- враг виден) — дистанцию решает игра/оружие, а не мод. Пока в бою, мод ничего не
    -- приказывает, поэтому моды на тактику (фланги, укрытия) работают как обычно.
    local native = OW.CVars.native_combat and OW.CVars.native_combat:GetBool() and not IsVJ(npc)
        and npc.HasCondition and COND_CAN_RANGE_ATTACK1
    -- VJ Base: в "своём бою" решает сам VJ. Если ИИ VJ выбрал врага (у него своя дальность
    -- зрения и свои правила) — NPC в бою, мод не вмешивается. Никаких наших дистанций.
    -- Но VJ помнит врага и "знает" где он даже сквозь стены: без AI-нод VJ-NPC не может к
    -- нему пройти и просто стоит, глядя в стену. Поэтому бой — только когда VJ реально
    -- ВИДИТ врага в пределах СВОЕЙ дальности зрения (SightDistance VJ), враг вплотную или в
    -- NPC попали. Иначе — после боевой готовности мод снова ведёт его по маршруту.
    if IsVJ(npc) and OW.CVars.native_combat and OW.CVars.native_combat:GetBool() then
        local sight = tonumber(npc.SightDistance) or 10000
        if (d <= sight * sight and npc:Visible(e)) or d < 250 * 250 or hurt then
            npc.OW_LastCombat = CurTime()
            return true
        end
        local linger = OW.CVars.combat_linger and OW.CVars.combat_linger:GetFloat() or 0
        return npc.OW_LastCombat ~= nil and CurTime() - npc.OW_LastCombat < linger
    end
    if native then
        local can = npc:HasCondition(COND_CAN_RANGE_ATTACK1)
            or (COND_CAN_MELEE_ATTACK1 and npc:HasCondition(COND_CAN_MELEE_ATTACK1))
            or (COND_CAN_RANGE_ATTACK2 and npc:HasCondition(COND_CAN_RANGE_ATTACK2))
        if can or (hurt and npc:Visible(e)) or d < 400 * 400 then
            npc.OW_LastCombat = CurTime()
            return true
        end
    elseif (d <= range * range or hurt) and (d < 600 * 600 or npc:Visible(e)) then
        npc.OW_LastCombat = CurTime()
        return true
    end
    local linger = OW.CVars.combat_linger and OW.CVars.combat_linger:GetFloat() or 0
    -- в своём бою дистанцию не ограничиваем (дальнобойное оружие), только совсем далёкого врага
    local lr = native and 3000 or range * 1.3
    return npc.OW_LastCombat ~= nil and CurTime() - npc.OW_LastCombat < math.max(linger, native and 3 or 0)
        and d <= lr * lr
end

function OW.IsFighting(npc)
    local f = FightingRaw(npc)
    if f and not npc.OW_CombatSince then
        npc.OW_CombatSince = CurTime()
        local e = npc:GetEnemy()
        Log(npc, string.format("БОЙ начат: враг %s (к%s) на %.0f, виден=%s", IsValid(e) and e:GetClass() or "?",
            IsValid(e) and tostring(e.OW_Team or (e.IsPlayer and e:IsPlayer() and e:GetNWInt("OW_Team", 0)) or "-") or "?",
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
    -- VJ Base сам подходит к врагу и атакует (рыцари, монстры ближнего боя). Раньше мод каждые
    -- полсекунды вызывал StopMoving() — VJ-NPC стояли и смотрели на врага издалека.
    -- Теперь: один раз снимаем наш приказ движения и дальше не мешаем.
    if IsVJ(npc) then
        if npc.OW_Goal or npc.OW_Target then
            if npc:IsCurrentSchedule(SCHED_FORCED_GO_RUN) or npc:IsCurrentSchedule(SCHED_FORCED_GO) then
                if npc.ClearSchedule then npc:ClearSchedule() end
            end
            npc.OW_Goal, npc.OW_Target, npc.OW_Path = nil, nil, nil
            Log(npc, "VJ: бой отдан ИИ VJ Base")
        end
        return
    end
    -- в режиме "свой бой" рывков не делаем: тактика целиком на ИИ NPC (и модах на него)
    local native = OW.CVars.native_combat and OW.CVars.native_combat:GetBool() and not IsVJ(npc)
    if not native and IsValid(e) and npc.OW_CombatSince and now - npc.OW_CombatSince > 5
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
-- Отношение VJ-NPC к сущности: VJ Base (ai/core.lua, MaintainRelationships) берёт его из
-- RelationshipMemory[ent]["override_disposition"] раньше всех своих правил (классы, союзники).
-- disp = nil — снять переопределение (VJ решает сам).
function OW.VJOverride(npc, ent, disp)
    if not (IsValid(npc) and npc.IsVJBaseSNPC and npc.SetRelationshipMemory and npc.RelationshipMemory) then return end
    local key = (VJ and VJ.MEM_OVERRIDE_DISPOSITION) or "override_disposition"
    npc:SetRelationshipMemory(ent, key, disp)
    if disp and disp ~= D_HT and npc.GetEnemy and npc:GetEnemy() == ent and npc.ResetEnemy then
        npc:ResetEnemy(true, false)
    end
end

function OW.SetupRelationships(npc)
    for other in pairs(OW.NPCs) do
        if other ~= npc and IsValid(other) and other:IsNPC() then
            local disp = (other.OW_Team == npc.OW_Team) and D_LI or D_HT
            npc:AddEntityRelationship(other, disp, 99)
            other:AddEntityRelationship(npc, disp, 99)
            -- VJ Base не слушает AddEntityRelationship: у него своя "память отношений".
            -- Ставим жёсткое переопределение (то же делает меню VJ "сделать союзником").
            OW.VJOverride(npc, other, disp)
            OW.VJOverride(other, npc, disp)
        end
    end
    -- Отношения с игроками (команда игрока / нейтральность) — sv_outpost_players.lua
    for _, ply in ipairs(player.GetAll()) do
        if OW.RelatePlayer then OW.RelatePlayer(npc, ply) end
    end
end

function OW.Register(npc, outpost)
    if not IsValid(npc) then return end
    if not npc:IsNPC() then
        -- некстбот и т.п.: считается в лимитах и захвате, но приказов не получает
        npc.OW_Team, npc.OW_Home, npc.OW_Role, npc.OW_Passive = outpost:GetOPTeam(), outpost, "passive", true
        npc:SetNWInt("OW_Team", npc.OW_Team)
        OW.NPCs[npc] = true
        return
    end
    -- Класс команды для VJ Base ставим ВСЕМ NPC аванпоста, не только VJ: VJ сравнивает свой
    -- класс с VJ_NPC_Class других. Без этого VJ считал обычных NPC своей команды (комбайнов)
    -- врагами по их родному классу и убивал их.
    npc.VJ_NPC_Class = { "CLASS_OUTPOST_TEAM_" .. outpost:GetOPTeam() }
    npc.OW_Team = outpost:GetOPTeam()
    if IsVJ(npc) then
        npc.DisableWandering = true
        -- своё "дружит со всеми игроками" у VJ-NPC отключаем: кто свой — решает команда
        -- (класс игрока выставляет OW.UpdatePlayerVJ)
        npc.PlayerFriendly = false
        npc.FriendsWithAllPlayerAllies = false
    end
    npc.OW_Team = outpost:GetOPTeam()
    npc.OW_Home = outpost
    npc.OW_Role = "reserve"
    npc.OW_ReserveSince = CurTime()
    npc.OW_SpawnClass = outpost:GetNPCClass()
    npc.OW_SpawnWeapon = outpost:GetNPCWeapon()
    npc.OW_SpawnMix = outpost.GetMix and outpost:GetMix() or ""
    npc:SetNWInt("OW_Team", npc.OW_Team)
    OW.TeamSpawn = OW.TeamSpawn or {}
    OW.TeamSpawn[npc.OW_Team] = { class = npc.OW_SpawnClass, weapon = npc.OW_SpawnWeapon, mix = npc.OW_SpawnMix }
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
            mask = MASK_NPCSOLID, filter = OW.WalkFilter,
        })
        if not tr.Hit then
            local f = FloorAt(p)
            if f and math.abs(f.z - lpos.z) < 40 then return f end
        end
    end
    return lpos
end

-- Строй "колонна по двое" ЗА ведущим.
-- heading — направление марша. По журналу v23: направление брали из скорости/взгляда
-- лидера, а они всё время скачут (поворот головы, шаг в сторону, бой) — точка строя
-- прыгала с одной стороны на другую на 200-300 юнитов, и бойцы бегали "хрен пойми куда".
-- Теперь для отряда NPC направление = к следующей точке маршрута лидера, сглаженное.
local function FormationOffset(i, n, leader, heading)
    local k = i - 2                         -- 0, 1, 2... — номер бойца за ведущим
    local row = math.floor(k / 2) + 1
    local side = (k % 2 == 0) and -1 or 1
    local fwd = heading
    if not fwd then
        fwd = Vector(1, 0, 0)
        if IsValid(leader) then
            local v = leader:GetVelocity()
            v.z = 0
            if v:LengthSqr() > 60 * 60 then
                fwd = v:GetNormalized()
            else
                local a = leader.EyeAngles and leader:EyeAngles() or leader:GetAngles()
                fwd = Angle(0, a.y, 0):Forward()
            end
        end
    end
    local right = Vector(fwd.y, -fwd.x, 0)
    return -fwd * (row * 70) + right * (side * 40)
end
OW.FormationOffset = FormationOffset
OW.SafeFormationPoint = SafeFormationPoint

-- Точка бойца №i в колонне по двое на следе лидера: ряд = 70 юнитов назад по следу,
-- в ряду — левее/правее на 35 (если сбоку нет стены, иначе прямо на следе).
function OW.TrailPoint(sq, i)
    local leader = sq.members[1]
    local k = i - 2
    local row = math.floor(k / 2) + 1
    local side = (k % 2 == 0) and -1 or 1
    local want = row * 70
    local trail = sq.trail or {}
    local p, prev = leader:GetPos(), leader:GetPos()
    local dir = Vector(0, 0, 0)
    local walked = 0
    for j = #trail, 1, -1 do
        local q = trail[j]
        local seg = prev:Distance(q)
        if seg > 0.1 then
            dir = prev - q
            if walked + seg >= want then
                p = LerpVector((want - walked) / seg, prev, q)
                walked = want
                break
            end
            walked = walked + seg
            p = q
        end
        prev = q
    end
    dir.z = 0
    if dir:LengthSqr() > 1 then
        dir:Normalize()
        local sidep = p + Vector(dir.y, -dir.x, 0) * (side * 35)
        local tr = util.TraceHull({ start = p + Vector(0, 0, 4), endpos = sidep + Vector(0, 0, 4),
            mins = HULL_MINS, maxs = HULL_MAXS, mask = MASK_NPCSOLID, filter = OW.WalkFilter })
        if not tr.Hit then
            local f = FloorAt(sidep)
            if f and math.abs(f.z - p.z) < 24 then return f end
        end
    end
    return p
end

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
        sq.trail = nil   -- новый лидер — новый след
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

        -- Отстали -> лидер идёт шагом (а не стоит: стоп-старт давал рывки всему отряду).
        -- Совсем далеко (>1100) — ждёт на месте.
        local slow = spread
        if leader.OW_SlowWalk ~= slow then
            leader.OW_SlowWalk = slow
            leader.OW_Goal = nil                 -- перевыдать приказ с новым шагом
        end
        local far = false
        if spread then
            for i = 2, #sq.members do
                if sq.members[i]:GetPos():DistToSqr(leader:GetPos()) > 1100 * 1100 then far = true break end
            end
        end
        if OW.IsFighting(leader) then
            OW.Engage(leader)
        elseif far then
            OW.Stop(leader)
        else
            OW.MoveTo(leader, sq.goal)
        end

        local lpos = leader:GetPos()
        -- След лидера: точки, где он реально прошёл. Бойцы идут колонной ПО СЛЕДУ —
        -- такие точки точно проходимы и не прыгают из стороны в сторону.
        sq.trail = sq.trail or {}
        local last = sq.trail[#sq.trail]
        if not last or last:DistToSqr(lpos) > 30 * 30 then
            table.insert(sq.trail, lpos)
            if #sq.trail > 60 then table.remove(sq.trail, 1) end
        end
        for i = 2, #sq.members do
            local m = sq.members[i]
            if OW.IsFighting(m) then
                OW.Engage(m)
            else
                local goal = OW.TrailPoint(sq, i)
                -- пока лидер идёт — бойцы тоже идут (не стоп-старт у каждой точки)
                local leaderMoving = leader:GetVelocity():Length2DSqr() > 40 * 40
                local d2 = m:GetPos():DistToSqr(goal)
                if d2 > 140 * 140 or (leaderMoving and d2 > 50 * 50) then
                    -- далеко отстал — бегом, рядом — в темпе лидера
                    m.OW_SlowWalk = leader.OW_SlowWalk and d2 < 300 * 300 or nil
                    OW.MoveTo(m, goal, 180)   -- цель сдвинулась <180 — не перевыдаём (меньше рывков)
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
-- Свои не должны воевать со своими. VJ Base сам решает, кто враг (и заставляет обычных NPC
-- отвечать ему тем же), поэтому каждый тик проверяем: если враг — NPC своей команды,
-- сбрасываем его и снова ставим "друг".
local function FixFriendlyFire(npc)
    if not npc.GetEnemy then return end
    local e = npc:GetEnemy()
    if IsValid(e) and e.OW_Team ~= nil and e.OW_Team == npc.OW_Team and e ~= npc then
        npc:AddEntityRelationship(e, D_LI, 99)
        if e.AddEntityRelationship and e:IsNPC() then e:AddEntityRelationship(npc, D_LI, 99) end
        npc:SetEnemy(NULL)
        if npc.ClearEnemyMemory then npc:ClearEnemyMemory(e) end
        OW.VJOverride(npc, e, D_LI)
        Log(npc, "враг был из своей команды (" .. e:GetClass() .. ") -> сброшен")
    end
end

function OW.Tick()
    for npc in pairs(OW.NPCs) do
        if not OW.IsAlive(npc) then OW.NPCs[npc] = nil
        elseif not npc.OW_Passive then FixFriendlyFire(npc) end
    end

    if OW.PlayersTick then OW.PlayersTick() end   -- набор бойцов в отряды игроков
    if OW.EnforcePlayers then OW.EnforcePlayers() end

    for _, op in ipairs(OW.GetOutposts()) do
        if op.BrainTick then op:BrainTick() end
    end

    for _, sq in pairs(OW.Squads) do OW.SquadTick(sq) end

    for npc in pairs(OW.NPCs) do
        if not npc.OW_Squad and not npc.OW_Passive then OW.GuardTick(npc) end
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

-- Кнопка "По умолчанию" в Server Settings: все серверные настройки мода — к значениям по умолчанию
concommand.Add("outpost_war_reset_settings", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    for _, cv in pairs(OW.CVars) do cv:Revert() end
    MsgN("[Outpost War] настройки сброшены по умолчанию")
end)

MsgN("[Outpost War] v" .. (OW.VERSION or "?") .. " загружен — движение v30")
