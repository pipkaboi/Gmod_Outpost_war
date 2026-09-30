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

local MAX_CLIMB    = 40      -- подъём между соседними областями (ступеньки, склоны)
local MAX_DROP     = 120     -- спуск (больше — это обрыв)
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

local function NearestArea(pos)
    return navmesh.GetNearestNavArea(pos, false, 500, false, true)
end

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
-- Перегорожен ли переход между областями пропом (забор, ворота, машина).
-- nav_generate пропы часто не учитывает и прокладывает навмеш сквозь сетчатый забор.
-- Проверяем три параллельные линии между центрами областей: забор перекрывает все три,
-- а случайная машина посреди большой области — обычно не все. Стены не проверяем —
-- их навмеш уже знает. Результат кэшируем на минуту.
local EDGE_CACHE, EDGE_TIME = {}, 0
local EMINS, EMAXS = Vector(-12, -12, 20), Vector(12, 12, 56)

local function PropFilter(e)
    if not OW.WalkFilter(e) then return false end
    return not e:IsWorld()
end

local function EdgeBlocked(from, to)
    if CurTime() - EDGE_TIME > 60 then EDGE_CACHE, EDGE_TIME = {}, CurTime() end
    local key = from:GetID() * 65536 + to:GetID()
    local c = EDGE_CACHE[key]
    if c ~= nil then return c end

    local a, b = from:GetCenter(), to:GetCenter()
    local dir = b - a
    dir.z = 0
    local blocked = true
    if dir:LengthSqr() < 1 then
        blocked = false
    else
        dir:Normalize()
        local side = Vector(-dir.y, dir.x, 0)
        for _, off in ipairs({ 0, 28, -28 }) do
            local tr = util.TraceHull({
                start = a + side * off, endpos = b + side * off,
                mins = EMINS, maxs = EMAXS, mask = MASK_NPCSOLID, filter = PropFilter,
            })
            if not (tr.Hit and IsValid(tr.Entity) and not tr.Entity:IsWorld()) then
                blocked = false
                break
            end
        end
    end
    EDGE_CACHE[key] = blocked
    return blocked
end

local function CanTraverse(from, to)
    local dz = from:ComputeAdjacentConnectionHeightChange(to)
    if dz > MAX_CLIMB or dz < -MAX_DROP then return false end
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
local function PortalPoint(a, b, prev)
    local ax1, ax2, ay1, ay2 = Bounds(a)
    local bx1, bx2, by1, by2 = Bounds(b)
    local ox1, ox2 = math.max(ax1, bx1), math.min(ax2, bx2)
    local oy1, oy2 = math.max(ay1, by1), math.min(ay2, by2)
    local x, y

    local function pick(v, lo, hi)
        if hi - lo > EDGE_MARGIN * 2 then return math.Clamp(v, lo + EDGE_MARGIN, hi - EDGE_MARGIN) end
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
        if not f or math.abs(f.z - p.z) > 40 then return false end
    end
    return true
end

local function Smooth(points)
    if #points <= 2 then return points end
    local out = { points[1] }
    local i = 1
    while i < #points do
        local best = i + 1
        for j = math.min(#points, i + 8), i + 2, -1 do
            if points[i]:Distance(points[j]) <= MAX_SEGMENT and P.ClearWalk(points[i], points[j]) then
                best = j
                break
            end
        end
        table.insert(out, points[best])
        i = best
    end
    return out
end

local function BuildPoints(areas, from, to)
    local points = { from }
    local prev = from
    for i = 2, #areas do
        local p = PortalPoint(areas[i - 1], areas[i], prev)
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
function P.Request(from, to)
    if not P.Available() then return "fail", "на карте нет навмеша" end
    local a, b = NearestArea(from), NearestArea(to)
    if not IsValid(a) then return "fail", "рядом с NPC нет навмеша" end
    if not IsValid(b) then return "fail", "рядом с целью нет навмеша" end

    local key = a:GetID() .. ">" .. b:GetID()
    local cached = P.Cache[key]
    if cached and CurTime() - cached.time < CACHE_TIME then
        if not cached.areas then return "fail", cached.reason end
        return "ok", BuildPoints(cached.areas, from, to)
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
