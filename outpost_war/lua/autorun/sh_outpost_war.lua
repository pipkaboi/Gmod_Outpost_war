-- lua/autorun/sh_outpost_war.lua
-- Общие (клиент + сервер) настройки мода "Outpost War"
AddCSLuaFile()

OutpostWar = OutpostWar or {}
local OW = OutpostWar

-- Серверные настройки. REPLICATED — чтобы клиент видел значения в меню настроек.
local CV_FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY)
OW.CVars = {
    capture_time   = CreateConVar("outpost_war_capture_time", "15", CV_FLAGS,
        "Seconds for one NPC to capture an outpost"),
    ignore_players = CreateConVar("outpost_war_ignore_players", "0", CV_FLAGS,
        "1 = outpost NPCs ignore players"),
    tint           = CreateConVar("outpost_war_tint", "1", CV_FLAGS,
        "1 = tint NPCs with their team color"),
    open_doors     = CreateConVar("outpost_war_open_doors", "1", CV_FLAGS,
        "1 = NPCs open doors in their way"),
    unlock_doors   = CreateConVar("outpost_war_unlock_doors", "0", CV_FLAGS,
        "1 = NPCs open even locked doors"),
    break_glass    = CreateConVar("outpost_war_break_glass", "1", CV_FLAGS,
        "1 = NPCs break glass in their way"),
    engage_dist    = CreateConVar("outpost_war_engage_dist", "800", CV_FLAGS,
        "Distance to a visible enemy at which NPCs stop marching and engage (units)"),
    player_squad   = CreateConVar("outpost_war_player_squad", "4", CV_FLAGS,
        "Max NPCs that join a player's squad (0 = none)"),
    spawn_at_outpost = CreateConVar("outpost_war_spawn_at_outpost", "1", CV_FLAGS,
        "1 = players in a team respawn at their team's outpost"),
    combat_linger  = CreateConVar("outpost_war_combat_linger", "8", CV_FLAGS,
        "Seconds NPCs stay in combat after losing sight of the enemy"),
    debug          = CreateConVar("outpost_war_debug", "0", bit.bor(FCVAR_REPLICATED, FCVAR_NOTIFY),
        "1 = draw NPC routes, 2 = also write data/outpost_war_log.txt (needs developer 1)"),
}

OW.TeamColors = {
    [0]  = Color(220, 220, 220), -- нейтральный
    [1]  = Color(255, 60, 60),   -- красный
    [2]  = Color(60, 110, 255),  -- синий
    [3]  = Color(60, 230, 60),   -- зелёный
    [4]  = Color(255, 230, 50),  -- жёлтый
    [5]  = Color(255, 60, 255),  -- розовый
    [6]  = Color(60, 240, 240),  -- голубой
    [7]  = Color(255, 140, 40),  -- оранжевый
    [8]  = Color(150, 60, 255),  -- фиолетовый
    [9]  = Color(120, 120, 120), -- серый
    [10] = Color(170, 255, 90),  -- салатовый
}

function OW.TeamColor(t)
    t = tonumber(t) or 0
    if OW.TeamColors[t] then return OW.TeamColors[t] end
    -- Для команд > 10 — стабильный цвет по номеру
    return HSVToColor((t * 67) % 360, 0.8, 1)
end

-- Перевод (resource/localization/<язык>/outpost_war.properties). На сервере — английский.
local EN = {
    team_neutral = "Neutral", team_n = "Team %s",
}
function OW.L(key)
    if CLIENT then
        local k = "outpost_war." .. key
        local s = language.GetPhrase(k)
        if s ~= k then return s end
    end
    return EN[key] or key
end

function OW.TeamName(t)
    t = tonumber(t) or 0
    if t == 0 then return OW.L("team_neutral") end
    return string.format(OW.L("team_n"), t)
end

-- Сообщения в чат: сервер шлёт ключ + аргументы, каждый клиент переводит на свой язык.
-- Аргумент вида {team = N} превращается в название команды.
if SERVER then
    util.AddNetworkString("OutpostWar_Notify")
    function OW.Notify(key, ...)
        local args = { ... }
        net.Start("OutpostWar_Notify")
        net.WriteString(key)
        net.WriteTable(args)
        net.Broadcast()
    end
else
    net.Receive("OutpostWar_Notify", function()
        local key, args = net.ReadString(), net.ReadTable()
        for i, a in ipairs(args) do
            if istable(a) and a.team then args[i] = OW.TeamName(a.team) else args[i] = tostring(a) end
        end
        local ok, text = pcall(string.format, OW.L(key), unpack(args))
        chat.AddText(Color(255, 200, 80), ok and text or key)
    end)
end

cleanup.Register("outposts")

-- Фильтр для проверок "можно ли пройти": стены И пропы (заборы, ворота, машины) — препятствия,
-- а NPC, игроки, двери (мы их открываем) и стёкла (разбиваем) — нет.
local PASSABLE = { prop_door_rotating = true, func_door = true, func_door_rotating = true,
    func_breakable_surf = true, func_breakable = true }
function OW.WalkFilter(e)
    if not IsValid(e) then return true end
    if e:IsNPC() or e:IsPlayer() or (e.IsNextBot and e:IsNextBot()) then return false end
    if PASSABLE[e:GetClass()] or e:GetClass() == "sent_outpost" then return false end
    return true
end
