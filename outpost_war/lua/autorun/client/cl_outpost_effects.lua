-- lua/autorun/client/cl_outpost_effects.lua
-- Клиентская часть: шрифты, надписи, своя вкладка в меню инструментов.

-- Тексты — в resource/localization/<язык>/outpost_war.properties

surface.CreateFont("OutpostWar_Big", {
    font = "Roboto", size = 48, weight = 800, extended = true,
})
surface.CreateFont("OutpostWar_Small", {
    font = "Roboto", size = 28, weight = 700, extended = true,
})

-- Отдельная вкладка "Outpost War" в меню Q (рядом с Tools / Options / Utilities)
hook.Add("AddToolMenuTabs", "OutpostWar_Tab", function()
    spawnmenu.AddToolTab("Outpost War", "Outpost War", "icon16/flag_red.png")
end)

-- Панель серверных настроек в той же вкладке
hook.Add("PopulateToolMenu", "OutpostWar_Settings", function()
    spawnmenu.AddToolMenuOption("Outpost War", "Settings", "outpost_war_settings",
        "Server Settings", "", "", function(pnl)
            local L = OutpostWar.L
            pnl:ClearControls()
            pnl:Help("Outpost War v" .. (OutpostWar.VERSION or "?"))
            pnl:Help(L("settings_admin"))
            pnl:NumSlider(L("capture_time"), "outpost_war_capture_time", 1, 120, 0)
            pnl:CheckBox(L("native_combat"), "outpost_war_native_combat")
            pnl:NumSlider(L("engage_dist"), "outpost_war_engage_dist", 400, 3000, 0)
            pnl:NumSlider(L("combat_linger"), "outpost_war_combat_linger", 0, 60, 0)
            pnl:NumSlider(L("corpse_time"), "outpost_war_corpse_time", 0, 300, 0)
            pnl:CheckBox(L("ignore_players"), "outpost_war_ignore_players")
            pnl:CheckBox(L("tint"), "outpost_war_tint")
            pnl:CheckBox(L("open_doors"), "outpost_war_open_doors")
            pnl:CheckBox(L("unlock_doors"), "outpost_war_unlock_doors")
            pnl:CheckBox(L("break_glass"), "outpost_war_break_glass")
            pnl:CheckBox(L("debug"), "outpost_war_debug")
            pnl:Button(L("clear_npcs"), "outpost_war_clear_npcs")
            pnl:Button(L("reset_defaults"), "outpost_war_reset_settings")
            pnl:Help(L("nodes_help"))
        end)
end)

---------------------------------------------------------------------------
-- Участие игрока в войне: выбор команды, отряд
---------------------------------------------------------------------------
CreateClientConVar("outpost_war_myteam", "1", true, false)

hook.Add("PopulateToolMenu", "OutpostWar_Player", function()
    spawnmenu.AddToolMenuOption("Outpost War", "Settings", "outpost_war_player",
        "Player", "", "", function(pnl)
            local L = OutpostWar.L
            pnl:ClearControls()
            pnl:Help(L("player_help"))
            pnl:NumSlider(L("team"), "outpost_war_myteam", 1, 10, 0)
            local join = pnl:Button(L("join"))
            join.DoClick = function()
                RunConsoleCommand("outpost_war_join", GetConVarString("outpost_war_myteam"))
            end
            pnl:Button(L("leave"), "outpost_war_join", "0")
            pnl:Button(L("dismiss"), "outpost_war_squad_dismiss")
            pnl:Help(L("settings_admin"))
            pnl:NumSlider(L("player_squad"), "outpost_war_player_squad", 0, 12, 0)
            pnl:CheckBox(L("spawn_at_outpost"), "outpost_war_spawn_at_outpost")
        end)
end)

-- Строка сверху экрана: команда игрока и размер его отряда
hook.Add("HUDPaint", "OutpostWar_PlayerHUD", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local t = ply:GetNWInt("OW_Team", 0)
    if t <= 0 then return end
    local OW = OutpostWar
    -- счёт точек: сколько всего и сколько у команды игрока
    local total, mine = 0, 0
    for _, op in ipairs(ents.FindByClass("sent_outpost")) do
        total = total + 1
        if op:GetOPTeam() == t then mine = mine + 1 end
    end
    local text = string.format(OW.L("hud"), OW.TeamName(t), ply:GetNWInt("OW_SquadCount", 0), mine, total)
    draw.SimpleTextOutlined(text, "OutpostWar_Small", ScrW() / 2, 12, OW.TeamColor(t),
        TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 2, color_black)
end)

---------------------------------------------------------------------------
-- Звёздочка над лидерами отрядов
---------------------------------------------------------------------------
local leaders = {}
timer.Create("OutpostWar_LeaderScan", 0.5, 0, function()
    leaders = {}
    for _, e in ipairs(ents.FindByClass("npc_*")) do
        if e:GetNWBool("OW_Leader", false) then leaders[#leaders + 1] = e end
    end
end)

-- 10 вершин звезды (внешние и внутренние по очереди)
local STAR = {}
for i = 0, 9 do
    local a = math.rad(-90 + i * 36)
    local r = (i % 2 == 0) and 1 or 0.42
    STAR[#STAR + 1] = { math.cos(a) * r, math.sin(a) * r }
end

local function DrawStar(size, col)
    surface.SetDrawColor(col)
    draw.NoTexture()
    for i = 1, 10 do
        local p1, p2 = STAR[i], STAR[i % 10 + 1]
        -- треугольник "центр — вершина — вершина"; рисуем в обоих направлениях обхода,
        -- потому что DrawPoly показывает только одну сторону
        surface.DrawPoly({ { x = 0, y = 0 }, { x = p1[1] * size, y = p1[2] * size }, { x = p2[1] * size, y = p2[2] * size } })
        surface.DrawPoly({ { x = 0, y = 0 }, { x = p2[1] * size, y = p2[2] * size }, { x = p1[1] * size, y = p1[2] * size } })
    end
end

hook.Add("PostDrawTranslucentRenderables", "OutpostWar_LeaderStar", function(_, sky)
    if sky or #leaders == 0 then return end
    local eye = EyePos()
    local ang = Angle(0, EyeAngles().y - 90, 90)
    for _, e in ipairs(leaders) do
        if IsValid(e) and e:Health() > 0 and e:GetPos():DistToSqr(eye) < 4000 * 4000 then
            local pos = e:GetPos() + Vector(0, 0, e:OBBMaxs().z + 16)
            local col = OutpostWar.TeamColor(e:GetNWInt("OW_Team", 0))
            cam.Start3D2D(pos, ang, 0.25)
                DrawStar(34, color_black)
                DrawStar(28, col)
            cam.End3D2D()
        end
    end
end)

---------------------------------------------------------------------------
-- Уборка клиентских трупов NPC аванпостов (обычные HL2-NPC падают клиентским ragdoll-ом)
---------------------------------------------------------------------------
hook.Add("CreateClientsideRagdoll", "OutpostWar_Cleanup", function(ent, rag)
    if not IsValid(ent) or ent:GetNWInt("OW_Team", -1) < 0 then return end
    local cv = GetConVar("outpost_war_corpse_time")
    local t = cv and cv:GetFloat() or 20
    if t <= 0 then return end
    timer.Simple(t, function()
        if IsValid(rag) then rag:SetRenderMode(RENDERMODE_TRANSCOLOR) rag:Remove() end
    end)
end)

---------------------------------------------------------------------------
-- Звезда над игроком, вступившим в войну: крупнее лидерской, с сиянием,
-- медленно вращается и пульсирует
---------------------------------------------------------------------------
local function DrawPlayerStar(ply)
    local t = ply:GetNWInt("OW_Team", 0)
    if t <= 0 or not ply:Alive() then return end
    if ply == LocalPlayer() and not ply:ShouldDrawLocalPlayer() then return end
    local col = OutpostWar.TeamColor(t)
    local now = CurTime()
    local pulse = 1 + math.sin(now * 3) * 0.08
    local head = ply:GetPos() + Vector(0, 0, ply:OBBMaxs().z + 22 + math.sin(now * 2) * 2)
    local ang = Angle(0, EyeAngles().y - 90, 90)
    ang:RotateAroundAxis(ang:Forward(), 0)
    cam.Start3D2D(head, ang, 0.25)
        -- сияние
        surface.SetDrawColor(col.r, col.g, col.b, 40)
        draw.NoTexture()
        for r = 70, 50, -10 do
            local poly = {}
            for i = 0, 23 do
                local a = math.rad(i * 15)
                poly[#poly + 1] = { x = math.cos(a) * r * pulse, y = math.sin(a) * r * pulse }
            end
            surface.DrawPoly(poly)
        end
        -- вращение звезды вокруг центра
        local m = Matrix()
        m:Rotate(Angle(0, now * 40 % 360, 0))
        cam.PushModelMatrix(m, true)
            DrawStar(52 * pulse, color_black)
            DrawStar(44 * pulse, col)
            DrawStar(20 * pulse, Color(255, 255, 255, 200))
        cam.PopModelMatrix()
    cam.End3D2D()
end

hook.Add("PostDrawTranslucentRenderables", "OutpostWar_PlayerStar", function(_, sky)
    if sky then return end
    local eye = EyePos()
    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) and ply:GetPos():DistToSqr(eye) < 5000 * 5000 then DrawPlayerStar(ply) end
    end
end)
