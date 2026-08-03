-- Options

hook.Add("PopulateToolMenu", "WorldPortals_PopulateToolMenu", function()
    spawnmenu.AddToolMenuOption("Options", "World Portals", "WorldPortals_Options", "Settings", "", "", function(panel)
        panel:ClearControls()
        panel:Help("World Portals")

        local enabled = panel:CheckBox("Enable portals", "worldportals_enabled")
        enabled:SetTooltip("Disables portal rendering entirely, all portals will show blank")

        local recursion = panel:NumSlider("Recursion depth", "worldportals_recurse_depth", 1, 9, 0)
        recursion:SetTooltip("Default: 2. Portals can show in other portals up to the selected depth. Use caution with higher values as this may have a major performance impact")

        local recurseWarn = panel:Help("\xE2\x9A\xA0 Depth 4+ can seriously hurt performance with multiple portals visible at once.")
        recurseWarn:SetTextColor(Color(200, 60, 20))

        ---@param value number
        local function updateRecurseWarn(value)
            local show = math.floor(tonumber(value) or 0) > 3
            if recurseWarn:IsVisible() ~= show then
                recurseWarn:SetVisible(show)
                -- Reflow the layout to account for the label appearing/disappearing.
                local wrap = recurseWarn:GetParent()
                if IsValid(wrap) then wrap:InvalidateLayout(true) end
                panel:InvalidateLayout(true)
            end
        end
        updateRecurseWarn(assert(GetConVar("worldportals_recurse_depth")):GetInt())
        recursion.OnValueChanged = function(_, value)
            updateRecurseWarn(value)
        end

        local ghosts = panel:CheckBox("Entity Ghosts", "worldportals_ghosts")
        ghosts:SetTooltip("Render props through portals as they are passing through them")

        local selfGhost = panel:CheckBox("Show yourself in portals", "worldportals_show_self")
        selfGhost:SetTooltip("Show your own body inside portals")
    end)
end)
