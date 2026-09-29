-- lua/autorun/sh_outpost_war.lua
-- Общие (клиент + сервер) настройки мода "Outpost War"
AddCSLuaFile()

OutpostWar = OutpostWar or {}
local OW = OutpostWar

-- Серверные настройки. REPLICATED — чтобы клиент видел значения в меню настроек.
local CV_FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY)
OW.CVars = {
    capture_time   = CreateConVar("outpost_war_capture_time", "15", CV_FLAGS,
        "Сколько секунд один NPC захватывает аванпост"),
    ignore_players = CreateConVar("outpost_war_ignore_players", "0", CV_FLAGS,
        "1 = NPC аванпостов не трогают игроков"),
    tint           = CreateConVar("outpost_war_tint", "1", CV_FLAGS,
        "1 = красить NPC в цвет команды"),
    open_doors     = CreateConVar("outpost_war_open_doors", "1", CV_FLAGS,
        "1 = NPC открывают двери на пути"),
    unlock_doors   = CreateConVar("outpost_war_unlock_doors", "0", CV_FLAGS,
        "1 = NPC открывают даже запертые двери"),
    debug          = CreateConVar("outpost_war_debug", "0", bit.bor(FCVAR_REPLICATED, FCVAR_NOTIFY),
        "1 = рисовать линии к целям NPC (нужно developer 1)"),
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

function OW.TeamName(t)
    t = tonumber(t) or 0
    if t == 0 then return "Нейтральный" end
    return "Команда " .. t
end

cleanup.Register("outposts")
