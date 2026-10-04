-- Violence District / NEO UI v0.4 | Written from scratch.
-- Generic client prototype. Not tested in Violence District or Arceus Neo.
-- Implemented: player ESP, camera aim, nearby generator prompts,
-- speed multiplier (0.0001x to 10x), local unanchor, local WalkSpeed floor,
-- JSON profiles, aim hold/FOV/point selection, object ESP and distance labels,
-- quick controls, floating menu logo, credits, Lite mode and typing pause. Automation starts OFF.
-- Server-specific requests are displayed as pending, never as working toggles.
-- No external libraries, downloads, remote firing, or injected config code.

-- Branding: replace LogoImage with a Roblox image asset URI for your own logo.
-- Leave it empty to use the built-in VD monogram. Credit is plain display text.
local BRANDING = {LogoText = "VD", LogoImage = "", Credit = "Hengker145"}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Input = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer
assert(LocalPlayer, "Run on the client after joining the game")
local environment = (type(getgenv) == "function" and getgenv()) or _G
local KEY, CONFIG_KEY = "VD_FromScratch_Base_v01", "VD_Neo_Config_Session_v2"
if environment[KEY] and environment[KEY].cleanup then environment[KEY].cleanup() end
local FILE, LEGACY_FILE = "VD_Neo_Config_v2.json", "VD_Neo_Config_v1.json"
local firePrompt = fireproximityprompt
local diskWrite, diskRead = writefile, readfile

-- BEGIN CONFIG CORE (pure validation; configs contain data only).
local defaults = {esp = false, aim = false, generator = false, enemiesOnly = true,
    speedEnabled = false, speedMultiplier = 1, noSlow = false, unanchor = false,
    aimAngle = 18, aimResponse = 12, aimPart = "Head", aimHold = true,
    showAimCircle = true, pauseTyping = true, objectESP = false,
    espMaxDistance = 500, aimMaxDistance = 500, espRefresh = 0.25,
    lite = false, showQuick = true, showHUD = true}
local limits = {speedMultiplier = {0.0001, 10}, aimAngle = {1, 90}, aimResponse = {1, 30},
    espMaxDistance = {25, 2000}, aimMaxDistance = {25, 2000}, espRefresh = {0.1, 2}}
local choices = {aimPart = {Head = true, HumanoidRootPart = true}}
local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end
local function validateConfig(document)
    if type(document) ~= "table" or document.version ~= 1 or type(document.settings) ~= "table" then
        return nil, "Config harus berupa JSON versi 1 dengan settings."
    end
    local settings, matched = {}, 0
    for key, default in pairs(defaults) do
        local value = document.settings[key]
        if value == nil then value = default else matched = matched + 1 end
        if type(default) == "boolean" then
            if type(value) ~= "boolean" then return nil, key .. " harus true/false." end
        elseif type(default) == "string" then
            if type(value) ~= "string" or not choices[key][value] then return nil, key .. " tidak dikenali." end
        else
            if not finite(value) then return nil, key .. " harus angka valid." end
            value = math.clamp(value, limits[key][1], limits[key][2])
        end
        settings[key] = value
    end
    if matched == 0 then return nil, "Tidak ada pengaturan yang dikenali." end
    return settings
end
local function multiplierToUnit(value)
    return math.clamp((math.log(math.clamp(value, 0.0001, 10)) / math.log(10) + 4) / 5, 0, 1)
end
local function unitToMultiplier(value)
    return math.clamp(10 ^ (math.clamp(value, 0, 1) * 5 - 4), 0.0001, 10)
end
-- END CONFIG CORE
local state = {alive = true}
for key, value in pairs(defaults) do state[key] = value end
local connections, markers, updaters = {}, {}, {}
local objectCandidates = setmetatable({}, {__mode = "k"})
local objectMarkers, extraUI = {}, {}
local inputState = {held = {}, right = false, fps = 0, hudElapsed = 0, pauseReason = nil}
local profileState = {names = {"Survivor", "Killer", "Lite", "Custom1", "Custom2"}, selected = 1, profiles = {}}
local function profileName() return profileState.names[profileState.selected] end
local prompts = setmetatable({}, {__mode = "k"})
local lastPrompt = setmetatable({}, {__mode = "k"})
local applyMovement, restoreMovement, clearAllVisuals, rescanObjects
local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(connections, connection)
    return connection
end
local function make(className, parent, properties)
    local object = Instance.new(className)
    for key, value in pairs(properties or {}) do object[key] = value end
    object.Parent = parent
    return object
end
local colors = {base = Color3.fromRGB(16, 20, 27), card = Color3.fromRGB(26, 32, 42),
    edge = Color3.fromRGB(43, 54, 68), text = Color3.fromRGB(235, 241, 247),
    muted = Color3.fromRGB(143, 158, 178), accent = Color3.fromRGB(96, 226, 184)}
local function round(object, radius)
    make("UICorner", object, {CornerRadius = UDim.new(0, radius or 10)})
end
local function label(parent, text, x, y, w, h, size, color)
    return make("TextLabel", parent, {Position = UDim2.fromOffset(x, y),
        Size = UDim2.new(w, -2 * x, 0, h), BackgroundTransparency = 1,
        Text = text, Font = Enum.Font.Gotham, TextSize = size or 13,
        TextColor3 = color or colors.text, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center, TextWrapped = true})
end
local function refreshUI()
    if not state.alive then return end
    for _, update in ipairs(updaters) do update() end
end
local function setSetting(key, value)
    if defaults[key] == nil then return end
    if limits[key] then
        if not finite(value) then return end
        value = math.clamp(value, limits[key][1], limits[key][2])
    elseif choices[key] then
        if type(value) ~= "string" or not choices[key][value] then return end
    elseif type(value) ~= "boolean" then return end
    if key == "generator" and type(firePrompt) ~= "function" then value = false end
    state[key] = value
    refreshUI()
    if applyMovement then applyMovement() end
end
local gui = make("ScreenGui", LocalPlayer:WaitForChild("PlayerGui"), {
    Name = "VD_Neo_UI", ResetOnSpawn = false, DisplayOrder = 100,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling})
local function surfaceSize()
    local size = gui.AbsoluteSize
    if size.X > 0 and size.Y > 0 then return size end
    local camera = workspace.CurrentCamera
    return camera and camera.ViewportSize or Vector2.new(800, 600)
end
local panel = make("Frame", gui, {Position = UDim2.fromOffset(12, 76),
    Name = "VD_MainMenu", Visible = false, Size = UDim2.fromOffset(340, 500),
    BackgroundColor3 = colors.base, BorderSizePixel = 0})
round(panel, 15)
make("UIStroke", panel, {Color = colors.edge, Thickness = 1})
local scale = make("UIScale", panel, {Scale = 1})
local header = make("Frame", panel, {Size = UDim2.new(1, -80, 0, 58),
    BackgroundTransparency = 1, Active = true})
local title = label(header, "VIOLENCE DISTRICT", 16, 7, 1, 24, 15)
title.Font = Enum.Font.GothamBold
title.Active = true
local subtitle = label(header, "NEO UI  /  v0.4", 16, 31, 1, 16, 10, colors.accent)
subtitle.Active = true
local function smallButton(text, x)
    local result = make("TextButton", panel, {Size = UDim2.fromOffset(29, 29),
        Position = UDim2.new(1, x, 0, 14), Text = text, TextSize = 19,
        BackgroundColor3 = colors.card, TextColor3 = colors.text, BorderSizePixel = 0})
    round(result, 8)
    return result
end
local minimize, close = smallButton("−", -76), smallButton("×", -39)
local tabs = make("Frame", panel, {Position = UDim2.fromOffset(12, 62),
    Size = UDim2.new(1, -24, 0, 33), BackgroundTransparency = 1})
local body = make("Frame", panel, {Position = UDim2.fromOffset(12, 104),
    Size = UDim2.new(1, -24, 0, 342), BackgroundTransparency = 1})
local footer = label(panel, "Siap · fitur lokal belum diuji di game", 16, 451, 1, 24, 11, colors.muted)
local credit = label(panel, "Credit · " .. BRANDING.Credit, 16, 477, 1, 16, 10, colors.accent)
credit.Name = "VD_Credit"
local messageUntil = 0
local function notify(message)
    footer.Text = message
    messageUntil = os.clock() + 7
end
local pages, tabButtons = {}, {}
local selectedTab = "Gerak"
local function switchTab(name)
    selectedTab = name
    for tab, page in pairs(pages) do
        page.Visible = tab == name
        tabButtons[tab].BackgroundColor3 = tab == name and colors.accent or colors.card
        tabButtons[tab].TextColor3 = tab == name and colors.base or colors.muted
    end
end
for index, name in ipairs({"Gerak", "Visual", "Game", "Config"}) do
    local tab = make("TextButton", tabs, {Position = UDim2.new((index - 1) / 4, 2, 0, 0),
        Size = UDim2.new(0.25, -4, 1, 0), Text = name, Font = Enum.Font.GothamBold,
        TextSize = 12, BackgroundColor3 = colors.card, TextColor3 = colors.muted, BorderSizePixel = 0})
    round(tab, 8)
    local page = make("ScrollingFrame", body, {Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
        ScrollBarImageColor3 = colors.edge, CanvasSize = UDim2.fromOffset(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y})
    make("UIListLayout", page, {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder})
    make("UIPadding", page, {PaddingRight = UDim.new(0, 7), PaddingBottom = UDim.new(0, 8)})
    pages[name], tabButtons[name] = page, tab
    connect(tab.Activated, function() switchTab(name) end)
end
local order = 0
local function card(page, height)
    order = order + 1
    local result = make("Frame", page, {Size = UDim2.new(1, 0, 0, height),
        BackgroundColor3 = colors.card, BorderSizePixel = 0, LayoutOrder = order})
    round(result)
    return result
end
local function toggle(page, text, description, key, available)
    local row = card(page, 78)
    local name = label(row, text, 12, 9, 1, 23, 13)
    name.Size = UDim2.new(1, -84, 0, 23)
    local desc = label(row, description, 12, 33, 1, 36, 10, colors.muted)
    desc.TextYAlignment = Enum.TextYAlignment.Top
    local control = make("TextButton", row, {Size = UDim2.fromOffset(48, 24),
        Position = UDim2.new(1, -60, 0, 10), TextSize = 10, Font = Enum.Font.GothamBold,
        TextColor3 = colors.muted, BorderSizePixel = 0, BackgroundColor3 = colors.edge})
    round(control, 12)
    local function update()
        control.Text = available == false and "N/A" or (state[key] and "ON" or "OFF")
        control.BackgroundColor3 = state[key] and colors.accent or colors.edge
        control.TextColor3 = state[key] and colors.base or colors.muted
        control.AutoButtonColor = available ~= false
    end
    table.insert(updaters, update)
    connect(control.Activated, function()
        if available == false then notify("Fitur ini tidak tersedia di executor."); return end
        setSetting(key, not state[key])
    end)
    update()
    return control
end
local function action(parent, text, x, y, width, callback)
    local control = make("TextButton", parent, {Position = UDim2.new(x, 8, 0, y),
        Size = UDim2.new(width, -16, 0, 34), Text = text, Font = Enum.Font.GothamBold,
        TextSize = 11, TextColor3 = colors.text, BackgroundColor3 = colors.edge, BorderSizePixel = 0})
    round(control, 8)
    connect(control.Activated, callback)
    return control
end
local function numeric(page, text, description, key)
    local row = card(page, 78)
    local name = label(row, text, 12, 9, 1, 24, 13)
    name.Size = UDim2.new(1, -110, 0, 24)
    local input = make("TextBox", row, {Position = UDim2.new(1, -94, 0, 9),
        Size = UDim2.fromOffset(82, 27), Text = "", ClearTextOnFocus = false,
        Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = colors.accent,
        BackgroundColor3 = colors.base, BorderSizePixel = 0})
    round(input, 6)
    label(row, description, 12, 39, 1, 30, 10, colors.muted)
    table.insert(updaters, function()
        if not input:IsFocused() then input.Text = string.format("%.6g", state[key]) end
    end)
    connect(input.FocusLost, function()
        local number = tonumber((input.Text:gsub(",", ".")))
        if not finite(number) then notify("Masukkan angka yang valid.")
        else setSetting(key, number) end
        input.Text = string.format("%.6g", state[key])
    end)
end
toggle(pages.Gerak, "Atur kecepatan", "Pengali WalkSpeed. Nilai 1× memakai kecepatan dasar karakter.", "speedEnabled")
local speedCard = card(pages.Gerak, 156)
label(speedCard, "Pengali kecepatan", 12, 7, 1, 24, 13)
local speedInput = make("TextBox", speedCard, {Position = UDim2.new(1, -104, 0, 7),
    Size = UDim2.fromOffset(92, 27), Text = "1", ClearTextOnFocus = false,
    Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = colors.accent,
    BackgroundColor3 = colors.base, BorderSizePixel = 0})
round(speedInput, 6)
label(speedCard, "0.0001×", 12, 38, 1, 18, 10, colors.muted)
local maxLabel = label(speedCard, "10×", 12, 38, 1, 18, 10, colors.muted)
maxLabel.TextXAlignment = Enum.TextXAlignment.Right
local slider = make("TextButton", speedCard, {Position = UDim2.fromOffset(12, 62),
    Size = UDim2.new(1, -24, 0, 24), BackgroundTransparency = 1, Text = "", AutoButtonColor = false})
local track = make("Frame", slider, {Position = UDim2.fromOffset(0, 10),
    Size = UDim2.new(1, 0, 0, 4), BackgroundColor3 = colors.edge, BorderSizePixel = 0})
round(track, 2)
local fill = make("Frame", track, {Size = UDim2.new(0.8, 0, 1, 0),
    BackgroundColor3 = colors.accent, BorderSizePixel = 0})
round(fill, 2)
local knob = make("Frame", slider, {Size = UDim2.fromOffset(16, 16),
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.8, 0, 0.5, 0),
    BackgroundColor3 = colors.accent, BorderSizePixel = 0})
round(knob, 8)
for index, value in ipairs({0.0001, 0.5, 1, 2, 10}) do
    local text = tostring(value) .. "×"
    action(speedCard, text, (index - 1) / 5, 96, 0.2, function() setSetting("speedMultiplier", value) end)
end
label(speedCard, "Ketik angka untuk presisi; slider memakai skala log.", 12, 132, 1, 18, 9, colors.muted)
table.insert(updaters, function()
    local unit = multiplierToUnit(state.speedMultiplier)
    fill.Size = UDim2.new(unit, 0, 1, 0)
    knob.Position = UDim2.new(unit, 0, 0.5, 0)
    if not speedInput:IsFocused() then speedInput.Text = string.format("%.6g", state.speedMultiplier) end
end)
connect(speedInput.FocusLost, function()
    local value = tonumber((speedInput.Text:gsub(",", ".")))
    if finite(value) then setSetting("speedMultiplier", value)
    else notify("Masukkan angka antara 0.0001 dan 10.") end
    speedInput.Text = string.format("%.6g", state.speedMultiplier)
end)
local sliding, sliderInput = false, nil
local function slideAt(position)
    local width = slider.AbsoluteSize.X
    if width > 0 then setSetting("speedMultiplier", unitToMultiplier((position.X - slider.AbsolutePosition.X) / width)) end
end
connect(slider.InputBegan, function(event)
    if event.UserInputType == Enum.UserInputType.Touch or event.UserInputType == Enum.UserInputType.MouseButton1 then
        sliding, sliderInput = true, event
        slideAt(event.Position)
    end
end)
connect(Input.InputChanged, function(event)
    if sliding and (event == sliderInput or (sliderInput.UserInputType == Enum.UserInputType.MouseButton1
        and event.UserInputType == Enum.UserInputType.MouseMovement)) then slideAt(event.Position) end
end)
connect(Input.InputEnded, function(event)
    if event == sliderInput then sliding = false; sliderInput = nil end
end)
toggle(pages.Gerak, "No slow · lokal", "Jaga batas minimum WalkSpeed; status stun dari server belum ditangani.", "noSlow")
toggle(pages.Gerak, "Auto lepas anchor · lokal", "Lepas Anchored pada bagian karakter sendiri; bukan lepas hook/carry.", "unanchor")
toggle(pages.Visual, "ESP pemain", "Highlight dan nama pemain. Karakter baru ditangani setelah respawn.", "esp")
toggle(pages.Visual, "Auto aim kamera", "Arahkan kamera ke target terlihat. Aim skill spear/kamera belum terhubung.", "aim")
toggle(pages.Visual, "Aim saat ditahan", "Minimalkan menu, tahan tombol HOLD. Di PC bisa tahan klik kanan.", "aimHold")
toggle(pages.Visual, "Lingkaran aim", "Tampilkan area pencarian target yang sesuai dengan sudut kamera.", "showAimCircle")
toggle(pages.Visual, "Pause saat mengetik", "Aim dan auto prompt berhenti sementara saat kolom teks sedang aktif.", "pauseTyping")
toggle(pages.Visual, "Filter tim lawan", "Pakai Team Roblox. Role survivor/killer khusus belum dikenali.", "enemiesOnly")
do
    local row = card(pages.Visual, 78)
    label(row, "Titik bidik", 12, 5, 1, 22, 13)
    local control = action(row, "Kepala", 0, 34, 1, function()
        setSetting("aimPart", state.aimPart == "Head" and "HumanoidRootPart" or "Head")
    end)
    table.insert(updaters, function() control.Text = state.aimPart == "Head" and "Kepala" or "Badan" end)
end
numeric(pages.Visual, "Sudut aim", "Rentang 1–90 derajat dari pusat kamera.", "aimAngle")
numeric(pages.Visual, "Respons aim", "Rentang 1–30. Nilai besar mengunci kamera lebih cepat.", "aimResponse")
numeric(pages.Visual, "Jarak aim", "Batas pencarian target dalam stud, 25–2000.", "aimMaxDistance")
toggle(pages.Visual, "ESP objek", "Generator, exit/pintu dan item berdasarkan nama; cakupan perlu dicek di game.", "objectESP")
numeric(pages.Visual, "Jarak ESP", "Batas pemain dan objek dalam stud, 25–2000.", "espMaxDistance")
numeric(pages.Visual, "Interval ESP", "Detik per pembaruan. Nilai besar mengurangi frekuensi kerja script.", "espRefresh")
toggle(pages.Visual, "Mode ringan", "Batasi ESP ke 180 stud, 8 objek, pembaruan minimal 0.65 detik.", "lite")
toggle(pages.Visual, "Tombol cepat", "Panel tombol muncul ketika menu diminimalkan atau disembunyikan.", "showQuick")
toggle(pages.Visual, "HUD status", "Tampilkan perkiraan FPS, status aim, dan profil terpilih.", "showHUD")
local generatorButton = toggle(pages.Game, "Auto prompt generator", "Coba prompt generator yang aktif dan dekat; belum auto perfect.", "generator", type(firePrompt) == "function")
local statusCard = card(pages.Game, 86)
local status = label(statusCard, "Generator OFF", 12, 10, 1, 66, 11, colors.muted)
status.TextYAlignment = Enum.TextYAlignment.Top
local pending = {
    {"Boost / auto gene perfect", "Perlu alur repair dan skill check game."},
    {"Peluru pistol tak habis", "Perlu sistem ammo/reload dan validasi game."},
    {"Magic bullet", "Perlu sistem hit senjata game."},
    {"Auto parry", "Perlu animasi serangan dan jendela parry."},
    {"Semua skill killer no cooldown", "Perlu handler skill dan timer game."},
    {"Aim skill kamera / spear", "Perlu arah skill, proyektil, dan data target."},
    {"Survivor god mode / self heal", "Perlu sistem damage dan heal game."},
    {"Invisible bagi pemain lain", "Perlu mekanik game; lokal saja tidak menjamin efek ini."},
    {"Semua perk aktif", "Perlu ownership dan efek perk game."},
    {"Auto jongkok untuk dodge", "Perlu deteksi killer, serangan, dan input crouch."}}
for _, entry in ipairs(pending) do
    local row = card(pages.Game, 76)
    local name = label(row, entry[1], 12, 6, 1, 22, 12)
    name.Size = UDim2.new(1, -104, 0, 22)
    local badge = label(row, "PERLU DATA", 0, 9, 0, 18, 8, colors.muted)
    badge.Position = UDim2.new(1, -93, 0, 9)
    badge.Size = UDim2.fromOffset(82, 18)
    label(row, entry[2], 12, 32, 1, 35, 10, colors.muted)
end
local applyProfilePreset
do
    local row = card(pages.Config, 147)
    label(row, "Profil config", 12, 7, 1, 23, 14)
    local select = action(row, "Profil: Survivor", 0, 35, 1, function()
        profileState.selected = profileState.selected % #profileState.names + 1
        refreshUI()
        notify("Profil dipilih. Save/Load memakai slot " .. profileName() .. ".")
    end)
    action(row, "Pakai preset profil", 0, 77, 1, function() applyProfilePreset() end)
    label(row, "Role dipilih manual. Save menyimpan pengaturan ke slot terpilih.", 12, 115, 1, 26, 10, colors.muted)
    table.insert(updaters, function() select.Text = "Profil: " .. profileName() end)
end
local configCard = card(pages.Config, 160)
label(configCard, "Konfigurasi", 12, 8, 1, 24, 14)
local storageLabel = label(configCard, "", 12, 33, 1, 24, 10, colors.muted)
storageLabel.Text = type(diskWrite) == "function" and type(diskRead) == "function"
    and "Simpan file JSON; cadangan tersedia selama sesi."
    or "API file terbatas; cadangan tersedia selama sesi."
local saveConfig, loadConfig, exportConfig, importConfig
action(configCard, "Save", 0, 67, 0.5, function() saveConfig() end)
action(configCard, "Load", 0.5, 67, 0.5, function() loadConfig() end)
action(configCard, "Export JSON", 0, 111, 0.5, function() exportConfig() end)
action(configCard, "Import JSON", 0.5, 111, 0.5, function() importConfig() end)
local diagnosticsCard = card(pages.Config, 80)
label(diagnosticsCard, "Data game", 12, 6, 1, 22, 13)
local diagnosticsButton = action(diagnosticsCard, "Salin / lihat diagnostik", 0, 35, 1, function() end)
do
    local row = card(pages.Config, 80)
    label(row, "Pengenalan objek", 12, 6, 1, 22, 13)
    action(row, "Scan ulang objek", 0, 35, 1, function()
        if rescanObjects then rescanObjects() end
    end)
end
local resetCard = card(pages.Config, 80)
label(resetCard, "Pengaturan default", 12, 6, 1, 22, 13)
action(resetCard, "Reset semua pengaturan", 0, 35, 1, function()
    for key, value in pairs(defaults) do state[key] = value end
    inputState.held, inputState.right = {}, false
    refreshUI()
    if applyMovement then applyMovement() end
    notify("Pengaturan direset; semua fitur OFF.")
end)
do
    local row = card(pages.Config, 86)
    label(row, "Credit", 12, 6, 1, 22, 14, colors.accent)
    label(row, BRANDING.Credit .. "\nOPSCRIPTVD · Violence District\nNEO UI v0.4", 12, 31, 1, 47, 11, colors.muted)
end
do
    local row = card(pages.Config, 80)
    label(row, "Tutup script dan matikan fitur", 12, 6, 1, 22, 13)
    action(row, "Unload script", 0, 35, 1, function()
        if state.cleanup then state.cleanup() end
    end)
end

-- Shared text modal: reports are read-only; import accepts JSON data only.
local reportPanel = make("Frame", gui, {Position = UDim2.fromScale(0.05, 0.1),
    Size = UDim2.fromScale(0.9, 0.8), Visible = false, BackgroundColor3 = colors.base,
    BorderSizePixel = 0, ZIndex = 10})
round(reportPanel, 14)
local modalTitle = label(reportPanel, "Diagnostik", 14, 6, 1, 32, 14)
modalTitle.ZIndex = 11
local reportClose = make("TextButton", reportPanel, {Size = UDim2.fromOffset(32, 28),
    Position = UDim2.new(1, -42, 0, 8), Text = "×", TextSize = 18,
    BackgroundColor3 = colors.card, TextColor3 = colors.text, BorderSizePixel = 0, ZIndex = 12})
round(reportClose, 8)
local reportScroll = make("ScrollingFrame", reportPanel, {
    Position = UDim2.fromOffset(12, 44), Size = UDim2.new(1, -24, 1, -104),
    BackgroundColor3 = colors.card, BorderSizePixel = 0, ScrollBarThickness = 5,
    CanvasSize = UDim2.fromOffset(0, 0), ZIndex = 11})
round(reportScroll, 8)
local reportText = make("TextBox", reportScroll, {Position = UDim2.fromOffset(8, 8),
    Size = UDim2.new(1, -22, 0, 500), BackgroundTransparency = 1, MultiLine = true,
    ClearTextOnFocus = false, TextEditable = false, Text = "", Font = Enum.Font.Code,
    TextSize = 12, TextColor3 = colors.text, TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, ZIndex = 12})
local modalAction = make("TextButton", reportPanel, {Position = UDim2.new(0, 12, 1, -48),
    Size = UDim2.new(1, -24, 0, 34), Text = "Salin teks", Font = Enum.Font.GothamBold,
    TextSize = 12, TextColor3 = colors.base, BackgroundColor3 = colors.accent, BorderSizePixel = 0, ZIndex = 12})
round(modalAction, 8)
local modalMode = "copy"
local function openModal(titleText, text, editable)
    modalTitle.Text, reportText.Text, reportText.TextEditable = titleText, text, editable == true
    modalMode = editable and "import" or "copy"
    modalAction.Text = editable and "Terapkan JSON" or "Salin teks"
    reportScroll.CanvasPosition = Vector2.new(0, 0)
    reportPanel.Visible = true
end
connect(reportClose.Activated, function() reportPanel.Visible = false; reportText:ReleaseFocus() end)
connect(reportText:GetPropertyChangedSignal("TextBounds"), function()
    local height = math.max(500, reportText.TextBounds.Y + 24)
    reportText.Size = UDim2.new(1, -22, 0, height)
    reportScroll.CanvasSize = UDim2.fromOffset(0, height + 16)
end)
local function document()
    local settings = {}
    for key in pairs(defaults) do settings[key] = state[key] end
    return {version = 1, profile = profileName(), placeId = game.PlaceId, settings = settings}
end
local function applySettings(settings)
    if type(firePrompt) ~= "function" then settings.generator = false end
    inputState.held, inputState.right = {}, false
    for key, value in pairs(settings) do state[key] = value end
    refreshUI()
    if applyMovement then applyMovement() end
end
local function applyConfigText(text)
    if type(text) ~= "string" or #text > 16384 then return false, "Config kosong atau terlalu besar." end
    local ok, decoded = pcall(function() return HttpService:JSONDecode(text) end)
    if not ok then return false, "JSON tidak valid." end
    local settings, errorText = validateConfig(decoded)
    if not settings then return false, errorText end
    applySettings(settings)
    profileState.profiles[profileName()] = document()
    return true, "Config diterapkan."
end
local function parseProfileBook(text)
    if type(text) ~= "string" or #text > 65536 then return nil, "File profil terlalu besar atau kosong." end
    local ok, decoded = pcall(function() return HttpService:JSONDecode(text) end)
    if not ok or type(decoded) ~= "table" or decoded.version ~= 2 or type(decoded.profiles) ~= "table" then
        return nil, "File profil versi 2 tidak valid."
    end
    local profiles = {}
    for _, name in ipairs(profileState.names) do
        local entry = decoded.profiles[name]
        if entry ~= nil then
            local settings, errorText = validateConfig(entry)
            if not settings then return nil, name .. ": " .. errorText end
            profiles[name] = {version = 1, profile = name, placeId = entry.placeId, settings = settings}
        end
    end
    return profiles
end
local function readProfileBook()
    if type(diskRead) == "function" then
        local ok, text = pcall(diskRead, FILE)
        if ok then
            local profiles = parseProfileBook(text)
            if profiles then return profiles, "file" end
        end
    end
    local profiles = parseProfileBook(environment[CONFIG_KEY])
    if profiles then return profiles, "sesi" end
    return nil
end
applyProfilePreset = function()
    local settings = {}
    for key, value in pairs(defaults) do settings[key] = value end
    local name = profileName()
    if name == "Survivor" then
        settings.esp, settings.objectESP, settings.espMaxDistance = true, true, 350
    elseif name == "Killer" then
        settings.esp, settings.aim, settings.aimHold = true, true, true
    elseif name == "Lite" then
        settings.esp, settings.lite, settings.showAimCircle = true, true, false
        settings.espMaxDistance, settings.espRefresh = 180, 0.65
    end
    applySettings(settings)
    notify("Preset " .. name .. " diterapkan. Tekan Save untuk menyimpan perubahan.")
end
saveConfig = function()
    -- Merge stored slots first, so Save after reloading the script preserves other profiles.
    local stored = readProfileBook()
    if stored then
        for name, entry in pairs(stored) do
            if not profileState.profiles[name] then profileState.profiles[name] = entry end
        end
    end
    profileState.profiles[profileName()] = document()
    local ok, text = pcall(function()
        return HttpService:JSONEncode({version = 2, selectedProfile = profileName(), profiles = profileState.profiles})
    end)
    if not ok then notify("Gagal membuat JSON."); return end
    environment[CONFIG_KEY] = text
    if type(diskWrite) == "function" then
        local written = pcall(diskWrite, FILE, text)
        if written then notify("Profil " .. profileName() .. " tersimpan ke file dan sesi."); return end
    end
    notify("Profil " .. profileName() .. " tersimpan untuk sesi ini.")
end
loadConfig = function()
    local stored, source = readProfileBook()
    if stored then
        profileState.profiles = stored
        local entry = stored[profileName()]
        if not entry then notify("Slot " .. profileName() .. " belum disimpan. Pakai preset atau Save dulu."); return end
        applySettings(entry.settings)
        notify("Profil " .. profileName() .. " dimuat dari " .. source .. ".")
        return
    end
    -- A single-profile v0.2 configuration can still be imported or loaded as a legacy fallback.
    local legacy = environment.VD_Neo_Config_Session_v1
    if type(diskRead) == "function" then
        local ok, text = pcall(diskRead, LEGACY_FILE)
        if ok and type(text) == "string" then legacy = text end
    end
    if type(legacy) == "string" then
        local ok, message = applyConfigText(legacy)
        notify(ok and "Config lama dimuat ke slot " .. profileName() .. "." or message)
    else
        notify("Belum ada profil tersimpan. Pakai preset, lalu Save.")
    end
end
do
    local stored = readProfileBook()
    if stored then
        for name, entry in pairs(stored) do
            profileState.profiles[name] = entry
        end
    end
end
exportConfig = function()
    local ok, text = pcall(function() return HttpService:JSONEncode(document()) end)
    if ok then openModal("Export config JSON", text, false)
    else notify("Gagal membuat JSON.") end
end
importConfig = function() openModal("Tempel config JSON", "", true); reportText:CaptureFocus() end
connect(modalAction.Activated, function()
    if modalMode == "import" then
        local ok, message = applyConfigText(reportText.Text)
        notify(message)
        if ok then reportPanel.Visible = false; reportText:ReleaseFocus() end
    elseif type(setclipboard) == "function" then
        local ok = pcall(setclipboard, reportText.Text)
        notify(ok and "Teks disalin." or "Gagal menyalin. Pilih teks secara manual.")
    else
        notify("Clipboard tidak tersedia. Pilih teks secara manual.")
    end
end)
local minimized = false
local function setMenuVisible(visible)
    panel.Visible = visible
    inputState.held = {}
    reportPanel.Visible = false
    reportText:ReleaseFocus()
    if visible then
        extraUI.menuOpened = true
        minimized = false
        body.Visible, tabs.Visible, footer.Visible, credit.Visible = true, true, true, true
        panel.Size, minimize.Text = UDim2.fromOffset(340, 500), "−"
    end
    refreshUI()
end
local function toggleMenu()
    if state.alive then setMenuVisible(minimized or not panel.Visible) end
end
connect(close.Activated, function() setMenuVisible(false) end)
connect(minimize.Activated, function()
    minimized = not minimized
    body.Visible, tabs.Visible, footer.Visible, credit.Visible = not minimized, not minimized, not minimized, not minimized
    panel.Size = UDim2.fromOffset(340, minimized and 58 or 500)
    minimize.Text = minimized and "+" or "−"
    refreshUI()
end)
local dragging, dragInput, dragStart, panelStart
local function beginDrag(event)
    if event.UserInputType == Enum.UserInputType.Touch or event.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging, dragInput, dragStart, panelStart = true, event, event.Position, panel.Position
    end
end
connect(header.InputBegan, beginDrag)
connect(title.InputBegan, beginDrag)
connect(subtitle.InputBegan, beginDrag)
connect(Input.InputChanged, function(event)
    if dragging and (event == dragInput or (dragInput.UserInputType == Enum.UserInputType.MouseButton1
        and event.UserInputType == Enum.UserInputType.MouseMovement)) then
        local delta = event.Position - dragStart
        local viewport = surfaceSize()
        local x = math.clamp(panelStart.X.Offset + delta.X, 0, math.max(0, viewport.X - panel.AbsoluteSize.X))
        local y = math.clamp(panelStart.Y.Offset + delta.Y, 0, math.max(0, viewport.Y - panel.AbsoluteSize.Y - 24))
        panel.Position = UDim2.fromOffset(x, y)
    end
end)
connect(Input.InputEnded, function(event)
    if event == dragInput then dragging = false; dragInput = nil end
end)
do
    local viewport = surfaceSize()
    local logo = make("TextButton", gui, {Name = "VD_MenuLogo", Position = UDim2.fromOffset(math.max(8, viewport.X - 72), 8),
        Size = UDim2.fromOffset(56, 56), Text = BRANDING.LogoImage == "" and BRANDING.LogoText or "",
        Font = Enum.Font.GothamBold, TextSize = 21, BackgroundColor3 = colors.base,
        TextColor3 = colors.accent, BorderSizePixel = 0, AutoButtonColor = false, ZIndex = 8})
    round(logo, 28)
    make("UIStroke", logo, {Color = colors.accent, Thickness = 2, Transparency = 0.15})
    make("ImageLabel", logo, {Name = "VD_LogoImage", Position = UDim2.fromOffset(10, 10),
        Size = UDim2.new(1, -20, 1, -20), BackgroundTransparency = 1, Image = BRANDING.LogoImage,
        Visible = BRANDING.LogoImage ~= "", ScaleType = Enum.ScaleType.Fit, ZIndex = 9})
    local function positionLogo(x, y)
        local surface = surfaceSize()
        logo.Position = UDim2.fromOffset(math.clamp(x, 0, math.max(0, surface.X - 56)),
            math.clamp(y, 0, math.max(0, surface.Y - 56)))
    end
    extraUI.clampLogo = function() positionLogo(logo.Position.X.Offset, logo.Position.Y.Offset) end
    extraUI.clampLogo()
    local movingInput, startX, startY, originalX, originalY, ignoredActivation
    connect(logo.InputBegan, function(event)
        if movingInput then return end
        if event.UserInputType == Enum.UserInputType.Touch or event.UserInputType == Enum.UserInputType.MouseButton1 then
            movingInput, ignoredActivation = event, nil
            startX, startY = event.Position.X, event.Position.Y
            originalX, originalY = logo.Position.X.Offset, logo.Position.Y.Offset
        end
    end)
    connect(Input.InputChanged, function(event)
        if movingInput and (event == movingInput or (movingInput.UserInputType == Enum.UserInputType.MouseButton1
            and event.UserInputType == Enum.UserInputType.MouseMovement)) then
            local dx, dy = event.Position.X - startX, event.Position.Y - startY
            if ignoredActivation or dx * dx + dy * dy >= 36 then
                ignoredActivation = movingInput
                positionLogo(originalX + dx, originalY + dy)
            end
        end
    end)
    connect(Input.InputEnded, function(event)
        if event == movingInput then movingInput = nil end
    end)
    connect(Input.WindowFocusReleased, function() movingInput = nil end)
    connect(logo.Activated, function(event)
        if ignoredActivation and (event == nil or event == ignoredActivation) then return end
        if movingInput and event and event ~= movingInput then return end
        toggleMenu()
    end)
    table.insert(updaters, function()
        local expanded = panel.Visible and not minimized
        logo.BackgroundColor3 = expanded and colors.accent or colors.base
        logo.TextColor3 = expanded and colors.base or colors.accent
    end)
    extraUI.overlay = make("ScreenGui", LocalPlayer:WaitForChild("PlayerGui"), {
        Name = "VD_Neo_AimOverlay", IgnoreGuiInset = true, ResetOnSpawn = false, DisplayOrder = 90})
    extraUI.circle = make("Frame", extraUI.overlay, {AnchorPoint = Vector2.new(0.5, 0.5),
        Name = "VD_AimCircle", BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false})
    make("UICorner", extraUI.circle, {CornerRadius = UDim.new(0.5, 0)})
    make("UIStroke", extraUI.circle, {Color = colors.accent, Thickness = 1, Transparency = 0.3})
    extraUI.hud = make("TextLabel", gui, {AnchorPoint = Vector2.new(0.5, 0),
        Name = "VD_StatusHUD",
        Position = UDim2.new(0.5, 0, 0, 3), Size = UDim2.fromOffset(330, 25),
        BackgroundColor3 = colors.base, BackgroundTransparency = 0.18, BorderSizePixel = 0,
        TextColor3 = colors.text, Font = Enum.Font.Gotham, TextSize = 10, Text = "VD v0.4 · siap"})
    round(extraUI.hud, 8)
    local quick = make("Frame", gui, {Position = UDim2.fromOffset(math.max(8, viewport.X - 88), 110),
        Name = "VD_QuickControls", Size = UDim2.fromOffset(76, 281), BackgroundColor3 = colors.base, BorderSizePixel = 0, ZIndex = 4})
    extraUI.quick = quick
    round(quick, 12)
    make("UIStroke", quick, {Color = colors.edge, Thickness = 1})
    extraUI.quickScale = make("UIScale", quick, {Scale = 1})
    local handle = label(quick, "NEO · geser", 6, 3, 1, 19, 8, colors.muted)
    handle.Active, handle.ZIndex = true, 5
    local function quickButton(text, y, height)
        local result = make("TextButton", quick, {Position = UDim2.fromOffset(6, y),
            Size = UDim2.new(1, -12, 0, height or 28), Text = text, Font = Enum.Font.GothamBold,
            TextSize = 10, TextColor3 = colors.text, BackgroundColor3 = colors.edge, BorderSizePixel = 0, ZIndex = 5})
        round(result, 7)
        return result
    end
    for index, entry in ipairs({{"AIM", "aim"}, {"ESP", "esp"}, {"SPEED", "speedEnabled"}, {"OBJ", "objectESP"}}) do
        local control = quickButton(entry[1], 25 + (index - 1) * 34)
        connect(control.Activated, function() setSetting(entry[2], not state[entry[2]]) end)
        table.insert(updaters, function()
            control.Text = entry[1] .. (state[entry[2]] and " ON" or " OFF")
            control.BackgroundColor3 = state[entry[2]] and colors.accent or colors.edge
            control.TextColor3 = state[entry[2]] and colors.base or colors.text
        end)
    end
    local hold = quickButton("HOLD AIM", 163, 40)
    connect(hold.InputBegan, function(event)
        if event.UserInputType == Enum.UserInputType.Touch or event.UserInputType == Enum.UserInputType.MouseButton1 then
            inputState.held[event] = true
        end
    end)
    connect(Input.InputEnded, function(event)
        inputState.held[event] = nil
        if event.UserInputType == Enum.UserInputType.MouseButton2 then inputState.right = false end
    end)
    local function stop()
        for _, key in ipairs({"esp", "objectESP", "aim", "generator", "speedEnabled", "noSlow", "unanchor"}) do state[key] = false end
        inputState.held, inputState.right = {}, false
        if restoreMovement then restoreMovement() end
        if clearAllVisuals then clearAllVisuals() end
        extraUI.circle.Visible = false
        refreshUI()
        notify("STOP: semua fitur permainan OFF; config tersimpan tetap ada.")
    end
    connect(quickButton("STOP", 209).Activated, stop)
    connect(quickButton("MENU", 243).Activated, toggleMenu)
    connect(Input.InputBegan, function(event, processed)
        if processed then return end
        if event.UserInputType == Enum.UserInputType.MouseButton2 then inputState.right = true end
        if event.KeyCode == Enum.KeyCode.RightShift then toggleMenu()
        elseif event.KeyCode == Enum.KeyCode.End then stop() end
    end)
    connect(Input.WindowFocusReleased, function() inputState.held, inputState.right = {}, false end)
    table.insert(updaters, function()
        quick.Visible = state.showQuick and extraUI.menuOpened == true and (minimized or not panel.Visible) and not reportPanel.Visible
        extraUI.hud.Visible = state.showHUD
    end)
    local draggingQuick, movingInput, start, original
    connect(handle.InputBegan, function(event)
        if event.UserInputType == Enum.UserInputType.Touch or event.UserInputType == Enum.UserInputType.MouseButton1 then
            draggingQuick, movingInput, start, original = true, event, event.Position, quick.Position
        end
    end)
    connect(Input.InputChanged, function(event)
        if draggingQuick and (event == movingInput or (movingInput.UserInputType == Enum.UserInputType.MouseButton1
            and event.UserInputType == Enum.UserInputType.MouseMovement)) then
            local current = surfaceSize()
            local delta = event.Position - start
            quick.Position = UDim2.fromOffset(
                math.clamp(original.X.Offset + delta.X, 0, math.max(0, current.X - quick.AbsoluteSize.X)),
                math.clamp(original.Y.Offset + delta.Y, 0, math.max(0, current.Y - quick.AbsoluteSize.Y - 36)))
        end
    end)
    connect(Input.InputEnded, function(event)
        if event == movingInput then draggingQuick, movingInput = false, nil end
    end)
end
switchTab("Gerak")
refreshUI()

local function eligible(player)
    if player == LocalPlayer then return false end
    if state.enemiesOnly and LocalPlayer.Team and player.Team
        and not LocalPlayer.Neutral and not player.Neutral
        and LocalPlayer.Team == player.Team then return false end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0
end
local function clearMarker(player)
    local marker = markers[player]
    if marker then
        marker.highlight:Destroy()
        marker.billboard:Destroy()
        markers[player] = nil
    end
end
local function markerOrigin()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local camera = workspace.CurrentCamera
    return root and root.Position or (camera and camera.CFrame.Position)
end
local function espDistance()
    return state.lite and math.min(state.espMaxDistance, 180) or state.espMaxDistance
end
local function updateMarkers()
    local origin = markerOrigin()
    for player, marker in pairs(markers) do
        if not player.Parent or not state.esp or not eligible(player)
            or marker.character ~= player.Character or not marker.head.Parent
            or (origin and (marker.head.Position - origin).Magnitude > espDistance()) then clearMarker(player) end
    end
    if not state.esp or not origin then return end
    for _, player in ipairs(Players:GetPlayers()) do
        if eligible(player) then
            local character = player.Character
            local head = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
            if head and head:IsA("BasePart") then
                local distance = (head.Position - origin).Magnitude
                if distance <= espDistance() then
                    if not markers[player] then
                        local highlight = make("Highlight", character, {Name = "VD_ClientESP",
                            Adornee = character, DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
                            FillColor = Color3.fromRGB(245, 89, 103), FillTransparency = 0.65,
                            OutlineColor = Color3.new(1, 1, 1)})
                        local billboard = make("BillboardGui", gui, {Adornee = head,
                            Size = UDim2.fromOffset(205, 35), StudsOffset = Vector3.new(0, 2.7, 0),
                            AlwaysOnTop = true, MaxDistance = 2000})
                        local text = make("TextLabel", billboard, {Size = UDim2.fromScale(1, 1),
                            BackgroundTransparency = 1, Text = "", TextColor3 = colors.text,
                            TextStrokeTransparency = 0.25, Font = Enum.Font.GothamBold, TextSize = 11})
                        markers[player] = {character = character, head = head, highlight = highlight,
                            billboard = billboard, text = text}
                    end
                    local marker = markers[player]
                    marker.highlight.Enabled = not state.lite
                    marker.text.Text = player.DisplayName .. " · " .. string.format("%.0f stud", distance)
                end
            end
        end
    end
end
connect(Players.PlayerRemoving, clearMarker)
local function isTyping()
    if not state.pauseTyping then return false end
    return Input:GetFocusedTextBox() ~= nil
end
-- A screen-space circle is used for both display and target selection.
local function aimRadius(camera)
    local viewport = camera.ViewportSize
    local focal = viewport.Y / (2 * math.tan(math.rad(camera.FieldOfView) / 2))
    return math.clamp(focal * math.tan(math.rad(math.min(state.aimAngle, 89))), 2,
        math.max(2, math.min(viewport.X, viewport.Y) / 2 - 6))
end
local function aimTarget(camera)
    local bestPart, bestScore = nil, aimRadius(camera) ^ 2
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = LocalPlayer.Character and {LocalPlayer.Character} or {}
    local origin = camera.CFrame.Position
    local centerX, centerY = camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2
    for _, player in ipairs(Players:GetPlayers()) do
        if eligible(player) then
            local target = player.Character:FindFirstChild(state.aimPart)
            if target and target:IsA("BasePart") then
                local delta = target.Position - origin
                local projected, visible = camera:WorldToViewportPoint(target.Position)
                if visible and delta.Magnitude > 0.01 and delta.Magnitude <= state.aimMaxDistance then
                    local score = (projected.X - centerX) ^ 2 + (projected.Y - centerY) ^ 2
                    if score < bestScore then
                        local hit = workspace:Raycast(origin, delta, rayParams)
                        if not hit or hit.Instance:IsDescendantOf(player.Character) then
                            bestScore, bestPart = score, target
                        end
                    end
                end
            end
        end
    end
    return bestPart
end
local renderName = KEY .. "_Aim"
RunService:BindToRenderStep(renderName, Enum.RenderPriority.Camera.Value + 1, function(dt)
    local camera = workspace.CurrentCamera
    if not state.alive or not camera then return end
    local surface = surfaceSize()
    scale.Scale = math.clamp(math.min((surface.X - 24) / 340, (surface.Y - 88) / 500), 0.35, 1)
    extraUI.clampLogo()
    do
        local position = panel.Position
        local x = math.clamp(position.X.Offset, 0, math.max(0, surface.X - 340 * scale.Scale))
        local y = math.clamp(position.Y.Offset, 0, math.max(0, surface.Y - (minimized and 58 or 500) * scale.Scale))
        if x ~= position.X.Offset or y ~= position.Y.Offset then panel.Position = UDim2.fromOffset(x, y) end
    end
    extraUI.quickScale.Scale = math.clamp((surface.Y - 100) / 281, 0.4, 1)
    do
        local position = extraUI.quick.Position
        local x = math.clamp(position.X.Offset, 0, math.max(0, surface.X - 76 * extraUI.quickScale.Scale))
        local y = math.clamp(position.Y.Offset, 0, math.max(0, surface.Y - 281 * extraUI.quickScale.Scale))
        if x ~= position.X.Offset or y ~= position.Y.Offset then extraUI.quick.Position = UDim2.fromOffset(x, y) end
    end
    extraUI.quick.Visible = state.showQuick and extraUI.menuOpened == true and (minimized or not panel.Visible) and not reportPanel.Visible
    extraUI.hud.Visible = state.showHUD
    local paused = reportPanel.Visible or isTyping()
    inputState.pauseReason = paused and "PAUSE" or nil
    local held = inputState.right or next(inputState.held) ~= nil
    extraUI.circle.Visible = state.aim and state.showAimCircle and not paused
    if extraUI.circle.Visible then
        local diameter = 2 * aimRadius(camera)
        extraUI.circle.Position = UDim2.fromOffset(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)
        extraUI.circle.Size = UDim2.fromOffset(diameter, diameter)
    end
    if state.aim and not paused and (not state.aimHold or held) then
        local humanoid = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if humanoid and humanoid.Health > 0 and camera.CameraType ~= Enum.CameraType.Scriptable then
            local target = aimTarget(camera)
            if target then
                local wanted = CFrame.lookAt(camera.CFrame.Position, target.Position)
                camera.CFrame = camera.CFrame:Lerp(wanted, 1 - math.exp(-state.aimResponse * dt))
            end
        end
    end
    if dt > 0 then
        local instant = math.min(999, 1 / dt)
        inputState.fps = inputState.fps == 0 and instant or inputState.fps + (instant - inputState.fps) * math.min(1, dt * 3)
    end
    inputState.hudElapsed = inputState.hudElapsed + dt
    if inputState.hudElapsed >= 0.3 then
        inputState.hudElapsed = 0
        local aimStatus = paused and "PAUSE" or (not state.aim and "AIM OFF"
            or (state.aimHold and not held and "AIM STANDBY" or "AIM ON"))
        extraUI.hud.Text = string.format("VD · %.0f FPS · %s · %s", inputState.fps, aimStatus, profileName())
    end
end)

local function isGeneratorPrompt(prompt)
    local node = prompt
    for _ = 1, 8 do
        if not node or node == workspace then break end
        local name = string.lower(node.Name)
        if string.find(name, "generator", 1, true) or string.find(name, "gerador", 1, true) then
            return true
        end
        node = node.Parent
    end
    return false
end
local function promptPosition(prompt)
    local parent = prompt.Parent
    if parent and parent:IsA("Attachment") then return parent.WorldPosition end
    if parent and parent:IsA("BasePart") then return parent.Position end
    if parent and parent:IsA("Model") then return parent:GetPivot().Position end
    return nil
end
-- Object recognition is name-based; labels do not certify game mechanics.
local function objectKind(name)
    name = string.lower(name)
    if string.find(name, "generator", 1, true) or string.find(name, "gerador", 1, true) then return "Generator" end
    if string.find(name, "exit", 1, true) or string.find(name, "escape", 1, true)
        or string.find(name, "extraction", 1, true) then return "Exit" end
    if string.find(name, "door", 1, true) or string.find(name, "gate", 1, true) then return "Pintu" end
    if string.find(name, "medkit", 1, true) or string.find(name, "bandage", 1, true)
        or string.find(name, "ammo", 1, true) or string.find(name, "pickup", 1, true)
        or string.find(name, "itemdrop", 1, true) then return "Item" end
    return nil
end
local function register(object)
    if object:IsA("ProximityPrompt") then prompts[object] = true end
    if not (object:IsA("Model") or object:IsA("BasePart") or object:IsA("Tool")) then return end
    local kind = objectKind(object.Name) or (object:IsA("Tool") and "Item" or nil)
    if not kind then return end
    local target = object
    for _ = 1, 4 do
        local parent = target.Parent
        if parent and parent ~= workspace and parent:IsA("Model") and objectKind(parent.Name) == kind then
            target = parent
        else break end
    end
    objectCandidates[target] = kind
end
local function objectAdornee(object)
    if object:IsA("BasePart") then return object end
    if object:IsA("Tool") then return object:FindFirstChild("Handle") end
    if object:IsA("Model") then return object.PrimaryPart or object:FindFirstChildWhichIsA("BasePart", true) end
    return nil
end
local function clearObjectMarker(object)
    local marker = objectMarkers[object]
    if marker then marker.billboard:Destroy(); objectMarkers[object] = nil end
end
local function inCharacter(object)
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character and object:IsDescendantOf(player.Character) then return true end
    end
    return false
end
local function updateObjectMarkers()
    if not state.objectESP then
        for object in pairs(objectMarkers) do clearObjectMarker(object) end
        return
    end
    local origin = markerOrigin()
    if not origin then return end
    local selected, retained = {}, {}
    for object, kind in pairs(objectCandidates) do
        if object.Parent and object:IsDescendantOf(workspace) and not inCharacter(object) then
            local part = objectAdornee(object)
            if part and part:IsA("BasePart") then
                local distance = (part.Position - origin).Magnitude
                if distance <= espDistance() then
                    table.insert(selected, {object = object, part = part, kind = kind, distance = distance})
                end
            end
        else objectCandidates[object] = nil end
    end
    table.sort(selected, function(a, b) return a.distance < b.distance end)
    for index, entry in ipairs(selected) do
        if index > (state.lite and 8 or 24) then break end
        retained[entry.object] = true
        local marker = objectMarkers[entry.object]
        if marker and marker.part ~= entry.part then clearObjectMarker(entry.object); marker = nil end
        if not marker then
            local billboard = make("BillboardGui", gui, {Adornee = entry.part,
                Size = UDim2.fromOffset(190, 34), StudsOffset = Vector3.new(0, 2, 0),
                AlwaysOnTop = true, MaxDistance = 2000})
            local text = make("TextLabel", billboard, {Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1, Text = "", TextStrokeTransparency = 0.2,
                Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = colors.accent})
            marker = {billboard = billboard, text = text, part = entry.part}
            objectMarkers[entry.object] = marker
        end
        marker.text.TextColor3 = entry.kind == "Exit" and Color3.fromRGB(249, 211, 98)
            or (entry.kind == "Item" and Color3.fromRGB(126, 191, 255) or colors.accent)
        marker.text.Text = entry.kind .. " · " .. string.format("%.0f stud", entry.distance)
    end
    for object in pairs(objectMarkers) do if not retained[object] then clearObjectMarker(object) end end
end
clearAllVisuals = function()
    for player in pairs(markers) do clearMarker(player) end
    for object in pairs(objectMarkers) do clearObjectMarker(object) end
end
rescanObjects = function()
    objectCandidates = setmetatable({}, {__mode = "k"})
    for object in pairs(objectMarkers) do clearObjectMarker(object) end
    for _, object in ipairs(workspace:GetDescendants()) do register(object) end
    updateObjectMarkers()
    local count = 0
    for _ in pairs(objectCandidates) do count = count + 1 end
    notify("Scan selesai: " .. count .. " kandidat berdasarkan nama.")
end
for _, object in ipairs(workspace:GetDescendants()) do register(object) end
connect(workspace.DescendantAdded, register)

-- BEGIN MOVEMENT CORE
local movement = {humanoid = nil, baseline = 16, restoreSpeed = nil, lastApplied = nil,
    active = false, parts = {}, anchors = {}}
local function restoreSpeed()
    local humanoid = movement.humanoid
    if humanoid and humanoid.Parent and movement.lastApplied ~= nil
        and math.abs(humanoid.WalkSpeed - movement.lastApplied) < 0.000001 then
        humanoid.WalkSpeed = movement.restoreSpeed
    end
    movement.active, movement.lastApplied, movement.restoreSpeed = false, nil, nil
end
local function restoreAnchors()
    for part, original in pairs(movement.anchors) do
        if part.Parent and part.Anchored == false then part.Anchored = original end
    end
    movement.anchors = {}
end
restoreMovement = function()
    restoreSpeed()
    restoreAnchors()
end
applyMovement = function()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid ~= movement.humanoid then
        restoreMovement()
        movement.humanoid, movement.parts = humanoid, {}
        movement.baseline = humanoid and humanoid.WalkSpeed > 0 and humanoid.WalkSpeed or 16
        if character then
            for _, part in ipairs(character:GetDescendants()) do
                if part:IsA("BasePart") then table.insert(movement.parts, part) end
            end
        end
    end
    if not humanoid or humanoid.Health <= 0 then restoreMovement(); return end
    if state.speedEnabled or state.noSlow then
        if not movement.active then
            movement.restoreSpeed = humanoid.WalkSpeed
            if humanoid.WalkSpeed > 0 then movement.baseline = humanoid.WalkSpeed end
            movement.active = true
        end
        local target = movement.baseline * (state.speedEnabled and state.speedMultiplier or 1)
        if state.speedEnabled or humanoid.WalkSpeed < target then
            if humanoid.WalkSpeed ~= target then humanoid.WalkSpeed = target end
            movement.lastApplied = target
        end
    else
        if movement.active then restoreSpeed() end
        if humanoid.WalkSpeed > 0 then movement.baseline = humanoid.WalkSpeed end
    end
    if state.unanchor then
        for _, part in ipairs(movement.parts) do
            if part.Parent and part.Anchored then
                movement.anchors[part] = true
                part.Anchored = false
            end
        end
    elseif next(movement.anchors) then restoreAnchors() end
end
-- END MOVEMENT CORE
local localCharacterConnection
local function watchLocalCharacter(character)
    if localCharacterConnection then localCharacterConnection:Disconnect() end
    movement.parts = {}
    localCharacterConnection = connect(character.DescendantAdded, function(part)
        if part:IsA("BasePart") then table.insert(movement.parts, part) end
    end)
end
if LocalPlayer.Character then watchLocalCharacter(LocalPlayer.Character) end
connect(LocalPlayer.CharacterAdded, watchLocalCharacter)
local movementElapsed = 0
connect(RunService.Heartbeat, function(dt)
    if not state.alive then return end
    movementElapsed = movementElapsed + dt
    if movementElapsed >= 0.1 then
        movementElapsed = 0
        applyMovement()
        if os.clock() > messageUntil then
            footer.Text = state.speedEnabled and string.format("Kecepatan %.6g× · basis %.6g", state.speedMultiplier, movement.baseline)
                or "Siap · gerak lokal / fitur game perlu data"
        end
    end
end)

local generatorStatus = "Generator OFF"
task.spawn(function()
    while state.alive do
        updateMarkers()
        updateObjectMarkers()
        task.wait(state.lite and math.max(state.espRefresh, 0.65) or state.espRefresh)
    end
end)
task.spawn(function()
    while state.alive do
        if state.generator and not isTyping() and not reportPanel.Visible then
            local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
            local chosen, shortest = nil, math.huge
            local recognized = 0
            for prompt in pairs(prompts) do
                if prompt:IsDescendantOf(workspace) and isGeneratorPrompt(prompt) then
                    recognized = recognized + 1
                    local position = promptPosition(prompt)
                    if root and position and prompt.Enabled then
                        local distance = (root.Position - position).Magnitude
                        if distance <= prompt.MaxActivationDistance and distance < shortest
                            and os.clock() - (lastPrompt[prompt] or -math.huge) > 3 then
                            shortest, chosen = distance, prompt
                        end
                    end
                end
            end
            if type(firePrompt) ~= "function" then
                generatorStatus = "fireproximityprompt tidak tersedia di executor."
            elseif chosen then
                lastPrompt[chosen] = os.clock()
                local ok = pcall(firePrompt, chosen, chosen.HoldDuration)
                generatorStatus = ok and "Prompt dicoba; progres harus dicek di game."
                    or "Executor gagal mengaktifkan prompt."
            else
                generatorStatus = recognized == 0 and "Tidak menemukan prompt generator. Perlu adapter game."
                    or "Dekati generator. Prompt harus aktif dan dalam jarak."
            end
        else
            generatorStatus = state.generator and "Generator PAUSE: kolom teks atau dialog aktif." or "Generator OFF"
        end
        if state.alive then
            status.Text = generatorStatus .. "\nPrompt saja; auto perfect dan boost belum terhubung."
        end
        task.wait(1)
    end
end)

connect(diagnosticsButton.Activated, function()
    local lines = {"VD NEO v0.4 diagnostics (structure only)",
        "PlaceId: " .. tostring(game.PlaceId), "GameId: " .. tostring(game.GameId),
        "fireproximityprompt: " .. tostring(type(firePrompt) == "function"),
        "fileWrite: " .. tostring(type(diskWrite) == "function"),
        "fileRead: " .. tostring(type(diskRead) == "function"),
        "SelectedProfile: " .. profileName(),
        "ESP objects: name-based recognition",
        "PLAYER STRUCTURE:"}
    for _, player in ipairs(Players:GetPlayers()) do
        table.insert(lines, player.Name .. " | team=" .. tostring(player.Team)
            .. " | neutral=" .. tostring(player.Neutral))
    end
    table.insert(lines, "PROXIMITY PROMPTS (max 80):")
    local count = 0
    for prompt in pairs(prompts) do
        if prompt:IsDescendantOf(workspace) then
            count = count + 1
            table.insert(lines, prompt:GetFullName() .. " | action=" .. prompt.ActionText
                .. " | object=" .. prompt.ObjectText .. " | generatorMatch=" .. tostring(isGeneratorPrompt(prompt)))
            if count >= 80 then break end
        end
    end
    table.insert(lines, "OBJECT MATCHES (max 60; name-based):")
    count = 0
    for object, kind in pairs(objectCandidates) do
        if object.Parent and object:IsDescendantOf(workspace) then
            count = count + 1
            table.insert(lines, kind .. " | " .. object:GetFullName())
            if count >= 60 then break end
        end
    end
    table.insert(lines, "REPLICATED REMOTE NAMES (max 80; no calls are made):")
    count = 0
    for _, object in ipairs(ReplicatedStorage:GetDescendants()) do
        if object:IsA("RemoteEvent") or object:IsA("RemoteFunction") or object:IsA("UnreliableRemoteEvent") then
            count = count + 1
            table.insert(lines, object.ClassName .. " | " .. object:GetFullName())
            if count >= 80 then break end
        end
    end
    openModal("Diagnostik game", table.concat(lines, "\n"), false)
    if type(setclipboard) == "function" then pcall(setclipboard, reportText.Text) end
end)

local function cleanup()
    if not state.alive then return end
    state.alive = false
    restoreMovement()
    RunService:UnbindFromRenderStep(renderName)
    for _, connection in ipairs(connections) do connection:Disconnect() end
    clearAllVisuals()
    extraUI.overlay:Destroy()
    gui:Destroy()
    if environment[KEY] == state then environment[KEY] = nil end
end
state.cleanup = cleanup
environment[KEY] = state
print("VD NEO v0.4 loaded. Tap the VD logo to open the menu. Client prototype; game-specific features marked pending.")
