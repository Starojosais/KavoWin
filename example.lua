-- KavoWin example: every element + every extra feature
-- Loads KavoWin straight from GitHub.
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/Starojosais/KavoWin/refs/heads/main/KavoWin.lua"))()

-- Themes: "Windows98" "WindowsVista" "WindowsLonghorn" "Windows7" "Windows10" "Windows11"
--         "Windows10Light" "Windows11Light"   (or a Kavo style colour table)
-- 3rd argument is optional: Size, MinSize, ToggleKey
local Window = Library.CreateLib("KavoWin Demo", "Windows11", {
	Size = Vector2.new(600, 400),
	ToggleKey = Enum.KeyCode.RightShift, -- hide / show the window
})

------------------------------------------------------------------ Main tab
local Main = Window:NewTab("Main")
local Player = Main:NewSection("Player")

Player:NewButton("Say hello", "Prints hello to the console", function()
	print("hello")
end)

local godToggle = Player:NewToggle("God mode", "Hover tips show in the status bar", function(state)
	print("God mode:", state)
end)

Player:NewSlider("WalkSpeed", "Max 200, min 16", 200, 16, function(value)
	local char = game.Players.LocalPlayer.Character
	if char and char:FindFirstChildOfClass("Humanoid") then
		char:FindFirstChildOfClass("Humanoid").WalkSpeed = value
	end
end)

-- extra args: default value, step (decimals work)
Player:NewSlider("Gravity", "Default 196.2", 400, 0, function(v) workspace.Gravity = v end, 196.2, 0.5)

Player:NewTextBox("Name", "Press enter to submit", function(text)
	print("typed:", text)
end)

Player:NewSeparator()

local teleports = Player:NewDropdown("Teleport", "Pick a place", { "Spawn", "Mid", "Edge" }, function(choice)
	print("teleport to", choice)
end)
-- teleports:Refresh({ "New", "List" })   teleports:SetValue("Mid")

Player:NewMultiDropdown("Features", "Select several", { "ESP", "Aimbot", "Fly", "Noclip" }, function(selected)
	print("selected:", table.concat(selected, ", "))
end)

Player:NewKeybind("Fly key", "Click, then press a key (Backspace clears)", Enum.KeyCode.F, function()
	print("fly toggled")
end)

Player:NewColorPicker("Accent", "Pick a colour, or enable Rainbow", Color3.fromRGB(0, 120, 215), function(color)
	print("colour:", color)
end)

------------------------------------------------------------------ Info tab
local Info = Window:NewTab("Info")
local About = Info:NewSection("About")
About:NewLabel("Plain label - supports <b>rich</b> <font color='#60CDFF'>text</font>")
About:NewParagraph("Paragraph", "Title in bold, body text wraps automatically across several lines when it gets long.")

------------------------------------------------------------------ Settings tab
local Settings = Window:NewTab("Settings")
local Look = Settings:NewSection("Appearance")

-- live theme switching, nothing is rebuilt
Look:NewDropdown("Theme", "Change the look instantly", Library.Themes, function(theme)
	Window:SetTheme(theme)
end)

Look:NewColorPicker("Custom accent", "Overrides SchemeColor", Color3.fromRGB(0, 120, 215), function(c)
	Window:ChangeColor("SchemeColor", c) -- Kavo compatible: Library:ChangeColor works too
end)

local Config = Settings:NewSection("Config")
Config:NewButton("Save config", "Saves every toggle/slider/dropdown/keybind/colour", function()
	Window:SaveConfig("demo")
	Window:Notify("Config", "Saved to your executor workspace", 3)
end)
Config:NewButton("Load config", "Restores the saved values", function()
	Window:LoadConfig("demo")
end)

Config:NewButton("Notification", "Toast notification styled for the theme", function()
	Window:Notify("Hello!", "This toast follows the current theme.", 4)
end)

Config:NewKeybind("Toggle UI", "Kavo compatible: Library:ToggleUI()", Enum.KeyCode.RightControl, function()
	Library:ToggleUI()
end)

Window:SetStatus("Ready - hover an element for its tip")
