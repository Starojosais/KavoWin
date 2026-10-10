# KavoWin

A faster, better looking, **Kavo-compatible** UI library for Roblox with Windows themes.

```lua
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/YOUR_NAME/YOUR_REPO/main/KavoWin.lua"))()
local Window  = Library.CreateLib("My Hub", "Windows11")
local Tab     = Window:NewTab("Main")
local Section = Tab:NewSection("Player")

Section:NewButton("Hello", "Prints hello", function() print("hello") end)
```

Existing Kavo scripts keep working: `CreateLib`, `NewTab`, `NewSection`, `NewButton`, `NewToggle`,
`NewSlider(name, tip, max, min, cb)`, `NewTextBox`, `NewDropdown`, `NewKeybind`, `NewColorPicker`,
`NewLabel`, `UpdateButton`, `UpdateToggle`, `UpdateLabel`, `UpdateSection`, `Refresh`,
`Library:ToggleUI()`, `Library:ChangeColor()`, `Library:DraggingEnabled()`.

## Themes

| Name | Look |
| --- | --- |
| `Windows98` | real 3D bevels, navy gradient title bar, group boxes, sunken fields |
| `WindowsVista` | Aero glass frame, glossy buttons, explorer style navigation |
| `WindowsLonghorn` | blue glass, round caption buttons |
| `Windows7` | light Aero glass, glossy blue selection |
| `Windows10` | flat dark, accent bar, toggle switches |
| `Windows11` | mica dark, rounded cards, accent pill, underline on focus |
| `Windows10Light`, `Windows11Light` | light variants |

Pass a Kavo style table for your own colours (`SchemeColor`, `Background`, `Header`, `TextColor`,
`ElementColor`). Old Kavo theme names (`DarkTheme`, `LightTheme`, ...) fall back to Windows 11.
Switch live with `Window:SetTheme("Windows98")`.

## Extras

- `Window:Notify(title, text, seconds)` - themed toast notifications
- `Section:NewMultiDropdown`, `NewSeparator`, `NewParagraph`
- Dropdowns get a search box when they have more than 8 entries
- Hover tips appear in a status bar (Windows 98 / Vista / 7 style)
- Minimise, maximise (also double click the title bar), resize grip, close
- Touch support for dragging, sliders and the colour picker
- `Window:SaveConfig(name)` / `LoadConfig(name)` / `GetConfig()` / `SetConfig(t)` (needs `writefile`)
- Element handles: `:SetValue()`, `:GetValue()`, `:SetState()`, `:SetKey()`, `:SetColor()`, `:SetText()`, `:Destroy()`, `:SetVisible()`
- `Window:SetToggleKey(Enum.KeyCode.RightShift)`, `Window:SetStatus(text)`, `Window:SelectTab(name)`
- 3rd argument of `CreateLib`: `{ Size = Vector2, MinSize = Vector2, ToggleKey = Enum.KeyCode }`

## Why it is faster than Kavo

- no `while wait() do` loop per element for theming (Kavo runs hundreds); theming is event driven
- automatic canvas / content sizing instead of manual resize calls
- one shared input listener for every keybind, drags only listen while dragging
- every connection is disconnected when the window is destroyed
- re-running the script replaces the old window instead of stacking copies

## Notes

`example.lua` uses every element. Fonts: Windows 98 uses Arial, Vista/7/10 use Source Sans, Windows 11 uses
Builder Sans (falls back to Source Sans if the client does not have it). Everything is drawn with frames,
so no image assets are required.
