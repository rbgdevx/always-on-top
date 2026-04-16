-------------------------------------------------
-- Always On Top — Options
--
-- Two UI surfaces driven by the same control factory:
--   1. A standalone floating window (300×450) — opened via /aot or /alwaysontop
--   2. A mirrored canvas panel registered with Blizzard's Settings UI
--
-- Both read from and write to AlwaysOnTopDB. When one instance mutates a
-- setting, addon.RefreshUI() repaints visible scoreboard state and
-- addon.NotifyConfigChanged() re-syncs the other instance's widgets.
-------------------------------------------------

local addonName, addon = ...

-------------------------------------------------
-- Reload prompt — used for settings whose visual effect can't be applied
-- live mid-match (e.g. RESPECT_SORT flip requires Blizzard to re-populate the
-- data provider, which only reliably happens after a reload).
-------------------------------------------------
StaticPopupDialogs["ALWAYSONTOP_RELOAD_REQUIRED"] = {
  text = "A setting changed that needs a UI reload to take effect. Reload now?",
  button1 = YES,
  button2 = NO,
  OnAccept = function()
    ReloadUI()
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3, -- avoids taint from ADDON_ACTION_BLOCKED
}

-- Settings that can't be applied live while a scoreboard is showing.
-- On commit, if the scoreboard is active, prompt the user to reload.
local RELOAD_REQUIRED_KEYS = {
  RESPECT_SORT = true,
}

-------------------------------------------------
-- Enum options for dropdowns
-------------------------------------------------
local RANK_POSITION_OPTIONS = {
  { value = "inline", label = "Inline (next to column values)" },
  { value = "below", label = "Below (under table, self only)" },
}

local RANK_LOCATION_OPTIONS = {
  { value = "suffix", label = "Suffix — 123K (1st)" },
  { value = "prefix", label = "Prefix — (1st) 123K" },
}

local RANK_TYPE_OPTIONS = {
  { value = "self", label = "Self only" },
  { value = "everyone", label = "Everyone" },
}

local DEFAULT_SORT_OPTIONS = {
  { value = "name", label = "Name" },
  { value = "kills", label = "Killing Blows" },
  { value = "hk", label = "Honor Kills" },
  { value = "deaths", label = "Deaths" },
  { value = "damage", label = "Damage Done" },
  { value = "healing", label = "Healing Done" },
  { value = "none", label = "None" },
}

-------------------------------------------------
-- Refresh broadcast — each BuildControls call registers a refresh fn here.
-- When any setting changes, every registered fn runs so all UI surfaces
-- (standalone + Blizzard panel) reflect the new state.
-------------------------------------------------
local refreshCallbacks = {}

function addon.NotifyConfigChanged()
  for i = 1, #refreshCallbacks do
    refreshCallbacks[i]()
  end
end

-------------------------------------------------
-- Control factory — called once per parent frame. Returns a refresh fn
-- that re-reads AlwaysOnTopDB into this instance's widgets.
-------------------------------------------------
local function BuildControls(parent)
  -- Content area with inset from the parent edges. Standalone frame has
  -- a titlebar occupying ~50px at the top; Blizzard canvas doesn't need
  -- that room but the small extra padding is harmless there.
  local content = CreateFrame("Frame", nil, parent)
  content:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, -50)
  content:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -20, 20)

  local widgets = {}
  local y = 0 -- cursor; grows negative downward

  ----------------------------------------------------------------------
  -- Commit: write to DB, re-sync addon upvalues, repaint scoreboard,
  -- and refresh every UI instance.
  ----------------------------------------------------------------------
  local function commit(key, value)
    AlwaysOnTopDB[key] = value
    addon.RefreshConfig()
    addon.RefreshUI()
    addon.NotifyConfigChanged()
    -- If this key can't be applied live and the scoreboard is open, prompt
    -- for a reload. Out-of-match changes don't need the popup — the new
    -- value will already be in effect for the next scoreboard the user opens.
    if RELOAD_REQUIRED_KEYS[key] and addon.IsScoreboardActive and addon.IsScoreboardActive() then
      StaticPopup_Show("ALWAYSONTOP_RELOAD_REQUIRED")
    end
  end

  ----------------------------------------------------------------------
  -- Checkbox helper
  ----------------------------------------------------------------------
  local function addCheckbox(labelText, key)
    local cb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
    -- UICheckButtonTemplate FontString is exposed via parentKey="Text" (capital T).
    -- Swap in GameFontNormal so the label matches the dropdown labels.
    cb.Text:SetFontObject("GameFontNormal")
    cb.Text:SetText(labelText)
    cb.Text:ClearAllPoints()
    cb.Text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    cb:SetScript("OnClick", function(self)
      commit(key, self:GetChecked() and true or false)
    end)
    y = y - 32
    return cb
  end

  ----------------------------------------------------------------------
  -- Dropdown helper — label above, dropdown below. Uses the modern
  -- WowStyle1DropdownTemplate (retail 11.x+). Selection text is
  -- auto-derived from the IsSelected callback, so no manual SetText or
  -- SetSelectedValue dance. Generator runs once via SetupMenu; external
  -- DB changes are propagated by calling :GenerateMenu() in refresh.
  ----------------------------------------------------------------------
  local function addDropdown(labelText, key, options)
    local lbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", content, "TOPLEFT", 4, y)
    lbl:SetText(labelText)
    y = y - 18

    local dd = CreateFrame("DropdownButton", nil, content, "WowStyle1DropdownTemplate")
    dd:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
    dd:SetWidth(240)
    dd:SetupMenu(function(dropdown, rootDescription)
      local function IsSelected(value)
        return AlwaysOnTopDB[key] == value
      end
      local function SetSelected(value)
        commit(key, value)
      end
      for _, opt in ipairs(options) do
        rootDescription:CreateRadio(opt.label, IsSelected, SetSelected, opt.value)
      end
    end)
    y = y - 34
    return dd
  end

  ----------------------------------------------------------------------
  -- Stack widgets
  ----------------------------------------------------------------------
  widgets.RESPECT_SORT = addCheckbox("Respect sort (don't pin to top)", "RESPECT_SORT")
  widgets.RANK_ENABLED = addCheckbox("Show rankings (1st, 2nd, 3rd)", "RANK_ENABLED")

  y = y - 10

  widgets.RANK_POSITION = addDropdown("Rank position", "RANK_POSITION", RANK_POSITION_OPTIONS)
  widgets.RANK_LOCATION = addDropdown("Rank location (inline only)", "RANK_LOCATION", RANK_LOCATION_OPTIONS)
  widgets.RANK_TYPE = addDropdown("Rank type (inline only)", "RANK_TYPE", RANK_TYPE_OPTIONS)

  y = y - 5

  widgets.SHOW_SORT_ARROW = addCheckbox("Show sort direction arrows", "SHOW_SORT_ARROW")

  y = y - 6

  widgets.DEFAULT_SORT = addDropdown("Default sort", "DEFAULT_SORT", DEFAULT_SORT_OPTIONS)

  ----------------------------------------------------------------------
  -- Reset button — writes every default back to AlwaysOnTopDB, then
  -- broadcasts a single refresh so both UI surfaces re-read the values.
  ----------------------------------------------------------------------
  y = y - 10
  local resetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  resetBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
  resetBtn:SetSize(200, 30)
  resetBtn:SetText("Reset settings")
  -- UIPanelButtonTemplate already uses GameFontNormal, so this matches the
  -- dropdown labels without any font override.
  resetBtn:SetScript("OnClick", function()
    for k, v in pairs(addon.defaults) do
      AlwaysOnTopDB[k] = v
    end
    addon.RefreshConfig()
    addon.RefreshUI()
    addon.NotifyConfigChanged()
  end)

  ----------------------------------------------------------------------
  -- Refresh — called on init and after every commit (broadcast).
  -- Dropdowns re-derive their selection text from IsSelected when
  -- GenerateMenu fires, so external DB changes propagate automatically.
  ----------------------------------------------------------------------
  local function refresh()
    local db = AlwaysOnTopDB
    widgets.RESPECT_SORT:SetChecked(db.RESPECT_SORT)
    widgets.RANK_ENABLED:SetChecked(db.RANK_ENABLED)
    widgets.SHOW_SORT_ARROW:SetChecked(db.SHOW_SORT_ARROW)

    widgets.RANK_POSITION:GenerateMenu()
    widgets.RANK_LOCATION:GenerateMenu()
    widgets.RANK_TYPE:GenerateMenu()
    widgets.DEFAULT_SORT:GenerateMenu()

    -- RANK_LOCATION and RANK_TYPE are inline-only; grey them out when
    -- position is "below" so the UI reflects what's actually in effect.
    local inlineMode = db.RANK_POSITION == "inline"
    widgets.RANK_LOCATION:SetEnabled(inlineMode)
    widgets.RANK_TYPE:SetEnabled(inlineMode)
  end

  refreshCallbacks[#refreshCallbacks + 1] = refresh
  return refresh
end

-------------------------------------------------
-- Standalone floating window (300×450)
-------------------------------------------------
local standaloneFrame

local function CreateStandaloneFrame()
  local frame = CreateFrame("Frame", "AlwaysOnTopOptionsFrame", UIParent, "BackdropTemplate")
  frame:SetSize(300, 450)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
  frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:Hide()

  -- Title
  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  title:SetPoint("TOP", 0, -16)
  title:SetText(addonName)

  -- Close X
  local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  closeBtn:SetPoint("TOPRIGHT", -5, -5)

  -- Esc closes the window
  tinsert(UISpecialFrames, "AlwaysOnTopOptionsFrame")

  return frame
end

-------------------------------------------------
-- Blizzard Settings canvas category — mirrored controls
-------------------------------------------------
local blizzardCategory

local function CreateBlizzardCanvas()
  -- No parent — Blizzard reparents the frame to the Settings canvas when
  -- the category is selected (see Blizzard_SettingsPanel.lua ~line 898).
  local frame = CreateFrame("Frame")

  -- Title header — Blizzard's canvas layout doesn't render a title at the
  -- top of the panel, so we add one ourselves to match what AceConfig-based
  -- addons display. BuildControls reserves 50px of top padding via its
  -- TOPLEFT 20,-50 anchor, so this fits above the first widget.
  -- Anchor pattern mirrors AceGUI's BlizOptionsGroup widget so the header
  -- sits in the same place users expect from AceConfig-based addons.
  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 10, -15)
  title:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 10, -45)
  title:SetJustifyH("LEFT")
  title:SetJustifyV("TOP")
  title:SetText(addonName)

  BuildControls(frame)

  local category = Settings.RegisterCanvasLayoutCategory(frame, addonName)
  Settings.RegisterAddOnCategory(category)
  return category
end

-------------------------------------------------
-- Public: toggle the standalone window
-------------------------------------------------
function addon.ShowOptions()
  if not standaloneFrame then
    return
  end
  if standaloneFrame:IsShown() then
    standaloneFrame:Hide()
  else
    -- Re-sync widgets in case the Blizzard panel changed anything since
    -- this window was last open.
    addon.NotifyConfigChanged()
    -- Reset position to screen center every open — dragging during a
    -- session is allowed, but we don't persist the user's drag position
    -- across open/close cycles.
    standaloneFrame:ClearAllPoints()
    standaloneFrame:SetPoint("CENTER")
    standaloneFrame:Show()
  end
end

-------------------------------------------------
-- Init — called from AlwaysOnTop.lua's ADDON_LOADED after AlwaysOnTopDB
-- has been populated with defaults.
-------------------------------------------------
function addon.InitOptions()
  standaloneFrame = CreateStandaloneFrame()
  BuildControls(standaloneFrame)

  blizzardCategory = CreateBlizzardCanvas()

  -- Populate widgets from the saved DB (both surfaces).
  addon.NotifyConfigChanged()

  -- Slash commands
  SLASH_ALWAYSONTOP1 = "/aot"
  SLASH_ALWAYSONTOP2 = "/alwaysontop"
  SlashCmdList["ALWAYSONTOP"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$") or ""
    if msg == "blizzard" or msg == "blizz" then
      -- Escape hatch: open via Blizzard's Settings UI instead.
      Settings.OpenToCategory(blizzardCategory:GetID())
    else
      addon.ShowOptions()
    end
  end
end
