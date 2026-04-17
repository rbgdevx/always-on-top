-------------------------------------------------
-- Always On Top
-- Pins local player to top of PvP scoreboard
-- and shows ordinal rankings on stat columns
-------------------------------------------------

local addonName, addon = ...

-------------------------------------------------
-- Settings
--
-- Live values are sourced from AlwaysOnTopDB (saved variable), populated on
-- ADDON_LOADED from addon.defaults. The Options window mutates the DB and
-- calls addon.RefreshConfig() to re-sync the locals below — closures that
-- captured them as upvalues see the new values via Lua's upvalue-by-ref.
--
-- DEFAULT_SORT = the final sort state we land on after computing ranks.
-- Valid values: "name", "kills", "hk", "deaths", "damage", "healing",
--               "stat1"..."statN" (game-mode dependent), or "none".
-- "none" = compute ranks but do NOT apply a final SortBattlefieldScoreData
--          call; leave whatever sort the user (or Blizzard) had in place.
-- Direction is not configurable: numbers land high→low, "name" lands A→Z.
-------------------------------------------------
addon.defaults = {
  RESPECT_SORT = false, -- true = do NOT pin local player to top
  RANK_ENABLED = true, -- show ordinal rankings
  RANK_POSITION = "below", -- "inline" = inline next to values, "below" = row below table (self only)
  RANK_LOCATION = "suffix", -- "suffix" or "prefix" (inline mode only)
  RANK_TYPE = "self", -- "self" or "everyone" (inline mode only)
  SHOW_SORT_ARROW = true, -- show sort direction arrow on column headers
  DEFAULT_SORT = "none", -- see header comment for valid values
}

local RESPECT_SORT
local RANK_ENABLED
local RANK_POSITION
local RANK_LOCATION
local RANK_TYPE
local SHOW_SORT_ARROW
local DEFAULT_SORT

-------------------------------------------------
-- Constants
-------------------------------------------------
local RANKABLE_STRING_KEYS = {
  killingBlows = true,
  honorableKills = true,
  deaths = true,
  damageDone = true,
  healingDone = true,
}

local ORDINAL_EXTRA_WIDTH = 30
local ARROW_EXTRA_WIDTH = 14

-------------------------------------------------
-- State
-------------------------------------------------
local ranksByGuid = {}
local ranksComputed = false
local computingRanks = false
local lastScoreCount = 0
local currentSortType = nil
local currentSortDescending = true
local trackedTableBuilders = {}

-------------------------------------------------
-- Helpers
-------------------------------------------------
local function IsMatchStateValid()
  return C_PvP.GetActiveMatchState() >= Enum.PvPMatchState.PostRound
end

-- Reads a raw numeric value off a scoreInfo table for the given dataKey.
-- dataKey is a string for main stats (e.g. "damageDone", "killingBlows") or a
-- number (pvpStatID) for solo-shuffle / BG-blitz stat columns. Returns 0 for
-- missing fields so callers can treat missing == zero uniformly.
local function GetStatValue(scoreInfo, dataKey)
  if not scoreInfo then
    return 0
  end
  if type(dataKey) == "number" then
    local stats = scoreInfo.stats
    if stats then
      for i = 1, #stats do
        local stat = stats[i]
        if stat.pvpStatID == dataKey then
          return stat.pvpStatValue or 0
        end
      end
    end
    return 0
  end
  return scoreInfo[dataKey] or 0
end

local function GetOrdinal(n)
  local mod100 = n % 100
  if mod100 >= 11 and mod100 <= 13 then
    return n .. "th"
  end
  local mod10 = n % 10
  if mod10 == 1 then
    return n .. "st"
  elseif mod10 == 2 then
    return n .. "nd"
  elseif mod10 == 3 then
    return n .. "rd"
  else
    return n .. "th"
  end
end

local ORDINAL_GAP = 4

local function ApplyOrdinal(cell, rank)
  if not rank then
    return
  end

  local fontString = cell.text
  if not fontString then
    return
  end

  -- Skip cells that haven't rendered text yet. Don't use GetText() here:
  -- retail 11.x+ hardens certain PvP scoreboard FontStrings so that reads
  -- from addon context return a "secret string" tainted value that fails
  -- string comparison (`==` raises "attempt to compare ... (a secret string
  -- value tainted by ...)"). GetStringWidth is a plain numeric query and is
  -- not subject to that taint.
  if fontString:GetStringWidth() == 0 then
    return
  end

  -- Create or reuse a floating ordinal FontString (outside text flow)
  if not cell._aotOrdinal then
    local ordFS = cell:CreateFontString(nil, "OVERLAY")
    local font, size, flags = fontString:GetFont()
    ordFS:SetFont(font, size, flags or "")
    ordFS:SetTextColor(1, 1, 1)
    cell._aotOrdinal = ordFS
  end

  local ordFS = cell._aotOrdinal
  ordFS:SetText("(" .. GetOrdinal(rank) .. ")")

  -- Anchor relative to the rendered text, not the cell edge
  -- Center-justified text: right edge is at center + half text width
  local halfText = fontString:GetStringWidth() / 2
  ordFS:ClearAllPoints()
  if RANK_LOCATION == "suffix" then
    ordFS:SetPoint("LEFT", fontString, "CENTER", halfText + ORDINAL_GAP, 0)
  else
    ordFS:SetPoint("RIGHT", fontString, "CENTER", -(halfText + ORDINAL_GAP), 0)
  end

  ordFS:Show()
end

-------------------------------------------------
-- Sort Direction Arrows
-------------------------------------------------
local function EnsureArrowTexture(header)
  if not header._aotArrow then
    local arrow = header:CreateTexture(nil, "OVERLAY")
    arrow:SetAtlas("common-icon-forwardarrow")
    arrow:SetSize(14, 14)
    if header.text then
      local justify = header.text:GetJustifyH()
      if justify == "LEFT" then
        arrow:SetPoint("LEFT", header.text, "LEFT", header.text:GetStringWidth() + 3, -2)
      elseif justify == "RIGHT" then
        arrow:SetPoint("LEFT", header.text, "RIGHT", 3, -2)
      else
        local halfText = header.text:GetStringWidth() / 2
        arrow:SetPoint("LEFT", header.text, "CENTER", halfText + 3, -2)
      end
    elseif header.icon then
      arrow:SetPoint("LEFT", header.icon, "RIGHT", 0, 0)
    else
      arrow:SetPoint("RIGHT", header, "RIGHT", -2, -2)
    end
    header._aotArrow = arrow
  end
  return header._aotArrow
end

local function UpdateSortArrows()
  -- Walk every tracked header. Show the arrow only when the flag is on AND
  -- this header is the active sort. Otherwise hide any existing arrow so
  -- toggling SHOW_SORT_ARROW off at runtime clears state instead of leaving
  -- stale arrows visible.
  for tableBuilder in pairs(trackedTableBuilders) do
    if tableBuilder.columns then
      for _, column in ipairs(tableBuilder.columns) do
        local header = column:GetHeaderFrame()
        if header and header.sortType then
          if SHOW_SORT_ARROW and header.sortType == currentSortType then
            local arrow = EnsureArrowTexture(header)
            if currentSortDescending then
              arrow:SetRotation(-math.pi / 2) -- point down
            else
              arrow:SetRotation(math.pi / 2) -- point up
            end
            arrow:Show()
          elseif header._aotArrow then
            header._aotArrow:Hide()
          end
        end
      end
    end
  end
end

hooksecurefunc("SortBattlefieldScoreData", function(sortType)
  if currentSortType == sortType then
    currentSortDescending = not currentSortDescending
  else
    currentSortType = sortType
    currentSortDescending = true
  end
  UpdateSortArrows()
end)

-------------------------------------------------
-- Rank Computation (Lua-side sort; one Blizzard sort call at the end to land visuals)
-------------------------------------------------
-- Returns the player's IN-MATCH faction (0 = Horde, 1 = Alliance) or nil if
-- not yet known. Reads from score data so it handles mercenary / cross-faction
-- correctly (the racial UnitFactionGroup would be wrong for mercenaries).
local function GetPlayerMatchFaction()
  local playerGuid = UnitGUID("player")
  if not playerGuid then
    return nil
  end
  for i = 1, GetNumBattlefieldScores() do
    local info = C_PvP.GetScoreInfo(i)
    if info and info.guid == playerGuid then
      return info.faction
    end
  end
  return nil
end

-- factionEnum from SetBattlefieldScoreFaction:
--   -1 = "All" tab, 0 = Horde, 1 = Alliance
-- Returns true if this tab is something the player cares about:
-- "All" always counts; faction tab counts only if it matches player's in-match
-- faction (not racial, to handle mercenary mode).
local function IsTabRelevant(factionEnum)
  if factionEnum == -1 then
    return true
  end
  local playerFaction = GetPlayerMatchFaction()
  if playerFaction == nil then
    return true -- can't tell, err on the side of computing
  end
  return factionEnum == playerFaction
end

local function ComputeRanks()
  if computingRanks then
    return
  end
  computingRanks = true

  ranksByGuid = {}
  ranksComputed = false

  if not RANK_ENABLED then
    computingRanks = false
    return
  end
  if not IsMatchStateValid() then
    computingRanks = false
    return
  end

  local numScores = GetNumBattlefieldScores()
  if numScores == 0 then
    computingRanks = false
    return
  end

  -- Collect (dataKey, rankKey) pairs from tracked columns.
  -- column.args[1] is set by ConstructCells and holds the dataProviderKey
  -- (string for main stats, number pvpStatID for pvp stat columns).
  -- We no longer need sortType here since we sort in Lua rather than calling
  -- SortBattlefieldScoreData per column.
  local pairs_list = {}
  for tableBuilder in pairs(trackedTableBuilders) do
    if tableBuilder.columns then
      for _, column in ipairs(tableBuilder.columns) do
        local header = column:GetHeaderFrame()
        if header and header.sortType and column.args and column.args[1] then
          local dataKey = column.args[1]
          local rankKey = nil
          if RANKABLE_STRING_KEYS[dataKey] then
            rankKey = dataKey
          elseif type(dataKey) == "number" then
            rankKey = "stat_" .. dataKey
          end
          if rankKey then
            pairs_list[#pairs_list + 1] = { dataKey = dataKey, rankKey = rankKey }
          end
        end
      end
    end
  end

  -- Snapshot every scoreInfo row once. We sort in Lua (not via the C sort)
  -- so we don't touch the scoreboard's visual state during rank compute, and
  -- our ranks don't depend on Blizzard's inscrutable toggle/direction
  -- semantics for SortBattlefieldScoreData under rapid successive calls.
  local scores = {}
  for i = 1, numScores do
    local info = C_PvP.GetScoreInfo(i)
    if info and info.guid then
      scores[#scores + 1] = info
    end
  end

  -- For each tracked column, sort a local copy descending by raw value with
  -- GUID as a deterministic tiebreaker (so tied-value players always land in
  -- the same slots across recomputes — e.g. tab switches in BGs). Skip true
  -- zeros entirely: they get no rank stored, so no ordinal is drawn inline.
  for _, entry in ipairs(pairs_list) do
    local dataKey = entry.dataKey
    local rankKey = entry.rankKey
    local sorted = {}
    for i = 1, #scores do
      sorted[i] = scores[i]
    end
    table.sort(sorted, function(a, b)
      local va = GetStatValue(a, dataKey)
      local vb = GetStatValue(b, dataKey)
      if va ~= vb then
        return va > vb
      end
      -- Tiebreak on name for determinism (human-readable if we ever
      -- debug a comparator result). Fall through to GUID when names
      -- are missing or identical — GUID is guaranteed non-nil here
      -- since we filter the scores snapshot on info.guid.
      if a.name and b.name and a.name ~= b.name then
        return a.name < b.name
      end
      return a.guid < b.guid
    end)
    for i = 1, #sorted do
      local info = sorted[i]
      if GetStatValue(info, dataKey) ~= 0 then
        if not ranksByGuid[info.guid] then
          ranksByGuid[info.guid] = {}
        end
        ranksByGuid[info.guid][rankKey] = i
      end
    end
  end

  -- Land the visual state on DEFAULT_SORT with a single C-side sort call.
  -- Our hooksecurefunc on SortBattlefieldScoreData fires naturally, updating
  -- currentSortType / currentSortDescending and the header arrow. Whatever
  -- direction Blizzard lands on is fine — we don't read from C_PvP for rank
  -- purposes after this point.
  if DEFAULT_SORT ~= "none" then
    SortBattlefieldScoreData(DEFAULT_SORT)
  end

  ranksComputed = true
  computingRanks = false
end

-- Wraps ComputeRanks with a one-frame alpha hide on the given scrollBox, so
-- any intermediate sort state is never visible to the user. For hidden frames
-- (e.g. PostRound compute before results panel appears) the alpha tweak is a
-- visual no-op.
local function RecomputeQuiet(scrollBox)
  if scrollBox then
    scrollBox:SetAlpha(0)
  end
  ComputeRanks()
  if scrollBox then
    C_Timer.After(0, function()
      scrollBox:SetAlpha(1)
    end)
  end
end

-------------------------------------------------
-- Below Row (ordinals anchored below table via column header offsets)
-------------------------------------------------
local function CreateBelowContainer(parent)
  local container = CreateFrame("Frame", nil, parent)
  container:SetAllPoints(parent)
  container:SetFrameLevel(parent:GetFrameLevel() + 10)
  container._fontStrings = {}
  container:Hide()
  return container
end

local function UpdateBelowRanks(container, scrollBox)
  if not container then
    return
  end

  for _, fs in pairs(container._fontStrings) do
    fs:Hide()
  end
  if container._label then
    container._label:Hide()
  end

  if RANK_POSITION ~= "below" or not RANK_ENABLED then
    container:Hide()
    return
  end

  if not IsMatchStateValid() or not ranksComputed then
    container:Hide()
    return
  end

  local playerGuid = UnitGUID("player")
  if not playerGuid then
    container:Hide()
    return
  end

  -- Player may legitimately have no entry in ranksByGuid (e.g. every column
  -- is zero → we skipped storing anything). We still want to render "-" in
  -- each slot, so don't bail on nil ranks. Instead bail only if the player
  -- isn't in the scoreboard at all.
  local playerScoreInfo = C_PvP.GetScoreInfoByPlayerGuid(playerGuid)
  if not playerScoreInfo then
    container:Hide()
    return
  end
  local ranks = ranksByGuid[playerGuid] or {}

  local scrollHeight = scrollBox:GetHeight()
  local hasAny = false
  local firstOrdinal = nil

  for tableBuilder in pairs(trackedTableBuilders) do
    if tableBuilder.columns then
      for _, column in ipairs(tableBuilder.columns) do
        local header = column:GetHeaderFrame()
        local args = column.args
        if header and args and args[1] then
          local dataKey = args[1]
          local rankKey
          if RANKABLE_STRING_KEYS[dataKey] then
            rankKey = dataKey
          elseif type(dataKey) == "number" then
            rankKey = "stat_" .. dataKey
          end

          if rankKey then
            -- rank may be nil (value was zero → we skipped storing).
            -- In that case, render "-" so the layout slot stays aligned
            -- with the column header and reads as "no ranking here".
            local rank = ranks[rankKey]
            local text
            if rank then
              text = GetOrdinal(rank)
            elseif GetStatValue(playerScoreInfo, dataKey) == 0 then
              text = "-"
            end

            if text then
              if not container._fontStrings[rankKey] then
                local fs = container:CreateFontString(nil, "OVERLAY")
                local font, size, flags = header.text:GetFont()
                fs:SetFont(font, (size or 10) - 1, flags or "")
                fs:SetTextColor(1, 1, 1)
                container._fontStrings[rankKey] = fs
              end

              local fs = container._fontStrings[rankKey]
              fs:SetText(text)
              fs:ClearAllPoints()
              fs:SetPoint("TOP", header, "BOTTOM", 0, -(scrollHeight + 4))
              fs:Show()
              hasAny = true

              if
                not firstOrdinal
                or (
                  header:GetLeft()
                  and (not firstOrdinal._aotHeaderLeft or header:GetLeft() < firstOrdinal._aotHeaderLeft)
                )
              then
                firstOrdinal = fs
                firstOrdinal._aotHeaderLeft = header:GetLeft()
              end
            end
          end
        end
      end
    end
  end

  if hasAny then
    -- Create or update the "Placement:" label
    if not container._label then
      local label = container:CreateFontString(nil, "OVERLAY")
      local font, size, flags = firstOrdinal:GetFont()
      label:SetFont(font, size, flags or "")
      label:SetTextColor(1, 1, 1)
      label:SetText("Placement:")
      container._label = label
    end
    container._label:ClearAllPoints()
    container._label:SetPoint("RIGHT", firstOrdinal, "LEFT", -35, 0)
    container._label:Show()
    container:Show()
  else
    if container._label then
      container._label:Hide()
    end
    container:Hide()
  end
end

-------------------------------------------------
-- Pin-to-top via HookScript (no hooksecurefunc = no taint)
-- Fires AFTER Blizzard's OnUpdate runs untainted, only acts at PostRound+
-------------------------------------------------
local function RebuildPinnedDataProvider(scrollBox)
  if not scrollBox or computingRanks then
    return
  end

  if RESPECT_SORT or not IsMatchStateValid() then
    return
  end

  local useAlternateColor = not C_PvP.IsMatchFactional()
  local dataProvider = CreateDataProvider()
  local localPlayerEntry = nil
  local otherEntries = {}

  local isCustomVictory = C_PvP.GetCustomVictoryStatID() ~= 0
  local isMatchComplete = PVPMatchUtil.IsActiveMatchComplete()

  for index = 1, GetNumBattlefieldScores() do
    local scoreInfo = C_PvP.GetScoreInfo(index)
    local isLocalPlayer = scoreInfo and scoreInfo.guid and IsPlayerGuid(scoreInfo.guid)

    local entry
    if isCustomVictory and isMatchComplete then
      local bgColor = isLocalPlayer and PVP_SCOREBOARD_ALLIANCE_ALT_ROW_COLOR or PVP_SCOREBOARD_HORDE_ALT_ROW_COLOR
      entry = { index = index, backgroundColor = bgColor }
    else
      entry = { index = index, useAlternateColor = useAlternateColor }
    end

    if isLocalPlayer then
      localPlayerEntry = entry
    else
      otherEntries[#otherEntries + 1] = entry
    end
  end

  if localPlayerEntry then
    dataProvider:Insert(localPlayerEntry)
  end
  for _, entry in ipairs(otherEntries) do
    dataProvider:Insert(entry)
  end

  scrollBox:SetDataProvider(dataProvider, ScrollBoxConstants.RetainScrollPosition)
end

if PVPMatchScoreboard then
  local belowScoreboard = CreateBelowContainer(PVPMatchScoreboard)
  PVPMatchScoreboard:HookScript("OnUpdate", function(self)
    RebuildPinnedDataProvider(self.scrollBox)
    UpdateBelowRanks(belowScoreboard, self.scrollBox)
  end)
end
if PVPMatchResults then
  local belowResults = CreateBelowContainer(PVPMatchResults)
  PVPMatchResults:HookScript("OnUpdate", function(self)
    RebuildPinnedDataProvider(self.scrollBox)
    UpdateBelowRanks(belowResults, self.scrollBox)
  end)
end

-------------------------------------------------
-- Hook: ConstructPVPMatchTable (widen columns + track headers)
-- Uses hooksecurefunc so original runs untainted
-------------------------------------------------
-- Applies ordinal/arrow width deltas to every column in the builder based on
-- the current config. Each column stashes the delta it's currently carrying
-- (_aotOrdinalDelta, _aotArrowDelta) so we can cleanly strip-then-re-add on
-- live config changes without accumulating stale width. Returns true if any
-- column width changed (caller should re-arrange).
local function ApplyColumnDeltas(tableBuilder)
  local changed = false
  for _, column in ipairs(tableBuilder.columns) do
    local header = column:GetHeaderFrame()
    local args = column.args
    local isSortable = header and header.sortType
    local isRankable = RANK_ENABLED
      and RANK_POSITION == "inline"
      and args
      and args[1]
      and (RANKABLE_STRING_KEYS[args[1]] or type(args[1]) == "number")

    local desiredOrdinal = isRankable and ORDINAL_EXTRA_WIDTH or 0
    local desiredArrow = (isSortable and SHOW_SORT_ARROW) and ARROW_EXTRA_WIDTH or 0

    local currentOrdinal = column._aotOrdinalDelta or 0
    local currentArrow = column._aotArrowDelta or 0

    if desiredOrdinal ~= currentOrdinal or desiredArrow ~= currentArrow then
      column.fixedWidth = (column.fixedWidth or 0) - currentOrdinal - currentArrow + desiredOrdinal + desiredArrow
      column._aotOrdinalDelta = desiredOrdinal
      column._aotArrowDelta = desiredArrow
      changed = true
    end
  end
  return changed
end

-- Walks every tracked builder and re-applies deltas + re-arranges headers.
-- Called from RefreshUI so toggling RANK_POSITION / SHOW_SORT_ARROW live
-- updates column widths without requiring the scoreboard to be closed+reopened.
local function ReapplyAllColumnDeltas()
  for tableBuilder in pairs(trackedTableBuilders) do
    if tableBuilder.columns then
      local changed = ApplyColumnDeltas(tableBuilder)
      if changed then
        tableBuilder:CalculateColumnSpacing()
        tableBuilder:ArrangeHeaders()
      end
    end
  end
end

hooksecurefunc("ConstructPVPMatchTable", function(tableBuilder, useAlternateColor)
  trackedTableBuilders[tableBuilder] = true

  local changed = ApplyColumnDeltas(tableBuilder)
  if changed then
    tableBuilder:CalculateColumnSpacing()
    tableBuilder:ArrangeHeaders()
  end

  if SHOW_SORT_ARROW and currentSortType then
    UpdateSortArrows()
  end

  -- If we hit this hook while the match is already at PostRound+ (which is
  -- the case for PVPMatchResults:Display at match end), compute ranks now.
  -- trackedTableBuilders is guaranteed to contain this builder at this point.
  -- The PVP_MATCH_STATE_CHANGED event can't be used for this because it may
  -- fire BEFORE Display runs, so trackedTableBuilders would be empty.
  if IsMatchStateValid() and not ranksComputed then
    RecomputeQuiet(nil) -- results frame isn't shown yet inside Display
  end
end)

-------------------------------------------------
-- Apply ordinals via ScrollBox frame callback
-- (avoids hooking AddRow which causes taint during active match)
-------------------------------------------------
local function ApplyOrdinalsToRow(owner, frame, elementData)
  -- Always clean up stale ordinals on recycled cells
  if frame.cells then
    for _, cell in ipairs(frame.cells) do
      if cell._aotOrdinal then
        cell._aotOrdinal:Hide()
      end
    end
  end

  if not RANK_ENABLED or RANK_POSITION ~= "inline" or not IsMatchStateValid() or not ranksComputed then
    return
  end
  if not frame.cells then
    return
  end

  local scoreIndex = elementData and elementData.index
  if not scoreIndex then
    return
  end

  local scoreInfo = C_PvP.GetScoreInfo(scoreIndex)
  if not scoreInfo or not scoreInfo.guid then
    return
  end
  local guid = scoreInfo.guid

  if RANK_TYPE == "self" then
    if not IsPlayerGuid(guid) then
      return
    end
  end

  local ranks = ranksByGuid[guid]
  if not ranks then
    return
  end

  for _, cell in ipairs(frame.cells) do
    if cell.text and cell.dataProviderKey then
      local key = cell.dataProviderKey
      local rankKey = nil
      if RANKABLE_STRING_KEYS[key] then
        rankKey = key
      elseif type(key) == "number" then
        rankKey = "stat_" .. key
      end
      if rankKey and ranks[rankKey] then
        ApplyOrdinal(cell, ranks[rankKey])
      end
    end
  end
end

-- Register callback on each scrollbox — fires AFTER AddRow populates cells
if PVPMatchResults and PVPMatchResults.scrollBox then
  ScrollUtil.AddInitializedFrameCallback(PVPMatchResults.scrollBox, ApplyOrdinalsToRow, nil, false)
end
if PVPMatchScoreboard and PVPMatchScoreboard.scrollBox then
  ScrollUtil.AddInitializedFrameCallback(PVPMatchScoreboard.scrollBox, ApplyOrdinalsToRow, nil, false)
end

-------------------------------------------------
-- Compute triggers
--
-- PostRound+ match state: compute while frames are still hidden, so the sort
-- churn is invisible. No scrollBox alpha tweak needed.
--
-- Tab change: recompute only if we're past match end AND the tab is relevant
-- (the player's own faction or "All"; enemy faction = skip). Wrapped in the
-- alpha trick so the user never sees intermediate sort states.
-------------------------------------------------
-- Pulls the saved-variable values into our local upvalues. Closures that
-- captured the upvalues see the new values because Lua upvalues are by ref.
function addon.RefreshConfig()
  local db = AlwaysOnTopDB
  RESPECT_SORT = db.RESPECT_SORT
  RANK_ENABLED = db.RANK_ENABLED
  RANK_POSITION = db.RANK_POSITION
  RANK_LOCATION = db.RANK_LOCATION
  RANK_TYPE = db.RANK_TYPE
  SHOW_SORT_ARROW = db.SHOW_SORT_ARROW
  DEFAULT_SORT = db.DEFAULT_SORT
end

-- Called by the Options window after a settings change, so visual state
-- reflects the new config without a /reload. If the scoreboard is open we
-- recompute ranks (which re-sorts and triggers row re-init via scrollBox),
-- and we always refresh sort arrows so SHOW_SORT_ARROW toggles take effect.
function addon.RefreshUI()
  if IsMatchStateValid() then
    local scrollBox = PVPMatchResults and PVPMatchResults:IsShown() and PVPMatchResults.scrollBox or nil
    RecomputeQuiet(scrollBox)
  end
  -- Column widths depend on RANK_POSITION and SHOW_SORT_ARROW; re-apply
  -- deltas so live toggles from the Options window take effect without a
  -- scoreboard rebuild.
  ReapplyAllColumnDeltas()
  UpdateSortArrows()
end

-- Exposed for the Options window so it can decide whether to show a
-- reload-required prompt when a setting that can't be applied live changes.
function addon.IsScoreboardActive()
  return (PVPMatchScoreboard and PVPMatchScoreboard:IsShown()) or (PVPMatchResults and PVPMatchResults:IsShown())
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
eventFrame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= addonName then
      return
    end
    -- Initialize saved vars with defaults for any missing keys. Using key-by-key
    -- fill (not table assignment) so future added settings pick up defaults on
    -- first load after upgrade.
    AlwaysOnTopDB = AlwaysOnTopDB or {}
    for k, v in pairs(addon.defaults) do
      if AlwaysOnTopDB[k] == nil then
        AlwaysOnTopDB[k] = v
      end
    end
    addon.RefreshConfig()
    -- Options.lua loads after us (TOC order) and sets this, so it's
    -- present by the time our addon's ADDON_LOADED fires.
    if addon.InitOptions then
      addon.InitOptions()
    end
  elseif event == "PVP_MATCH_STATE_CHANGED" then
    if IsMatchStateValid() then
      RecomputeQuiet(nil) -- frame not yet visible; no alpha tweak needed
    else
      -- Mid-match or pre-match: clear any stale cache, do nothing else.
      ranksByGuid = {}
      ranksComputed = false
    end
  end
end)

hooksecurefunc("SetBattlefieldScoreFaction", function(factionEnum)
  if not IsMatchStateValid() then
    return
  end
  if not IsTabRelevant(factionEnum) then
    return
  end
  -- Pick the currently-visible results scrollBox (tab switching happens here
  -- at match end in BGs). PVPMatchScoreboard is mid-match which we ignore.
  local scrollBox = PVPMatchResults and PVPMatchResults:IsShown() and PVPMatchResults.scrollBox or nil
  RecomputeQuiet(scrollBox)
end)
