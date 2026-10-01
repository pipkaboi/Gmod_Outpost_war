-- lua/autorun/server/sv_outpost_path.lua
-- Поиск пути по навмешу (A*) для NPC аванпостов.
--
-- NPC из HL2 сами умеют ходить только по AI-нодам карты, а на большинстве карт GMod
-- их нет. Поэтому маршрут строим сами по навмешу (maps/<карта>.nav, создаётся
-- командой nav_generate), а NPC ведём короткими отрезками от точки к точке.
--
-- Поиск идёт в фоне (корутина, несколько миллисекунд за кадр), поэтому даже на
-- больших картах сервер не подвисает, а лимит поиска можно держать большим.

OutpostWar = OutpostWar or {}
local OW = OutpostWar
OW.Path = OW.Path or {}
local P = OW.Path

-- Подъём между соседними областями. NPC шагают вверх только на ~18 (ступенька); прыгать
-- не умеют. По журналу: маршрут шёл через уступ ~25-35 (nav_generate считает его
-- проходимым для игрока), NPC стояли перед ним с бесконечными провалами.
local MAX_CLIMB    = 22
-- Спуск: NPC из HL2 не умеют спрыгивать с уступов (по журналу: точка в 85 юнитах и на 70 ниже —
-- край балкона — бесконечные провалы). Поэтому спуск — только как по ступенькам/склону.
local MAX_DROP     = 48
local MAX_ITER     = 200000  -- лимит A*
local FRAME_BUDGET = 0.003   -- сек процессорного времени на поиск за кадр
local CACHE_TIME   = 30      -- сек, сколько хранится маршрут
local MAX_SEGMENT  = 700     -- макс. длина прямого участка после сглаживания
-- По журналу: движок надёжно строит путь только на ~200 юнитов, дальше — SCHED_FAIL.
-- Поэтому каждый участок режем на отрезки не длиннее SUB_SEGMENT.
local SUB_SEGMENT  = 200
local EDGE_MARGIN  = 24      -- отступ точек маршрута от краёв проходов (NPC ~ 32 юнита шириной)

P.Cache = P.Cache or {}  -- key -> { areas = {...} | false, reason = str, time = t }
P.Jobs  = P.Jobs or {}   -- key -> job
P.Queue = P.Queue or {}  -- список ключей в очереди
P.Blocked = P.Blocked or {} -- [id области] = время (например, запертая дверь)

local BLOCK_TIME = 60

local function IsBlocked(area)
    local t = P.Blocked[area:GetID()]
    return t and CurTime() - t < BLOCK_TIME
end

-- Пометить область навмеша у pos как непроходимую на минуту (и сбросить кэш маршрутов)
function P.BlockAt(pos, radius)
    local found = navmesh.Find(pos, radius or 40, 80, 80)
    for _, area in ipairs(found) do P.Blocked[area:GetID()] = CurTime() end
    if #found > 0 then P.Cache = {} end
end

function P.Available()
    return navmesh and navmesh.IsLoaded and navmesh.IsLoaded() and navmesh.GetNavAreaCount() > 0
end

-- Область навмеша на ТОМ ЖЕ этаже, что и pos.
-- Раньше брали просто ближайшую (GetNearestNavArea): если точка на втором этаже/балконе,
-- а прямо под ней пол первого этажа, иногда выбиралась нижняя область — маршрут вёл
-- под точку, и NPC стояли этажом ниже ("до точки 170" в журнале бесконечно).
local SAME_FLOOR = 60
local function FloorDiff(area, pos)
    return math.abs(area:GetZ(pos) - pos.z)
end

-- Список всех областей (обновляется, если навмеш поменялся)
local ALL, ALL_COUNT = {}, -1
local function AllAreas()
    local n = navmesh.GetNavAreaCount()
    if n ~= ALL_COUNT then
        ALL, ALL_COUNT = {}, n
        for _, a in ipairs(navmesh.GetAllNavAreas()) do
            ALL[#ALL + 1] = { area = a, c = a:GetCenter(),
                r2 = (math.max(a:GetSizeX(), a:GetSizeY()) / 2 + 300) ^ 2 }
        end
    end
    return ALL
end

local NEAR_CACHE, NEAR_TIME = {}, 0
local function NearestArea(pos)
    -- 1) область прямо под точкой (её проекция содержит pos), не глубже 120 юнитов
    local a = navmesh.GetNavArea(pos + Vector(0, 0, 20), 120)
    if IsValid(a) and FloorDiff(a, pos) < SAME_FLOOR then return a end

    -- 2) ближайшая область в радиусе 300, но только на том же уровне по высоте.
    -- (navmesh.Find не годится: он ищет заливкой от области под точкой, а её как раз нет)
    if CurTime() - NEAR_TIME > 20 then NEAR_CACHE, NEAR_TIME = {}, CurTime() end
    local key = math.floor(pos.x / 32) .. "," .. math.floor(pos.y / 32) .. "," .. math.floor(pos.z / 32)
    local c = NEAR_CACHE[key]
    if c ~= nil then return c or nil end

    local best, bestD
    for _, e in ipairs(AllAreas()) do
        local dx, dy = e.c.x - pos.x, e.c.y - pos.y
        if dx * dx + dy * dy < e.r2 and IsValid(e.area) then
            local cp = e.area:GetClosestPointOnArea(pos)
            if cp and math.abs(cp.z - pos.z) < SAME_FLOOR then
                local d = cp:DistToSqr(pos)
                if d < 300 * 300 and (not bestD or d < bestD) then best, bestD = e.area, d end
            end
        end
    end
    NEAR_CACHE[key] = best or false
    return best
end
P.NearestArea = NearestArea

---------------------------------------------------------------------------
-- Двоичная куча
---------------------------------------------------------------------------
local function HeapPush(h, item, key)
    local n = #h + 1
    h[n] = { item, key }
    while n > 1 do
        local parent = math.floor(n / 2)
        if h[parent][2] <= h[n][2] then break end
        h[parent], h[n] = h[n], h[parent]
        n = parent
    end
end

local function HeapPop(h)
    local top = h[1]
    local last = table.remove(h)
    if #h > 0 then
        h[1] = last
        local n, size = 1, #h
        while true do
            local l, r, m = n * 2, n * 2 + 1, n
            if l <= size and h[l][2] < h[m][2] then m = l end
            if r <= size and h[r][2] < h[m][2] then m = r end
            if m == n then break end
            h[m], h[n] = h[n], h[m]
            n = m
        end
    end
    return top[1]
end

---------------------------------------------------------------------------
-- Проходимость и стоимость
---------------------------------------------------------------------------
-- Проверка перехода между областями — см. EdgeBlocked ниже.
local EDGE_CACHE, EDGE_TIME = {}, 0
local EMINS, EMAXS = Vector(-12, -12, 20), Vector(12, 12, 64)   -- до 64: и низкие балки

local function PropFilter(e)
    if not OW.WalkFilter(e) then return false end
    return not e:IsWorld()
end

-- Середина общей границы областей (со сдвигом shift вдоль неё)
local function EdgePortal(from, to, shift)
    local f0, f2, t0, t2 = from:GetCorner(0), from:GetCorner(2), to:GetCorner(0), to:GetCorner(2)
    local ox1, ox2 = math.max(math.min(f0.x, f2.x), math.min(t0.x, t2.x)), math.min(math.max(f0.x, f2.x), math.max(t0.x, t2.x))
    local oy1, oy2 = math.max(math.min(f0.y, f2.y), math.min(t0.y, t2.y)), math.min(math.max(f0.y, f2.y), math.max(t0.y, t2.y))
    local x, y
    if ox2 - ox1 >= oy2 - oy1 then   -- граница вдоль X
        x = math.Clamp((ox1 + ox2) / 2 + shift, ox1 + 4, math.max(ox1 + 4, ox2 - 4))
        y = (oy1 + oy2) / 2
    else                             -- граница вдоль Y
        y = math.Clamp((oy1 + oy2) / 2 + shift, oy1 + 4, math.max(oy1 + 4, oy2 - 4))
        x = (ox1 + ox2) / 2
    end
    local p = Vector(x, y, 0)
    p.z = math.max(from:GetZ(p), to:GetZ(p))
    return p
end

local function LegHit(a, b)
    local tr = util.TraceHull({
        start = a, endpos = b, mins = EMINS, maxs = EMAXS,
        mask = MASK_NPCSOLID, filter = OW.WalkFilter,   -- стены мира И пропы
    })
    -- начали внутри чего-то (ящик стоит на центре области) — эту проверку не считаем
    return tr.Hit and not tr.StartSolid
end

-- Перегорожен ли переход между областями.
-- 1) Тонкие стены и балки: nav_generate (сетка ~25 юнитов) иногда соединяет области сквозь
--    тонкую стенку/перегородку — маршрут шёл сквозь стену на поворотах.
-- 2) Пропы (заборы, ворота): навмеш их часто не учитывает.
-- Проверяем путь "центр области -> граница -> центр соседней" (он целиком внутри двух
-- областей, поэтому настоящие углы комнат не мешают) в трёх местах границы. Заблокировано,
-- только если перекрыты все три. Результат кэшируем на минуту.
local function EdgeBlocked(from, to)
    if CurTime() - EDGE_TIME > 60 then EDGE_CACHE, EDGE_TIME = {}, CurTime() end
    local key = from:GetID() * 65536 + to:GetID()
    local c = EDGE_CACHE[key]
    if c ~= nil then return c end

    local a, b = from:GetCenter(), to:GetCenter()
    local blocked = true
    for _, off in ipairs({ 0, 24, -24 }) do
        local m = EdgePortal(from, to, off)
        if not LegHit(a, m) and not LegHit(m, b) then
            blocked = false
            break
        end
    end
    EDGE_CACHE[key] = blocked
    return blocked
end

local function CanTraverse(from, to)
    local dz = from:ComputeAdjacentConnectionHeightChange(to)
    if dz > MAX_CLIMB or dz < -MAX_DROP then return false end
    if to:HasAttributes(NAV_MESH_JUMP or 2) then return false end   -- место "только прыжком"

    return not EdgeBlocked(from, to)
end

local function StepCost(from, to)
    local cost = from:GetCenter():Distance(to:GetCenter())
    if to:IsUnderwater() then cost = cost * 5 end
    if to:HasAttributes(NAV_MESH_JUMP or 2) then cost = cost * 5 end
    if to:HasAttributes(NAV_MESH_AVOID or 128) then cost = cost * 4 end
    if to:HasAttributes(NAV_MESH_CROUCH or 1) then cost = cost * 10 end
    -- узкие области (проходы у стен) чуть дороже — меньше трения об углы
    local w = math.min(to:GetSizeX(), to:GetSizeY())
    if w < 40 then cost = cost * 1.5 end
    return cost
end

-- A* (выполняется внутри корутины)
local function AStar(startArea, goalArea)
    if startArea == goalArea then return { startArea } end

    local goalCenter = goalArea:GetCenter()
    local open, g, came, closed = {}, {}, {}, {}
    g[startArea:GetID()] = 0
    HeapPush(open, startArea, startArea:GetCenter():Distance(goalCenter))

    local iter = 0
    while #open > 0 do
        iter = iter + 1
        if iter > MAX_ITER then return nil, "слишком далеко (превышен лимит поиска)" end
        if iter % 300 == 0 then coroutine.yield() end

        local cur = HeapPop(open)
        if IsValid(cur) then
            local id = cur:GetID()
            if not closed[id] then
                closed[id] = true

                if cur == goalArea then
                    local list = { cur }
                    while came[id] do
                        cur = came[id]
                        id = cur:GetID()
                        table.insert(list, 1, cur)
                    end
                    return list
                end

                for _, nb in ipairs(cur:GetAdjacentAreas()) do
                    local nid = nb:GetID()
                    if not closed[nid] and not IsBlocked(nb) and CanTraverse(cur, nb) then
                        local ng = g[id] + StepCost(cur, nb)
                        if not g[nid] or ng < g[nid] then
                            g[nid] = ng
                            came[nid] = cur
                            HeapPush(open, nb, ng + nb:GetCenter():Distance(goalCenter))
                        end
                    end
                end
            end
        end
    end
    return nil, "нет прохода (цель не связана с навмешем старта: обрыв, стена или разрыв в навмеше)"
end

-- Фоновая обработка очереди
hook.Add("Think", "OutpostWar_PathJobs", function()
    if #P.Queue == 0 then return end
    local start = SysTime()
    while #P.Queue > 0 and SysTime() - start < FRAME_BUDGET do
        local key = P.Queue[1]
        local job = P.Jobs[key]
        if not job then
            table.remove(P.Queue, 1)
        else
            local ok, areas, reason = coroutine.resume(job.co)
            if not ok then
                ErrorNoHalt("[OutpostWar] ошибка поиска пути: " .. tostring(areas) .. "\n")
                areas, reason = nil, "ошибка"
            end
            if coroutine.status(job.co) == "dead" then
                P.Cache[key] = { areas = areas or false, reason = reason, time = CurTime() }
                P.Jobs[key] = nil
                table.remove(P.Queue, 1)
                if not areas then
                    MsgN("[Outpost War] Маршрут не найден: " .. tostring(reason))
                end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Точки маршрута
---------------------------------------------------------------------------
local function Bounds(area)
    local a, b = area:GetCorner(0), area:GetCorner(2)
    return math.min(a.x, b.x), math.max(a.x, b.x), math.min(a.y, b.y), math.max(a.y, b.y)
end

-- Точка на общей границе областей a и b, с отступом от краёв прохода
-- lane (-1..1) — своя "полоса" у каждого NPC: точка сдвигается поперёк прохода.
-- Иначе все NPC идут через одну и ту же точку у угла проёма и толпятся в ней.
local LANE_WIDTH = 40
local function PortalPoint(a, b, prev, lane)
    local ax1, ax2, ay1, ay2 = Bounds(a)
    local bx1, bx2, by1, by2 = Bounds(b)
    local ox1, ox2 = math.max(ax1, bx1), math.min(ax2, bx2)
    local oy1, oy2 = math.max(ay1, by1), math.min(ay2, by2)
    local x, y

    local function pick(v, lo, hi)
        if hi - lo > EDGE_MARGIN * 2 then
            lo, hi = lo + EDGE_MARGIN, hi - EDGE_MARGIN
            local half = (hi - lo) / 2
            local v0 = math.Clamp(v, lo, hi) + (lane or 0) * math.min(LANE_WIDTH, half)
            return math.Clamp(v0, lo, hi)
        end
        return (lo + hi) / 2
    end

    if ox2 > ox1 and oy2 - oy1 < 2 and oy2 - oy1 > -40 then       -- граница по горизонтали (общий отрезок вдоль X)
        x = pick(prev.x, ox1, ox2)
        y = (oy1 + oy2) / 2
    elseif oy2 > oy1 and ox2 - ox1 < 2 and ox2 - ox1 > -40 then   -- граница по вертикали (общий отрезок вдоль Y)
        y = pick(prev.y, oy1, oy2)
        x = (ox1 + ox2) / 2
    else
        -- области не касаются (спуск/перепад) — ближайшая точка b
        return b:GetClosestPointOnArea(prev)
    end

    local p = Vector(x, y, 0)
    p.z = b:GetZ(p)
    return p
end

local HULL_MINS, HULL_MAXS = Vector(-18, -18, 20), Vector(18, 18, 64)

local function FloorAt(p)
    local tr = util.TraceLine({
        start = p + Vector(0, 0, 40), endpos = p - Vector(0, 0, 120),
        mask = MASK_NPCSOLID_BRUSHONLY,
    })
    if tr.Hit and not tr.StartSolid then return tr.HitPos end
end

-- Можно ли пройти от a до b по прямой (без стен, углов и обрывов)
function P.ClearWalk(a, b)
    local tr = util.TraceHull({
        start = a, endpos = b, mins = HULL_MINS, maxs = HULL_MAXS,
        mask = MASK_NPCSOLID, filter = OW.WalkFilter,   -- учитываем и пропы (заборы, ворота)
    })
    if tr.Hit or tr.StartSolid then return false end
    local steps = math.floor(a:Distance(b) / 48)
    for i = 1, steps do
        local p = LerpVector(i / (steps + 1), a, b)
        local f = FloorAt(p)
        if not f or math.abs(f.z - p.z) > 24 then return false end   -- уступ выше ступеньки — не напрямую
    end
    return true
end

-- Насколько точки между i и j отходят от прямой i-j (по горизонтали)
local function MaxDeviation(points, i, j)
    local a, b = points[i], points[j]
    local dx, dy = b.x - a.x, b.y - a.y
    local len2 = dx * dx + dy * dy
    local worst = 0
    for k = i + 1, j - 1 do
        local p = points[k]
        local t = len2 > 0 and math.Clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0, 1) or 0
        local ex, ey = a.x + dx * t - p.x, a.y + dy * t - p.y
        worst = math.max(worst, math.sqrt(ex * ex + ey * ey))
    end
    return worst
end

-- Срезать угол можно, если прямая свободна. Но на лестницах с разворотом (пролёт,
-- площадка, пролёт обратно) прямая от нижнего пролёта к верхнему проходит над
-- перилами/пролётом — поэтому если высота меняется, точки не должны далеко отходить от прямой.
local function CanShortcut(points, i, j)
    if points[i]:Distance(points[j]) > MAX_SEGMENT then return false end
    if math.abs(points[i].z - points[j].z) > 24 or math.abs(points[i + 1].z - points[i].z) > 24 then
        if MaxDeviation(points, i, j) > 40 then return false end
    end
    return P.ClearWalk(points[i], points[j])
end
P.MaxDeviation = MaxDeviation

local function Smooth(points)
    if #points <= 2 then return points end
    local out = { points[1] }
    local i = 1
    while i < #points do
        local best = i + 1
        for j = math.min(#points, i + 8), i + 2, -1 do
            if CanShortcut(points, i, j) then
                best = j
                break
            end
        end
        table.insert(out, points[best])
        i = best
    end
    return out
end

local function BuildPoints(areas, from, to, lane)
    local points = { from }
    local prev = from
    for i = 2, #areas do
        local p = PortalPoint(areas[i - 1], areas[i], prev, lane)
        table.insert(points, p)
        prev = p
    end
    table.insert(points, to)
    local smooth = Smooth(points)
    local path = { smooth[1] }
    for i = 2, #smooth do
        local a, b = smooth[i - 1], smooth[i]
        local n = math.ceil(a:Distance(b) / SUB_SEGMENT)
        for k = 1, n - 1 do
            local p = LerpVector(k / n, a, b)
            local f = FloorAt(p)
            table.insert(path, f and (f + Vector(0, 0, 4)) or p)
        end
        table.insert(path, b)
    end
    table.remove(path, 1)
    return path
end

---------------------------------------------------------------------------
-- Запрос маршрута.
-- Возвращает: "ok", точки | "pending" | "fail", причина
---------------------------------------------------------------------------
function P.Request(from, to, lane)
    if not P.Available() then return "fail", "на карте нет навмеша" end
    local a, b = NearestArea(from), NearestArea(to)
    if not IsValid(a) then return "fail", "рядом с NPC нет навмеша" end
    if not IsValid(b) then return "fail", "рядом с целью нет навмеша" end

    P.LastStartZ, P.LastGoalZ = math.floor(a:GetZ(from)), math.floor(b:GetZ(to))
    local key = a:GetID() .. ">" .. b:GetID()
    local cached = P.Cache[key]
    if cached and CurTime() - cached.time < CACHE_TIME then
        if not cached.areas then return "fail", cached.reason end
        return "ok", BuildPoints(cached.areas, from, to, lane)
    end

    if not P.Jobs[key] then
        P.Jobs[key] = { co = coroutine.create(function() return AStar(a, b) end) }
        table.insert(P.Queue, key)
    end
    return "pending"
end

-- Сброс кэша (например, после nav_generate или изменения карты)
concommand.Add("outpost_war_path_reset", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    P.Cache, P.Jobs, P.Queue = {}, {}, {}
end)

timer.Create("OutpostWar_PathCache", 30, 0, function()
    local now = CurTime()
    for k, v in pairs(P.Cache) do
        if now - v.time > CACHE_TIME then P.Cache[k] = nil end
    end
end)
