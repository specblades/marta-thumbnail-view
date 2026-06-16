marta.expose()

plugin {
    id = "com.csaturnus.marta.thumbnailviewer",
    name = "Thumbnail Viewer",
    apiVersion = "2.2"
}

local thumbs = require "libmartathumbs"
local tiles_status_id = "thumbnail-viewer.tiles"
local last_model_signatures = {}
local refresh_tiles_if_enabled

local function folder_path(model)
    if model == nil or model.folder == nil then
        return nil
    end

    local path = model.folder.path
    if path ~= nil then
        return tostring(path)
    end

    return tostring(model.folder)
end

local function ns_window(context)
    if context == nil or context.window == nil then
        return nil
    end

    return context.window.nsWindow
end

local function remember_folder_mode(path, mode)
    if path ~= nil and path ~= "" then
        thumbs.setFolderMode(path, mode)
    end
end

local function remove_tiles_status(pane)
    if pane ~= nil and pane.view ~= nil then
        pane.view:removeStatusText(tiles_status_id)
    end
end

local function pane_key(context, pane)
    return tostring(context and context.window) .. ":" .. tostring(pane and pane.id)
end

local function model_signature(model)
    local parts = {folder_path(model) or "", tostring(#model)}

    for index = 0, #model - 1 do
        local item = model:getItem(index)
        local info = item and item.info
        if info ~= nil then
            parts[#parts + 1] = tostring(info.path)
        end
    end

    return table.concat(parts, "\n")
end

local function remember_model_signature(context, pane, model)
    if pane ~= nil and model ~= nil then
        last_model_signatures[pane_key(context, pane)] = model_signature(model)
    end
end

local function run_action(action_id, context)
    local action = globalContext.actions:getById(action_id)
    if action == nil then
        context.activePane.view:showNotification("Action not found: " .. action_id, "thumbnail-viewer.action-not-found", 2)
        return
    end

    context.window:runAction(action, context)
end

local function run_first_action(action_ids, context)
    for _, action_id in ipairs(action_ids) do
        local action = globalContext.actions:getById(action_id)
        if action ~= nil then
            context.window:runAction(action, context)
            return true
        end
    end

    context.activePane.view:showNotification("Action not found", "thumbnail-viewer.action-not-found", 2)
    return false
end

local function collect_items(model)
    local items = {}

    for index = 0, #model - 1 do
        local item = model:getItem(index)
        local info = item and item.info
        if info ~= nil then
            table.insert(items, {
                index = index,
                path = tostring(info.path),
                name = tostring(info.name),
                isFolder = info.isFolder,
                isFile = info.isFile,
                isPackage = info.isPackage,
                selected = model:isSelected(index),
                current = index == model.currentIndex
            })
        end
    end

    return items
end

local function current_rect_table(pane)
    local rect = pane.view.currentItemRect
    if rect == nil then
        return nil
    end

    return {
        x = rect.x,
        y = rect.y,
        width = rect.width,
        height = rect.height
    }
end

local function show_tiles(context, options)
    options = options or {}

    local pane = context.activePane
    local model = pane.model
    local folder = model.folder
    if folder == nil then
        if not options.quiet then
            martax.alert("No folder is open in the active pane.")
        end
        return
    end

    local path = folder_path(model)
    local window = ns_window(context)
    if window == nil then
        if not options.quiet then
            pane.view:showNotification("Window is not available", "thumbnail-viewer.show-failed", 3)
        end
        return
    end

    local callbacks = {
        select = function(index, mode, anchor)
            index = tonumber(index)
            anchor = tonumber(anchor)
            if index == nil then
                return
            end

            if mode == "toggle" then
                model.currentIndex = index
                model:invertSelection(index)
            elseif mode == "extend" and anchor ~= nil then
                local from = math.min(anchor, index)
                local to = math.max(anchor, index)
                model:deselectAll()
                model.currentIndex = index
                model:select({from = from, to = to})
            else
                model:deselectAll()
                model.currentIndex = index
                model:select(index)
            end

            pane.view:ensureCurrentItemVisible()
        end,

        open = function(index)
            index = tonumber(index)
            if index ~= nil then
                model:deselectAll()
                model.currentIndex = index
                model:select(index)
            end

            thumbs.closeOverlay(window)
            run_first_action({"core.open.folder", "core.open.directory", "core.open"}, context)
        end,

        action = function(action_id)
            if action_id == "thumbnail.preview" then
                run_first_action({"core.preview"}, context)
            else
                run_action(action_id, context)
            end
        end,

        close = function(reason)
            remove_tiles_status(pane)
            if reason == "keyboard" or reason == "toggle" then
                last_model_signatures[pane_key(context, pane)] = nil
                remember_folder_mode(path, "list")
            end
        end,

        refresh = function()
            if refresh_tiles_if_enabled ~= nil then
                refresh_tiles_if_enabled(context, true)
            end
        end
    }

    local ok, state_or_message = thumbs.showOverlay(
        window,
        collect_items(model),
        tostring(pane.id),
        current_rect_table(pane),
        callbacks,
        options.toggle ~= false
    )
    if ok and state_or_message == "closed" then
        remove_tiles_status(pane)
        last_model_signatures[pane_key(context, pane)] = nil
        remember_folder_mode(path, "list")
    elseif ok then
        remember_model_signature(context, pane, model)
        remember_folder_mode(path, "tiles")
        pane.view:addStatusText("Tiles", tiles_status_id, "ending")
    elseif state_or_message ~= nil and not options.quiet then
        pane.view:showNotification(tostring(state_or_message), "thumbnail-viewer.show-failed", 3)
    end
end

local function apply_saved_view_mode(context)
    local pane = context.activePane
    if pane == nil or pane.model == nil then
        return
    end

    local path = folder_path(pane.model)
    if path == nil then
        return
    end

    local mode = thumbs.getFolderMode(path)
    if mode == "tiles" then
        show_tiles(context, {toggle = false, quiet = true})
    else
        local window = ns_window(context)
        if window ~= nil then
            thumbs.closeOverlay(window)
        end
        remove_tiles_status(pane)
        last_model_signatures[pane_key(context, pane)] = nil
    end
end

refresh_tiles_if_enabled = function(context, force)
    local pane = context.activePane
    if pane == nil or pane.model == nil then
        return
    end

    local path = folder_path(pane.model)
    if path == nil then
        return
    end

    if thumbs.getFolderMode(path) == "tiles" then
        local key = pane_key(context, pane)
        local signature = model_signature(pane.model)
        if not force and last_model_signatures[key] == signature then
            return
        end

        local window = ns_window(context)
        if window ~= nil and thumbs.updateOverlay(window, collect_items(pane.model)) then
            remember_model_signature(context, pane, pane.model)
            pane.view:addStatusText("Tiles", tiles_status_id, "ending")
        else
            show_tiles(context, {toggle = false, quiet = true})
        end
    end
end

listModelHandler {
    locationChanged = function(context)
        apply_saved_view_mode(context)
    end,

    modelReloaded = function(context)
        refresh_tiles_if_enabled(context)
    end,

    modelUpdated = function(context)
        refresh_tiles_if_enabled(context)
    end,

    modelRefreshed = function(context)
        refresh_tiles_if_enabled(context)
    end,

    stateUpdated = function(context)
        refresh_tiles_if_enabled(context)
    end
}

action {
    id = "open",
    name = "View",
    shortName = "View",
    apply = function(context)
        show_tiles(context)
    end
}
