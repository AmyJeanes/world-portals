-- Options

hook.Add("PopulateToolMenu", "WorldPortals_PopulateToolMenu", function()
    ---@diagnostic disable-next-line: deprecated
    spawnmenu.AddToolMenuOption("Options", "World Portals", "WorldPortals_Options", "Settings", "", "", function(panel)
        panel:ClearControls()

        local title = vgui.Create("DLabel")
        title:SetText("World Portals")
        panel:AddItem(title)

        local enabled = vgui.Create("DCheckBoxLabel")
        enabled:SetText("Enable portals")
        enabled:SetConVar("worldportals_enabled")
        enabled:SetTooltip("When off, portals don't render and entity Draw bails. Saves the per-frame engine RenderView allocations the recursion produces.")
        panel:AddItem(enabled)

        local recursion = vgui.Create("DNumSlider")
        recursion:SetText("Recursion depth")
        recursion:SetMinMax(1, 9)
        recursion:SetDecimals(0)
        recursion:SetConVar("worldportals_recurse_depth")
        recursion:SetTooltip("Default: 2. Higher = portals seen through portals seen through portals... up to 9 levels.")
        panel:AddItem(recursion)

        -- Show the perf warning only at depth 4+ (each level re-renders every visible portal).
        local recurseWarn = vgui.Create("DLabel")
        recurseWarn:SetText("\xE2\x9A\xA0 Depth 4+ can seriously hurt performance with multiple portals visible at once.")
        recurseWarn:SetTextColor(Color(200, 60, 20))
        recurseWarn:SetWrap(true)
        recurseWarn:SetAutoStretchVertical(true)
        panel:AddItem(recurseWarn)

        local function updateRecurseWarn(value)
            local show = math.floor(tonumber(value) or 0) > 3
            if recurseWarn:IsVisible() ~= show then
                recurseWarn:SetVisible(show)
                -- AddItem wraps each item in a DSizeToContents panel that doesn't shrink
                -- when the inner label hides, so re-fit the wrapper before reflowing.
                local wrap = recurseWarn:GetParent()
                if IsValid(wrap) then wrap:InvalidateLayout(true) end
                panel:InvalidateLayout(true)
            end
        end
        updateRecurseWarn(GetConVar("worldportals_recurse_depth"):GetInt())
        recursion.OnValueChanged = function(_, value)
            updateRecurseWarn(value)
        end

        local ghosts = vgui.Create("DCheckBoxLabel")
        ghosts:SetText("Entity Ghosts")
        ghosts:SetConVar("worldportals_ghosts")
        ghosts:SetTooltip("While something is mid-teleport, show its emerging half coming out the other portal so it looks like one whole body crossing through, instead of being cut off at the opening. Works for players, NPCs, ragdolls and props.")
        panel:AddItem(ghosts)

        local selfGhost = vgui.Create("DCheckBoxLabel")
        selfGhost:SetText("See yourself in portals")
        selfGhost:SetConVar("worldportals_ghosts_self")
        selfGhost:SetTooltip("Show your own body in portals: your reflection seen looking through a portal, plus the 'ghost' half that completes your body while you're mid-teleport (in third-person and recursive views). Turn off to never see yourself in any portal.")
        panel:AddItem(selfGhost)

        local debugMode = vgui.Create("DComboBox")
        debugMode:SetSortItems(false)
        debugMode:AddChoice("Off", 0)
        debugMode:AddChoice("Clipped to visible", 1)
        debugMode:AddChoice("Rendered only", 2)
        debugMode:AddChoice("All including culled", 3)
        debugMode:SetValue(({[0]="Off",[1]="Clipped to visible",[2]="Rendered only",[3]="All including culled"})
            [GetConVar("worldportals_debug"):GetInt()] or "Off")
        debugMode.OnSelect = function(_, _, _, value)
            RunConsoleCommand("worldportals_debug", tostring(value))
        end
        local debugLabel = vgui.Create("DLabel")
        debugLabel:SetText("Debug overlay")
        panel:AddItem(debugLabel)
        panel:AddItem(debugMode)
    end)
end)
