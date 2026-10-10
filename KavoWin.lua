--[[
    KavoWin  -  a faster, better looking, Kavo-compatible UI library for Roblox
    ---------------------------------------------------------------------------
    * Same API as Kavo UI Library (xHeptc):  CreateLib > NewTab > NewSection > NewXxx
    * Themes: Windows98, WindowsVista, WindowsLonghorn, Windows7, Windows10, Windows11
              (+ Windows10Light, Windows11Light, or your own Kavo-style colour table)
    * No polling loops: theming is event driven, layout uses automatic sizing,
      every connection is cleaned up when the window is destroyed.

    Usage:
        local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/Starojosais/KavoWin/refs/heads/main/KavoWin.lua"))()
        local Window  = Library.CreateLib("My Hub", "Windows11")
        local Tab     = Window:NewTab("Main")
        local Section = Tab:NewSection("Player")
        Section:NewButton("Hello", "Prints hello", function() print("hello") end)

    See example.lua for every element and every extra feature.
]]

local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local RunService       = game:GetService("RunService")
local HttpService      = game:GetService("HttpService")

local E = Enum
local rgb, V2, U2, U1 = Color3.fromRGB, Vector2.new, UDim2.new, UDim.new
local WHITE, BLACK = Color3.new(1, 1, 1), Color3.new(0, 0, 0)
local EMPTY = {}

local LEFT, CENTER, RIGHT = E.TextXAlignment.Left, E.TextXAlignment.Center, E.TextXAlignment.Right
local UIT = E.UserInputType
local MB1, TOUCH, MMOVE, KEYBOARD = UIT.MouseButton1, UIT.Touch, UIT.MouseMovement, UIT.Keyboard

local Library = { Version = "1.0.0", Windows = {} }

--------------------------------------------------------------------------------
-- small helpers
--------------------------------------------------------------------------------
local function fire(cb, ...)
	if type(cb) ~= "function" then return end
	local ok, err = pcall(cb, ...)
	if not ok then warn("[KavoWin] callback error: " .. tostring(err)) end
end

local function lum(c) return c.R * 0.299 + c.G * 0.587 + c.B * 0.114 end
-- lighten dark colours / darken light colours (used to derive borders & hovers)
local function shade(c, t) return c:Lerp(lum(c) < 0.5 and WHITE or BLACK, t) end

local function gloss(a, b, c, d) -- Aero style "glass" gradient: bright top half, darker bottom half
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, a), ColorSequenceKeypoint.new(0.5, b),
		ColorSequenceKeypoint.new(0.51, c), ColorSequenceKeypoint.new(1, d),
	})
end
local function vgrad(a, b) return ColorSequence.new(a, b) end

local function pickFont(name, fallback)
	local ok, f = pcall(function() return E.Font[name] end)
	if ok and f then return f end
	return fallback
end
local SS, SSB = E.Font.SourceSans, E.Font.SourceSansBold
local FONT = {
	arial = pickFont("Arial", SS), arialB = pickFont("ArialBold", SSB),
	seg = SS, segB = pickFont("SourceSansSemibold", SSB),
	fluent = pickFont("BuilderSans", SS), fluentB = pickFont("BuilderSansBold", SSB),
}

local TI = {}
local function tween(obj, props, t)
	local info = TI[t or 0.15]
	if not info then
		info = TweenInfo.new(t or 0.15, E.EasingStyle.Quad, E.EasingDirection.Out)
		TI[t or 0.15] = info
	end
	local tw = TweenService:Create(obj, info, props)
	tw:Play()
	return tw
end

local GUIOBJ = { Frame = 1, TextButton = 1, TextLabel = 1, TextBox = 1, ImageLabel = 1, ImageButton = 1, ScrollingFrame = 1, CanvasGroup = 1 }
local function new(class, props, parent)
	local o = Instance.new(class)
	if GUIOBJ[class] then
		o.BorderSizePixel = 0
		o.BackgroundTransparency = 1
		if class == "TextButton" or class == "ImageButton" then o.AutoButtonColor = false end
		if class == "TextButton" or class == "TextLabel" or class == "TextBox" then o.Text = "" end
	end
	if props then for k, v in pairs(props) do o[k] = v end end
	if parent then o.Parent = parent end
	return o
end

local function isPress(i) return i.UserInputType == MB1 or i.UserInputType == TOUCH end
local function isMove(i) return i.UserInputType == MMOVE or i.UserInputType == TOUCH end
local function pointer(i)
	if i.UserInputType == TOUCH then return V2(i.Position.X, i.Position.Y) end
	return UserInputService:GetMouseLocation()
end

-- starts a drag session: onMove(input) while moving, onEnd() when released
local function beginDrag(onMove, onEnd)
	local c1, c2
	local function stop()
		if c1 then c1:Disconnect() c1 = nil end
		if c2 then c2:Disconnect() c2 = nil end
		if onEnd then onEnd() end
	end
	c1 = UserInputService.InputChanged:Connect(function(i) if isMove(i) then onMove(i) end end)
	c2 = UserInputService.InputEnded:Connect(function(i) if isPress(i) then stop() end end)
	return stop
end

-- Kavo compatible: Library:DraggingEnabled(frame, parent)
function Library:DraggingEnabled(frame, parent)
	parent = parent or frame
	frame.InputBegan:Connect(function(input)
		if isPress(input) then
			local startPos, startUI = input.Position, parent.Position
			beginDrag(function(i)
				local d = i.Position - startPos
				parent.Position = U2(startUI.X.Scale, startUI.X.Offset + d.X, startUI.Y.Scale, startUI.Y.Offset + d.Y)
			end)
		end
	end)
end

--------------------------------------------------------------------------------
-- Box: paints a GuiObject from a "spec" table. Everything visual goes through here.
--   spec = { fill = Color3 | ColorSequence, alpha, rot, radius, stroke, strokeA, thick,
--            inner, innerA, bevel = {otl, obr, itl, ibr}, text }
-- Never use a Box on an object that also owns a UIListLayout (bevel frames would be laid out).
--------------------------------------------------------------------------------
local function Box(root)
	local layers, corner, stroke, grad, inner, innerCorner, innerStroke
	local gradOn, visFill = false, false
	return function(s, animate)
		s = s or EMPTY
		local bev = s.bevel
		if bev then -- Windows 98 style 3D bevel (4 stacked frames)
			if not layers then
				layers = {}
				local g = { { 0, -1 }, { 1, -2 }, { 1, -3 }, { 2, -4 } }
				for i = 1, 4 do
					layers[i] = new("Frame", {
						Name = "_b" .. i, ZIndex = 0, BackgroundTransparency = 0,
						Position = U2(0, g[i][1], 0, g[i][1]), Size = U2(1, g[i][2], 1, g[i][2]),
					}, root)
				end
			end
			root.BackgroundTransparency = 0
			root.BackgroundColor3 = bev.obr
			layers[1].BackgroundColor3 = bev.otl
			layers[2].BackgroundColor3 = bev.ibr
			layers[3].BackgroundColor3 = bev.itl
			layers[4].BackgroundColor3 = s.fill or bev.itl
			for i = 1, 4 do layers[i].Visible = true end
			if grad then grad.Enabled = false end
			if stroke then stroke.Enabled = false end
			if inner then inner.Visible = false end
			if corner then corner.CornerRadius = U1(0, 0) end
			gradOn, visFill = false, true
			return
		end
		if layers then for i = 1, 4 do layers[i].Visible = false end end

		local r = s.radius or 0
		if r > 0 or corner then
			if not corner then corner = new("UICorner", nil, root) end
			corner.CornerRadius = U1(0, r)
		end

		local f = s.fill
		if f == nil then
			root.BackgroundTransparency = 1
			if grad then grad.Enabled = false end
			gradOn, visFill = false, false
		elseif typeof(f) == "ColorSequence" then
			if not grad then grad = new("UIGradient", nil, root) end
			grad.Enabled = true
			grad.Rotation = s.rot or 90
			grad.Color = f
			root.BackgroundColor3 = WHITE
			root.BackgroundTransparency = s.alpha or 0
			gradOn, visFill = true, true
		else
			if grad then grad.Enabled = false end
			root.BackgroundTransparency = s.alpha or 0
			if animate and visFill and not gradOn then
				tween(root, { BackgroundColor3 = f }, 0.12)
			else
				root.BackgroundColor3 = f
			end
			gradOn, visFill = false, true
		end

		if s.stroke then
			if not stroke then stroke = new("UIStroke", { ApplyStrokeMode = E.ApplyStrokeMode.Border }, root) end
			stroke.Enabled = true
			stroke.Color = s.stroke
			stroke.Transparency = s.strokeA or 0
			stroke.Thickness = s.thick or 1
		elseif stroke then
			stroke.Enabled = false
		end

		if s.inner then
			if not inner then
				inner = new("Frame", { Name = "_inner", ZIndex = 0, Position = U2(0, 1, 0, 1), Size = U2(1, -2, 1, -2) }, root)
				innerCorner = new("UICorner", nil, inner)
				innerStroke = new("UIStroke", nil, inner)
			end
			inner.Visible = true
			innerCorner.CornerRadius = U1(0, math.max(r - 1, 0))
			innerStroke.Color = s.inner
			innerStroke.Transparency = s.innerA or 0.5
		elseif inner then
			inner.Visible = false
		end
	end
end

--------------------------------------------------------------------------------
-- THEMES
-- A palette (Kavo style: Background / Header / TextColor / SchemeColor / ElementColor)
-- goes into one of three builders, which return a full "theme table" T of specs.
--   classic : Windows 98   (real 3D bevels, navy gradient title bar)
--   aero    : Vista / Longhorn / 7  (glass frame, glossy buttons, explorer style nav)
--   modern  : Windows 10 / 11 (flat, accent colour, switches, mica style)
--------------------------------------------------------------------------------
local function buildClassic(P)
	local face, field, txt, navy = P.Background, P.ElementColor, P.TextColor, P.SchemeColor
	local lt = face:Lerp(WHITE, 0.5)
	local sh = face:Lerp(BLACK, 0.33)
	local dk = face:Lerp(BLACK, 0.95)
	local bv = {
		raised  = { otl = WHITE, obr = dk,    itl = lt,    ibr = sh },
		pressed = { otl = dk,    obr = WHITE, itl = sh,    ibr = lt },
		sunken  = { otl = sh,    obr = WHITE, itl = dk,    ibr = lt },
		window  = { otl = lt,    obr = dk,    itl = WHITE, ibr = sh },
		etched  = { otl = sh,    obr = WHITE, itl = WHITE, ibr = sh },
		status  = { otl = sh,    obr = WHITE, itl = face,  ibr = face },
	}
	local raised  = { fill = face,  bevel = bv.raised,  text = txt }
	local pressed = { fill = face,  bevel = bv.pressed, text = txt }
	local sunken  = { fill = field, bevel = bv.sunken,  text = txt }
	local hot     = { fill = navy,  text = WHITE }
	local capSet  = { idle = raised, hover = raised, down = pressed }
	return {
		Name = "Windows 98",
		Font = FONT.arial, FontB = FONT.arialB, Size = 13, HeadBig = 0,
		Text = txt, Dim = face:Lerp(BLACK, 0.7), Face = face,
		RowH = 22, FieldH = 20, SliderH = 40, OptH = 18, TabH = 20, TabGap = 0, StatusH = 20,
		HeadH = 16, HeadGap = 0, Gap = 4, Pad = 8, RowPad = 0, PagePad = 6, SecGap = 6,
		SideW = 130, SidePad = 3, BodyPad = 6,
		TitleX = 4, TitleTop = 4, TitleH = 18, InL = 4, InB = 4,

		Win = { fill = face, bevel = bv.window },
		Title = { fill = vgrad(P.Header, P.Header2 or rgb(16, 132, 208)), rot = 0 },
		TitleText = WHITE, TitleBold = true,
		Icon = { rgb(235, 60, 20), rgb(40, 170, 60), rgb(30, 60, 220), rgb(250, 210, 20) },
		Cap = {
			w = 16, h = 14, cw = 16, gap = 2, gap2 = 0, y = 2, r = 2,
			gs = 7, gt = 2, gl = 9, minDy = 3, maxBar = true,
			min = capSet, close = capSet, icon = txt, closeIcon = txt, closeIconHot = txt,
		},
		PressShift = true,

		Side = { fill = field, bevel = bv.sunken },
		Tab = { idle = { text = txt }, hover = { text = txt }, sel = { fill = navy, text = WHITE } },

		GroupKind = "etched", Group = { fill = face, bevel = bv.etched },
		GroupHead = txt, GroupBold = false,

		Action = { idle = raised, hover = raised, down = pressed }, ActionAlign = CENTER,
		Btn = { idle = raised, hover = raised, down = pressed },
		Field = { idle = sunken, focus = sunken }, FieldPad = 4,
		Row = {},
		ToggleKind = "check", CheckSize = 13, CheckMark = txt,
		Check = { off = sunken, on = sunken, offHover = sunken, onHover = sunken },
		TrackH = 4, ThumbW = 11, ThumbH = 21,
		Track = { fill = face, bevel = bv.sunken },
		Thumb = { idle = raised, hover = raised, down = raised },
		List = { fill = field, bevel = bv.sunken }, ComboBtn = true,
		Opt = { idle = { text = txt }, hover = hot, sel = hot },
		Status = { fill = face, bevel = bv.status },
		Toast = { fill = rgb(255, 255, 225), stroke = BLACK, text = BLACK },
		Scroll = { w = 16, color = face },
		Grip = sh, Sep = { sh, WHITE },
	}
end

local function buildAero(P)
	local v = P.variant
	local base, body, txt, acc = P.Header, P.Background, P.TextColor, P.SchemeColor
	local lh = (v == "longhorn")
	local rad = lh and 5 or 3
	local winR = (v == "vista" and 8) or (lh and 12) or 7
	local frame = gloss(base:Lerp(WHITE, 0.34), base:Lerp(WHITE, 0.14), base:Lerp(BLACK, 0.06), base)
	local line = rgb(171, 173, 179)

	local btnStroke = lh and rgb(90, 115, 150) or rgb(112, 112, 112)
	local btn = {
		idle  = { fill = gloss(rgb(242, 242, 242), rgb(235, 235, 235), rgb(221, 221, 221), rgb(207, 207, 207)), stroke = btnStroke, radius = rad, inner = WHITE, innerA = 0.35, text = txt },
		hover = { fill = gloss(rgb(234, 246, 253), rgb(217, 240, 252), rgb(190, 230, 253), rgb(167, 217, 245)), stroke = rgb(60, 127, 177), radius = rad, inner = WHITE, innerA = 0.4, text = txt },
		down  = { fill = gloss(rgb(229, 244, 252), rgb(196, 229, 246), rgb(152, 209, 239), rgb(104, 179, 225)), stroke = rgb(44, 98, 139), radius = rad, text = txt },
	}
	local tabHov = { fill = vgrad(rgb(250, 252, 254), rgb(235, 243, 253)), stroke = rgb(184, 214, 251), radius = rad, text = txt }
	local tabSel = {
		fill = gloss(rgb(250, 250, 251), rgb(235, 244, 254), rgb(220, 235, 252), rgb(193, 219, 252)),
		stroke = rgb(125, 162, 206), radius = rad, inner = WHITE, innerA = 0.3, text = txt,
	}

	-- caption buttons (glass) ------------------------------------------------
	local cr = lh and 11 or 3
	local function glass(a, b, c, d, st)
		return { fill = gloss(a, b, c, d), stroke = st or rgb(30, 45, 70), strokeA = 0.3, radius = cr, inner = WHITE, innerA = 0.45 }
	end
	local gIdle = glass(base:Lerp(WHITE, 0.6), base:Lerp(WHITE, 0.38), base:Lerp(BLACK, 0.02), base:Lerp(WHITE, 0.22))
	local gHot  = glass(rgb(226, 243, 255), rgb(180, 222, 252), rgb(110, 180, 235), rgb(150, 205, 245), rgb(40, 90, 150))
	local gDown = glass(rgb(170, 205, 235), rgb(120, 170, 220), rgb(60, 120, 190), rgb(90, 150, 210), rgb(30, 70, 120))
	local rIdle = glass(rgb(235, 160, 145), rgb(215, 110, 92), rgb(190, 62, 44), rgb(208, 92, 72), rgb(90, 20, 10))
	local rHot  = glass(rgb(250, 190, 175), rgb(240, 130, 108), rgb(222, 64, 42), rgb(236, 102, 80), rgb(100, 20, 10))
	local rDown = glass(rgb(190, 100, 85), rgb(170, 60, 45), rgb(140, 30, 20), rgb(160, 50, 38), rgb(70, 10, 5))

	local chk = { fill = vgrad(WHITE, rgb(228, 230, 234)), stroke = rgb(142, 143, 143), radius = 2 }
	local chkH = { fill = vgrad(rgb(233, 246, 253), rgb(206, 230, 246)), stroke = rgb(60, 127, 177), radius = 2 }

	return {
		Name = (v == "vista" and "Windows Vista") or (lh and "Windows Longhorn") or "Windows 7",
		Font = FONT.seg, FontB = FONT.segB, Size = 16, HeadBig = 2,
		Text = txt, Dim = rgb(76, 96, 122), Face = body,
		RowH = 26, FieldH = 22, SliderH = 44, OptH = 22, TabH = 26, TabGap = 2, StatusH = 24,
		HeadH = 24, HeadGap = 4, Gap = 5, Pad = 10, RowPad = 0, PagePad = 12, SecGap = 8,
		SideW = 140, SidePad = 4, BodyPad = 0,
		TitleX = 0, TitleTop = 0, TitleH = 30, InL = 8, InB = 8,

		Win = { fill = frame, radius = winR, stroke = rgb(30, 50, 80), strokeA = 0.25, inner = WHITE, innerA = 0.55 },
		TitleText = lh and WHITE or txt,
		TitleStroke = lh and BLACK or WHITE, TitleStrokeA = lh and 0.6 or 0.5, TitleBold = false,
		Icon = { rgb(235, 60, 20), rgb(40, 170, 60), rgb(30, 90, 220), rgb(250, 210, 20) },
		Cap = {
			w = lh and 22 or 28, h = lh and 22 or 19, cw = lh and 22 or 47,
			gap = lh and 4 or 0, gap2 = lh and 4 or 0, y = lh and 4 or 1, r = lh and 10 or 6,
			gs = 8, gt = 2, gl = 11, minDy = 3, maxBar = false,
			min = { idle = gIdle, hover = gHot, down = gDown },
			close = { idle = rIdle, hover = rHot, down = rDown },
			icon = lh and WHITE or rgb(30, 40, 60), closeIcon = WHITE, closeIconHot = WHITE,
		},

		Body = { fill = body, stroke = rgb(30, 50, 80), strokeA = 0.35 },
		Side = { fill = vgrad(WHITE, rgb(239, 244, 251)), rot = 0 }, Div = rgb(214, 222, 233),
		Tab = { idle = { text = txt }, hover = tabHov, sel = tabSel },

		GroupKind = "head", GroupHead = acc, GroupBold = true, GroupLine = rgb(209, 218, 230),

		Action = btn, ActionAlign = CENTER, Btn = btn,
		Field = {
			idle = { fill = WHITE, stroke = line, radius = 2, text = txt },
			focus = { fill = WHITE, stroke = rgb(87, 148, 201), radius = 2, text = txt },
		},
		FieldPad = 4, Row = {},
		ToggleKind = "check", CheckSize = 14, CheckMark = rgb(33, 55, 90),
		Check = { off = chk, on = chk, offHover = chkH, onHover = chkH },
		TrackH = 4, ThumbW = 11, ThumbH = 20,
		Track = { fill = vgrad(rgb(206, 212, 222), rgb(232, 236, 242)), stroke = line, radius = 2 },
		Thumb = { idle = btn.idle, hover = btn.hover, down = btn.down },
		List = { fill = WHITE, stroke = line, radius = 2 }, ComboBtn = false,
		Opt = { idle = { text = txt }, hover = tabHov, sel = tabSel },
		Status = { fill = vgrad(rgb(247, 249, 252), rgb(228, 235, 244)) },
		Toast = { fill = vgrad(rgb(252, 253, 255), rgb(232, 239, 248)), stroke = rgb(100, 125, 165), radius = 4, text = txt },
		Scroll = { w = 10, color = rgb(150, 175, 205) },
		Grip = rgb(120, 140, 170), Sep = { rgb(209, 218, 230) },
	}
end

local function buildModern(P)
	local w11 = (P.variant == "win11")
	local bg, hd, el, tx, ac = P.Background, P.Header, P.ElementColor, P.TextColor, P.SchemeColor
	local dark = lum(bg) < 0.5
	local dim = P.Dim or tx:Lerp(bg, 0.38)
	local border = shade(el, w11 and 0.07 or 0.12)
	local hover = shade(el, 0.07)
	local down = el:Lerp(bg, 0.5)
	local r = w11 and 4 or 0
	local onAc = lum(ac) > 0.6 and BLACK or WHITE
	local fieldBg = dark and el:Lerp(BLACK, 0.3) or el:Lerp(WHITE, 0.6)
	local rowStroke = w11 and shade(el, 0.08) or el
	local hotStroke = w11 and shade(el, 0.1) or tx:Lerp(bg, 0.5)
	local mute = tx:Lerp(bg, 0.55)

	local function card(fill, st) return { fill = fill, radius = r, stroke = st, text = tx } end
	local btn = {
		idle = card(shade(el, 0.1), border), hover = card(shade(el, 0.16), border), down = card(shade(el, 0.05), border),
	}
	local capHot = shade(hd, 0.12)
	local capDown = shade(hd, 0.2)
	local capSet = { idle = EMPTY, hover = { fill = capHot }, down = { fill = capDown } }
	local ring = dark and tx:Lerp(bg, 0.15) or rgb(140, 140, 140)

	return {
		Name = w11 and "Windows 11" or "Windows 10",
		Font = w11 and FONT.fluent or FONT.seg, FontB = w11 and FONT.fluentB or FONT.segB,
		Size = w11 and 14 or 16, HeadBig = 2,
		Text = tx, Dim = dim, Face = bg,
		RowH = w11 and 38 or 34, FieldH = w11 and 26 or 24, SliderH = 54, OptH = 30, TabH = w11 and 36 or 38,
		TabGap = w11 and 2 or 0, StatusH = 24, HeadH = 26, HeadGap = 6, Gap = w11 and 4 or 3, Pad = 0,
		RowPad = 12, PagePad = 16, SecGap = 14, SideW = 150, SidePad = w11 and 6 or 0, BodyPad = 0,
		TitleX = 0, TitleTop = 0, TitleH = 32, InL = 0, InB = 0,

		Win = { fill = bg, radius = w11 and 8 or 0, stroke = border },
		Title = { fill = hd }, TitleText = tx, TitleBold = false,
		Icon = { ac, ac, ac, ac },
		Cap = {
			w = 46, h = 32, cw = 46, gap = 0, gap2 = 0, y = 0, r = 0,
			gs = 10, gt = 1, gl = 14, minDy = 0, maxBar = false,
			min = capSet,
			close = {
				idle = EMPTY,
				hover = { fill = w11 and rgb(196, 43, 28) or rgb(232, 17, 35) },
				down = { fill = w11 and rgb(160, 40, 30) or rgb(241, 112, 122) },
			},
			icon = tx, closeIcon = tx, closeIconHot = WHITE,
		},

		Side = { fill = hd }, Div = border,
		Tab = {
			idle = { text = tx },
			hover = { fill = shade(hd, 0.07), radius = r, text = tx },
			sel = { fill = shade(hd, 0.12), radius = r, text = tx },
		},
		TabInd = w11 and { w = 3, h = 16, r = 2, color = ac } or { w = 4, full = true, r = 0, color = ac },

		GroupKind = "head", GroupHead = tx, GroupBold = true,

		Row = {
			idle = { fill = el, radius = r, stroke = rowStroke },
			hover = { fill = hover, radius = r, stroke = hotStroke },
		},
		Action = {
			idle = card(el, rowStroke), hover = card(hover, hotStroke), down = card(down, hotStroke),
		},
		ActionAlign = LEFT, Btn = btn,
		Field = {
			idle = card(fieldBg, border),
			focus = card(fieldBg, w11 and border or ac),
		},
		FieldPad = 8, FieldLine = w11 and ac or nil,
		ToggleKind = "switch", CheckSize = 18, CheckMark = onAc,
		Check = {
			off = { radius = w11 and 3 or 0, stroke = tx:Lerp(bg, 0.25) },
			offHover = { radius = w11 and 3 or 0, stroke = tx },
			on = { fill = ac, radius = w11 and 3 or 0, stroke = ac },
			onHover = { fill = ac:Lerp(bg, 0.15), radius = w11 and 3 or 0, stroke = ac:Lerp(bg, 0.15) },
		},
		Sw = {
			w = 40, h = 20, thumb = w11 and 12 or 10,
			off = { radius = 10, stroke = tx:Lerp(bg, w11 and 0.25 or 0.1), thick = w11 and 1 or 2 },
			on = { fill = ac, radius = 10, stroke = ac },
			offThumb = w11 and tx:Lerp(bg, 0.3) or tx, onThumb = onAc,
		},
		TrackH = w11 and 4 or 2, ThumbW = w11 and 14 or 8, ThumbH = w11 and 14 or 22,
		Track = { fill = mute, radius = 2 }, Fill = { fill = ac, radius = 2 },
		Thumb = w11 and {
			idle = { fill = ac, radius = 7, stroke = ring, thick = 3 },
			hover = { fill = ac:Lerp(WHITE, 0.15), radius = 7, stroke = ring, thick = 3 },
			down = { fill = ac:Lerp(bg, 0.2), radius = 7, stroke = ring, thick = 3 },
		} or {
			idle = { fill = tx }, hover = { fill = ac }, down = { fill = ac:Lerp(bg, 0.25) },
		},
		List = { fill = fieldBg, radius = r, stroke = border }, ComboBtn = false,
		Opt = {
			idle = { text = tx },
			hover = { fill = hover, radius = r, text = tx },
			sel = { fill = shade(el, 0.12), radius = r, text = ac },
		},
		Status = { fill = hd },
		Toast = { fill = el, radius = r, stroke = border, text = tx },
		Scroll = { w = w11 and 4 or 6, color = mute },
		Grip = dim, Sep = { border },
	}
end

local Builders = { classic = buildClassic, aero = buildAero, modern = buildModern }

local Palettes = {
	windows98 = { builder = "classic", Background = rgb(192, 192, 192), Header = rgb(0, 0, 128), Header2 = rgb(16, 132, 208),
		TextColor = rgb(0, 0, 0), SchemeColor = rgb(0, 0, 128), ElementColor = rgb(255, 255, 255) },
	windowsvista = { builder = "aero", variant = "vista", Background = rgb(255, 255, 255), Header = rgb(132, 168, 206),
		TextColor = rgb(0, 0, 0), SchemeColor = rgb(0, 51, 153), ElementColor = rgb(255, 255, 255) },
	windowslonghorn = { builder = "aero", variant = "longhorn", Background = rgb(240, 245, 252), Header = rgb(62, 118, 186),
		TextColor = rgb(10, 20, 40), SchemeColor = rgb(20, 70, 150), ElementColor = rgb(255, 255, 255) },
	windows7 = { builder = "aero", variant = "win7", Background = rgb(255, 255, 255), Header = rgb(178, 205, 236),
		TextColor = rgb(0, 0, 0), SchemeColor = rgb(30, 57, 91), ElementColor = rgb(255, 255, 255) },
	windows10 = { builder = "modern", variant = "win10", Background = rgb(32, 32, 32), Header = rgb(22, 22, 22),
		TextColor = rgb(255, 255, 255), SchemeColor = rgb(0, 120, 215), ElementColor = rgb(51, 51, 51) },
	windows11 = { builder = "modern", variant = "win11", Background = rgb(39, 39, 39), Header = rgb(32, 32, 32),
		TextColor = rgb(255, 255, 255), SchemeColor = rgb(96, 205, 255), ElementColor = rgb(50, 50, 50) },
	windows10light = { builder = "modern", variant = "win10", Background = rgb(255, 255, 255), Header = rgb(240, 240, 240),
		TextColor = rgb(0, 0, 0), SchemeColor = rgb(0, 120, 215), ElementColor = rgb(243, 243, 243) },
	windows11light = { builder = "modern", variant = "win11", Background = rgb(249, 249, 249), Header = rgb(243, 243, 243),
		TextColor = rgb(0, 0, 0), SchemeColor = rgb(0, 95, 184), ElementColor = rgb(255, 255, 255) },
}
local ALIAS = {
	["98"] = "windows98", win98 = "windows98", windows98 = "windows98", windows95 = "windows98",
	vista = "windowsvista", winvista = "windowsvista", windowsvista = "windowsvista",
	longhorn = "windowslonghorn", winlonghorn = "windowslonghorn", windowslonghorn = "windowslonghorn",
	["7"] = "windows7", win7 = "windows7", windows7 = "windows7",
	["10"] = "windows10", win10 = "windows10", windows10 = "windows10",
	["11"] = "windows11", win11 = "windows11", windows11 = "windows11",
	win10light = "windows10light", windows10light = "windows10light",
	win11light = "windows11light", windows11light = "windows11light",
	-- old Kavo names keep working (mapped to the nearest Windows theme)
	darktheme = "windows11", lighttheme = "windows11light",
}

local function resolveTheme(sel)
	local P = {}
	local base
	if type(sel) == "table" then
		base = Palettes.windows11
		for k, v in pairs(base) do P[k] = v end
		for k, v in pairs(sel) do P[k] = v end -- Kavo style custom colour table
		return P
	end
	local key = ALIAS[string.lower(tostring(sel or "windows11")):gsub("[%s%._%-]", "")]
	if not key then
		if sel ~= nil then warn("[KavoWin] unknown theme '" .. tostring(sel) .. "', using Windows11") end
		key = "windows11"
	end
	base = Palettes[key]
	for k, v in pairs(base) do P[k] = v end
	return P
end

Library.Themes = { "Windows98", "WindowsVista", "WindowsLonghorn", "Windows7", "Windows10", "Windows11", "Windows10Light", "Windows11Light" }

--------------------------------------------------------------------------------
-- gui mounting helpers
--------------------------------------------------------------------------------
local function randomName()
	local t = {}
	for i = 1, 14 do t[i] = string.char(math.random(97, 122)) end
	return table.concat(t)
end

local function containers()
	local list = {}
	pcall(function() if gethui then list[#list + 1] = gethui() end end)
	pcall(function() list[#list + 1] = game:GetService("CoreGui") end)
	pcall(function() list[#list + 1] = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui") end)
	return list
end

local function purge(title) -- remove an older window with the same title (re-execution safe)
	for _, c in ipairs(containers()) do
		pcall(function()
			for _, g in ipairs(c:GetChildren()) do
				if g:IsA("ScreenGui") and g:GetAttribute("KavoWin") == title then g:Destroy() end
			end
		end)
	end
end

local function mount(gui)
	pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
	for _, c in ipairs(containers()) do
		local ok = pcall(function() gui.Parent = c end)
		if ok and gui.Parent == c then return end
	end
end

--------------------------------------------------------------------------------
-- CreateLib  (same signature as Kavo: CreateLib(name, theme))
--   opts (optional 3rd arg): { Size = Vector2, ToggleKey = Enum.KeyCode, MinSize = Vector2 }
--------------------------------------------------------------------------------
function Library.CreateLib(title, themeSel, opts)
	title = tostring(title or "Library")
	opts = type(opts) == "table" and opts or {}
	local size = opts.Size or V2(580, 380)
	local minSize = opts.MinSize or V2(460, 300)

	for i = #Library.Windows, 1, -1 do
		local w = Library.Windows[i]
		if w.Title == title then w:Destroy() end
	end
	purge(title)

	local P = resolveTheme(themeSel)
	local T = {}
	local function rebuild()
		local nt = Builders[P.builder](P)
		for k in pairs(T) do T[k] = nil end
		for k, v in pairs(nt) do T[k] = v end
	end
	rebuild()

	local Win = { Title = title }
	local reg, conns, tabs, keybinds, settings = {}, {}, {}, {}, {}
	local alive = true
	local selectedTab
	local statusText = "Ready"
	local statusLbl

	----------------------------------------------------------------------------
	-- theme registry (replaces Kavo's one-`while wait()`-loop-per-element)
	----------------------------------------------------------------------------
	local function bind(fn)
		reg[fn] = true
		local ok, err = pcall(fn)
		if not ok then warn("[KavoWin] theme error: " .. tostring(err)) end
		return fn
	end
	local function unbind(fn) reg[fn] = nil end
	local function applyAll()
		for fn in pairs(reg) do
			local ok, err = pcall(fn)
			if not ok then warn("[KavoWin] theme error: " .. tostring(err)) end
		end
	end
	local function keep(c) conns[#conns + 1] = c return c end

	-- label whose font/size follow the theme; colorRole: "text" | "dim" | nil (caller colours it)
	local function mkText(parent, props, bold, colorRole)
		local l = new("TextLabel", props, parent)
		l.RichText = true
		bind(function()
			l.Font = bold and T.FontB or T.Font
			l.TextSize = T.Size
			if colorRole == "text" then l.TextColor3 = T.Text
			elseif colorRole == "dim" then l.TextColor3 = T.Dim end
		end)
		return l
	end

	-- hover / press tracking; render(state, animate) with state = idle | hover | down
	local function stateful(obj, render)
		local over, down, state = false, false, "idle"
		local function calc() state = (down and over) and "down" or (over and "hover" or "idle") end
		local function reset() over, down = false, false calc() render(state, true) end
		obj.MouseEnter:Connect(function() over = true calc() render(state, true) end)
		obj.MouseLeave:Connect(reset)
		if obj:IsA("GuiButton") then
			obj.MouseButton1Down:Connect(function() down = true calc() render(state, true) end)
			obj.MouseButton1Up:Connect(function() down = false calc() render(state, true) end)
		end
		obj.InputEnded:Connect(function(i) if i.UserInputType == TOUCH then reset() end end)
		local fn = bind(function() render(state, false) end)
		return function() render(state, true) end, fn
	end

	local function hookTip(obj, tip)
		if type(tip) ~= "string" or tip == "" then return end
		obj.MouseEnter:Connect(function() if statusLbl then statusLbl.Text = tip end end)
		obj.MouseLeave:Connect(function() if statusLbl then statusLbl.Text = statusText end end)
	end

	-- small drawn glyphs (no image assets needed) ------------------------------
	local function chevron(parent, props)
		local c = new("Frame", props, parent)
		c.AnchorPoint = V2(0.5, 0.5)
		local a = new("Frame", { BackgroundTransparency = 0, AnchorPoint = V2(0.5, 0.5), Rotation = -45 }, c)
		local b = new("Frame", { BackgroundTransparency = 0, AnchorPoint = V2(0.5, 0.5), Rotation = 45 }, c)
		return c, function(color, thick, len)
			local d = math.floor(len * 0.354 + 0.5)
			a.Size, b.Size = U2(0, thick, 0, len), U2(0, thick, 0, len)
			a.Position, b.Position = U2(0.5, -d, 0.5, 0), U2(0.5, d, 0.5, 0)
			a.BackgroundColor3, b.BackgroundColor3 = color, color
		end
	end

	-- checkbox with a drawn tick mark. returns frame, paint(on, hover, animate)
	local function makeCheck(parent, props)
		local f = new("Frame", props, parent)
		local set = Box(f)
		local m1 = new("Frame", { BackgroundTransparency = 0, AnchorPoint = V2(0.5, 0.5), Rotation = -45, Visible = false }, f)
		local m2 = new("Frame", { BackgroundTransparency = 0, AnchorPoint = V2(0.5, 0.5), Rotation = 45, Visible = false }, f)
		local function paint(on, hover, anim)
			local cs = T.CheckSize
			f.Size = U2(0, cs, 0, cs)
			local c = T.Check
			set(on and (hover and c.onHover or c.on) or (hover and c.offHover or c.off), anim)
			local k = cs / 16
			local t = math.max(2, math.floor(2 * k + 0.5))
			m1.Visible, m2.Visible = on, on
			m1.BackgroundColor3, m2.BackgroundColor3 = T.CheckMark, T.CheckMark
			m1.Size, m2.Size = U2(0, t, 0, math.floor(5 * k + 0.5)), U2(0, t, 0, math.floor(9.5 * k + 0.5))
			m1.Position = U2(0, math.floor(4.8 * k + 0.5), 0, math.floor(9.2 * k + 0.5))
			m2.Position = U2(0, math.floor(9.7 * k + 0.5), 0, math.floor(7.7 * k + 0.5))
		end
		return f, paint
	end

	-- text field (sunken edit box / modern input). returns frame, textbox
	local function newField(parent, props)
		local f = new("Frame", props, parent)
		local set = Box(f)
		local tb = new("TextBox", {
			Size = U2(1, 0, 1, 0), ClearTextOnFocus = false, TextXAlignment = LEFT,
			ClipsDescendants = true, TextTruncate = E.TextTruncate.AtEnd,
		}, f)
		local tpad = new("UIPadding", nil, tb)
		local line = new("Frame", { Name = "_line", BackgroundTransparency = 0, AnchorPoint = V2(0, 1), Position = U2(0, 2, 1, 0), Size = U2(1, -4, 0, 2), Visible = false, ZIndex = 3 }, f)
		local focused = false
		local function paint(anim)
			set(focused and T.Field.focus or T.Field.idle, anim)
			tb.Font, tb.TextSize = T.Font, T.Size
			tb.TextColor3, tb.PlaceholderColor3 = T.Text, T.Dim
			tpad.PaddingLeft, tpad.PaddingRight = U1(0, T.FieldPad), U1(0, T.FieldPad)
			line.Visible = focused and T.FieldLine ~= nil
			if T.FieldLine then line.BackgroundColor3 = T.FieldLine end
		end
		tb.Focused:Connect(function() focused = true paint(true) end)
		tb.FocusLost:Connect(function() focused = false paint(true) end)
		bind(function() paint(false) end)
		return f, tb
	end

	----------------------------------------------------------------------------
	-- window frame
	----------------------------------------------------------------------------
	local gui = new("ScreenGui", { Name = randomName(), ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 100, ZIndexBehavior = E.ZIndexBehavior.Sibling })
	pcall(function() gui:SetAttribute("KavoWin", title) end)
	mount(gui)
	Win.Gui = gui

	local Main = new("Frame", {
		Name = "Main", Active = true, ClipsDescendants = true,
		Size = U2(0, size.X, 0, size.Y), Position = U2(0.5, -size.X / 2, 0.5, -size.Y / 2),
	}, gui)
	local setMain = Box(Main)

	local TitleBar = new("Frame", { Name = "TitleBar", Active = true }, Main)
	local setTitle = Box(TitleBar)
	local Icon = new("Frame", { Name = "Icon", AnchorPoint = V2(0, 0.5), Position = U2(0, 8, 0.5, 0), Size = U2(0, 13, 0, 13) }, TitleBar)
	local iconSq = {}
	for i = 1, 4 do
		iconSq[i] = new("Frame", {
			BackgroundTransparency = 0, Size = U2(0, 6, 0, 6),
			Position = U2(0, ((i - 1) % 2) * 7, 0, math.floor((i - 1) / 2) * 7),
		}, Icon)
	end
	local TitleLbl = new("TextLabel", { Name = "Title", Text = title, TextXAlignment = LEFT, TextTruncate = E.TextTruncate.AtEnd }, TitleBar)

	-- caption buttons (minimise / maximise / close) ---------------------------
	local caps, capsW = {}, 0
	local function newCap(kind)
		local b = new("TextButton", { Name = kind }, TitleBar)
		local set = Box(b)
		local g = {}
		if kind == "min" then
			g.a = new("Frame", { BackgroundTransparency = 0, AnchorPoint = V2(0.5, 0.5) }, b)
		elseif kind == "max" then
			g.a = new("Frame", { AnchorPoint = V2(0.5, 0.5) }, b)
			g.s = new("UIStroke", nil, g.a)
			g.t = new("Frame", { BackgroundTransparency = 0, AnchorPoint = V2(0.5, 0) }, b)
		else
			g.a = new("Frame", { BackgroundTransparency = 0, AnchorPoint = V2(0.5, 0.5), Rotation = 45 }, b)
			g.b = new("Frame", { BackgroundTransparency = 0, AnchorPoint = V2(0.5, 0.5), Rotation = -45 }, b)
		end
		local c = { btn = b }
		c.redraw = stateful(b, function(st, anim)
			local C = T.Cap
			set((kind == "close" and C.close or C.min)[st], anim)
			local col = C.icon
			if kind == "close" then col = (st == "idle") and C.closeIcon or C.closeIconHot end
			local gs, gt = C.gs, C.gt
			if kind == "min" then
				g.a.Size = U2(0, gs, 0, gt)
				g.a.Position = U2(0.5, 0, 0.5, C.minDy)
				g.a.BackgroundColor3 = col
			elseif kind == "max" then
				g.a.Size = U2(0, gs, 0, gs - (C.maxBar and 1 or 0))
				g.a.Position = U2(0.5, 0, 0.5, C.maxBar and 1 or 0)
				g.s.Thickness, g.s.Color = gt, col
				g.t.Visible = C.maxBar
				g.t.BackgroundColor3 = col
				g.t.Size = U2(0, gs + 2 * gt, 0, 2)
				g.t.Position = U2(0.5, 0, 0.5, -math.floor(gs / 2) - gt + 1)
			else
				for _, f in ipairs({ g.a, g.b }) do
					f.Size = U2(0, gt, 0, C.gl)
					f.Position = U2(0.5, 0, 0.5, 0)
					f.BackgroundColor3 = col
				end
			end
		end)
		return c
	end
	caps.min, caps.max, caps.close = newCap("min"), newCap("max"), newCap("close")

	local function layoutCaps()
		local C = T.Cap
		local x = C.r
		caps.close.btn.Size = U2(0, C.cw, 0, C.h)
		caps.close.btn.Position = U2(1, -(x + C.cw), 0, C.y)
		x = x + C.cw + C.gap
		caps.max.btn.Size = U2(0, C.w, 0, C.h)
		caps.max.btn.Position = U2(1, -(x + C.w), 0, C.y)
		x = x + C.w + C.gap2
		caps.min.btn.Size = U2(0, C.w, 0, C.h)
		caps.min.btn.Position = U2(1, -(x + C.w), 0, C.y)
		capsW = x + C.w
	end

	-- body --------------------------------------------------------------------
	local Body = new("Frame", { Name = "Body" }, Main)
	local setBody = Box(Body)
	local Side = new("Frame", { Name = "Side" }, Body)
	local setSide = Box(Side)
	local TabList = new("ScrollingFrame", {
		Name = "Tabs", Size = U2(1, 0, 1, 0), ScrollBarThickness = 0, CanvasSize = U2(0, 0, 0, 0),
		AutomaticCanvasSize = E.AutomaticSize.Y, ScrollingDirection = E.ScrollingDirection.Y,
	}, Side)
	local tabPad = new("UIPadding", nil, TabList)
	local tabLayout = new("UIListLayout", { SortOrder = E.SortOrder.LayoutOrder }, TabList)
	local Div = new("Frame", { Name = "Div", BackgroundTransparency = 0 }, Body)
	local PageHost = new("Frame", { Name = "Pages", ClipsDescendants = true }, Body)
	local Status = new("Frame", { Name = "Status" }, Body)
	local setStatus = Box(Status)
	statusLbl = mkText(Status, { Name = "Text", Position = U2(0, 8, 0, 0), Size = U2(1, -30, 1, 0), TextXAlignment = LEFT, Text = statusText, TextTruncate = E.TextTruncate.AtEnd }, false, "dim")
	local Grip = new("TextButton", { Name = "Grip", AnchorPoint = V2(1, 1), Position = U2(1, -2, 1, -2), Size = U2(0, 14, 0, 14) }, Status)
	local gripDots = {}
	for i, p in ipairs({ { 11, 11 }, { 7, 11 }, { 11, 7 }, { 3, 11 }, { 7, 7 }, { 11, 3 } }) do
		gripDots[i] = new("Frame", { BackgroundTransparency = 0, Size = U2(0, 2, 0, 2), Position = U2(0, p[1], 0, p[2]) }, Grip)
	end

	bind(function()
		setMain(T.Win)
		TitleBar.Position = U2(0, T.TitleX, 0, T.TitleTop)
		TitleBar.Size = U2(1, -2 * T.TitleX, 0, T.TitleH)
		setTitle(T.Title)
		local ic = T.Icon
		Icon.Visible = ic ~= nil
		if ic then for i = 1, 4 do iconSq[i].BackgroundColor3 = ic[i] end end
		layoutCaps()
		local left = ic and 28 or 10
		TitleLbl.Position = U2(0, left, 0, 0)
		TitleLbl.Size = U2(1, -(left + capsW + 6), 1, 0)
		TitleLbl.Font = T.TitleBold and T.FontB or T.Font
		TitleLbl.TextSize = T.Size
		TitleLbl.TextColor3 = T.TitleText
		if T.TitleStroke then
			TitleLbl.TextStrokeColor3 = T.TitleStroke
			TitleLbl.TextStrokeTransparency = T.TitleStrokeA
		else
			TitleLbl.TextStrokeTransparency = 1
		end

		local top = T.TitleTop + T.TitleH
		Body.Position = U2(0, T.InL, 0, top)
		Body.Size = U2(1, -2 * T.InL, 1, -(top + T.InB))
		setBody(T.Body)
		local bp, sh = T.BodyPad, T.StatusH
		local gap = bp > 0 and 4 or 0
		Side.Position = U2(0, bp, 0, bp)
		Side.Size = U2(0, T.SideW, 1, -(sh + 2 * bp + gap))
		setSide(T.Side)
		tabPad.PaddingLeft, tabPad.PaddingRight = U1(0, T.SidePad), U1(0, T.SidePad)
		tabPad.PaddingTop, tabPad.PaddingBottom = U1(0, T.SidePad), U1(0, T.SidePad)
		tabLayout.Padding = U1(0, T.TabGap)
		Div.Visible = T.Div ~= nil
		if T.Div then
			Div.BackgroundColor3 = T.Div
			Div.Position = U2(0, bp + T.SideW, 0, 0)
			Div.Size = U2(0, 1, 1, -sh)
		end
		local px = bp + T.SideW + (bp > 0 and 6 or 1)
		PageHost.Position = U2(0, px, 0, bp)
		PageHost.Size = U2(1, -(px + bp), 1, -(sh + 2 * bp + gap))
		Status.Position = U2(0, bp, 1, -(bp + sh))
		Status.Size = U2(1, -2 * bp, 0, sh)
		setStatus(T.Status)
		for i = 1, 6 do gripDots[i].BackgroundColor3 = T.Grip end
	end)

	----------------------------------------------------------------------------
	-- window behaviour: drag, double click, resize, min / max / close
	----------------------------------------------------------------------------
	local maximized, minimized = false, false
	local restore = {}

	local function setMax(v)
		if minimized or v == maximized then return end
		maximized = v
		if v then
			restore.pos, restore.size = Main.Position, Main.Size
			tween(Main, { Position = U2(0, 0, 0, 0), Size = U2(1, 0, 1, 0) }, 0.18)
		else
			tween(Main, { Position = restore.pos, Size = restore.size }, 0.18)
		end
		Grip.Visible = not v
	end

	local function setMin(v)
		if maximized or v == minimized then return end
		minimized = v
		if v then
			restore.msize = Main.Size
			Body.Visible = false
			tween(Main, { Size = U2(restore.msize.X.Scale, restore.msize.X.Offset, 0, T.TitleTop + T.TitleH + T.InB) }, 0.15)
		else
			Body.Visible = true
			tween(Main, { Size = restore.msize }, 0.15)
		end
	end

	caps.min.btn.Activated:Connect(function() setMin(not minimized) end)
	caps.max.btn.Activated:Connect(function() setMax(not maximized) end)
	caps.close.btn.Activated:Connect(function()
		local as, p = Main.AbsoluteSize, Main.Position
		tween(Main, { Size = U2(0, 0, 0, 0), Position = U2(p.X.Scale, p.X.Offset + as.X / 2, p.Y.Scale, p.Y.Offset + as.Y / 2) }, 0.12)
		task.delay(0.14, function() Win:Destroy() end)
	end)

	local function overCaps(p)
		local ap, as = TitleBar.AbsolutePosition, TitleBar.AbsoluteSize
		return p.X >= ap.X + as.X - capsW - 4 and p.Y <= ap.Y + as.Y
	end
	local lastClick = 0
	TitleBar.InputBegan:Connect(function(input)
		if not isPress(input) or overCaps(pointer(input)) then return end
		local now = os.clock()
		if now - lastClick < 0.35 then lastClick = 0 setMax(not maximized) return end
		lastClick = now
		if maximized then return end
		local startPos, startUI = input.Position, Main.Position
		beginDrag(function(i)
			local d = i.Position - startPos
			Main.Position = U2(startUI.X.Scale, startUI.X.Offset + d.X, startUI.Y.Scale, startUI.Y.Offset + d.Y)
		end)
	end)

	Grip.InputBegan:Connect(function(input)
		if not isPress(input) or maximized or minimized then return end
		local startPos, startSize = input.Position, Main.AbsoluteSize
		beginDrag(function(i)
			local d = i.Position - startPos
			Main.Size = U2(0, math.max(minSize.X, startSize.X + d.X), 0, math.max(minSize.Y, startSize.Y + d.Y))
		end)
	end)

	-- one input listener for every keybind + the toggle key
	Win.ToggleKey = opts.ToggleKey
	keep(UserInputService.InputBegan:Connect(function(input, gp)
		if gp or input.UserInputType ~= KEYBOARD then return end
		if Win.ToggleKey and input.KeyCode == Win.ToggleKey then Win:Toggle() return end
		for _, kb in ipairs(keybinds) do
			if not kb.listening and kb.key == input.KeyCode then fire(kb.cb) end
		end
	end))

	----------------------------------------------------------------------------
	-- tabs
	----------------------------------------------------------------------------
	local function cfgKey(tabName, secName, name)
		local base = tabName .. "/" .. secName .. "/" .. name
		local key, n = base, 1
		while settings[key] do n = n + 1 key = base .. "#" .. n end
		return key
	end

	function Win:NewTab(tabName)
		tabName = tostring(tabName or "Tab")
		local tab, entry = {}, { name = tabName }
		tabs[#tabs + 1] = entry

		local btn = new("TextButton", { Name = tabName, LayoutOrder = #tabs, Size = U2(1, 0, 0, T.TabH) }, TabList)
		local setBtn = Box(btn)
		local lbl = mkText(btn, { Name = "Text", TextXAlignment = LEFT, Text = tabName, TextTruncate = E.TextTruncate.AtEnd }, false)
		local ind = new("Frame", { Name = "Ind", BackgroundTransparency = 0, Visible = false, AnchorPoint = V2(0, 0.5) }, btn)
		local indCorner = new("UICorner", nil, ind)
		local page = new("ScrollingFrame", {
			Name = tabName, Size = U2(1, 0, 1, 0), Visible = false, Active = true,
			CanvasSize = U2(0, 0, 0, 0), AutomaticCanvasSize = E.AutomaticSize.Y,
			ScrollingDirection = E.ScrollingDirection.Y, VerticalScrollBarInset = E.ScrollBarInset.Always,
		}, PageHost)
		local pLayout = new("UIListLayout", { SortOrder = E.SortOrder.LayoutOrder }, page)
		local pPad = new("UIPadding", nil, page)
		entry.page = page

		entry.redraw = stateful(btn, function(st, anim)
			local sel = selectedTab == entry
			local s = sel and T.Tab.sel or (st == "idle" and T.Tab.idle or T.Tab.hover)
			setBtn(s, anim)
			btn.Size = U2(1, 0, 0, T.TabH)
			local I = T.TabInd
			local px = I and 14 or 10
			lbl.Position, lbl.Size = U2(0, px, 0, 0), U2(1, -(px + 6), 1, 0)
			lbl.TextColor3 = s.text or T.Text
			ind.Visible = sel and I ~= nil
			if I then
				ind.BackgroundColor3 = I.color
				ind.Size = I.full and U2(0, I.w, 1, 0) or U2(0, I.w, 0, I.h)
				ind.Position = U2(0, I.full and 0 or 3, 0.5, 0)
				indCorner.CornerRadius = U1(0, I.r)
			end
		end)
		bind(function()
			page.ScrollBarThickness = T.Scroll.w
			page.ScrollBarImageColor3 = T.Scroll.color
			pLayout.Padding = U1(0, T.SecGap)
			local pp = U1(0, T.PagePad)
			pPad.PaddingLeft, pPad.PaddingRight, pPad.PaddingTop, pPad.PaddingBottom = pp, pp, pp, pp
		end)

		function entry.select()
			if selectedTab == entry then return end
			local prev = selectedTab
			selectedTab = entry
			if prev then prev.page.Visible = false prev.redraw() end
			page.Visible = true
			entry.redraw()
		end
		btn.Activated:Connect(entry.select)
		if #tabs == 1 then entry.select() end

		function tab:Select() entry.select() end
		function tab:Destroy()
			for i, t in ipairs(tabs) do if t == entry then table.remove(tabs, i) break end end
			btn:Destroy() page:Destroy()
			if selectedTab == entry then selectedTab = nil if tabs[1] then tabs[1].select() end end
		end

		----------------------------------------------------------------------
		-- sections
		----------------------------------------------------------------------
		function tab:NewSection(secName, hidden)
			secName = tostring(secName or "Section")
			local sec, order = {}, 0
			local function nextOrder() order = order + 1 return order end

			local root = new("Frame", { Name = "Section", Size = U2(1, 0, 0, 0) }, page)
			local rootList = new("UIListLayout", { SortOrder = E.SortOrder.LayoutOrder }, root)
			local rootPad = new("UIPadding", nil, root)
			local head = mkText(root, { Name = "Head", LayoutOrder = 1, Text = secName, TextXAlignment = LEFT, ZIndex = 3 }, true)
			local headPad = new("UIPadding", nil, head)
			local headLine = new("Frame", { Name = "Line", BackgroundTransparency = 0, AnchorPoint = V2(0, 1), Position = U2(0, 0, 1, 0), Size = U2(1, 0, 0, 1), Visible = false }, head)
			local card = new("Frame", { Name = "Card", LayoutOrder = 2, Size = U2(1, 0, 0, 0) }, root)
			local setCard = Box(card)
			local content = new("Frame", { Name = "Content", Size = U2(1, 0, 0, 0) }, card)
			local cList = new("UIListLayout", { SortOrder = E.SortOrder.LayoutOrder }, content)
			local cPad = new("UIPadding", nil, content)

			local function resize()
				local ch = cList.AbsoluteContentSize.Y + cPad.PaddingTop.Offset + cPad.PaddingBottom.Offset
				content.Size = U2(1, 0, 0, ch)
				card.Size = U2(1, 0, 0, ch)
				root.Size = U2(1, 0, 0, rootList.AbsoluteContentSize.Y + rootPad.PaddingTop.Offset + rootPad.PaddingBottom.Offset)
			end
			cList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(resize)
			rootList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(resize)

			bind(function()
				local hh = T.HeadH
				head.Font = (T.GroupBold ~= false) and T.FontB or T.Font
				head.TextSize = T.Size + (T.HeadBig or 0)
				head.TextColor3 = T.GroupHead
				if T.GroupKind == "etched" then -- Win98 group box: title sits on the top border
					head.Parent = card
					head.AutomaticSize = E.AutomaticSize.X
					head.Size = U2(0, 0, 0, hh)
					head.Position = U2(0, 10, 0, -math.floor(hh / 2))
					head.BackgroundTransparency, head.BackgroundColor3 = 0, T.Face
					headPad.PaddingLeft, headPad.PaddingRight = U1(0, 3), U1(0, 3)
					rootPad.PaddingTop = U1(0, hidden and 0 or math.floor(hh / 2))
					headLine.Visible = false
				else
					head.Parent = root
					head.AutomaticSize = E.AutomaticSize.None
					head.Size = U2(1, 0, 0, hh)
					head.Position = U2(0, 0, 0, 0)
					head.BackgroundTransparency = 1
					headPad.PaddingLeft, headPad.PaddingRight = U1(0, 0), U1(0, 0)
					rootPad.PaddingTop = U1(0, 0)
					headLine.Visible = T.GroupLine ~= nil
					if T.GroupLine then headLine.BackgroundColor3 = T.GroupLine end
				end
				head.Visible = not hidden
				rootList.Padding = U1(0, hidden and 0 or T.HeadGap)
				setCard(T.Group)
				local p = U1(0, T.Pad)
				cPad.PaddingLeft, cPad.PaddingRight, cPad.PaddingTop, cPad.PaddingBottom = p, p, p, p
				cList.Padding = U1(0, T.Gap)
				resize()
			end)

			local function finish(o, obj, tip)
				o.Instance = obj
				function o:Destroy() obj:Destroy() end
				function o:SetVisible(v) obj.Visible = v end
				hookTip(obj, tip)
				return o
			end
			local function remember(name, get, set)
				settings[cfgKey(tabName, secName, tostring(name))] = { get = get, set = set }
			end
			local function rowHover(st) return st == "idle" and T.Row.idle or T.Row.hover end

			function sec:UpdateSection(newTitle) head.Text = tostring(newTitle) end
			function sec:Destroy() root:Destroy() end

			------------------------------------------------------------------
			-- Label / Paragraph / Separator
			------------------------------------------------------------------
			function sec:NewLabel(text)
				local o = {}
				local l = new("TextLabel", {
					Name = "Label", LayoutOrder = nextOrder(), Size = U2(1, 0, 0, 0), AutomaticSize = E.AutomaticSize.Y,
					TextWrapped = true, TextXAlignment = LEFT, TextYAlignment = E.TextYAlignment.Top,
					RichText = true, Text = tostring(text or ""),
				})
				l.Parent = content
				local pad = new("UIPadding", nil, l)
				bind(function()
					l.Font, l.TextSize, l.TextColor3 = T.Font, T.Size, T.Text
					pad.PaddingLeft, pad.PaddingRight = U1(0, T.RowPad), U1(0, T.RowPad)
					pad.PaddingTop, pad.PaddingBottom = U1(0, 3), U1(0, 3)
				end)
				function o:UpdateLabel(t) l.Text = tostring(t) end
				o.SetText = o.UpdateLabel
				return finish(o, l)
			end

			function sec:NewParagraph(title, text)
				local o = {}
				local f = new("Frame", { Name = "Paragraph", LayoutOrder = nextOrder(), Size = U2(1, 0, 0, 0), AutomaticSize = E.AutomaticSize.Y }, content)
				new("UIListLayout", { SortOrder = E.SortOrder.LayoutOrder, Padding = U1(0, 2) }, f)
				local pad = new("UIPadding", nil, f)
				local t1 = mkText(f, { Name = "Title", LayoutOrder = 1, Size = U2(1, 0, 0, 0), AutomaticSize = E.AutomaticSize.Y, TextWrapped = true, TextXAlignment = LEFT, Text = tostring(title or "") }, true, "text")
				local t2 = mkText(f, { Name = "Body", LayoutOrder = 2, Size = U2(1, 0, 0, 0), AutomaticSize = E.AutomaticSize.Y, TextWrapped = true, TextXAlignment = LEFT, TextYAlignment = E.TextYAlignment.Top, Text = tostring(text or "") }, false, "dim")
				bind(function()
					pad.PaddingLeft, pad.PaddingRight = U1(0, T.RowPad), U1(0, T.RowPad)
					pad.PaddingTop, pad.PaddingBottom = U1(0, 3), U1(0, 3)
				end)
				function o:Update(a, b) if a ~= nil then t1.Text = tostring(a) end if b ~= nil then t2.Text = tostring(b) end end
				return finish(o, f)
			end

			function sec:NewSeparator()
				local o = {}
				local f = new("Frame", { Name = "Separator", LayoutOrder = nextOrder(), Size = U2(1, 0, 0, 8) }, content)
				local l1 = new("Frame", { BackgroundTransparency = 0, AnchorPoint = V2(0, 0.5) }, f)
				local l2 = new("Frame", { BackgroundTransparency = 0, AnchorPoint = V2(0, 0.5) }, f)
				bind(function()
					local S, rp = T.Sep, T.RowPad
					l1.BackgroundColor3 = S[1]
					l1.Size = U2(1, -rp * 2, 0, 1)
					l1.Position = U2(0, rp, 0.5, S[2] and -1 or 0)
					l2.Visible = S[2] ~= nil
					if S[2] then
						l2.BackgroundColor3 = S[2]
						l2.Size = l1.Size
						l2.Position = U2(0, rp, 0.5, 0)
					end
				end)
				return finish(o, f)
			end

			------------------------------------------------------------------
			-- Button   NewButton(name, tip, callback)
			------------------------------------------------------------------
			function sec:NewButton(name, tip, callback)
				name = tostring(name or "Button")
				local o = {}
				local b = new("TextButton", { Name = "Button", LayoutOrder = nextOrder() }, content)
				local set = Box(b)
				local lbl = mkText(b, { Name = "Text", Text = name, TextTruncate = E.TextTruncate.AtEnd }, false)
				stateful(b, function(st, anim)
					local s = T.Action[st]
					set(s, anim)
					b.Size = U2(1, 0, 0, T.RowH)
					local off = (T.PressShift and st == "down") and 1 or 0
					local p = (T.ActionAlign == CENTER) and 4 or T.RowPad
					lbl.TextXAlignment = T.ActionAlign
					lbl.Position = U2(0, p + off, 0, off)
					lbl.Size = U2(1, -(p * 2), 1, 0)
					lbl.TextColor3 = s.text or T.Text
				end)
				b.Activated:Connect(function() fire(callback) end)
				function o:UpdateButton(t) lbl.Text = tostring(t) end
				o.SetText = o.UpdateButton
				function o:Fire() fire(callback) end
				return finish(o, b, tip)
			end

			------------------------------------------------------------------
			-- Toggle   NewToggle(name, tip, callback(state))
			------------------------------------------------------------------
			function sec:NewToggle(name, tip, callback)
				name = tostring(name or "Toggle")
				local o, on = {}, false
				local row = new("TextButton", { Name = "Toggle", LayoutOrder = nextOrder() }, content)
				local setRow = Box(row)
				local lbl = mkText(row, { Name = "Text", Text = name, TextXAlignment = LEFT, TextTruncate = E.TextTruncate.AtEnd }, false, "text")
				local chk, paintChk = makeCheck(row, { Name = "Check", AnchorPoint = V2(0, 0.5) })
				local sw = new("Frame", { Name = "Switch", AnchorPoint = V2(1, 0.5) }, row)
				local setSw = Box(sw)
				local thumb = new("Frame", { Name = "Thumb", BackgroundTransparency = 0, AnchorPoint = V2(0, 0.5) }, sw)
				local thumbCorner = new("UICorner", nil, thumb)
				local redraw = stateful(row, function(st, anim)
					row.Size = U2(1, 0, 0, T.RowH)
					setRow(rowHover(st), anim)
					local rp = T.RowPad
					if T.ToggleKind == "check" then
						sw.Visible, chk.Visible = false, true
						paintChk(on, st ~= "idle", anim)
						chk.Position = U2(0, rp, 0.5, 0)
						lbl.Position = U2(0, rp + T.CheckSize + 8, 0, 0)
						lbl.Size = U2(1, -(rp * 2 + T.CheckSize + 8), 1, 0)
					else
						chk.Visible, sw.Visible = false, true
						local S = T.Sw
						sw.Size = U2(0, S.w, 0, S.h)
						sw.Position = U2(1, -rp, 0.5, 0)
						setSw(on and S.on or S.off, anim)
						thumbCorner.CornerRadius = U1(0, S.thumb)
						thumb.BackgroundColor3 = on and S.onThumb or S.offThumb
						thumb.Size = U2(0, S.thumb, 0, S.thumb)
						local inset = math.floor((S.h - S.thumb) / 2)
						local target = on and U2(1, -(S.thumb + inset), 0.5, 0) or U2(0, inset, 0.5, 0)
						if anim then tween(thumb, { Position = target }, 0.12) else thumb.Position = target end
						lbl.Position = U2(0, rp, 0, 0)
						lbl.Size = U2(1, -(rp * 2 + S.w + 8), 1, 0)
					end
				end)
				local function setState(v, silent)
					on = v and true or false
					redraw()
					if not silent then fire(callback, on) end
				end
				row.Activated:Connect(function() setState(not on) end)
				function o:UpdateToggle(newText, state)
					if newText ~= nil then lbl.Text = tostring(newText) end
					if state ~= nil then setState(state) end
				end
				function o:SetState(v, silent) setState(v, silent) end
				function o:GetState() return on end
				function o:SetText(t) lbl.Text = tostring(t) end
				remember(name, function() return on end, function(v) setState(v) end)
				return finish(o, row, tip)
			end

			------------------------------------------------------------------
			-- Slider   NewSlider(name, tip, max, min, callback(value) [, default, step])
			------------------------------------------------------------------
			function sec:NewSlider(name, tip, maxv, minv, callback, default, step)
				name = tostring(name or "Slider")
				maxv, minv, step = tonumber(maxv) or 100, tonumber(minv) or 0, tonumber(step) or 1
				local lo, hi = math.min(minv, maxv), math.max(minv, maxv)
				local value = math.clamp(tonumber(default) or lo, lo, hi)
				local dragging, o = false, {}

				local root = new("Frame", { Name = "Slider", LayoutOrder = nextOrder() }, content)
				local setRow = Box(root)
				local lbl = mkText(root, { Name = "Text", Text = name, TextXAlignment = LEFT, TextTruncate = E.TextTruncate.AtEnd }, false, "text")
				local val = mkText(root, { Name = "Value", TextXAlignment = RIGHT, AnchorPoint = V2(1, 0) }, false, "dim")
				local area = new("TextButton", { Name = "Area", AnchorPoint = V2(0, 1) }, root)
				local track = new("Frame", { Name = "Track", AnchorPoint = V2(0, 0.5) }, area)
				local setTrack = Box(track)
				local fill = new("Frame", { Name = "Fill" }, track)
				local setFill = Box(fill)
				local thumb = new("Frame", { Name = "Thumb", AnchorPoint = V2(0.5, 0.5) }, area)
				local setThumb = Box(thumb)

				local function fmt(v)
					if v == math.floor(v) then return tostring(math.floor(v)) end
					return tostring(math.floor(v * 100 + 0.5) / 100)
				end
				local function paintPos()
					local a = (hi == lo) and 0 or (value - lo) / (hi - lo)
					local off = math.floor(T.ThumbW * (0.5 - a) + 0.5)
					thumb.Position = U2(a, off, 0.5, 0)
					if T.Fill then fill.Size = U2(a, off, 1, 0) end
					val.Text = fmt(value)
				end
				local redraw = stateful(area, function(st, anim)
					if dragging then st = "down" end
					local px = T.RowPad
					root.Size = U2(1, 0, 0, T.SliderH)
					setRow(rowHover(st), anim)
					lbl.Position, lbl.Size = U2(0, px, 0, 4), U2(1, -(px * 2 + 60), 0, T.Size + 6)
					val.Position, val.Size = U2(1, -px, 0, 4), U2(0, 56, 0, T.Size + 6)
					area.Position = U2(0, px, 1, px > 0 and -8 or -2)
					area.Size = U2(1, -px * 2, 0, math.max(T.ThumbH, 16) + 2)
					track.Position, track.Size = U2(0, 0, 0.5, 0), U2(1, 0, 0, T.TrackH)
					setTrack(T.Track, false)
					fill.Visible = T.Fill ~= nil
					if T.Fill then setFill(T.Fill, false) end
					thumb.Size = U2(0, T.ThumbW, 0, T.ThumbH)
					setThumb(T.Thumb[st], anim)
					paintPos()
				end)
				local function setValue(v, silent)
					v = math.clamp(v, lo, hi)
					if v == value and silent then return end
					value = v
					paintPos()
					if not silent then fire(callback, value) end
				end
				local function fromX(px)
					local w = area.AbsoluteSize.X - T.ThumbW
					local a = (w > 0) and math.clamp((px - area.AbsolutePosition.X - T.ThumbW / 2) / w, 0, 1) or 0
					local v = lo + (hi - lo) * a
					v = math.floor(v / step + 0.5) * step
					v = math.floor(math.clamp(v, lo, hi) * 1e6 + 0.5) / 1e6
					if v ~= value then setValue(v) end
				end
				area.InputBegan:Connect(function(input)
					if not isPress(input) then return end
					dragging = true redraw()
					fromX(pointer(input).X)
					beginDrag(function(i) fromX(pointer(i).X) end, function() dragging = false redraw() end)
				end)
				function o:SetValue(v, silent) setValue(tonumber(v) or value, silent) end
				function o:GetValue() return value end
				remember(name, function() return value end, function(v) setValue(tonumber(v) or value) end)
				return finish(o, root, tip)
			end

			------------------------------------------------------------------
			-- TextBox   NewTextBox(name, tip, callback(text) [, placeholder])   (fires on Enter)
			------------------------------------------------------------------
			function sec:NewTextBox(name, tip, callback, placeholder)
				name = tostring(name or "Textbox")
				local o = {}
				local row = new("Frame", { Name = "TextBox", LayoutOrder = nextOrder() }, content)
				local setRow = Box(row)
				local lbl = mkText(row, { Name = "Text", Text = name, TextXAlignment = LEFT, TextTruncate = E.TextTruncate.AtEnd }, false, "text")
				local field, tb = newField(row, { Name = "Field", AnchorPoint = V2(1, 0.5) })
				tb.PlaceholderText = placeholder or "Type here..."
				stateful(row, function(st, anim)
					local rp = T.RowPad
					row.Size = U2(1, 0, 0, T.RowH)
					setRow(rowHover(st), anim)
					lbl.Position, lbl.Size = U2(0, rp, 0, 0), U2(0.45, -rp, 1, 0)
					field.Position, field.Size = U2(1, -rp, 0.5, 0), U2(0.55, -rp, 0, T.FieldH)
				end)
				tb.FocusLost:Connect(function(enter) if enter then fire(callback, tb.Text) end end)
				function o:SetText(t, silent)
					tb.Text = tostring(t or "")
					if not silent then fire(callback, tb.Text) end
				end
				function o:GetText() return tb.Text end
				remember(name, function() return tb.Text end, function(v) o:SetText(v) end)
				return finish(o, row, tip)
			end

			------------------------------------------------------------------
			-- Dropdown / MultiDropdown
			--   NewDropdown(name, tip, list, callback(value))
			--   NewMultiDropdown(name, tip, list, callback(selectedTable))
			------------------------------------------------------------------
			local function makeDropdown(multi, name, tip, list, callback)
				name = tostring(name or "Dropdown")
				list = type(list) == "table" and list or {}
				local o = {}
				local isOpen, current, chosen, entries = false, nil, {}, {}
				local visibleCount = #list

				local root = new("Frame", { Name = "Dropdown", LayoutOrder = nextOrder(), ClipsDescendants = true }, content)
				local head = new("TextButton", { Name = "Head" }, root)
				local setHead = Box(head)
				local lbl = mkText(head, { Name = "Text", Text = name, TextXAlignment = LEFT, TextTruncate = E.TextTruncate.AtEnd }, false, "text")
				local field = new("Frame", { Name = "Field", AnchorPoint = V2(1, 0.5) }, head)
				local setField = Box(field)
				local val = mkText(field, { Name = "Value", TextXAlignment = LEFT, TextTruncate = E.TextTruncate.AtEnd }, false, "text")
				local arrowBtn = new("Frame", { Name = "ArrowBtn", AnchorPoint = V2(1, 0) }, field)
				local setArrowBtn = Box(arrowBtn)
				local arrow, paintArrow = chevron(arrowBtn, { Name = "Arrow", Size = U2(0, 10, 0, 10), Position = U2(0.5, 0, 0.5, 0) })
				local panel = new("Frame", { Name = "Panel" }, root)
				local setPanel = Box(panel)
				local sFrame, search = newField(panel, { Name = "Search" })
				search.PlaceholderText = "Search..."
				local scroller = new("ScrollingFrame", {
					Name = "List", CanvasSize = U2(0, 0, 0, 0), AutomaticCanvasSize = E.AutomaticSize.Y,
					ScrollingDirection = E.ScrollingDirection.Y, VerticalScrollBarInset = E.ScrollBarInset.Always, Active = true,
				}, panel)
				new("UIListLayout", { SortOrder = E.SortOrder.LayoutOrder }, scroller)

				local pick, setOpen, applyFilter, redrawHead

				local function panelHeight()
					local hasSearch = #list > 8
					local sH = hasSearch and (T.FieldH + 8) or 0
					return sH + math.min(visibleCount * T.OptH, T.OptH * 6) + 6, sH, hasSearch
				end
				local function relayout(anim)
					local ph, sH, hasSearch = panelHeight()
					head.Size = U2(1, 0, 0, T.RowH)
					panel.Position, panel.Size = U2(0, 0, 0, T.RowH + 2), U2(1, 0, 0, ph)
					setPanel(T.List)
					sFrame.Visible = hasSearch
					sFrame.Position, sFrame.Size = U2(0, 4, 0, 4), U2(1, -8, 0, T.FieldH)
					scroller.Position, scroller.Size = U2(0, 3, 0, sH + 3), U2(1, -6, 1, -(sH + 6))
					scroller.ScrollBarThickness = math.min(T.Scroll.w, 10)
					scroller.ScrollBarImageColor3 = T.Scroll.color
					local h = isOpen and (T.RowH + 2 + ph) or T.RowH
					if anim then tween(root, { Size = U2(1, 0, 0, h) }, 0.15) else root.Size = U2(1, 0, 0, h) end
				end
				local function selectedList()
					local out = {}
					for _, v in ipairs(list) do if chosen[v] then out[#out + 1] = v end end
					return out
				end
				local function display()
					if multi then
						local names = {}
						for _, v in ipairs(list) do if chosen[v] then names[#names + 1] = tostring(v) end end
						val.Text = #names > 0 and table.concat(names, ", ") or "None"
					else
						val.Text = current ~= nil and tostring(current) or "Select..."
					end
				end

				redrawHead = stateful(head, function(st, anim)
					local rp, aw = T.RowPad, 18
					setHead(rowHover(st), anim)
					lbl.Position, lbl.Size = U2(0, rp, 0, 0), U2(0.45, -rp, 1, 0)
					field.Position, field.Size = U2(1, -rp, 0.5, 0), U2(0.55, -rp, 0, T.FieldH)
					setField(isOpen and T.Field.focus or T.Field.idle, anim)
					arrowBtn.Position = U2(1, T.ComboBtn and -2 or 0, 0, T.ComboBtn and 2 or 0)
					arrowBtn.Size = U2(0, aw, 1, T.ComboBtn and -4 or 0)
					setArrowBtn(T.ComboBtn and (st == "down" and T.Btn.down or T.Btn.idle) or nil, anim)
					paintArrow(T.Text, T.Cap.gt, 7)
					val.Position, val.Size = U2(0, T.FieldPad, 0, 0), U2(1, -(T.FieldPad + aw + 2), 1, 0)
					val.TextColor3 = T.Text
				end)

				setOpen = function(v)
					isOpen = v
					tween(arrow, { Rotation = v and 180 or 0 }, 0.15)
					relayout(true)
					redrawHead()
				end
				applyFilter = function()
					local q = string.lower(search.Text or "")
					local n = 0
					for _, ent in ipairs(entries) do
						local show = (#list <= 8) or q == "" or string.find(ent.lower, q, 1, true) ~= nil
						ent.btn.Visible = show
						if show then n = n + 1 end
					end
					visibleCount = n
					relayout(isOpen)
				end
				pick = function(v)
					if multi then
						chosen[v] = (not chosen[v]) or nil
						for _, ent in ipairs(entries) do if ent.value == v then ent.redraw() end end
						display()
						fire(callback, selectedList())
					else
						current = v
						display()
						for _, ent in ipairs(entries) do ent.redraw() end
						fire(callback, v)
						setOpen(false)
					end
				end

				local function build()
					for _, ent in ipairs(entries) do unbind(ent.fn) ent.btn:Destroy() end
					entries = {}
					for i, v in ipairs(list) do
						local ent = { value = v, lower = string.lower(tostring(v)) }
						local btn = new("TextButton", { Name = "Option", LayoutOrder = i }, scroller)
						local set = Box(btn)
						local l = mkText(btn, { Name = "Text", TextXAlignment = LEFT, Text = tostring(v), TextTruncate = E.TextTruncate.AtEnd }, false)
						local chk, paintChk
						if multi then chk, paintChk = makeCheck(btn, { Name = "Check", AnchorPoint = V2(0, 0.5) }) end
						ent.btn = btn
						ent.redraw, ent.fn = stateful(btn, function(st, anim)
							local isSel = (multi and chosen[v]) or ((not multi) and current == v)
							local s = (st ~= "idle" and T.Opt.hover) or (isSel and T.Opt.sel) or T.Opt.idle
							btn.Size = U2(1, 0, 0, T.OptH)
							set(s, anim)
							l.TextColor3 = s.text or T.Text
							local x = 8
							if multi then
								chk.Position = U2(0, 6, 0.5, 0)
								paintChk(isSel and true or false, st ~= "idle", anim)
								x = 6 + T.CheckSize + 6
							end
							l.Position, l.Size = U2(0, x, 0, 0), U2(1, -(x + 6), 1, 0)
						end)
						btn.Activated:Connect(function() pick(v) end)
						entries[i] = ent
					end
					display()
					applyFilter()
				end

				head.Activated:Connect(function() setOpen(not isOpen) end)
				search:GetPropertyChangedSignal("Text"):Connect(function() applyFilter() end)
				bind(function() relayout(false) end)
				build()

				function o:Refresh(newList)
					list = type(newList) == "table" and newList or {}
					local present = {}
					for _, v in ipairs(list) do present[v] = true end
					if current ~= nil and not present[current] then current = nil end
					for k in pairs(chosen) do if not present[k] then chosen[k] = nil end end
					search.Text = ""
					build()
				end
				function o:SetValue(v, silent)
					if multi then
						chosen = {}
						for _, x in ipairs(type(v) == "table" and v or { v }) do chosen[x] = true end
					else
						current = v
					end
					display()
					for _, ent in ipairs(entries) do ent.redraw() end
					if not silent then fire(callback, multi and selectedList() or current) end
				end
				function o:GetValue() if multi then return selectedList() end return current end
				remember(name, function() return o:GetValue() end, function(v) o:SetValue(v) end)
				return finish(o, root, tip)
			end

			function sec:NewDropdown(name, tip, list, callback) return makeDropdown(false, name, tip, list, callback) end
			function sec:NewMultiDropdown(name, tip, list, callback) return makeDropdown(true, name, tip, list, callback) end

			------------------------------------------------------------------
			-- Keybind   NewKeybind(name, tip, Enum.KeyCode, callback)
			------------------------------------------------------------------
			function sec:NewKeybind(name, tip, key, callback)
				name = tostring(name or "Keybind")
				if typeof(key) == "string" then
					local ok, k = pcall(function() return E.KeyCode[key] end)
					key = ok and k or nil
				end
				if typeof(key) ~= "EnumItem" then key = E.KeyCode.Unknown end
				local o = {}
				local kb = { key = key, cb = callback, listening = false }
				keybinds[#keybinds + 1] = kb

				local row = new("Frame", { Name = "Keybind", LayoutOrder = nextOrder() }, content)
				local setRow = Box(row)
				local lbl = mkText(row, { Name = "Text", Text = name, TextXAlignment = LEFT, TextTruncate = E.TextTruncate.AtEnd }, false, "text")
				local btn = new("TextButton", { Name = "Key", AnchorPoint = V2(1, 0.5) }, row)
				local setBtn = Box(btn)
				local kl = mkText(btn, { Name = "Text", Size = U2(1, 0, 1, 0), TextXAlignment = CENTER, TextTruncate = E.TextTruncate.AtEnd }, false)

				stateful(row, function(st, anim)
					local rp = T.RowPad
					row.Size = U2(1, 0, 0, T.RowH)
					setRow(rowHover(st), anim)
					lbl.Position, lbl.Size = U2(0, rp, 0, 0), U2(1, -(rp * 2 + 100), 1, 0)
				end)
				local redraw = stateful(btn, function(st, anim)
					local s = kb.listening and T.Btn.down or T.Btn[st]
					setBtn(s, anim)
					btn.Size = U2(0, 90, 0, T.FieldH)
					btn.Position = U2(1, -T.RowPad, 0.5, 0)
					kl.Text = kb.listening and "..." or (kb.key == E.KeyCode.Unknown and "None" or kb.key.Name)
					kl.TextColor3 = s.text or T.Text
					local off = (T.PressShift and s == T.Btn.down) and 1 or 0
					kl.Position = U2(0, off, 0, off)
				end)
				btn.Activated:Connect(function()
					if kb.listening then return end
					kb.listening = true
					redraw()
					local c
					c = keep(UserInputService.InputBegan:Connect(function(input)
						if input.UserInputType ~= KEYBOARD then return end
						c:Disconnect()
						if input.KeyCode == E.KeyCode.Backspace then kb.key = E.KeyCode.Unknown
						elseif input.KeyCode ~= E.KeyCode.Escape then kb.key = input.KeyCode end
						task.defer(function() kb.listening = false redraw() end)
					end))
				end)
				function o:SetKey(k) if typeof(k) == "EnumItem" then kb.key = k redraw() end end
				function o:GetKey() return kb.key end
				finish(o, row, tip)
				function o:Destroy()
					for i, k in ipairs(keybinds) do if k == kb then table.remove(keybinds, i) break end end
					row:Destroy()
				end
				remember(name, function() return kb.key.Name end, function(v) o:SetKey(E.KeyCode[v] or kb.key) end)
				return o
			end

			------------------------------------------------------------------
			-- ColorPicker   NewColorPicker(name, tip, Color3, callback(color))
			------------------------------------------------------------------
			function sec:NewColorPicker(name, tip, default, callback)
				name = tostring(name or "Color Picker")
				local o = {}
				local color = typeof(default) == "Color3" and default or WHITE
				local h, s, v = color:ToHSV()
				local rainbow, isOpen, rbConn = false, false, nil
				local PH = 124

				local root = new("Frame", { Name = "ColorPicker", LayoutOrder = nextOrder(), ClipsDescendants = true }, content)
				local head = new("TextButton", { Name = "Head" }, root)
				local setHead = Box(head)
				local lbl = mkText(head, { Name = "Text", Text = name, TextXAlignment = LEFT, TextTruncate = E.TextTruncate.AtEnd }, false, "text")
				local swatch = new("Frame", { Name = "Swatch", AnchorPoint = V2(1, 0.5) }, head)
				local setSwatch = Box(swatch)
				local panel = new("Frame", { Name = "Panel" }, root)
				local setPanel = Box(panel)

				local sv = new("TextButton", { Name = "SV", BackgroundTransparency = 0, ClipsDescendants = true }, panel)
				local svW = new("Frame", { Name = "W", BackgroundTransparency = 0, BackgroundColor3 = WHITE, Size = U2(1, 0, 1, 0) }, sv)
				new("UIGradient", { Transparency = NumberSequence.new(0, 1) }, svW)
				local svB = new("Frame", { Name = "B", BackgroundTransparency = 0, BackgroundColor3 = BLACK, Size = U2(1, 0, 1, 0) }, sv)
				new("UIGradient", { Transparency = NumberSequence.new(1, 0), Rotation = 90 }, svB)
				local svCur = new("Frame", { Name = "Cursor", AnchorPoint = V2(0.5, 0.5), Size = U2(0, 10, 0, 10) }, sv)
				new("UICorner", { CornerRadius = U1(1, 0) }, svCur)
				new("UIStroke", { Thickness = 2, Color = WHITE }, svCur)

				local hueB = new("TextButton", { Name = "Hue", BackgroundTransparency = 0, BackgroundColor3 = WHITE, AnchorPoint = V2(1, 0) }, panel)
				local kp = {}
				for i = 0, 6 do kp[#kp + 1] = ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6, 1, 1)) end
				new("UIGradient", { Color = ColorSequence.new(kp), Rotation = 90 }, hueB)
				local hueCur = new("Frame", { Name = "Cursor", AnchorPoint = V2(0.5, 0.5), Size = U2(1, 4, 0, 5) }, hueB)
				new("UIStroke", { Thickness = 2, Color = WHITE }, hueCur)

				local hexLbl = mkText(panel, { Name = "HexLabel", Text = "Hex", TextXAlignment = LEFT }, false, "dim")
				local hexField, hexTB = newField(panel, { Name = "Hex" })
				local rbBtn = new("TextButton", { Name = "Rainbow" }, panel)
				local setRb = Box(rbBtn)
				local rbLbl = mkText(rbBtn, { Name = "Text", Size = U2(1, 0, 1, 0), TextXAlignment = CENTER, Text = "Rainbow: Off" }, false)

				local function paintSwatch()
					local base = T.Field.idle
					setSwatch({ fill = color, bevel = base.bevel, stroke = base.stroke, radius = base.radius, thick = base.thick }, false)
				end
				local function apply(silent, fromHex)
					color = Color3.fromHSV(h, s, v)
					sv.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
					svCur.Position = U2(s, 0, 1 - v, 0)
					hueCur.Position = U2(0.5, 0, h, 0)
					paintSwatch()
					if not fromHex then
						hexTB.Text = string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
					end
					if not silent then fire(callback, color) end
				end

				local function relayout(anim)
					local rp = T.RowPad
					head.Size = U2(1, 0, 0, T.RowH)
					lbl.Position, lbl.Size = U2(0, rp, 0, 0), U2(1, -(rp * 2 + 52), 1, 0)
					swatch.Position, swatch.Size = U2(1, -rp, 0.5, 0), U2(0, 44, 0, T.FieldH - 2)
					panel.Position, panel.Size = U2(0, 0, 0, T.RowH + 2), U2(1, 0, 0, PH)
					setPanel(T.List)
					sv.Position, sv.Size = U2(0, 8, 0, 8), U2(1, -158, 0, PH - 16)
					hueB.Position, hueB.Size = U2(1, -126, 0, 8), U2(0, 16, 0, PH - 16)
					hexLbl.Position, hexLbl.Size = U2(1, -118, 0, 8), U2(0, 110, 0, T.Size + 4)
					hexField.Position, hexField.Size = U2(1, -118, 0, 10 + T.Size + 4), U2(0, 110, 0, T.FieldH)
					rbBtn.Position, rbBtn.Size = U2(1, -118, 0, 10 + T.Size + 4 + T.FieldH + 8), U2(0, 110, 0, T.FieldH)
					local hgt = isOpen and (T.RowH + 2 + PH) or T.RowH
					if anim then tween(root, { Size = U2(1, 0, 0, hgt) }, 0.15) else root.Size = U2(1, 0, 0, hgt) end
					paintSwatch()
				end

				local redrawHead = stateful(head, function(st, anim) setHead(rowHover(st), anim) end)
				local rbRedraw = stateful(rbBtn, function(st, anim)
					local sp = rainbow and T.Btn.down or T.Btn[st]
					setRb(sp, anim)
					rbLbl.Text = rainbow and "Rainbow: On" or "Rainbow: Off"
					rbLbl.TextColor3 = sp.text or T.Text
				end)
				local function setRainbow(on)
					rainbow = on and true or false
					if rbConn then rbConn:Disconnect() rbConn = nil end
					if rainbow then
						s, v = 1, 1
						rbConn = keep(RunService.Heartbeat:Connect(function(dt)
							h = (h + dt * 0.25) % 1
							apply()
						end))
					end
					rbRedraw()
				end

				head.Activated:Connect(function()
					isOpen = not isOpen
					relayout(true)
					redrawHead()
				end)
				rbBtn.Activated:Connect(function() setRainbow(not rainbow) end)
				sv.InputBegan:Connect(function(input)
					if not isPress(input) then return end
					setRainbow(false)
					local function upd(i)
						local p = pointer(i)
						s = math.clamp((p.X - sv.AbsolutePosition.X) / math.max(sv.AbsoluteSize.X, 1), 0, 1)
						v = 1 - math.clamp((p.Y - sv.AbsolutePosition.Y) / math.max(sv.AbsoluteSize.Y, 1), 0, 1)
						apply()
					end
					upd(input)
					beginDrag(upd)
				end)
				hueB.InputBegan:Connect(function(input)
					if not isPress(input) then return end
					setRainbow(false)
					local function upd(i)
						h = math.clamp((pointer(i).Y - hueB.AbsolutePosition.Y) / math.max(hueB.AbsoluteSize.Y, 1), 0, 1)
						apply()
					end
					upd(input)
					beginDrag(upd)
				end)
				hexTB.FocusLost:Connect(function()
					local t = hexTB.Text:gsub("#", "")
					if #t == 6 and t:match("^%x+$") then
						setRainbow(false)
						h, s, v = Color3.fromRGB(tonumber(t:sub(1, 2), 16), tonumber(t:sub(3, 4), 16), tonumber(t:sub(5, 6), 16)):ToHSV()
						apply()
					else
						apply(true)
					end
				end)

				bind(function() relayout(false) end)
				apply(true)

				function o:SetColor(c, silent)
					if typeof(c) ~= "Color3" then return end
					setRainbow(false)
					h, s, v = c:ToHSV()
					apply(silent)
				end
				function o:GetColor() return color end
				function o:SetRainbow(on) setRainbow(on) end
				remember(name, function() return { color.R, color.G, color.B } end, function(t)
					if type(t) == "table" then o:SetColor(Color3.new(t[1] or 1, t[2] or 1, t[3] or 1)) end
				end)
				return finish(o, root, tip)
			end

			return sec
		end -- NewSection

		return tab
	end -- NewTab

	----------------------------------------------------------------------------
	-- notifications (toasts)
	----------------------------------------------------------------------------
	local toasts = new("Frame", { Name = "Toasts", AnchorPoint = V2(1, 1), Position = U2(1, -16, 1, -16), Size = U2(0, 300, 1, -32), ZIndex = 50 }, gui)
	new("UIListLayout", {
		SortOrder = E.SortOrder.LayoutOrder, Padding = U1(0, 8),
		VerticalAlignment = E.VerticalAlignment.Bottom, HorizontalAlignment = E.HorizontalAlignment.Right,
	}, toasts)
	local toastN = 0

	function Win:Notify(heading, text, duration)
		if not alive then return end
		toastN = toastN + 1
		local S = T.Toast
		local t = new("CanvasGroup", {
			Name = "Toast", LayoutOrder = toastN, Size = U2(1, 0, 0, 0),
			AutomaticSize = E.AutomaticSize.Y, GroupTransparency = 1,
		}, toasts)
		Box(t)(S)
		new("UIPadding", { PaddingLeft = U1(0, 12), PaddingRight = U1(0, 12), PaddingTop = U1(0, 10), PaddingBottom = U1(0, 10) }, t)
		new("UIListLayout", { SortOrder = E.SortOrder.LayoutOrder, Padding = U1(0, 3) }, t)
		local function line(order, str, font)
			new("TextLabel", {
				Name = "Line" .. order, LayoutOrder = order, Size = U2(1, 0, 0, 0), AutomaticSize = E.AutomaticSize.Y,
				TextWrapped = true, TextXAlignment = LEFT, TextYAlignment = E.TextYAlignment.Top, RichText = true,
				Font = font, TextSize = T.Size, TextColor3 = S.text or T.Text, Text = tostring(str),
			}, t)
		end
		line(1, heading or "Notification", T.FontB)
		if text ~= nil and text ~= "" then line(2, text, T.Font) end
		tween(t, { GroupTransparency = 0 }, 0.2)
		task.delay(tonumber(duration) or 4, function()
			if t.Parent then
				tween(t, { GroupTransparency = 1 }, 0.25)
				task.delay(0.3, function() t:Destroy() end)
			end
		end)
		return t
	end

	----------------------------------------------------------------------------
	-- window API
	----------------------------------------------------------------------------
	function Win:Toggle() gui.Enabled = not gui.Enabled end
	function Win:SetVisible(v) gui.Enabled = v and true or false end
	function Win:SetToggleKey(k) Win.ToggleKey = k end
	function Win:SetStatus(text) statusText = tostring(text or "") statusLbl.Text = statusText end
	function Win:SetTitle(text) TitleLbl.Text = tostring(text) end
	function Win:Minimize(v) setMin(v ~= false) end
	function Win:Maximize(v) setMax(v ~= false) end
	function Win:SelectTab(name)
		for _, t in ipairs(tabs) do if t.name == name then t.select() return end end
	end

	function Win:SetTheme(sel)
		P = resolveTheme(sel)
		rebuild()
		applyAll()
	end
	function Win:GetTheme() return T.Name end
	function Win:ChangeColor(prop, color)
		if typeof(color) ~= "Color3" then return end
		if prop == "Background" or prop == "SchemeColor" or prop == "Header" or prop == "TextColor" or prop == "ElementColor" then
			P[prop] = color
			rebuild()
			applyAll()
		end
	end

	function Win:Destroy()
		if not alive then return end
		alive = false
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		conns = {}
		for i, w in ipairs(Library.Windows) do
			if w == Win then table.remove(Library.Windows, i) break end
		end
		if Library.Current == Win then Library.Current = Library.Windows[#Library.Windows] end
		pcall(function() gui:Destroy() end)
	end

	-- config (works with any executor that has writefile / readfile) ----------
	local function cfgPath(name)
		name = tostring(name or title):gsub("[^%w_%-]", "_")
		if makefolder and isfolder then
			if not isfolder("KavoWin") then pcall(makefolder, "KavoWin") end
			return "KavoWin/" .. name .. ".json"
		end
		return "KavoWin_" .. name .. ".json"
	end
	function Win:GetConfig()
		local out = {}
		for key, s in pairs(settings) do
			local ok, v = pcall(s.get)
			if ok and v ~= nil then out[key] = v end
		end
		return out
	end
	function Win:SetConfig(cfg)
		if type(cfg) ~= "table" then return end
		for key, v in pairs(cfg) do
			local s = settings[key]
			if s then
				local ok, err = pcall(s.set, v)
				if not ok then warn("[KavoWin] config '" .. key .. "': " .. tostring(err)) end
			end
		end
	end
	function Win:SaveConfig(name)
		if not writefile then warn("[KavoWin] writefile is not available in this environment") return false end
		local ok, err = pcall(function() writefile(cfgPath(name), HttpService:JSONEncode(Win:GetConfig())) end)
		if not ok then warn("[KavoWin] could not save config: " .. tostring(err)) end
		return ok
	end
	function Win:LoadConfig(name)
		if not (readfile and isfile) then warn("[KavoWin] readfile is not available in this environment") return false end
		local path = cfgPath(name)
		if not isfile(path) then return false end
		local ok, data = pcall(function() return HttpService:JSONDecode(readfile(path)) end)
		if not ok then warn("[KavoWin] could not read config: " .. tostring(data)) return false end
		Win:SetConfig(data)
		return true
	end

	Library.Windows[#Library.Windows + 1] = Win
	Library.Current = Win
	return Win
end

--------------------------------------------------------------------------------
-- Kavo compatible library level helpers (act on the most recent window)
--------------------------------------------------------------------------------
function Library:ToggleUI() if Library.Current then Library.Current:Toggle() end end
function Library:ChangeColor(prop, color) if Library.Current then Library.Current:ChangeColor(prop, color) end end
function Library:SetTheme(sel) if Library.Current then Library.Current:SetTheme(sel) end end
function Library:Notify(a, b, c) if Library.Current then return Library.Current:Notify(a, b, c) end end
function Library:Destroy() for i = #Library.Windows, 1, -1 do Library.Windows[i]:Destroy() end end

return Library
