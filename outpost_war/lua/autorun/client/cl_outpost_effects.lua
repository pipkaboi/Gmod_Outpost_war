-- lua/autorun/client/cl_outpost_effects.lua
-- Клиентская часть: шрифты, надписи, своя вкладка в меню инструментов.

language.Add("Cleanup_outposts", "Outposts")
language.Add("Cleaned_outposts", "Cleaned up all outposts")

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
            pnl:ClearControls()
            pnl:Help("Эти настройки меняет только хост / админ сервера.")
            pnl:NumSlider("Время захвата (сек)", "outpost_war_capture_time", 1, 120, 0)
            pnl:CheckBox("NPC не трогают игроков", "outpost_war_ignore_players")
            pnl:CheckBox("Красить NPC в цвет команды", "outpost_war_tint")
            pnl:CheckBox("NPC открывают двери", "outpost_war_open_doors")
            pnl:CheckBox("...даже запертые", "outpost_war_unlock_doors")
            pnl:CheckBox("Отладка (нужно developer 1)", "outpost_war_debug")
            pnl:Button("Удалить всех NPC аванпостов", "outpost_war_clear_npcs")
            pnl:Help("NPC ходят по AI-нодам карты. На картах без нод они идут к цели "
                .. "короткими шагами и хуже обходят препятствия.")
        end)
end)
