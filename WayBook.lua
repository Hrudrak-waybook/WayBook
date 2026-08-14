-- WayBook - a clickable directory of your saved TomTom waypoints.
--
-- Left-click a line to point the crazy arrow at it, shift-click to copy or
-- share it, right-click to edit its label, note and tags all in one window,
-- and the red minus deletes it.
-- Everything configurable lives in the Options window.

-- Keybinding display names. Set at the top of the file, before anything else
-- runs, because the Key Bindings UI falls back to the raw binding name when
-- BINDING_NAME_<name> is missing at the moment it renders.
BINDING_NAME_WAYBOOK_TOGGLE_LIST    = "Toggle waypoint list"
BINDING_NAME_WAYBOOK_TOGGLE_OPTIONS = "Toggle options"
BINDING_NAME_WAYBOOK_ADD_TARGET     = "Add waypoint"
BINDING_NAME_WAYBOOK_CLEAR_ARROW    = "Clear the arrow"

-- TomTom is a hard dependency, so LibStub and HereBeDragons are already loaded.
local hbd = LibStub and LibStub("HereBeDragons-2.0", true)

-- Layout numbers, colours and timings, held as fields on one table rather
-- than as ~40 separate file-scope locals.
--
-- Lua caps a function at 200 locals and the main chunk of this file counts as
-- one. In 1.26.19 a single added helper took it to 201 and the whole file
-- stopped compiling, which in game is the silent "addon does not load"
-- failure. A table costs one slot however many fields it carries.
--
-- Purely a rename: every value, and every place that reads it, is unchanged.
local K = {}

K.FRAME_WIDTH  = 360
-- 446 rather than 420 since 1.26.8: the group-by row added under the search
-- box takes 26px, and the frame grew by exactly that so the list area below
-- it is unchanged.
K.FRAME_HEIGHT = 446
K.GROUP_ROW_Y = -68   -- group-by radios and the sort toggle, under the search box
K.ROW_PADDING = 5   -- row height on top of the glyph height
K.CHECK_INTERVAL = 0.5
K.VISIT_DISTANCE = 15   -- yards; counts as "I went there"
K.DISTANCE_INTERVAL = 1   -- how often the list re-reads distances while open
K.ZONE_INDENT = 12
K.BUTTON_WIDTH, K.BUTTON_HEIGHT = 100, 22
K.SEARCH_BOX_HEIGHT = 22
K.BUTTON_FONT_DELTA = -2   -- trims the stock button label a touch
K.MIN_LIST_FONT_SIZE = 7
K.MAX_LIST_FONT_SIZE = 20
K.DEFAULT_LIST_FONT_SIZE = 10   -- what GameFontNormalSmall gives you

K.DEFAULT_CLEAR_DISTANCE  = 10
K.DEFAULT_ARRIVE_DISTANCE = 10

K.BAR_PADDING = 10   -- text inset inside the collapsed bar
K.BAR_GAP = 4        -- gap between the bar and the expanded window
-- Grace period before an actual collapse, so the mouse has time to cross the
-- gap between the bar and the window (or between the window and a child
-- window like Options) without everything snapping shut mid-move.
K.COLLAPSE_DELAY = 0.4
-- How often the collapse watcher polls IsMouseOver() on every relevant
-- window. Fast enough to feel immediate, cheap enough to run continuously.
K.WATCH_INTERVAL = 0.15

K.COLOR_LABEL    = "|cff40ff40"
K.COLOR_COORDS   = "|cffffffff"
K.COLOR_NOTE     = "|cffffd100"
-- Raw hex, not an escape-code string: this tints badge text via SetTextColor
-- (needs 0-1 floats through HexToRGB), and the tooltip's tag line (needs
-- floats too), never a |cff-prefixed string dropped straight into :SetText.
K.COLOR_TAG = "ff9933"
K.ZONE_COLORS  = { "73b3ff", "ffbf59", "d999ff", "73ffd9", "ff8c99", "f2f280" }
-- Okabe & Ito (2008) - the standard reference palette for "distinguishable to
-- both normal and color-blind vision", six of its seven non-black entries.
-- Dropped Vermillion (d55e00): with only six slots, it sits closest to
-- Orange, the one pair least worth keeping if something has to go.
K.ZONE_COLORS_COLORBLIND = { "0072b2", "e69f00", "56b4e9", "cc79a7", "009e73", "f0e442" }
-- Light enough that the header text stays fully legible over it.
K.ZONE_BAND_ALPHA = 0.22

local function HexToRGB(hex)
    return (tonumber(hex:sub(1, 2), 16) or 255) / 255,
           (tonumber(hex:sub(3, 4), 16) or 255) / 255,
           (tonumber(hex:sub(5, 6), 16) or 255) / 255
end

local function Tint(texture, r, g, b, a)
    if texture.SetColorTexture then
        texture:SetColorTexture(r, g, b, a)
    else
        texture:SetTexture(r, g, b, a)
    end
end

-- The stock DialogBox background texture is not fully opaque at every texel,
-- so setting an alpha on the backdrop itself is not enough to stop the 3D
-- world from showing through in places. A plain child frame at a strictly
-- lower frame level draws underneath every one of the parent's own regions -
-- backdrop included, regardless of that region's own layer or sublevel - so
-- a solid ColorTexture on one is a guaranteed opaque fill regardless of what
-- the backdrop's own texture does.
local function AddOpaqueBackground(f)
    local bg = CreateFrame("Frame", nil, f)
    bg:SetAllPoints(f)
    bg:SetFrameLevel(0)
    local tex = bg:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints(bg)
    tex:SetColorTexture(0.06, 0.05, 0.05, 1)
    return bg
end

local WayBook = CreateFrame("Frame")
local frame, scrollFrame, content, countText, searchBox
-- Set by ScrollToWaypoint, consumed by the next Refresh, then cleared. A uid
-- rather than an index, since the row a waypoint lands on depends on the
-- current sort, grouping and search, none of which are known at the moment
-- the waypoint is created.
local pendingScrollUid
local optionsFrame
local exportFrame
local shareFrame
local editFrame
local barFrame
local entryRows, headerRows = {}, {}
local entries, display = {}, {}
local zoneCounts = {}
local zoneNearest = {}   -- zone -> distance of its closest waypoint, for nearest-first
local entryTotal = 0   -- how many waypoints exist before the search filter
local refreshPending = false

-- Forward declarations for things defined later that earlier code reaches into.
local Toggle, ToggleOptions, RestyleAll, RefreshOptions, PromptDelete, PromptShare, PromptEdit
local StartCollapseWatcher, StopCollapseWatcher

-- The waypoint the crazy arrow is currently pointing at, tracked via a hook on
-- TomTom:SetCrazyArrow. Declared up here because renaming needs to read it.
local activeArrow

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40WayBook:|r " .. msg)
end

--------------------------------------------------------------------------
-- Settings accessors
--------------------------------------------------------------------------

local function Setting(key, default)
    local v = WayBookDB and WayBookDB[key]
    if v == nil then return default end
    return v
end

local function ListFontSize()   return Setting("listFontSize", K.DEFAULT_LIST_FONT_SIZE) end
local function ArriveDistance() return Setting("arriveDistance", K.DEFAULT_ARRIVE_DISTANCE) end
-- "zone", "tag" or "none". Replaced the old groupByZone boolean in 1.21.0 so
-- a second grouping axis had somewhere to go; see the PLAYER_LOGIN migration
-- for how an existing profile's boolean, and the 1.21.0 "category" value,
-- both become one of these.
local function GroupMode()      return Setting("groupBy", "zone") end
local function GroupByZone()    return GroupMode() == "zone" end
local function GroupByTag()     return GroupMode() == "tag" end
local function SortDescending() return Setting("sortDescending", false) end
local function SortMode()       return Setting("sortMode", "label") end
local function ShowVisits()     return Setting("showVisits", false) end
local function ClearArrowOnLogin() return Setting("clearArrowOnLogin", true) end
local function ShowLabel()      return Setting("showLabel", true) end
-- Label is the only column on out of the box. The rest are opt-in, so a fresh
-- character opens to a plain list of names.
local function ShowZone()       return Setting("showZone", false) end
-- Tags are never a text column - they render as badges under the row
-- (see the Tags section) - so this only ever gates whether those badges draw.
local function ShowTags()       return Setting("showTags", false) end
local function ShowCoords()     return Setting("showCoords", false) end
local function ShowDistance()   return Setting("showDistance", false) end
local function ColorblindMode() return Setting("colorblindMode", false) end

local function ActiveZoneColors()
    return ColorblindMode() and K.ZONE_COLORS_COLORBLIND or K.ZONE_COLORS
end

local function RowHeight()
    return ListFontSize() + K.ROW_PADDING
end

-- Keyed by whichever group label is currently on screen - a zone name or a
-- tag name. The two axes are never both active at once, so there is no
-- collision to guard against beyond the remote coincidence of a zone and a
-- tag sharing a name.
local function Collapsed(groupKey)
    return WayBookDB and WayBookDB.collapsed and WayBookDB.collapsed[groupKey]
end

local function SetCollapsed(groupKey, state)
    WayBookDB.collapsed = WayBookDB.collapsed or {}
    WayBookDB.collapsed[groupKey] = state or nil
end

--------------------------------------------------------------------------
-- Notes
--
-- Kept in WayBook's own SavedVariables rather than bolted onto TomTom's uid
-- table, keyed by TomTom's own waypoint key. That key includes the title, so
-- a rename has to carry the note across with it.
--------------------------------------------------------------------------

local function NoteKey(uid)
    if type(uid) ~= "table" then return nil end
    return TomTom:GetKey(uid)
end

local function GetNote(uid)
    local key = NoteKey(uid)
    if not key then return nil end
    local notes = WayBookDB and WayBookDB.notes
    return notes and notes[key]
end

local function SetNote(uid, text)
    local key = NoteKey(uid)
    if not key then return end
    WayBookDB.notes = WayBookDB.notes or {}
    text = (text or ""):match("^%s*(.-)%s*$")
    WayBookDB.notes[key] = (text ~= "") and text or nil
end

--------------------------------------------------------------------------
-- Tags
--
-- Two tables: a persistent, reusable list of tag names you build up once
-- ("Quartermaster", "Quest Giver", "Klaxxi", ...), and the subset of that
-- list assigned to each waypoint. A waypoint can carry several at once.
-- Replaced the single free-text category from 1.21.0, which only allowed one.
--------------------------------------------------------------------------

local function TagDefinitions()
    return (WayBookDB and WayBookDB.tagDefinitions) or {}
end

local function TagSortLess(a, b) return a:lower() < b:lower() end

-- Case-insensitive de-dup, so typing "klaxxi" after "Klaxxi" already exists
-- reuses it rather than creating a second, differently-cased entry. Whichever
-- casing was defined first is the one that sticks.
local function DefineTag(name)
    name = (name or ""):match("^%s*(.-)%s*$")
    if name == "" then return nil end

    WayBookDB.tagDefinitions = WayBookDB.tagDefinitions or {}
    local defs = WayBookDB.tagDefinitions
    for _, existing in ipairs(defs) do
        if existing:lower() == name:lower() then return existing end
    end

    defs[#defs + 1] = name
    table.sort(defs, TagSortLess)
    return name
end

-- Only prunes the master list a new waypoint could pick from. Waypoints that
-- already carry this tag keep it - scrubbing every one of them back out
-- would be a second, much more surprising action bundled into "delete this
-- from the picker".
local function RemoveTagDefinition(name)
    local defs = WayBookDB and WayBookDB.tagDefinitions
    if not defs then return end
    for i, existing in ipairs(defs) do
        if existing == name then
            table.remove(defs, i)
            return
        end
    end
end

-- Tags accumulate cruft fast during testing (define one, use it once, forget
-- about it) with nothing that ever cleaned it back up - RemoveTagDefinition
-- above existed but nothing called it. Sweeps the master list down to only
-- names at least one current waypoint still carries. Safe to call any time
-- the picker list and actual usage might have drifted apart, EXCEPT
-- mid-rename: a rename's own SetTags(uid, nil) is a transient step before the
-- same tags land back on the new uid a few lines later, and pruning in that
-- gap would drop a still-wanted definition before it gets reapplied. So this
-- is wired into ToggleTag and DeleteWaypoint specifically below, never into
-- SetTags itself.
local function PruneUnusedTagDefinitions()
    local defs = WayBookDB and WayBookDB.tagDefinitions
    if not defs or not next(defs) then return end

    local used = {}
    if WayBookDB.tags then
        for _, tags in pairs(WayBookDB.tags) do
            for _, t in ipairs(tags) do used[t] = true end
        end
    end

    local stale = {}
    for _, name in ipairs(defs) do
        if not used[name] then stale[#stale + 1] = name end
    end
    for _, name in ipairs(stale) do
        RemoveTagDefinition(name)
    end
end

-- Returns a fresh copy every time, so a caller mutating the result (the tag
-- picker's checkboxes do) can never corrupt the saved list by accident.
local function GetTags(uid)
    local key = NoteKey(uid)
    if not key then return {} end
    local tags = WayBookDB and WayBookDB.tags and WayBookDB.tags[key]
    if not tags then return {} end
    local copy = {}
    for i, t in ipairs(tags) do copy[i] = t end
    return copy
end

local function SetTags(uid, tags)
    local key = NoteKey(uid)
    if not key then return end
    WayBookDB.tags = WayBookDB.tags or {}
    if not tags or #tags == 0 then
        WayBookDB.tags[key] = nil
        return
    end
    local copy = {}
    for _, t in ipairs(tags) do copy[#copy + 1] = t end
    table.sort(copy, TagSortLess)
    WayBookDB.tags[key] = copy
end

local function HasTag(uid, tagName)
    for _, t in ipairs(GetTags(uid)) do
        if t == tagName then return true end
    end
    return false
end

-- Case-insensitive on purpose: DefineTag folds "quest"/"Quest"/"QUEST" into
-- whichever spelling was typed first (see DefineTag's own lower() compare),
-- so the canonical stored casing isn't something a row-render check should
-- have to guess right.
local function IsQuestTagged(tags)
    if not tags then return false end
    for _, t in ipairs(tags) do
        if t:lower() == "quest" then return true end
    end
    return false
end

local function ToggleTag(uid, tagName, on)
    local tags = GetTags(uid)
    if on then
        if not HasTag(uid, tagName) then
            tags[#tags + 1] = tagName
        end
    else
        for i, t in ipairs(tags) do
            if t == tagName then
                table.remove(tags, i)
                break
            end
        end
    end
    SetTags(uid, tags)
    PruneUnusedTagDefinitions()
end

-- Auto-tags any waypoint Questie creates as "Quest" (case-insensitive match
-- with IsQuestTagged above), so its book icon shows without tagging it by
-- hand every time Questie's tracked objective changes. Added in 1.25.1,
-- reversing the "no auto-tagging" stance the book icon originally
-- shipped with - deliberately narrow: this only reacts to Questie's own
-- from = "Questie" marker on a waypoint TomTom just created, nothing else
-- about Questie's own data.
--
-- hooksecurefunc gives this the exact arguments AddWaypoint was called with,
-- not its return value or the table it actually stored - AddWaypoint builds
-- a brand new uid table internally (TomTom.lua:995) rather than reusing opts,
-- so opts itself can't be used as uid here. Re-deriving the same key
-- AddWaypoint used (GetKeyArgs on the same m, x, y, title) and looking it up
-- in TomTom.waypoints is the only reliable way back to the real uid.
local function AutoTagQuestieWaypoint(_, m, x, y, opts)
    if not (opts and opts.from == "Questie" and opts.title) then return end
    local key = TomTom:GetKeyArgs(m, x, y, opts.title)
    local uid = TomTom.waypoints[m] and TomTom.waypoints[m][key]
    if not uid then return end
    DefineTag("Quest")
    ToggleTag(uid, "Quest", true)
end


--------------------------------------------------------------------------
-- Visit tracking
--
-- Same keying as notes. A visit is recorded when you actually reach a
-- waypoint the arrow was pointing at, so the count reflects deliberate trips
-- rather than incidental proximity.
--------------------------------------------------------------------------

local function GetVisits(uid)
    local key = NoteKey(uid)
    if not key then return 0, nil end
    local record = WayBookDB and WayBookDB.visits and WayBookDB.visits[key]
    if not record then return 0, nil end
    return record.count or 0, record.last
end

local function RecordVisit(uid)
    local key = NoteKey(uid)
    if not key then return end
    WayBookDB.visits = WayBookDB.visits or {}
    local record = WayBookDB.visits[key] or {}
    record.count = (record.count or 0) + 1
    record.last  = time()
    WayBookDB.visits[key] = record
    return record.count
end

local function ClearVisits(uid)
    local key = NoteKey(uid)
    if key and WayBookDB.visits then WayBookDB.visits[key] = nil end
end


--------------------------------------------------------------------------
-- Distance
--
-- TomTom's GetVectorToWaypoint bails out when the waypoint is not registered,
-- when hbd cannot place the player, or when the player and the waypoint sit in
-- different instances, so a nil answer means "another continent, or inside an
-- instance" rather than "very far away". Those entries get a dash and are
-- parked at the end of a nearest-first sort.
--------------------------------------------------------------------------

K.UNKNOWN_DISTANCE = math.huge

local function DistanceTo(uid)
    if not (TomTom and TomTom.GetDistanceToWaypoint) then return nil end
    local ok, dist = pcall(TomTom.GetDistanceToWaypoint, TomTom, uid)
    if not ok then return nil end
    return dist
end

local function DistanceText(dist)
    if not dist then return "|cff666666-|r" end
    if dist < 1000 then return ("|cffb0b0b0%d yd|r"):format(math.floor(dist + 0.5)) end
    return ("|cffb0b0b0%.1fk yd|r"):format(dist / 1000)
end

local function AgoText(stamp)
    if not stamp then return "never" end
    local delta = time() - stamp
    if delta < 60    then return "just now" end
    if delta < 3600  then return ("%dm ago"):format(delta / 60) end
    if delta < 86400 then return ("%dh ago"):format(delta / 3600) end
    return ("%dd ago"):format(delta / 86400)
end

--------------------------------------------------------------------------
-- Fonts
--
-- Scoped to the list contents only. Buttons, checkboxes and sliders keep the
-- stock Blizzard sizes: their layouts are built around fixed heights and fixed
-- vertical spacing, so resizing their labels overflows the widgets and pushes
-- rows into each other. The list is the only part that reflows.
--
-- The size is absolute, never relative. An earlier version read the current
-- size back with GetFont() and added an offset, but SetFontObject does not
-- reliably clear an explicit SetFont, so GetFont returned the size we had
-- already applied. Every slider tick then stacked another offset on top, and
-- a slider drag fires OnValueChanged dozens of times, which is how a one point
-- nudge turned into giant text.
--
-- Each string's font file and flags are captured once, before anything is
-- applied, and only the point size is ever written afterwards.
--------------------------------------------------------------------------

local styled = {}

local function ApplyFont(record)
    if not (record.fs and record.file) then return end
    -- A rejected size would leave the string with no font at all, which reads
    -- as the text vanishing, so fall back to the original font object.
    local ok = pcall(record.fs.SetFont, record.fs, record.file, ListFontSize(), record.flags)
    if not ok then
        record.fs:SetFontObject(record.base)
    end
end

local function StyleFont(fs, baseObject)
    if not fs then return end
    baseObject = baseObject or "GameFontNormalSmall"
    fs:SetFontObject(baseObject)

    local file, _, flags = fs:GetFont()
    local record = { fs = fs, base = baseObject, file = file, flags = flags }
    styled[#styled + 1] = record
    ApplyFont(record)
end

function RestyleAll()
    for _, record in ipairs(styled) do
        ApplyFont(record)
    end
end

-- One-off trim for chrome labels. Deliberately not registered with the styled
-- table: it runs once at build time and is never re-applied, so it cannot
-- compound the way the old relative sizing did.
local function ShrinkOnce(fs, delta)
    if not fs then return end
    local file, size, flags = fs:GetFont()
    if file and size then
        pcall(fs.SetFont, fs, file, size + delta, flags)
    end
end

-- One comparator for both list modes so a reversed sort flips zones and labels
-- together rather than only one of them.
local function Ascending(a, b)
    if SortDescending() then return a > b end
    return a < b
end

-- Visits and recency default to biggest-first, since "most frequented" is the
-- useful direction. Reverse flips them like everything else. Label is both a
-- mode of its own and the tiebreak for the other two.
local function CompareEntries(a, b)
    local mode = SortMode()

    if mode == "visits" and a.visits ~= b.visits then
        if SortDescending() then return a.visits < b.visits end
        return a.visits > b.visits
    end

    if mode == "recent" then
        local av, bv = a.lastVisit or 0, b.lastVisit or 0
        if av ~= bv then
            if SortDescending() then return av < bv end
            return av > bv
        end
    end

    -- Nearest first, and unreachable entries sink to the bottom because
    -- K.UNKNOWN_DISTANCE compares larger than any real reading.
    if mode == "distance" then
        local ad, bd = a.distance or K.UNKNOWN_DISTANCE, b.distance or K.UNKNOWN_DISTANCE
        if ad ~= bd then
            if SortDescending() then return ad > bd end
            return ad < bd
        end
    end

    if a.title ~= b.title then return Ascending(a.title, b.title) end
    return Ascending(a.zone, b.zone)
end

local function ZoneName(mapID)
    if hbd then
        local name = hbd:GetLocalizedMap(mapID)
        if name then return name end
    end
    return "Map " .. tostring(mapID)
end

--------------------------------------------------------------------------
-- Search
--
-- Lives only for as long as the window is open. Persisting it would mean
-- logging in to a book that silently hides most of itself.
--------------------------------------------------------------------------

local searchQuery = ""
local searchTerms = {}

local function SetSearchQuery(text)
    searchQuery = (text or ""):match("^%s*(.-)%s*$")
    wipe(searchTerms)
    for word in searchQuery:lower():gmatch("%S+") do
        searchTerms[#searchTerms + 1] = word
    end
end

local function Searching()
    return #searchTerms > 0
end

-- Every term has to turn up somewhere in the label, the zone, the note or one
-- of the tags, so "bank org" finds the Orgrimmar bank whichever order you
-- type the words in. Matched plainly rather than as a pattern: a stray "-"
-- or "(" in a label would otherwise blow up the match.
local function Matches(title, zone, note, tagText)
    if not Searching() then return true end
    local haystack = (title .. " " .. zone .. " " .. (note or "") .. " " .. (tagText or ""))
        :lower()
    for _, term in ipairs(searchTerms) do
        if not haystack:find(term, 1, true) then return false end
    end
    return true
end

--------------------------------------------------------------------------
-- Data
--------------------------------------------------------------------------

-- The "Untagged" bucket exists so an entry with no tags still shows up under
-- a header when grouped that way, instead of vanishing.
K.UNTAGGED = "Untagged"

-- Only ever computes zone-based grouping: every waypoint has exactly one
-- zone, so a single groupKey/color per entry is unambiguous there. Tag
-- grouping is many-to-many instead - a waypoint can own several tags at
-- once - and gets its own multi-membership pass in BuildDisplay(), which
-- ignores groupKey/color entirely and does not reuse this.
local function Collect()
    wipe(entries)
    wipe(zoneCounts)
    wipe(zoneNearest)
    entryTotal = 0

    local store = TomTom and TomTom.waypoints
    if not store then return end

    for mapID, group in pairs(store) do
        local zone = ZoneName(mapID)
        for _, uid in pairs(group) do
            local title = uid.title or "Unknown waypoint"
            entryTotal = entryTotal + 1
            local note = GetNote(uid)
            local tags = GetTags(uid)
            local tagText = #tags > 0 and table.concat(tags, " ") or nil
            -- Group counts come off the filtered set so a header never
            -- promises rows the search has taken away.
            if Matches(title, zone, note, tagText) then
                local count, last = GetVisits(uid)
                -- Read once per rebuild. The sort would otherwise ask TomTom
                -- again on every comparison, and a distance that shifts partway
                -- through a sort makes the comparator inconsistent.
                local dist = DistanceTo(uid)
                entries[#entries + 1] = {
                    uid       = uid,
                    mapID     = mapID,
                    zone      = zone,
                    tags      = tags,
                    groupKey  = zone,
                    x         = (uid[2] or 0) * 100,
                    y         = (uid[3] or 0) * 100,
                    title     = title,
                    visits    = count,
                    lastVisit = last,
                    distance  = dist,
                }
                zoneCounts[zone] = (zoneCounts[zone] or 0) + 1
                local nearest = zoneNearest[zone]
                if dist and (not nearest or dist < nearest) then
                    zoneNearest[zone] = dist
                end
            end
        end
    end

    table.sort(entries, function(a, b)
        if a.zone ~= b.zone then
            -- Zones lead with their closest member, otherwise nearest-first
            -- would still open on whichever zone sorts first alphabetically.
            if SortMode() == "distance" then
                local az = zoneNearest[a.zone] or K.UNKNOWN_DISTANCE
                local bz = zoneNearest[b.zone] or K.UNKNOWN_DISTANCE
                if az ~= bz then
                    if SortDescending() then return az > bz end
                    return az < bz
                end
            end
            return Ascending(a.zone, b.zone)
        end
        return CompareEntries(a, b)
    end)

    -- Assign each distinct zone the next color in the palette.
    local palette = ActiveZoneColors()
    local zoneColor, index, lastZone = {}, 0, nil
    for _, e in ipairs(entries) do
        if e.zone ~= lastZone then
            index = index + 1
            zoneColor[e.zone] = palette[((index - 1) % #palette) + 1]
            lastZone = e.zone
        end
        e.color = zoneColor[e.zone]
    end
end

-- The one canonical /way line for an entry. Shared by the delete undo hint,
-- the export dump and the share popup, so all three stay in the same format
-- TomTom itself accepts.
local function WayCommand(entry)
    return ("/way %s %.1f %.1f %s"):format(entry.zone, entry.x, entry.y, entry.title)
end

--------------------------------------------------------------------------
-- Export
--
-- Honors the search box exactly like the main list does: filter down to a
-- few waypoints and only those export, clear the box and the whole book
-- does. Collapsed zones are ignored either way, since collapsing is a fold
-- of the display, not a narrowing of what is in the book. Each line is a
-- working /way command (zone x y title, same order DeleteWaypoint already
-- prints as its own undo hint), so the text doubles as something you can
-- paste straight back into chat. A note becomes a following comment line:
-- /way itself has nowhere to put one.
--------------------------------------------------------------------------

local function BuildExportText()
    -- Collect() only ever narrows by the search box, never by collapsed
    -- zones, so this already matches the rule above without extra work. It
    -- recomputes entries/zoneCounts/zoneNearest under the same filter that is
    -- already in effect, so nothing here changes what the main list shows.
    Collect()
    local rows = {}
    for _, e in ipairs(entries) do rows[#rows + 1] = e end

    table.sort(rows, function(a, b)
        if a.zone ~= b.zone then return a.zone < b.zone end
        return a.title < b.title
    end)

    local header
    if Searching() then
        header = ("-- WayBook export: %d waypoint%s matching \"%s\", %s")
            :format(#rows, #rows == 1 and "" or "s", searchQuery, date("%Y-%m-%d %H:%M"))
    else
        header = ("-- WayBook export: %d waypoint%s, %s")
            :format(#rows, #rows == 1 and "" or "s", date("%Y-%m-%d %H:%M"))
    end
    local lines = {
        header,
        "-- Paste a line into chat to recreate that waypoint.",
        "",
    }
    local lastZone
    for _, e in ipairs(rows) do
        if e.zone ~= lastZone then
            if lastZone then lines[#lines + 1] = "" end
            lastZone = e.zone
        end
        lines[#lines + 1] = WayCommand(e)
        local note = GetNote(e.uid)
        if note then lines[#lines + 1] = "-- Note: " .. note end
        local tags = GetTags(e.uid)
        if #tags > 0 then lines[#lines + 1] = "-- Tags: " .. table.concat(tags, ", ") end
    end

    if #rows == 0 then
        lines[#lines + 1] = "-- Nothing saved yet."
    end

    return table.concat(lines, "\n")
end

-- Every tag a waypoint owns is a header it belongs under - a many-to-many
-- relationship, unlike zone. So a multi-tagged waypoint appears more than
-- once in the flattened display, once per tag (and "Klaxxi" or "Shieldwall"
-- both get their own header the moment anything owns that tag), rather than
-- picking a single alphabetically-first home the way an earlier cut of this
-- did. Each appearance is the same shared entry table, just referenced from
-- more than one row - clicking any of them acts on the one real waypoint.
local function BuildTagDisplay()
    local groups = {}
    for _, e in ipairs(entries) do
        local memberOf = (#e.tags > 0) and e.tags or { K.UNTAGGED }
        for _, tagName in ipairs(memberOf) do
            local g = groups[tagName]
            if not g then
                g = { entries = {} }
                groups[tagName] = g
            end
            g.entries[#g.entries + 1] = e
            if e.distance and (not g.nearest or e.distance < g.nearest) then
                g.nearest = e.distance
            end
        end
    end

    local names = {}
    for name in pairs(groups) do names[#names + 1] = name end
    table.sort(names, function(a, b)
        if SortMode() == "distance" then
            local az = groups[a].nearest or K.UNKNOWN_DISTANCE
            local bz = groups[b].nearest or K.UNKNOWN_DISTANCE
            if az ~= bz then
                if SortDescending() then return az > bz end
                return az < bz
            end
        end
        return Ascending(a, b)
    end)

    local palette = ActiveZoneColors()
    for i, name in ipairs(names) do
        local g = groups[name]
        table.sort(g.entries, CompareEntries)
        display[#display + 1] = {
            kind     = "header",
            groupKey = name,
            color    = palette[((i - 1) % #palette) + 1],
            count    = #g.entries,
        }
        if Searching() or not Collapsed(name) then
            for _, e in ipairs(g.entries) do
                display[#display + 1] = { kind = "entry", entry = e }
            end
        end
    end
end

-- Flatten into the actual list of lines to draw: headers plus entries when
-- grouped by zone (one groupKey per entry, straight off Collect()) or by tag
-- (many-to-many, see BuildTagDisplay), a plain alphabetical run of entries
-- when ungrouped.
local function BuildDisplay()
    wipe(display)
    Collect()

    local mode = GroupMode()

    if mode == "none" then
        local flat = {}
        for _, e in ipairs(entries) do flat[#flat + 1] = e end
        table.sort(flat, CompareEntries)
        for _, e in ipairs(flat) do
            display[#display + 1] = { kind = "entry", entry = e }
        end
        return
    end

    if mode == "tag" then
        BuildTagDisplay()
        return
    end

    local lastGroup
    for _, e in ipairs(entries) do
        if e.groupKey ~= lastGroup then
            lastGroup = e.groupKey
            display[#display + 1] = {
                kind     = "header",
                groupKey = e.groupKey,
                color    = e.color,
                count    = zoneCounts[e.groupKey] or 0,
            }
        end
        -- A search overrides a collapsed group. Otherwise a hit inside a
        -- folded group shows up as a header with a count and no rows under it.
        if Searching() or not Collapsed(e.groupKey) then
            display[#display + 1] = { kind = "entry", entry = e }
        end
    end
end

-- e.color cycles per distinct group, and the group is whichever axis is
-- currently active (zone or tag) - see Collect(). It is only safe to tint the
-- Zone segment with it while zone actually is that axis; grouped by tag,
-- e.color identifies a tag instead, and painting the zone name with a tag's
-- color would misidentify it.
K.COLOR_ZONE_FALLBACK = "|cff8899aa"

local function RowText(e)
    local parts = {}
    if ShowLabel() then parts[#parts + 1] = K.COLOR_LABEL .. e.title .. "|r" end
    -- Tags never join this line - see the Tags section for why they render
    -- as their own badges under the row instead.
    if ShowZone() then
        local zoneColor = GroupByTag() and K.COLOR_ZONE_FALLBACK or ("|cff" .. e.color)
        parts[#parts + 1] = zoneColor .. e.zone .. "|r"
    end
    if ShowCoords() then
        parts[#parts + 1] = ("%s(%.1f, %.1f)|r"):format(K.COLOR_COORDS, e.x, e.y)
    end
    -- Distance is deliberately absent: it gets its own font string pinned to the
    -- right edge of the row so the numbers line up down the column.
    if ShowVisits() then
        parts[#parts + 1] = ("|cff999999x%d|r"):format(e.visits or 0)
    end
    local text = table.concat(parts, "  -  ")
    if GetNote(e.uid) then
        text = text .. "  " .. K.COLOR_NOTE .. "*|r"
    end
    return text
end

--------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------

-- Clear-on-arrival lives in TomTom's profile and is baked into each waypoint's
-- callbacks when it is created, so existing waypoints have to be rebuilt for a
-- change to take hold. ReloadWaypoints does that in place, no UI reload needed.
-- TomTom:AddWaypoint always resolves cleardistance to a concrete number and
-- freezes it onto that specific waypoint at creation time - it only ever
-- falls back to the live profile setting when a waypoint doesn't already
-- have one.
--
-- This used to be implemented by mutating TomTom.profile.persistence.cleardistance
-- itself (the shared global every addon's waypoints fall back to when they
-- don't set their own). That broke other addons' own arrival-clearing: Questie
-- tags its own tracked-objective waypoint with from = "Questie" and never sets
-- its own cleardistance, so it silently inherited whatever WayBook set the
-- global to - meaning "Keep waypoints on arrival" also stopped Questie's quest
-- waypoint from clearing when you reached it. Confirmed by reading
-- TrackerUtils.lua/QuestieFrame.lua's TomTom:AddWaypoint calls. Fix: only ever
-- freeze cleardistance on waypoints WayBook itself created (source == "WayBook",
-- set at creation in AddTargetWaypoint/RenameWaypoint) and leave the shared
-- global at its normal default, so any other addon's waypoints keep behaving
-- exactly as if WayBook didn't exist.
local function ApplyKeepOnArrivalToOwnWaypoints()
    local store = TomTom and TomTom.waypoints
    if not store then return end
    local dist = WayBookDB.keepOnArrival and 0
        or (WayBookDB.savedClearDistance or K.DEFAULT_CLEAR_DISTANCE)
    for _, group in pairs(store) do
        for _, uid in pairs(group) do
            if uid.source == "WayBook" then
                uid.cleardistance = dist
            end
        end
    end
end

local function SetKeepOnArrival(keep)
    if not (TomTom and TomTom.profile) then return end

    WayBookDB.keepOnArrival = keep and true or false
    ApplyKeepOnArrivalToOwnWaypoints()
    TomTom:ReloadWaypoints()
end

local function KeepOnArrivalEnabled()
    return WayBookDB and WayBookDB.keepOnArrival or false
end

local function ActivateWaypoint(entry)
    if not (TomTom and TomTom.SetCrazyArrow) then return end
    -- SetCrazyArrow itself never fails or returns anything - it happily sets
    -- active_point on a waypoint the arrow can never actually reach, and only
    -- the crazy arrow's own OnUpdate later discovers that (GetDistanceToWaypoint
    -- comes back nil) and silently hides itself, forever, with no message.
    -- Same nil check the row's own hover tooltip already uses for "Not on this
    -- continent" - checking it here first catches the failure before claiming
    -- success instead of after the arrow has already gone quietly missing.
    if not DistanceTo(entry.uid) then
        Print(("%s (%s) is on another continent - the arrow can't reach it.")
            :format(entry.title, entry.zone))
        return
    end
    TomTom:SetCrazyArrow(entry.uid, TomTom.profile.arrow.arrival, entry.title)
end

local function DeleteWaypoint(entry)
    if not (TomTom and TomTom.RemoveWaypoint) then return end
    local undo = WayCommand(entry)
    SetNote(entry.uid, nil)
    SetTags(entry.uid, nil)
    ClearVisits(entry.uid)
    TomTom:RemoveWaypoint(entry.uid)
    PruneUnusedTagDefinitions()
    Print(("Removed %s. Re-add with: %s"):format(entry.title, undo))
end

-- TomTom stores each waypoint under a key built from map, x, y AND title
-- (GetKeyArgs in TomTom.lua), so editing uid.title in place would orphan the
-- entry under its old key. A rename has to be a remove followed by an add.
-- Returns the waypoint's current uid on every path except "it's gone" (nil),
-- including the no-op ones, so a caller that keeps its own reference to a
-- waypoint (the Edit window does) can stay pointed at the right one across a
-- rename, which - see below - always changes the underlying uid.
local function RenameWaypoint(entry, newTitle)
    newTitle = (newTitle or ""):match("^%s*(.-)%s*$")
    if newTitle == "" then
        Print("A label cannot be empty.")
        return entry.uid
    end
    if newTitle == entry.title then return entry.uid end

    local uid = entry.uid
    if not TomTom:IsValidWaypoint(uid) then
        Print("That waypoint no longer exists.")
        return nil
    end

    local m, x, y = uid[1], uid[2], uid[3]
    local wasActive = (activeArrow == uid)
    local oldTitle = entry.title
    local note = GetNote(uid)
    local tags = GetTags(uid)
    local visitCount, visitLast = GetVisits(uid)

    SetNote(uid, nil)
    SetTags(uid, nil)
    ClearVisits(uid)
    TomTom:RemoveWaypoint(uid)
    local newUid = TomTom:AddWaypoint(m, x, y, {
        title        = newTitle,
        source       = "WayBook",
        persistent   = true,
        crazy        = false,
        cleardistance = KeepOnArrivalEnabled() and 0
            or (WayBookDB.savedClearDistance or K.DEFAULT_CLEAR_DISTANCE),
    })

    if newUid then
        if note then SetNote(newUid, note) end
        if #tags > 0 then SetTags(newUid, tags) end
        if visitCount > 0 then
            WayBookDB.visits = WayBookDB.visits or {}
            WayBookDB.visits[NoteKey(newUid)] = { count = visitCount, last = visitLast }
        end
    end

    -- Removing the old one dropped the arrow, so put it back on the new entry.
    if wasActive and newUid then
        TomTom:SetCrazyArrow(newUid, TomTom.profile.arrow.arrival, newTitle)
    end

    return newUid
end

-- Moving a waypoint is the same remove-then-add problem as renaming it, and
-- for the same reason: TomTom's key is built from map, x, y AND title, so x
-- and y cannot be edited in place any more than the title can. Returns the
-- current uid on every path except "it's gone", exactly like RenameWaypoint,
-- so the Edit window can repoint itself and keep editing the same waypoint.
--
-- newX and newY arrive as the 0-100 numbers the user actually typed; TomTom
-- stores fractions, hence the /100 at the point of the add.
local function MoveWaypoint(entry, newX, newY)
    local uid = entry.uid
    if not TomTom:IsValidWaypoint(uid) then
        Print("That waypoint no longer exists.")
        return nil
    end

    local m, oldX, oldY = uid[1], uid[2], uid[3]
    -- Compare at display precision. Reformatting an unchanged box to one
    -- decimal place otherwise reads as a move and needlessly rebuilds the
    -- waypoint, dropping and restoring the arrow on the way through.
    if ("%.1f"):format(newX) == ("%.1f"):format(oldX * 100)
        and ("%.1f"):format(newY) == ("%.1f"):format(oldY * 100) then
        return uid
    end

    local title = entry.title
    local wasActive = (activeArrow == uid)
    local note = GetNote(uid)
    local tags = GetTags(uid)
    local visitCount, visitLast = GetVisits(uid)

    SetNote(uid, nil)
    SetTags(uid, nil)
    ClearVisits(uid)
    TomTom:RemoveWaypoint(uid)
    local newUid = TomTom:AddWaypoint(m, newX / 100, newY / 100, {
        title        = title,
        source       = "WayBook",
        persistent   = true,
        crazy        = false,
        cleardistance = KeepOnArrivalEnabled() and 0
            or (WayBookDB.savedClearDistance or K.DEFAULT_CLEAR_DISTANCE),
    })

    if newUid then
        if note then SetNote(newUid, note) end
        if #tags > 0 then SetTags(newUid, tags) end
        if visitCount > 0 then
            WayBookDB.visits = WayBookDB.visits or {}
            WayBookDB.visits[NoteKey(newUid)] = { count = visitCount, last = visitLast }
        end
    end

    if wasActive and newUid then
        TomTom:SetCrazyArrow(newUid, TomTom.profile.arrow.arrival, title)
    end

    return newUid
end

-- Held in an upvalue rather than passed through StaticPopup's data field,
-- which is plumbed differently across client versions.
local deleteTarget

StaticPopupDialogs["WAYBOOK_DELETE"] = {
    text = "Delete this waypoint?\n\n|cff40ff40%s|r\n\nIts note, tags and visit history go with it.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3,
    OnAccept = function()
        if deleteTarget then DeleteWaypoint(deleteTarget) end
        deleteTarget = nil
    end,
    OnCancel = function() deleteTarget = nil end,
}

function PromptDelete(entry)
    deleteTarget = entry
    StaticPopup_Show("WAYBOOK_DELETE", entry.title)
end

function PromptShare(entry)
    if not (shareFrame and shareFrame.SetEntry) then return end
    shareFrame:SetEntry(entry)
    shareFrame:Show()
end

function PromptEdit(entry)
    if not (editFrame and editFrame.SetEntry) then return end
    editFrame:SetEntry(entry)
    editFrame:Show()
end

-- WoW exposes no API for another unit's world position: UnitPosition only
-- answers for you and your own group, and returns nil for an NPC. So this
-- banks YOUR coordinates under the target's name, which is the same thing
-- when you are standing at the NPC. With no target, it saves your position
-- under a placeholder title and opens the Edit window straight into the
-- label field, rather than leaving it untitled - the button always adds
-- something, target or not.
-- Ask the next Refresh to scroll this waypoint into view.
--
-- A brand-new waypoint can easily land inside a group the user has collapsed,
-- in which case no row exists to scroll to at all, so the containing group is
-- forced open first. Which group that is depends on the grouping mode: the
-- zone name when grouped by zone, and K.UNTAGGED when grouped by tag, since
-- nothing freshly created carries a tag yet.
--
-- Does nothing while the list window is closed - there is no scroll position
-- to move, and leaving the request pending would make the list jump the next
-- time the window happened to open.
-- Tags derived from whatever is currently targeted, applied once at the
-- moment a waypoint is created from that target. Deliberately inline in
-- AddTargetWaypoint rather than on a hook: a hook on TomTom:AddWaypoint would
-- fire for every waypoint from every source, and these are only ever meant to
-- land on one you deliberately added from a target. Nothing on arrival, on
-- clicking a row, or on any other creation path touches tags.
--
-- UnitClassification is reliable on any targetable NPC. Note that it says
-- nothing about what an NPC *does* - vendor, trainer, banker and the rest are
-- not exposed on a target at all, only at interaction time, which is a
-- separate mechanism entirely.
--
-- UnitFactionGroup was tried here in 1.26.14 and removed in 1.26.15. For NPCs
-- it only answers for factions closely allied with Alliance or Horde, and
-- returns nil for everything else (goblins are the documented example), so it
-- tagged some waypoints and silently skipped most. A tag you cannot trust the
-- absence of is worse than no tag.
-- One table instead of nine file-scope locals. Lua caps a function at 200
-- locals and the main chunk had reached exactly that; the next one added
-- stopped the file compiling outright. See the gotcha in HANDOFF.md.
local AutoTag = {}

AutoTag.CLASSIFICATION = {
    rare      = { "Rare" },
    rareelite = { "Rare", "Elite" },
    elite     = { "Elite" },
    worldboss = { "Elite" },
    -- "normal" is absent on purpose: tagging everything ordinary as ordinary
    -- would put a tag on almost every waypoint and say nothing.
}

-- Reputation faction, read off the target's own tooltip.
--
-- No API maps an NPC to its reputation faction. C_Reputation only enumerates
-- the player's own standings, and UnitFactionGroup answers a different
-- question badly (see above). The tooltip does carry it: probing Gina Mudclaw
-- on this client returned name / "Tillers Quartermaster" / "Level 90" /
-- "The Tillers".
--
-- That position is not fixed - an NPC with no subtitle shifts every line up
-- by one, and a hostile one may have no faction line at all - so this matches
-- text against the set of faction names the player actually knows rather than
-- reading a line number. Matching that way is also what stops a subtitle or a
-- creature type from becoming a junk tag: anything that is not an exact
-- faction name is ignored.
--
-- Coverage is bounded by what the reputation list returns, which is factions
-- the player has encountered, and excludes any under a collapsed header in
-- the reputation UI. A miss produces no tag rather than a wrong one, so this
-- is left alone instead of expanding the player's own headers behind them.

-- Only a corroborating signal now, never the thing the match depends on.
--
-- This was the primary mechanism until 1.26.18, and it half worked: the
-- reputation list only enumerates rows that are *visible*, so a faction
-- sitting under a collapsed header in the reputation pane is simply absent.
-- Kik'tik's tooltip read "The Klaxxi" exactly, with no stray whitespace,
-- and still failed to tag while Gina Mudclaw's "The Tillers" succeeded -
-- the difference was which header happened to be expanded.
--
-- Note C_Reputation.GetNumFactions does not exist on this client even though
-- C_Reputation itself does, hence the fallback to the global.
function AutoTag.KnownFactionNames()
    local names = {}
    local getData = (C_Reputation and C_Reputation.GetFactionDataByIndex)
        or function(i)
            local name = GetFactionInfo(i)
            return name and { name = name } or nil
        end
    local getNum = (C_Reputation and C_Reputation.GetNumFactions) or GetNumFactions
    if not getNum then return names end
    for i = 1, (getNum() or 0) do
        local data = getData(i)
        -- Headers are kept too: a few of them carry reputation in their own
        -- right, and an exact-match lookup makes including them costless.
        if data and data.name then names[data.name] = true end
    end
    return names
end

-- The localized word the tooltip's level line starts with, used to tell a
-- level line apart from a subtitle. Derived from the game's own format string
-- rather than hardcoded, the same way Leatrix_Plus does it on this client.
AutoTag.LEVEL_WORD = TOOLTIP_UNIT_LEVEL
    and strtrim((TOOLTIP_UNIT_LEVEL:gsub("%%s", "")))
    or LEVEL or "Level"

-- Some faction names carry an article the game shows but nobody says: "The
-- Tillers", "The Klaxxi". Dropped so the tag reads the way the faction is
-- actually referred to, and so it lines up with tags defined by hand.
function AutoTag.StripArticle(name)
    return (name:gsub("^The%s+", ""))
end

-- An NPC's subtitle is usually its faction plus its role, "Tillers
-- Quartermaster". The faction is already its own tag, so only the role is new
-- information here. Removed with a plain find rather than a pattern, because
-- faction names contain characters Lua patterns treat as magic - "Shado-Pan"
-- would otherwise match far more than intended.
function AutoTag.RoleFromSubtitle(subtitle, faction, factionTag)
    local text = subtitle
    -- Longest form first, so "The Tillers Quartermaster" loses the whole
    -- faction rather than being left holding a stray "The".
    for _, name in ipairs({ faction, factionTag }) do
        if name and name ~= "" then
            local at = text:find(name, 1, true)
            if at then
                text = text:sub(1, at - 1) .. text:sub(at + #name)
            end
        end
    end
    -- Trims whatever the removal left behind at either end, punctuation
    -- included, so a possessive like "Tillers' Quartermaster" does not come
    -- back as "' Quartermaster".
    text = (text:gsub("^[%s%p]+", ""))
    text = (text:gsub("[%s%p]+$", ""))
    if text == "" then return nil end
    return text
end

-- A tooltip line carrying a percentage is a live status readout, not part of
-- the unit's identity. "100% Threat" shows up while you are in combat with
-- the unit and went straight into the tag list as if it were a subtitle.
--
-- There is no localized global for that line on this client - checked, and
-- the only THREAT constants installed here are quest names - so this keys off
-- the percent sign, which survives translation where matching the English
-- word would not.
--
-- Applied to both the subtitle and the faction candidate. Which of the two
-- slots the threat line actually landed in is not distinguishable from the
-- symptom, and rejecting it in both costs nothing.
function AutoTag.IsStatusLine(text)
    return text:find("%%") ~= nil
end

-- Reads the target's tooltip once and returns both the faction line and the
-- subtitle, since finding either needs the whole populated tooltip anyway.
function AutoTag.ScanTargetTooltip()
    if not AutoTag.scanTooltip then
        AutoTag.scanTooltip = CreateFrame("GameTooltip", "WayBookScanTooltip", UIParent,
            "GameTooltipTemplate")
    end
    AutoTag.scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    AutoTag.scanTooltip:ClearLines()
    AutoTag.scanTooltip:SetUnit("target")

    local lines, levelAt = {}, nil
    -- From line 2: line 1 is always the unit's own name, and skipping it
    -- stops an NPC named after its faction from tagging itself off its title.
    for i = 2, AutoTag.scanTooltip:NumLines() do
        local line = _G["WayBookScanTooltipTextLeft" .. i]
        local text = line and line:GetText()
        lines[i] = (text ~= "" and text) or nil
        if lines[i] and not levelAt and lines[i]:find(AutoTag.LEVEL_WORD, 1, true) then
            levelAt = i
        end
    end

    -- The level line is the spine of an NPC tooltip. Everything before it is
    -- name and optional subtitle; the faction, when there is one, is the line
    -- straight after it. Both probes on this client agree:
    --
    --   Gina Mudclaw / Tillers Quartermaster / Level 90 / The Tillers
    --   Kik'tik      / Flight Master         / Level 90 / The Klaxxi
    --
    -- Reading position rather than matching against the player's reputation
    -- list means a faction still tags when it is collapsed out of that list,
    -- or has never been encountered at all.
    local subtitle = (levelAt ~= 2) and lines[2] or nil
    local faction = levelAt and lines[levelAt + 1] or nil
    if subtitle and AutoTag.IsStatusLine(subtitle) then subtitle = nil end
    if faction and AutoTag.IsStatusLine(faction) then faction = nil end

    -- Fall back to a reputation-list match anywhere in the tooltip if the
    -- structural read came up empty - a tooltip with no level line at all
    -- would otherwise yield nothing.
    if not faction then
        local known = AutoTag.KnownFactionNames()
        for i = 2, AutoTag.scanTooltip:NumLines() do
            if lines[i] and known[lines[i]] then
                faction = lines[i]
                break
            end
        end
    end

    return faction, subtitle
end

function AutoTag.TargetAutoTags()
    local tags = {}
    for _, tagName in ipairs(AutoTag.CLASSIFICATION[UnitClassification("target") or ""] or {}) do
        tags[#tags + 1] = tagName
    end

    local faction, subtitle = AutoTag.ScanTargetTooltip()
    local factionTag = faction and AutoTag.StripArticle(faction)
    if factionTag and factionTag ~= "" then tags[#tags + 1] = factionTag end

    if subtitle then
        local role = AutoTag.RoleFromSubtitle(subtitle, faction, factionTag)
        if role then tags[#tags + 1] = role end
    end
    return tags
end

local function ScrollToWaypoint(uid)
    if not (uid and frame and frame:IsShown()) then return end
    local mode = GroupMode()
    if mode == "zone" then
        SetCollapsed(ZoneName(uid[1]), nil)
    elseif mode == "tag" then
        -- Read the tags rather than assuming Untagged: a waypoint added from
        -- a target arrives already carrying its auto-tags, so it lands under
        -- those headers and never appears in Untagged at all.
        local tags = GetTags(uid)
        if #tags == 0 then
            SetCollapsed(K.UNTAGGED, nil)
        else
            for _, tagName in ipairs(tags) do SetCollapsed(tagName, nil) end
        end
    end
    pendingScrollUid = uid
end

local function AddTargetWaypoint()
    local m, x, y = TomTom:GetCurrentPlayerPosition()
    if not (m and x and y) then
        Print("Could not work out your position here.")
        return
    end

    if not UnitExists("target") then
        local uid = TomTom:AddWaypoint(m, x, y, {
            title        = "New waypoint",
            source       = "WayBook",
            persistent   = true,
            crazy        = false,
            cleardistance = KeepOnArrivalEnabled() and 0
                or (WayBookDB.savedClearDistance or K.DEFAULT_CLEAR_DISTANCE),
        })
        if uid then PromptEdit({ uid = uid, title = "New waypoint" }) end
        return uid
    end

    local name = UnitName("target")
    if not name or name == "" then
        Print("Could not read the target's name.")
        return
    end

    -- Read while the target is definitely still selected, before anything
    -- else happens.
    local autoTags = AutoTag.TargetAutoTags()

    local uid = TomTom:AddWaypoint(m, x, y, {
        title        = name,
        source       = "WayBook",
        persistent   = true,
        crazy        = false,   -- you are already standing on it
        cleardistance = KeepOnArrivalEnabled() and 0
            or (WayBookDB.savedClearDistance or K.DEFAULT_CLEAR_DISTANCE),
    })
    if uid then
        -- Through DefineTag so the master list picks them up with its usual
        -- case-insensitive dedup - an existing "rare" is reused rather than
        -- sitting alongside a second "Rare".
        local applied = {}
        for _, tagName in ipairs(autoTags) do
            local canonical = DefineTag(tagName)
            if canonical then
                ToggleTag(uid, canonical, true)
                applied[#applied + 1] = canonical
            end
        end
        -- Tagged before scrolling, so the group this lands under is the one
        -- ScrollToWaypoint opens.
        ScrollToWaypoint(uid)
        if #applied > 0 then
            Print(("Saved %s. Tagged %s."):format(name, table.concat(applied, ", ")))
        else
            Print(("Saved %s."):format(name))
        end
    end
    return uid
end

local function ClearArrow()
    if TomTom:IsCrazyArrowEmpty() then
        return
    end
    TomTom:SetCrazyArrow(nil)
end

local function MinimapShown()
    return not (WayBookDB and WayBookDB.minimap and WayBookDB.minimap.hide)
end

local function SetMinimapShown(show)
    local icon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not (icon and WayBookDB.minimap) then return end
    WayBookDB.minimap.hide = not show
    if show then icon:Show("WayBook") else icon:Hide("WayBook") end
end

local function AutoCollapseEnabled()
    return Setting("autoCollapse", false)
end

-- The bar's own visibility tracks this setting directly, independent of
-- whatever collapse/expand cycle the main window is currently in - see the
-- Collapse bar section below.
local function SetAutoCollapse(show)
    WayBookDB.autoCollapse = show and true or false
    if barFrame then
        if WayBookDB.autoCollapse then barFrame:Show() else barFrame:Hide() end
    end
    -- Flipping the checkbox while the main window happens to already be open
    -- has to take effect immediately, not just on the window's next OnShow.
    if WayBookDB.autoCollapse then
        if frame and frame:IsShown() then StartCollapseWatcher() end
    else
        StopCollapseWatcher()
    end
end

--------------------------------------------------------------------------
-- Arrive-and-clear
--
-- TomTom only ever drops the arrow as a side effect of deleting the waypoint
-- (_both_clear_distance in TomTom.lua calls RemoveWaypoint). This watches the
-- arrow's own target and clears just the arrow, leaving the waypoint in place.
--------------------------------------------------------------------------

local leftTheArea, visitRecorded, sinceCheck = false, false, 0
local StartWatching

local function StopWatching()
    WayBook:SetScript("OnUpdate", nil)
end

local function WatchArrow(_, elapsed)
    sinceCheck = sinceCheck + elapsed
    if sinceCheck < K.CHECK_INTERVAL then return end
    sinceCheck = 0

    if type(activeArrow) ~= "table" or not TomTom:IsValidWaypoint(activeArrow) then
        StopWatching()
        return
    end

    -- nil means another continent or an instance, so there is nothing to judge.
    local dist = TomTom:GetDistanceToWaypoint(activeArrow)
    if not dist then return end

    local threshold = ArriveDistance()
    if dist > math.max(threshold, K.VISIT_DISTANCE) then
        leftTheArea = true
        return
    end

    -- Same two guards TomTom uses: don't fire if the arrow was set while we
    -- were already standing there, and don't fire while flying over.
    if not leftTheArea or UnitOnTaxi("player") then return end

    if not visitRecorded and dist <= K.VISIT_DISTANCE then
        visitRecorded = true
        local count = RecordVisit(activeArrow)
        Print(("Reached %s. Visit %d."):format(activeArrow.title or "waypoint", count or 1))
        WayBook:Refresh()
    end

    if threshold > 0 and dist <= threshold then
        TomTom:SetCrazyArrow(nil)
        StopWatching()
    end
end

-- Runs whenever the arrow has a target, not only when arrow-clearing is on,
-- because visits are tracked independently of that setting.
function StartWatching()
    leftTheArea = false
    visitRecorded = false
    sinceCheck = 0
    if activeArrow then
        WayBook:SetScript("OnUpdate", WatchArrow)
    else
        StopWatching()
    end
end

local function TrackArrow(_, uid)
    activeArrow = (type(uid) == "table") and uid or nil
    -- Corpse runs have their own sticky handling in TomTom. Leave them be.
    if activeArrow and activeArrow.corpse then
        activeArrow = nil
    end
    StartWatching()
end

--------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------

-- Fixed at 7pt regardless of the list font-size slider: small badges are
-- wanted here specifically, not badges that scale with everything else.
-- Captured once from GameFontNormalSmall's own file/flags so the
-- badge text still matches the rest of the list's typeface.
K.BADGE_FONT_SIZE = 7
K.BADGE_HEIGHT     = 12   -- background + text, one badge line
K.BADGE_PADDING    = 4    -- horizontal padding inside a badge's background
K.BADGE_GAP        = 4    -- gap between adjacent badges
K.BADGE_ROW_GAP    = 2    -- gap between the label line and the badge line
K.BADGE_EDGE_SIZE  = 4    -- UI-Tooltip-Border's edge thickness, scaled down for a small pill
K.BADGE_INSET      = 1
local badgeFontFile, badgeFontFlags

-- WoW's own Quest Log window icon (the blue book) - confirmed by dumping
-- QuestLogFrame's texture regions in game and visually checking fileID 136797
-- with a temporary preview frame. Blizzard doesn't expose this as a named
-- atlas, only as a bare file ID, so there is no string path to reference
-- instead. Shown next to any row whose waypoint carries the "Quest" tag -
-- see IsQuestTagged - not tied to Questie or any other detection.
K.QUEST_TAG_ICON = 136797
K.QUEST_ICON_GAP = 3   -- matches the gap row.del already keeps before row.text

local function BadgeFont()
    if not badgeFontFile then
        local probe = UIParent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        badgeFontFile, _, badgeFontFlags = probe:GetFont()
        probe:Hide()
    end
    return badgeFontFile, K.BADGE_FONT_SIZE, badgeFontFlags
end

-- One badge = a small rounded pill sized to fit its own text, plus the text
-- itself on top. UI-Tooltip-Border's corner art is what gives it rounded
-- corners for free - no custom texture asset to ship - scaled down with a
-- thin edge and tight insets so it reads as a pill rather than a dialog.
-- Pooled per row the same way entry/header rows pool against the whole list,
-- since the number of tags per waypoint varies row to row and refresh to
-- refresh.
local function AcquireBadge(row, index)
    local badge = row.badges[index]
    if badge then return badge end

    badge = CreateFrame("Frame", nil, row, BackdropTemplateMixin and "BackdropTemplate" or nil)
    badge:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = K.BADGE_EDGE_SIZE,
        insets = { left = K.BADGE_INSET, right = K.BADGE_INSET, top = K.BADGE_INSET, bottom = K.BADGE_INSET },
    })
    do
        local r, g, b = HexToRGB(K.COLOR_TAG)
        badge:SetBackdropColor(r, g, b, 0.16)
        badge:SetBackdropBorderColor(r, g, b, 0.8)
    end

    badge.text = badge:CreateFontString(nil, "ARTWORK")
    badge.text:SetPoint("CENTER", badge, "CENTER", 0, 0)
    local file, size, flags = BadgeFont()
    badge.text:SetFont(file, size, flags)
    badge.text:SetTextColor(HexToRGB(K.COLOR_TAG))

    row.badges[index] = badge
    return badge
end

-- Lays out every tag as its own badge along one line under the label line,
-- left to right. Returns the height that line needs, 0 when there is nothing
-- to show, so the caller can grow the row by exactly that much and no more.
local function LayoutBadges(row, tags)
    if not (tags and #tags > 0) then
        for _, badge in ipairs(row.badges) do badge:Hide() end
        return 0
    end

    -- Lines up under the label text rather than the delete button: same
    -- left edge row.text itself uses (row.del's width, plus its own 2px
    -- inset, plus the 3px gap between the button and the text). Whoever
    -- called this must set row.questIcon's shown/hidden state and size
    -- first (see the entry-row refresh loop) - read here, not recomputed,
    -- so badges never drift out from under row.text when the icon shows.
    local x = row.del:GetWidth() + 2 + 3
    if row.questIcon:IsShown() then
        x = x + row.questIcon:GetWidth() + K.QUEST_ICON_GAP
    end
    for i, tagName in ipairs(tags) do
        local badge = AcquireBadge(row, i)
        badge.text:SetText(tagName)
        local w = badge.text:GetStringWidth() + K.BADGE_PADDING * 2
        badge:SetSize(w, K.BADGE_HEIGHT)
        badge:ClearAllPoints()
        badge:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", x, -K.BADGE_ROW_GAP)
        badge:Show()
        x = x + w + K.BADGE_GAP
    end
    for i = #tags + 1, #row.badges do
        row.badges[i]:Hide()
    end

    return K.BADGE_ROW_GAP + K.BADGE_HEIGHT
end

local function AcquireEntryRow(index)
    local row = entryRows[index]
    if row then return row end

    row = CreateFrame("Button", nil, content)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- A row can be taller than one text line once tag badges are showing
    -- underneath, but the label line itself - the delete button, the text,
    -- the distance reading - should never drift from the top of it. label
    -- is a fixed-height (RowHeight()) slice pinned to the row's own top, so
    -- everything anchored against label instead of row keeps behaving
    -- exactly like a single-height row regardless of how tall row grows.
    row.label = CreateFrame("Frame", nil, row)
    row.label:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.label:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row.badges = {}

    -- Delete affordance. A child button, so its clicks never reach the row.
    row.del = CreateFrame("Button", nil, row)
    row.del:SetPoint("LEFT", row.label, "LEFT", 2, 0)
    row.del.text = row.del:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.del.text:SetPoint("CENTER", row.del, "CENTER", 0, 0)
    row.del.text:SetText("|cffff5555-|r")
    StyleFont(row.del.text, "GameFontNormalSmall")

    -- Quest-tag icon. Sized and positioned fresh every refresh (see below),
    -- since whether it shows at all varies row to row - starts hidden here
    -- just to have a real object for LayoutBadges to query before the first
    -- refresh ever sets it one way or the other.
    row.questIcon = row:CreateTexture(nil, "ARTWORK")
    row.questIcon:SetTexture(K.QUEST_TAG_ICON)
    row.questIcon:Hide()

    -- Right-justified against the row's own right edge, so every reading in the
    -- column ends on the same pixel however wide the number is. No width is set:
    -- the string sizes to its text, and row.text then anchors to whatever left
    -- edge that leaves, which keeps the two from overlapping at any font size.
    row.dist = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.dist:SetPoint("RIGHT", row.label, "RIGHT", -4, 0)
    row.dist:SetJustifyH("RIGHT")
    row.dist:SetWordWrap(false)
    StyleFont(row.dist, "GameFontNormalSmall")

    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.text:SetPoint("RIGHT", row.label, "RIGHT", -4, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    StyleFont(row.text, "GameFontNormalSmall")

    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints()
    Tint(row.highlight, 1, 1, 1, 0.12)
    row.highlight:Hide()

    row:SetScript("OnEnter", function(self)
        self.highlight:Show()
        if not self.entry then return end
        local e = self.entry
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(e.title, 0.25, 1, 0.25)
        if e.tags and #e.tags > 0 then
            GameTooltip:AddLine(table.concat(e.tags, ", "), HexToRGB(K.COLOR_TAG))
        end
        GameTooltip:AddLine(e.zone, 0.8, 0.8, 0.8)
        GameTooltip:AddLine(("%.1f, %.1f"):format(e.x, e.y), 1, 1, 1)
        -- Read live rather than off the cached entry, so a hover always shows
        -- the current figure even between ticks.
        local dist = DistanceTo(e.uid)
        if dist then
            GameTooltip:AddLine(("%d yards away"):format(math.floor(dist + 0.5)), 0.7, 0.7, 0.7)
        else
            GameTooltip:AddLine("Not on this continent", 0.7, 0.7, 0.7)
        end
        local count, last = GetVisits(e.uid)
        if count > 0 then
            GameTooltip:AddLine(("Visited %d time%s, last %s")
                :format(count, count == 1 and "" or "s", AgoText(last)), 0.6, 0.8, 1)
        end
        local note = GetNote(e.uid)
        if note then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(note, 1, 0.82, 0, true)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left-click to set the arrow", 0.6, 0.6, 0.6)
        GameTooltip:AddLine("Shift-click to copy or share it", 0.6, 0.6, 0.6)
        GameTooltip:AddLine("Right-click to edit it", 0.6, 0.6, 0.6)
        GameTooltip:AddLine("The red minus deletes it", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)

    row:SetScript("OnLeave", function(self)
        self.highlight:Hide()
        GameTooltip:Hide()
    end)

    row:SetScript("OnClick", function(self, button)
        if not self.entry then return end
        if button == "RightButton" then
            PromptEdit(self.entry)
        elseif IsShiftKeyDown() then
            PromptShare(self.entry)
        else
            ActivateWaypoint(self.entry)
        end
    end)

    -- Keep the row highlight up while the pointer is on the child button, so
    -- it stays obvious which line the minus belongs to.
    row.del:SetScript("OnEnter", function(self)
        local parent = self:GetParent()
        parent.highlight:Show()
        if not parent.entry then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Delete waypoint")
        GameTooltip:AddLine(parent.entry.title, 1, 1, 1)
        GameTooltip:AddLine("You will be asked to confirm.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    row.del:SetScript("OnLeave", function(self)
        self:GetParent().highlight:Hide()
        GameTooltip:Hide()
    end)
    row.del:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        if parent.entry then PromptDelete(parent.entry) end
    end)

    entryRows[index] = row
    return row
end

local function AcquireHeaderRow(index)
    local row = headerRows[index]
    if row then return row end

    row = CreateFrame("Button", nil, content)
    row:RegisterForClicks("LeftButtonUp")

    -- Banded background, tinted per group to match the header text color.
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()

    row.toggle = CreateFrame("Button", nil, row)
    row.toggle:SetSize(14, 14)
    row.toggle:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.toggle.text = row.toggle:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.toggle.text:SetPoint("CENTER", row.toggle, "CENTER", 0, 0)
    StyleFont(row.toggle.text, "GameFontNormalSmall")

    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", row.toggle, "RIGHT", 4, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    StyleFont(row.text, "GameFontNormalSmall")

    local function Flip(self)
        local owner = self.owner or self
        if not owner.groupKey then return end
        SetCollapsed(owner.groupKey, not Collapsed(owner.groupKey))
        WayBook:Refresh()
    end

    row.toggle.owner = row
    row.toggle:SetScript("OnClick", Flip)
    row:SetScript("OnClick", Flip)

    headerRows[index] = row
    return row
end

-- Distances go stale the moment you move, so the list re-reads them on a timer
-- while it is open. Only while something on screen actually depends on them:
-- with the column off and the sort on anything else, nothing here runs.
local distanceTicker

local function UpdateDistanceTicker()
    local wanted = frame and frame:IsShown()
        and (ShowDistance() or SortMode() == "distance")

    if wanted and not distanceTicker then
        distanceTicker = C_Timer.NewTicker(K.DISTANCE_INTERVAL, function()
            WayBook:Refresh()
        end)
    elseif not wanted and distanceTicker then
        distanceTicker:Cancel()
        distanceTicker = nil
    end
end

function WayBook:Refresh()
    UpdateDistanceTicker()
    if not frame or not frame:IsShown() then return end

    BuildDisplay()

    local rh = RowHeight()
    local grouped = GroupMode() ~= "none"
    local indent = grouped and K.ZONE_INDENT or 0
    local usedEntry, usedHeader = 0, 0
    -- Deliberate: redundant while grouped by tag, since a multi-tagged
    -- waypoint already shows up once under each of its tags' headers (see
    -- BuildTagDisplay) - repeating the same tags as badges under every one
    -- of those occurrences just echoes what the headers already say.
    local showTags = ShowTags() and not GroupByTag()
    -- Header rows are always exactly rh tall; entry rows grow by the badge
    -- line's height when they are showing tags, so positions accumulate
    -- rather than stepping by a single constant.
    local y = 0
    local scrollTargetY

    for _, line in ipairs(display) do
        if line.kind == "header" then
            usedHeader = usedHeader + 1
            local row = AcquireHeaderRow(usedHeader)
            row.groupKey = line.groupKey
            row:SetHeight(rh)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, y)
            local r, g, b = HexToRGB(line.color)
            Tint(row.bg, r, g, b, K.ZONE_BAND_ALPHA)
            -- The glyph has to agree with what is actually drawn, and a search
            -- forces every group open regardless of its saved state.
            local folded = Collapsed(line.groupKey) and not Searching()
            row.toggle.text:SetText(folded and "+" or "-")
            row.text:SetText(("|cff%s%s|r |cff999999(%d)|r")
                :format(line.color, line.groupKey, line.count))
            row:Show()
            y = y - rh
        else
            usedEntry = usedEntry + 1
            local row = AcquireEntryRow(usedEntry)
            local entry = line.entry

            -- The minus (and the quest icon, sized to match it) track the row
            -- height so neither overflows a short row.
            local btn = math.min(14, rh - 1)
            row.del:SetSize(btn, btn)

            local isQuest = IsQuestTagged(entry.tags)
            row.questIcon:SetSize(btn, btn)
            row.questIcon:ClearAllPoints()
            row.questIcon:SetPoint("LEFT", row.del, "RIGHT", K.QUEST_ICON_GAP, 0)
            if isQuest then row.questIcon:Show() else row.questIcon:Hide() end

            -- LayoutBadges reads row.questIcon's shown/hidden state and size
            -- to line badges up under row.text, so it has to run after the
            -- icon is set up above, not before.
            local tags = showTags and entry.tags or nil
            local badgeHeight = LayoutBadges(row, tags)

            row.label:SetHeight(rh)
            row:SetHeight(rh + badgeHeight)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", indent, y)
            row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, y)
            -- y is this row's own top edge, so -y is its distance below the
            -- top of the scroll child - which is exactly the scroll offset
            -- that brings it to the top of the visible area. Captured here
            -- rather than computed afterwards because rows vary in height,
            -- so there is no index-times-row-height shortcut to fall back on.
            if pendingScrollUid and entry.uid == pendingScrollUid then
                scrollTargetY = -y
            end
            row.entry = entry
            row.text:ClearAllPoints()
            if isQuest then
                row.text:SetPoint("LEFT", row.questIcon, "RIGHT", K.QUEST_ICON_GAP, 0)
            else
                row.text:SetPoint("LEFT", row.del, "RIGHT", 3, 0)
            end
            if ShowDistance() then
                row.dist:SetText(DistanceText(entry.distance))
                row.dist:Show()
                row.text:SetPoint("RIGHT", row.dist, "LEFT", -6, 0)
            else
                row.dist:Hide()
                row.text:SetPoint("RIGHT", row.label, "RIGHT", -4, 0)
            end
            row.text:SetText(RowText(entry))
            row:Show()
            y = y - (rh + badgeHeight)
        end
    end

    for i = usedEntry + 1, #entryRows do
        entryRows[i].entry = nil
        LayoutBadges(entryRows[i], nil)
        entryRows[i]:Hide()
    end
    for i = usedHeader + 1, #headerRows do
        headerRows[i].groupKey = nil
        headerRows[i]:Hide()
    end

    content:SetHeight(math.max(-y, 1))

    -- Consumed on the next refresh whether or not a row was actually found:
    -- a waypoint the search box currently filters out has no row to scroll
    -- to, and leaving the request pending would fire it at some unrelated
    -- later refresh instead.
    if pendingScrollUid then
        if scrollTargetY then
            -- The scroll range is derived from the child's size, which only
            -- just changed on the line above - without this the clamp below
            -- reads the previous rebuild's maximum.
            scrollFrame:UpdateScrollChildRect()
            local maxScroll = math.max(0, content:GetHeight() - scrollFrame:GetHeight())
            scrollFrame:SetVerticalScroll(math.min(scrollTargetY, maxScroll))
        end
        pendingScrollUid = nil
    end

    if entryTotal == 0 then
        countText:SetText("|cff999999No waypoints saved. Press Add Waypoint to save one here.|r")
    elseif Searching() then
        if #entries == 0 then
            countText:SetText(("|cffff8080Nothing matches \"%s\".|r"):format(searchQuery))
        else
            countText:SetText(("|cff999999%d of %d waypoints match \"%s\"|r")
                :format(#entries, entryTotal, searchQuery))
        end
    else
        countText:SetText(("|cff999999%d waypoint%s|r")
            :format(#entries, #entries == 1 and "" or "s"))
    end
end

-- Several TomTom calls can fire in a burst; coalesce them into one refresh.
local function QueueRefresh()
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0, function()
        refreshPending = false
        WayBook:Refresh()
    end)
end

--------------------------------------------------------------------------
-- Options window
--------------------------------------------------------------------------

local function MakeCheck(parent, name, label, x, y, getter, setter)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local text = cb.Text or cb.text or _G[name .. "Text"]
    if text then
        text:SetText(label)
    end
    cb:SetScript("OnClick", function(self)
        setter(self:GetChecked() and true or false)
        -- Group-by lives in two places since 1.26.8 (Options and the main
        -- window's own row), so every click has to re-sync both sets, not
        -- just the panel it was made in.
        RefreshOptions()
        RefreshMainControls()
        WayBook:Refresh()
    end)
    cb.Sync = function() cb:SetChecked(getter() and true or false) end
    return cb
end

local function MakeSlider(parent, name, label, x, y, minV, maxV, step, getter, setter)
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    s:SetWidth(250)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end

    local title = _G[name .. "Text"]
    local low   = _G[name .. "Low"]
    local high  = _G[name .. "High"]
    if low  then low:SetText(tostring(minV)) end
    if high then high:SetText(tostring(maxV)) end

    s.Sync = function()
        local v = getter()
        s.settingValue = true
        s:SetValue(v)
        s.settingValue = false
        if title then title:SetText(("%s: %g"):format(label, v)) end
    end

    s:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        if title then title:SetText(("%s: %g"):format(label, value)) end
        if self.settingValue then return end
        setter(value)
    end)

    return s
end

-- A bright, distinctly-colored label, so the four section
-- headings (General / Group by: / Show in the list: / Sort by:) read as
-- structure rather than blending into the checkbox labels below them, which
-- keep the template's own default yellow. No background band - removed on
-- request; color alone carries the distinction now.
K.SECTION_HEADING_COLOR = { 0.65, 0.85, 1 }

local function MakeSectionHeading(parent, x, y, text)
    local heading = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    heading:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    heading:SetText(text)
    heading:SetTextColor(K.SECTION_HEADING_COLOR[1], K.SECTION_HEADING_COLOR[2], K.SECTION_HEADING_COLOR[3])
    return heading
end

-- Grouping already prints the zone on every header, so the Zone column would
-- just repeat it on each row underneath. Turning grouping on stashes the
-- column's current state and switches it off; turning grouping off hands it
-- back exactly as it was.
local function SyncZoneColumn(grouping)
    if grouping then
        if WayBookDB.zoneColumnPreGroup == nil then
            WayBookDB.zoneColumnPreGroup = ShowZone() and true or false
        end
        WayBookDB.showZone = false
    elseif WayBookDB.zoneColumnPreGroup ~= nil then
        WayBookDB.showZone = WayBookDB.zoneColumnPreGroup
        WayBookDB.zoneColumnPreGroup = nil
    end
end

-- Same stash-and-restore for the Tags badges while grouping by tag.
--
-- This used to be deliberately absent, on the reasoning that a multi-tagged
-- waypoint's other tags were still new information when only its first one
-- named the header. That stopped being true in 1.22.1, when grouping by tag
-- became genuinely many-to-many: a waypoint now appears under a header for
-- every tag it owns, so the badges repeat what the headers already say from
-- every angle. Refresh has suppressed them since then; this makes the
-- checkbox itself reflect that instead of sitting there ticked and ignored.
local function SyncTagColumn(grouping)
    if grouping then
        if WayBookDB.tagColumnPreGroup == nil then
            WayBookDB.tagColumnPreGroup = ShowTags() and true or false
        end
        WayBookDB.showTags = false
    elseif WayBookDB.tagColumnPreGroup ~= nil then
        WayBookDB.showTags = WayBookDB.tagColumnPreGroup
        WayBookDB.tagColumnPreGroup = nil
    end
end

local function SetGroupMode(mode)
    WayBookDB.groupBy = mode
    SyncZoneColumn(mode == "zone")
    SyncTagColumn(mode == "tag")
end

-- At least one column has to stay visible or every row renders blank. Tags
-- are not part of this check: they are a badge toggle, not one of the
-- mutually-exclusive text columns.
local function SetColumn(key, value)
    WayBookDB[key] = value
    if not (ShowLabel() or ShowZone() or ShowCoords() or ShowVisits() or ShowDistance()) then
        WayBookDB.showLabel = true
        Print("At least one column has to stay on, so Label was switched back on.")
    end
end

--------------------------------------------------------------------------
-- Export window
--------------------------------------------------------------------------

local function BuildExportUI()
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil

    exportFrame = CreateFrame("Frame", "WayBookExportFrame", UIParent, template)
    exportFrame:SetSize(480, 420)
    exportFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    AddOpaqueBackground(exportFrame)
    exportFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    exportFrame:SetMovable(true)
    exportFrame:EnableMouse(true)
    exportFrame:RegisterForDrag("LeftButton")
    exportFrame:SetScript("OnDragStart", exportFrame.StartMoving)
    exportFrame:SetScript("OnDragStop", exportFrame.StopMovingOrSizing)
    exportFrame:SetClampedToScreen(true)
    -- Strictly above the Options window's own "DIALOG" strata, not just equal
    -- to it, since Options stays open behind this and same-strata ties do not
    -- reliably favour whichever frame opened last. That was the whole bug: an
    -- opaque backdrop still loses to a same-strata frame that wins the tie.
    exportFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    exportFrame:SetToplevel(true)
    exportFrame:Hide()

    tinsert(UISpecialFrames, "WayBookExportFrame")

    local title = exportFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOP", exportFrame, "TOP", 0, -16)
    title:SetText("WayBook Export")

    local close = CreateFrame("Button", nil, exportFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", exportFrame, "TOPRIGHT", -6, -6)

    -- The stock multi-line, scrollable text box. Confirmed present on this
    -- client via BagBrother, which uses it the same way: a plain EditBox
    -- inside a ScrollFrame does not wrap or scroll on its own.
    local scroll = CreateFrame("ScrollFrame", "WayBookExportScroll", exportFrame,
        "InputScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", exportFrame, "TOPLEFT", 20, -40)
    scroll:SetPoint("BOTTOMRIGHT", exportFrame, "BOTTOMRIGHT", -32, 20)
    -- No character limit on a read-back-never text dump, so the counter would
    -- have nothing meaningful to show. Set before OnLoad: that is what reads
    -- this flag, same as BagBrother's config editor does with this template.
    scroll.hideCharCount = true
    InputScrollFrame_OnLoad(scroll)

    local box = scroll.EditBox
    box:SetFontObject(ChatFontNormal)
    box:SetScript("OnEscapePressed", function() exportFrame:Hide() end)
    -- Editable rather than read-only: a read-only EditBox on this client also
    -- refuses Ctrl+A/Ctrl+C, and nothing here ever reads the text back, so an
    -- accidental keystroke costs nothing.
    box:SetScript("OnEditFocusLost", function(self) self:HighlightText() end)

    exportFrame.scroll = scroll
    exportFrame.box = box

    exportFrame:SetScript("OnShow", function(self)
        self:Raise()
        box:SetText(BuildExportText())
        box:SetCursorPosition(0)
        box:HighlightText()
        box:SetFocus()
    end)
end

local function ToggleExport()
    if not exportFrame then return end
    if exportFrame:IsShown() then exportFrame:Hide() else exportFrame:Show() end
end

--------------------------------------------------------------------------
-- Share window
--
-- Shift-click a row for this. Two boxes because WoW has no single action
-- that covers both purposes: the chat edit box treats a leading "/" as a
-- command, never as text to send, so the working /way line can only ever be
-- copied out, not transmitted as chat. Sending something over chat instead
-- means a second, plain-English line with the coordinates spelled out.
--------------------------------------------------------------------------

local function BuildShareUI()
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil

    shareFrame = CreateFrame("Frame", "WayBookShareFrame", UIParent, template)
    shareFrame:SetSize(420, 172)
    shareFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    AddOpaqueBackground(shareFrame)
    shareFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    shareFrame:SetMovable(true)
    shareFrame:EnableMouse(true)
    shareFrame:RegisterForDrag("LeftButton")
    shareFrame:SetScript("OnDragStart", shareFrame.StartMoving)
    shareFrame:SetScript("OnDragStop", shareFrame.StopMovingOrSizing)
    shareFrame:SetClampedToScreen(true)
    -- Same reasoning as the Export window: a same-strata tie against whatever
    -- else is open is not something to leave to chance.
    shareFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    shareFrame:SetToplevel(true)
    shareFrame:Hide()

    tinsert(UISpecialFrames, "WayBookShareFrame")

    local title = shareFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOP", shareFrame, "TOP", 0, -16)
    shareFrame.title = title

    local close = CreateFrame("Button", nil, shareFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", shareFrame, "TOPRIGHT", -6, -6)

    local copyLabel = shareFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    copyLabel:SetPoint("TOPLEFT", shareFrame, "TOPLEFT", 20, -42)
    copyLabel:SetText("Copy this to keep it, paste it elsewhere, or share it with someone "
        .. "who also has TomTom:")
    copyLabel:SetPoint("TOPRIGHT", shareFrame, "TOPRIGHT", -20, -42)
    copyLabel:SetJustifyH("LEFT")

    -- A single-line EditBox, not the multi-line template Export uses: one
    -- /way command never wraps, and InputBoxTemplate is the lighter widget
    -- for that. Highlighted on every show so Ctrl+C works immediately.
    local copyBox = CreateFrame("EditBox", "WayBookShareCopyBox", shareFrame, "InputBoxTemplate")
    copyBox:SetAutoFocus(false)
    copyBox:SetSize(370, 20)
    copyBox:SetPoint("TOP", shareFrame, "TOP", 2, -76)
    copyBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    copyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    copyBox:SetScript("OnEditFocusLost", function(self) self:HighlightText() end)
    shareFrame.copyBox = copyBox

    local chatBtn = CreateFrame("Button", nil, shareFrame, "UIPanelButtonTemplate")
    chatBtn:SetSize(170, 22)
    chatBtn:SetPoint("BOTTOM", shareFrame, "BOTTOM", 0, 20)
    chatBtn:SetText("Send to Chat")
    chatBtn:SetScript("OnClick", function()
        local box = ChatEdit_ChooseBoxForSend()
        ChatEdit_ActivateChat(box)
        box:Insert(shareFrame.chatLine or "")
    end)
    chatBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Send to Chat")
        GameTooltip:AddLine(
            "Puts the /way command into your chat box. A leading slash always runs as a " ..
            "command rather than sending, so pressing Enter there recreates the " ..
            "waypoint on your end rather than reaching anyone else's chat.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    chatBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    function shareFrame:SetEntry(entry)
        self.title:SetText(entry.title)
        self.copyBox:SetText(WayCommand(entry))
        self.chatLine = WayCommand(entry)
    end

    shareFrame:SetScript("OnShow", function(self)
        self:Raise()
        self.copyBox:SetCursorPosition(0)
        self.copyBox:SetFocus()
        self.copyBox:HighlightText()
    end)
end

--------------------------------------------------------------------------
-- Edit window
--
-- Right-click a row for this - label, note and tags together, replacing
-- what used to be three separate mechanisms (alt-click rename, plain
-- right-click note, ctrl-click tags). Consolidated down to just
-- left-click (activate) and right-click (edit); shift-click share stays.
--
-- Label and note commit on Enter or on losing focus, the same "apply as you
-- go" feel the tags list already had. Tags get two ways in: a dropdown of
-- everything already defined (add existing) and a text box (define new),
-- with the waypoint's current tags listed below as removable chips,
-- replacing the former standalone Tags window's full
-- checkbox-per-tag list, which does not scale as the master list grows.
--------------------------------------------------------------------------

-- One chip = a tag name plus a small red "x". No checkbox: membership here
-- is binary and one-directional (this waypoint has it or the x removes it),
-- unlike the old picker where every defined tag needed its own toggle.
-- Same rounded-pill look as a main-list badge (AcquireBadge), but a
-- Button, not a bare Frame, since the whole chip is the removal
-- control here: click it and it's gone, no separate "x". Wraps left to
-- right within the fixed-width chip area (see RefreshChips below); the
-- original one-tag-per-row list this replaced could not grow past about
-- three tags without drawing over "Define a new tag:" underneath it.
local function AcquireEditTagChip(pool, parent, index)
    local chip = pool[index]
    if chip then return chip end

    chip = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    chip:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = K.BADGE_EDGE_SIZE,
        insets = { left = K.BADGE_INSET, right = K.BADGE_INSET, top = K.BADGE_INSET, bottom = K.BADGE_INSET },
    })
    do
        local r, g, b = HexToRGB(K.COLOR_TAG)
        chip:SetBackdropColor(r, g, b, 0.16)
        chip:SetBackdropBorderColor(r, g, b, 0.8)
    end

    chip.text = chip:CreateFontString(nil, "ARTWORK")
    chip.text:SetPoint("CENTER", chip, "CENTER", 0, 0)
    local file, size, flags = BadgeFont()
    chip.text:SetFont(file, size, flags)
    chip.text:SetTextColor(HexToRGB(K.COLOR_TAG))

    chip:SetScript("OnEnter", function(self)
        local r, g, b = HexToRGB(K.COLOR_TAG)
        self:SetBackdropColor(r, g, b, 0.32)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Click to remove")
        GameTooltip:Show()
    end)
    chip:SetScript("OnLeave", function(self)
        local r, g, b = HexToRGB(K.COLOR_TAG)
        self:SetBackdropColor(r, g, b, 0.16)
        GameTooltip:Hide()
    end)

    pool[index] = chip
    return chip
end

local function BuildEditUI()
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil

    editFrame = CreateFrame("Frame", "WayBookEditFrame", UIParent, template)
    editFrame:SetSize(380, 260)
    editFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    AddOpaqueBackground(editFrame)
    editFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    editFrame:SetMovable(true)
    editFrame:EnableMouse(true)
    editFrame:RegisterForDrag("LeftButton")
    editFrame:SetScript("OnDragStart", editFrame.StartMoving)
    editFrame:SetScript("OnDragStop", editFrame.StopMovingOrSizing)
    editFrame:SetClampedToScreen(true)
    editFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    editFrame:SetToplevel(true)
    editFrame:Hide()

    tinsert(UISpecialFrames, "WayBookEditFrame")

    local title = editFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOP", editFrame, "TOP", 0, -16)
    editFrame.title = title

    local close = CreateFrame("Button", nil, editFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", editFrame, "TOPRIGHT", -6, -6)

    local labelHeading = editFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    labelHeading:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 20, -42)
    labelHeading:SetText("Label:")

    local labelBox = CreateFrame("EditBox", "WayBookEditLabelBox", editFrame, "InputBoxTemplate")
    labelBox:SetAutoFocus(false)
    labelBox:SetSize(330, 20)
    labelBox:SetMaxLetters(60)
    labelBox:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 26, -58)

    local noteHeading = editFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    noteHeading:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 20, -86)
    noteHeading:SetText("Note:")

    local noteBox = CreateFrame("EditBox", "WayBookEditNoteBox", editFrame, "InputBoxTemplate")
    noteBox:SetAutoFocus(false)
    noteBox:SetSize(330, 20)
    noteBox:SetMaxLetters(200)
    noteBox:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 26, -102)

    local coordHeading = editFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    coordHeading:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 20, -130)
    coordHeading:SetText("Coordinates:")

    local coordBox = CreateFrame("EditBox", "WayBookEditCoordBox", editFrame, "InputBoxTemplate")
    coordBox:SetAutoFocus(false)
    coordBox:SetSize(330, 20)
    coordBox:SetMaxLetters(20)
    coordBox:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 26, -146)

    local tagsHeading = editFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    tagsHeading:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 20, -174)
    tagsHeading:SetText("Tags:")

    -- Native Blizzard dropdown, no library - confirmed present and used this
    -- way (CreateFrame + UIDropDownMenu_Initialize/_AddButton) by Titan and
    -- others on this client. Lists whatever the waypoint does not already
    -- carry; picking one adds it immediately and closes the menu, the same
    -- "click it, done" feel as everything else in this window.
    local addTagDropdown = CreateFrame("Frame", "WayBookEditTagDropdown", editFrame,
        "UIDropDownMenuTemplate")
    addTagDropdown:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 4, -192)
    UIDropDownMenu_SetWidth(addTagDropdown, 150)
    UIDropDownMenu_SetText(addTagDropdown, "Add existing tag")

    -- Fixed-width, but never fixed-height: chips wrap within CHIP_AREA_WIDTH
    -- and RefreshChips grows the frame to fit however many rows that takes,
    -- rather than letting them run under the controls below.
    -- Declared once and used both to place the chip area and to work out
    -- where everything under it lands. RefreshChips used to repeat this
    -- number as a literal, which silently broke the whole lower half of the
    -- window the moment the Coordinates field pushed the chip area down in
    -- 1.26.8 - the chips ended up below "Define a new tag:" instead of above
    -- it, and the frame fell back to its minimum height with dead space at
    -- the bottom. Anything that needs the chip area's y reads this.
    local CHIP_AREA_Y = -230
    local CHIP_AREA_WIDTH = 330
    local CHIP_ROW_STEP = K.BADGE_HEIGHT + 6
    local GAP_AFTER_CHIPS = 20
    local GAP_HEADING_TO_BOX = 16
    local GAP_BEFORE_CLOSE = 16
    local CLOSE_BUTTON_HEIGHT = 22
    local BOTTOM_MARGIN = 20
    local MIN_FRAME_HEIGHT = 342   -- a floor only, not a target - the common
                                   -- zero/one-tag case should compute close to
                                   -- this on its own, not get padded up to it.
                                   -- 260 before 1.26.8; grew by the same 44
                                   -- the Coordinates field pushed everything
                                   -- below it down by.

    local chipContent = CreateFrame("Frame", nil, editFrame)
    chipContent:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 26, CHIP_AREA_Y)
    chipContent:SetSize(CHIP_AREA_WIDTH, 1)
    editFrame.chipContent = chipContent
    editFrame.chips = {}

    local newLabel = editFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    newLabel:SetText("Define a new tag:")

    local newBox = CreateFrame("EditBox", "WayBookEditNewTagBox", editFrame, "InputBoxTemplate")
    newBox:SetAutoFocus(false)
    newBox:SetSize(240, 20)
    newBox:SetMaxLetters(40)

    local addBtn = CreateFrame("Button", nil, editFrame, "UIPanelButtonTemplate")
    addBtn:SetSize(70, 22)
    addBtn:SetText("Add")

    -- Positioned by RefreshChips rather than here, since everything below the
    -- chip area moves with however many rows the chips wrapped onto. Hiding
    -- the frame runs the same OnHide the X does, so the label, note and
    -- coordinates all commit on the way out.
    local closeBtn = CreateFrame("Button", nil, editFrame, "UIPanelButtonTemplate")
    closeBtn:SetSize(100, 22)
    closeBtn:SetText("Close")
    closeBtn:SetScript("OnClick", function() editFrame:Hide() end)

    -- Rebuilds the chip list against the waypoint's current tags, wrapping
    -- left to right, then repositions everything below the chip area (and
    -- the frame's own height) to match however tall that turned out to be.
    -- Called on every show and every add/remove, rather than patching chips
    -- in place - Refresh() on the main list works the same way for the same
    -- reason: recomputing from scratch can't drift out of sync the way
    -- incremental patches can.
    local function RefreshChips()
        local entry = editFrame.entry
        if not entry then return end
        local tags = GetTags(entry.uid)

        local x, y = 0, 0
        for i, tagName in ipairs(tags) do
            local chip = AcquireEditTagChip(editFrame.chips, chipContent, i)
            chip.text:SetText(tagName)
            local w = chip.text:GetStringWidth() + K.BADGE_PADDING * 2
            if x > 0 and x + w > CHIP_AREA_WIDTH then
                x = 0
                y = y + CHIP_ROW_STEP
            end
            chip:SetSize(w, K.BADGE_HEIGHT)
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", chipContent, "TOPLEFT", x, -y)
            chip:Show()
            chip:SetScript("OnClick", function()
                ToggleTag(entry.uid, tagName, false)
                WayBook:Refresh()
                RefreshChips()
            end)
            x = x + w + K.BADGE_GAP
        end
        for i = #tags + 1, #editFrame.chips do
            editFrame.chips[i]:Hide()
        end

        local chipsHeight = (#tags > 0) and (y + K.BADGE_HEIGHT) or 0
        local newLabelY = CHIP_AREA_Y - chipsHeight - GAP_AFTER_CHIPS
        local newBoxY = newLabelY - GAP_HEADING_TO_BOX

        newLabel:ClearAllPoints()
        newLabel:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 20, newLabelY)
        newBox:ClearAllPoints()
        newBox:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 26, newBoxY)
        addBtn:ClearAllPoints()
        addBtn:SetPoint("TOPRIGHT", editFrame, "TOPRIGHT", -20, newBoxY + 2)

        -- newBox and addBtn share the same bottom edge by construction
        -- (addBtn sits 2px higher but is 2px taller) - newBoxY - 20 is that
        -- edge. Close sits centred below it, and the frame ends below Close.
        local closeBtnY = newBoxY - 20 - GAP_BEFORE_CLOSE
        closeBtn:ClearAllPoints()
        closeBtn:SetPoint("TOP", editFrame, "TOP", 0, closeBtnY)

        local contentBottomY = closeBtnY - CLOSE_BUTTON_HEIGHT
        editFrame:SetHeight(math.max(-contentBottomY + BOTTOM_MARGIN, MIN_FRAME_HEIGHT))
    end
    editFrame.RefreshChips = RefreshChips

    UIDropDownMenu_Initialize(addTagDropdown, function(self, level)
        local entry = editFrame.entry
        if not entry then return end
        local assigned = {}
        for _, t in ipairs(GetTags(entry.uid)) do assigned[t] = true end
        for _, tagName in ipairs(TagDefinitions()) do
            if not assigned[tagName] then
                local info = UIDropDownMenu_CreateInfo()
                info.text = tagName
                info.notCheckable = true
                info.func = function()
                    ToggleTag(entry.uid, tagName, true)
                    WayBook:Refresh()
                    RefreshChips()
                    UIDropDownMenu_SetText(addTagDropdown, "Add existing tag")
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
    end)

    local function AddNewTag()
        local entry = editFrame.entry
        if not entry then return end
        local canonical = DefineTag(newBox:GetText())
        if canonical then
            ToggleTag(entry.uid, canonical, true)
            WayBook:Refresh()
        end
        newBox:SetText("")
        RefreshChips()
    end

    addBtn:SetScript("OnClick", AddNewTag)
    newBox:SetScript("OnEnterPressed", AddNewTag)
    newBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Renaming always changes the underlying uid (TomTom keys by title), so
    -- the entry this window holds has to be repointed at whatever
    -- RenameWaypoint returns - every edit made afterward, in the same
    -- session, needs to land on the still-alive waypoint, not the one that
    -- was just removed out from under it.
    local function CommitLabel()
        local entry = editFrame.entry
        if not entry then return end
        local newUid = RenameWaypoint(entry, labelBox:GetText())
        if newUid and TomTom:IsValidWaypoint(newUid) then
            entry.uid = newUid
            entry.title = newUid.title or entry.title
            editFrame.title:SetText(entry.title)
            labelBox:SetText(entry.title)
        end
    end

    local function CommitNote()
        local entry = editFrame.entry
        if not entry then return end
        SetNote(entry.uid, noteBox:GetText())
        WayBook:Refresh()
    end

    -- Shows the coordinates the way every other part of the addon does, so
    -- what you read in the row, the tooltip and the Share line is what you
    -- get back in this box.
    local function CoordText(uid)
        if not uid then return "" end
        return ("%.1f, %.1f"):format((uid[2] or 0) * 100, (uid[3] or 0) * 100)
    end

    -- Accepts "45.2, 67.8", "45.2 67.8" and "45,2" style separators equally,
    -- since the display format uses a comma and typing one back in is the
    -- obvious thing to do. Anything that is not two numbers inside the map's
    -- own 0-100 range is refused outright rather than clamped - silently
    -- moving a waypoint somewhere the user did not ask for is worse than
    -- saying no.
    local function CommitCoords()
        local entry = editFrame.entry
        if not entry then return end
        local text = coordBox:GetText() or ""
        local sx, sy = text:match("^%s*(-?[%d%.]+)%s*[,%s]%s*(-?[%d%.]+)%s*$")
        local nx, ny = tonumber(sx), tonumber(sy)
        if not (nx and ny) then
            Print("Coordinates need to look like 45.2, 67.8.")
            coordBox:SetText(CoordText(entry.uid))
            return
        end
        if nx < 0 or nx > 100 or ny < 0 or ny > 100 then
            Print("Coordinates have to be between 0 and 100.")
            coordBox:SetText(CoordText(entry.uid))
            return
        end
        -- Same repointing RenameWaypoint needs, and for the same reason: a
        -- move is a remove-then-add, so the uid this window is holding stops
        -- existing the moment the move succeeds.
        local newUid = MoveWaypoint(entry, nx, ny)
        if newUid and TomTom:IsValidWaypoint(newUid) then
            entry.uid = newUid
            entry.zone = ZoneName(newUid[1]) or entry.zone
            coordBox:SetText(CoordText(newUid))
            WayBook:Refresh()
        end
    end

    labelBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    labelBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    labelBox:SetScript("OnEditFocusLost", CommitLabel)

    noteBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    noteBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    noteBox:SetScript("OnEditFocusLost", CommitNote)

    coordBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    coordBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    coordBox:SetScript("OnEditFocusLost", CommitCoords)

    -- EditBoxes do not chain to one another on their own; each one has to be
    -- told what Tab means. HandyNotes and DBM-GUI wire theirs the same way on
    -- this client. The ring wraps, and Shift-Tab walks it backwards.
    --
    -- Moving focus fires the box's own OnEditFocusLost, so tabbing out of a
    -- field commits it, exactly as clicking away already did. Deliberately no
    -- HighlightText on arrival: tabbing to the Note to add to it should not
    -- leave the whole note selected, one keystroke from being wiped.
    local tabRing = { labelBox, noteBox, coordBox, newBox }
    for i, box in ipairs(tabRing) do
        local nextBox = tabRing[i % #tabRing + 1]
        local prevBox = tabRing[(i - 2) % #tabRing + 1]
        box:SetScript("OnTabPressed", function()
            if IsShiftKeyDown() then prevBox:SetFocus() else nextBox:SetFocus() end
        end)
    end

    function editFrame:SetEntry(entry)
        self.entry = entry
        self.title:SetText(entry.title)
    end

    editFrame:SetScript("OnShow", function(self)
        self:Raise()
        local entry = self.entry
        labelBox:SetText(entry and entry.title or "")
        noteBox:SetText(entry and GetNote(entry.uid) or "")
        coordBox:SetText(entry and CoordText(entry.uid) or "")
        RefreshChips()
        labelBox:SetFocus()
        labelBox:HighlightText()
    end)

    -- Hiding the frame does not reliably fire OnEditFocusLost for a box that
    -- still holds focus at that moment (Escape, or clicking the X while
    -- still typing) - commit both explicitly so nothing typed is lost.
    editFrame:SetScript("OnHide", function()
        CommitLabel()
        CommitNote()
        CommitCoords()
        CloseDropDownMenus()
    end)

    -- This client's dropdowns do not close when you click away from them.
    -- Blizzard wires that up on retail through UIDropDownMenuDelegate's own
    -- GLOBAL_MOUSE_DOWN handler; the FrameXML here does not, which is exactly
    -- why every dropdown library installed on this system (LibUIDropDownMenu,
    -- Eliote's) reimplements the same handler itself. The event is available
    -- on this client regardless - DBM-GUI registers it straight onto a button,
    -- and three Titan addons register it on UIDropDownMenuDelegate - so
    -- WayBook needs its own listener, not a whole embedded library.
    --
    -- Deliberately NOT done the way those libraries do it, by overwriting
    -- UIDropDownMenuDelegate's OnEvent script: that is a shared global, and
    -- replacing its handler would break every other addon leaning on it.
    --
    -- Scoped to "the Edit window is open", since that is the only place
    -- WayBook opens a dropdown at all. IsMouseOver is a geometric bounds
    -- check rather than a mouse-focus one, for the same reason the collapse
    -- watcher uses it - a click landing on a child button inside the list
    -- must still count as inside.
    local dropdownWatcher = CreateFrame("Frame")
    dropdownWatcher:RegisterEvent("GLOBAL_MOUSE_DOWN")
    dropdownWatcher:SetScript("OnEvent", function(_, _, button)
        if button ~= "LeftButton" and button ~= "RightButton" then return end
        if not editFrame:IsShown() then return end
        local list = _G["DropDownList1"]
        if not (list and list:IsVisible()) then return end
        if list:IsMouseOver() or addTagDropdown:IsMouseOver() then return end
        CloseDropDownMenus()
    end)
end

local function BuildOptionsUI()
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil

    optionsFrame = CreateFrame("Frame", "WayBookOptionsFrame", UIParent, template)
    optionsFrame:SetSize(330, 616)
    optionsFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    AddOpaqueBackground(optionsFrame)
    optionsFrame:SetMovable(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
    -- Draggable within a session, but the position is deliberately not saved:
    -- the panel recenters every time it opens.
    optionsFrame:SetScript("OnDragStop", optionsFrame.StopMovingOrSizing)
    optionsFrame:SetClampedToScreen(true)
    optionsFrame:SetFrameStrata("DIALOG")
    optionsFrame:Hide()

    tinsert(UISpecialFrames, "WayBookOptionsFrame")

    local title = optionsFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOP", optionsFrame, "TOP", 0, -16)
    title:SetText("WayBook Options")

    local close = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -6, -6)

    MakeSectionHeading(optionsFrame, 22, -42, "General")

    local keepCheck = MakeCheck(optionsFrame, "WayBookOptKeep",
        "Keep waypoints on arrival", 20, -62,
        KeepOnArrivalEnabled, SetKeepOnArrival)
    keepCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Keep waypoints on arrival")
        GameTooltip:AddLine(
            "TomTom deletes a waypoint once you reach it. Ticking this sets that " ..
            "distance to 0 so your saved places survive visiting them.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    keepCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local iconCheck = MakeCheck(optionsFrame, "WayBookOptIcon",
        "Show minimap button", 20, -86,
        MinimapShown, SetMinimapShown)

    local reverseCheck = MakeCheck(optionsFrame, "WayBookOptReverse",
        "Reverse sort order", 20, -110,
        SortDescending,
        function(v) WayBookDB.sortDescending = v end)
    reverseCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Reverse sort order")
        GameTooltip:AddLine(
            "Flips the list to Z to A. When grouped, this reverses both the group " ..
            "order and the labels inside each group.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    reverseCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local loginCheck = MakeCheck(optionsFrame, "WayBookOptLogin",
        "Clear arrow on login", 20, -134,
        ClearArrowOnLogin,
        function(v) WayBookDB.clearArrowOnLogin = v end)
    loginCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Clear arrow on login")
        GameTooltip:AddLine(
            "TomTom stores a 'crazy' flag on every waypoint made while its autoqueue " ..
            "option is on, and re-applies it to each one when it restores them, so " ..
            "whichever loads last grabs the arrow. This drops it a second after login.",
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    loginCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Swaps the zone/tag header and badge palette for Okabe & Ito's
    -- colorblind-safe six, rather than replacing the default outright,
    -- so anyone who prefers the original palette still can.
    local colorblindCheck = MakeCheck(optionsFrame, "WayBookOptColorblind",
        "Use colorblind-friendly colors", 20, -158,
        ColorblindMode,
        function(v)
            WayBookDB.colorblindMode = v
            WayBook:Refresh()
        end)
    colorblindCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Use colorblind-friendly colors")
        GameTooltip:AddLine(
            "Switches the zone/tag header colors to the Okabe-Ito palette, chosen to " ..
            "stay distinguishable under the common forms of color blindness.",
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    colorblindCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local barCheck = MakeCheck(optionsFrame, "WayBookOptBar",
        "Auto-collapse to text bar", 20, -182,
        AutoCollapseEnabled, SetAutoCollapse)
    barCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Auto-collapse to text bar")
        GameTooltip:AddLine(
            "Shrinks the main window down to a small draggable \"WayBook\" bar a " ..
            "moment after the mouse leaves it (and any Options, Export, Share or " ..
            "Edit window open at the time). Hover the bar to bring the window back.",
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    barCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Right-hand column, level with the new "General" heading on the left.
    -- Moved here in 1.21.1, out of the way of the left column's
    -- checkbox run.
    MakeSectionHeading(optionsFrame, 180, -42, "Group by:")

    -- Radios, same pattern as "Sort by:" below: the setter always writes its
    -- own mode regardless of the checkbox's own checked/unchecked state, and
    -- RefreshOptions() re-syncs every checkbox afterward so only the true
    -- match ends up ticked.
    local function GroupRadio(name, label, mode, y)
        return MakeCheck(optionsFrame, name, label, 188, y,
            function() return GroupMode() == mode end,
            function() SetGroupMode(mode) end)
    end

    local groupNoneCheck = GroupRadio("WayBookOptGroupNone", "None", "none", -62)

    local groupZoneCheck = GroupRadio("WayBookOptGroupZone", "By Zone", "zone", -86)

    local groupTagCheck = GroupRadio("WayBookOptGroupTag", "By Tag", "tag", -110)
    groupTagCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("By Tag")
        GameTooltip:AddLine(
            "Groups by every tag a waypoint has (right-click a row to manage its " ..
            "tags), so one with several tags shows under each of their headers. " ..
            "Anything untagged falls into its own Untagged header.",
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    groupTagCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    MakeSectionHeading(optionsFrame, 22, -218, "Show in the list:")

    local labelCheck = MakeCheck(optionsFrame, "WayBookOptLabel",
        "Label", 30, -238, ShowLabel,
        function(v) SetColumn("showLabel", v) end)

    local zoneCheck = MakeCheck(optionsFrame, "WayBookOptZone",
        "Zone", 30, -262, ShowZone,
        function(v) SetColumn("showZone", v) end)

    -- Redundant while grouping by zone is on, so it goes flat and unclickable
    -- rather than sitting there ticked and doing nothing.
    local zoneCheckSync = zoneCheck.Sync
    local zoneCheckText = zoneCheck.Text or zoneCheck.text or _G["WayBookOptZoneText"]
    zoneCheck.Sync = function()
        zoneCheckSync()
        local grouping = GroupByZone()
        if grouping then zoneCheck:Disable() else zoneCheck:Enable() end
        if zoneCheckText then
            if grouping then
                zoneCheckText:SetTextColor(0.5, 0.5, 0.5)
            else
                zoneCheckText:SetTextColor(1, 0.82, 0)
            end
        end
    end
    zoneCheck:SetScript("OnEnter", function(self)
        if not GroupByZone() then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Zone")
        GameTooltip:AddLine(
            "Off because Group by Zone is on. The zone already appears on every " ..
            "header, so the column would only repeat it.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    zoneCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Not a text column: this gates whether tag badges draw under a row.
    local tagsCheck = MakeCheck(optionsFrame, "WayBookOptTags",
        "Tags", 30, -286, ShowTags,
        function(v) WayBookDB.showTags = v end)

    -- Redundant while grouping by tag is on, exactly like Zone above, so it
    -- gets the same flat-and-unclickable treatment.
    local tagsCheckSync = tagsCheck.Sync
    local tagsCheckText = tagsCheck.Text or tagsCheck.text or _G["WayBookOptTagsText"]
    tagsCheck.Sync = function()
        tagsCheckSync()
        local grouping = GroupByTag()
        if grouping then tagsCheck:Disable() else tagsCheck:Enable() end
        if tagsCheckText then
            if grouping then
                tagsCheckText:SetTextColor(0.5, 0.5, 0.5)
            else
                tagsCheckText:SetTextColor(1, 0.82, 0)
            end
        end
    end
    tagsCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Tags")
        if GroupByTag() then
            GameTooltip:AddLine(
                "Off because Group by Tag is on. A waypoint already appears " ..
                "under a header for every tag it has, so the badges would " ..
                "only repeat them.", 1, 1, 1, true)
        else
            GameTooltip:AddLine(
                "Shows each waypoint's tags as small badges under its row. " ..
                "Right-click a row to manage its tags.", 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    tagsCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local coordCheck = MakeCheck(optionsFrame, "WayBookOptCoords",
        "Coordinates", 30, -310, ShowCoords,
        function(v) SetColumn("showCoords", v) end)

    local visitCheck = MakeCheck(optionsFrame, "WayBookOptVisitCol",
        "Visits", 30, -334, ShowVisits,
        function(v) SetColumn("showVisits", v) end)

    local distCheck = MakeCheck(optionsFrame, "WayBookOptDistCol",
        "Distance", 30, -358, ShowDistance,
        function(v) SetColumn("showDistance", v) end)
    distCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Distance")
        GameTooltip:AddLine(
            "How far away each waypoint is, refreshed once a second while this " ..
            "window is open. A dash means another continent or an instance, where " ..
            "the game will not give out a position.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    distCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    MakeSectionHeading(optionsFrame, 180, -218, "Sort by:")

    -- Mutually exclusive, so each one just writes the mode and the others
    -- untick themselves when RefreshOptions re-syncs.
    local function SortRadio(name, label, mode, y)
        return MakeCheck(optionsFrame, name, label, 188, y,
            function() return SortMode() == mode end,
            function() WayBookDB.sortMode = mode end)
    end

    local sortLabelCheck  = SortRadio("WayBookOptSortLabel",  "Label",        "label",  -238)
    local sortVisitsCheck = SortRadio("WayBookOptSortVisits", "Visits",       "visits", -262)
    local sortRecentCheck = SortRadio("WayBookOptSortRecent", "Last visited", "recent", -286)
    local sortNearCheck   = SortRadio("WayBookOptSortNear",   "Nearest",      "distance", -310)
    sortNearCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Nearest")
        GameTooltip:AddLine(
            "Closest waypoint first, re-sorted once a second as you move. Grouped, " ..
            "whichever group holds your closest waypoint leads. Anything off the " ..
            "continent sits at the bottom.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    sortNearCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local arriveSlider = MakeSlider(optionsFrame, "WayBookOptArrive",
        "Clear arrow within (yards)", 36, -408, 0, 60, 1,
        ArriveDistance,
        function(v)
            WayBookDB.arriveDistance = v
            StartWatching()
        end)
    arriveSlider:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Clear arrow on arrival")
        GameTooltip:AddLine(
            "Drops the crazy arrow once you get this close. The waypoint itself is " ..
            "never removed. Set to 0 to switch this off.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    arriveSlider:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local fontSlider = MakeSlider(optionsFrame, "WayBookOptFont",
        "List font size", 36, -466, K.MIN_LIST_FONT_SIZE, K.MAX_LIST_FONT_SIZE, 1,
        ListFontSize,
        function(v)
            WayBookDB.listFontSize = v
            RestyleAll()
            WayBook:Refresh()
        end)
    fontSlider:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("List font size")
        GameTooltip:AddLine(
            "Point size for the waypoint list only. Buttons and checkboxes keep " ..
            "their stock size. 10 is the default.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    fontSlider:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local exportBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    exportBtn:SetSize(140, 22)
    exportBtn:SetPoint("BOTTOM", optionsFrame, "BOTTOM", 0, 74)
    exportBtn:SetText("Export Waypoints")
    exportBtn:SetScript("OnClick", function() ToggleExport() end)
    exportBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Export Waypoints")
        GameTooltip:AddLine(
            "Every waypoint the search box currently matches, as /way lines ready " ..
            "to copy out. Clear the search first for the whole book. Ignores any " ..
            "collapsed groups either way.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    exportBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local resetBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    resetBtn:SetSize(140, 22)
    resetBtn:SetPoint("BOTTOMLEFT", optionsFrame, "BOTTOMLEFT", 20, 46)
    resetBtn:SetText("Restore window")
    resetBtn:SetScript("OnClick", function()
        WayBookDB.point = nil
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end)

    local defaultsBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    defaultsBtn:SetSize(120, 22)
    defaultsBtn:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -20, 46)
    defaultsBtn:SetText("Restore defaults")
    defaultsBtn:SetScript("OnClick", function()
        WayBookDB.arriveDistance = K.DEFAULT_ARRIVE_DISTANCE
        WayBookDB.listFontSize   = K.DEFAULT_LIST_FONT_SIZE
        WayBookDB.sortDescending = false
        WayBookDB.clearArrowOnLogin = true
        WayBookDB.colorblindMode = false
        WayBookDB.showLabel      = true
        WayBookDB.showZone       = false
        WayBookDB.showTags       = false
        WayBookDB.showCoords     = false
        WayBookDB.showVisits     = false
        WayBookDB.showDistance   = false
        WayBookDB.sortMode       = "label"
        WayBookDB.collapsed      = nil
        WayBookDB.zoneColumnPreGroup = nil
        WayBookDB.tagColumnPreGroup  = nil
        SetGroupMode("zone")
        SetMinimapShown(true)
        SetKeepOnArrival(true)
        SetAutoCollapse(false)
        if TomTom and TomTom.profile then
            TomTom.profile.arrow.setclosest = false
        end
        RestyleAll()
        StartWatching()
        RefreshOptions()
        RefreshMainControls()
        WayBook:Refresh()
        Print("Options restored to defaults. Notes, tags and tag definitions were left alone.")
    end)

    -- Version and license, small and greyed, at the very bottom of the panel.
    -- The version is read back out of the TOC rather than written here, so a
    -- release bump stays a one-file edit and this line can never go stale.
    -- The license is a literal on purpose: GetAddOnMetadata only returns
    -- Blizzard's own standard fields plus anything prefixed "X-", and
    -- "## License" is neither, so asking for it would just come back nil.
    -- Not registered in the styled table below, so the list font-size slider
    -- leaves it alone - it is chrome, not list content.
    local GetMeta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    local version = GetMeta and GetMeta("WayBook", "Version") or "?"
    local footer = optionsFrame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    footer:SetPoint("BOTTOM", optionsFrame, "BOTTOM", 0, 12)
    footer:SetText("WayBook v" .. version .. "  |  MIT License")

    optionsFrame.controls = {
        keepCheck, iconCheck, groupNoneCheck, groupZoneCheck, groupTagCheck,
        reverseCheck, loginCheck, colorblindCheck, barCheck,
        labelCheck, tagsCheck, zoneCheck, coordCheck, visitCheck, distCheck,
        sortLabelCheck, sortVisitsCheck, sortRecentCheck, sortNearCheck,
        arriveSlider, fontSlider,
    }

    optionsFrame:SetScript("OnShow", function(self)
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        RefreshOptions()
    end)

    optionsFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
end

function RefreshOptions()
    if not optionsFrame or not optionsFrame.controls then return end
    for _, control in ipairs(optionsFrame.controls) do
        if control.Sync then control.Sync() end
    end
end

-- Same job as RefreshOptions, for the main window's own group-by row. Kept
-- separate rather than folded in because the two frames are built at
-- different times and either can exist without the other.
function RefreshMainControls()
    if not frame or not frame.controls then return end
    for _, control in ipairs(frame.controls) do
        if control.Sync then control.Sync() end
    end
end

function ToggleOptions()
    if not optionsFrame then return end
    if optionsFrame:IsShown() then optionsFrame:Hide() else optionsFrame:Show() end
end

--------------------------------------------------------------------------
-- Collapse bar
--
-- Optional (Options: "Auto-collapse to text bar"). When on, the main window
-- and whichever of Options/Export/Share/Edit happen to be open hide
-- themselves a short delay after the mouse leaves all of them, and a small
-- draggable "WayBook" bar stays on screen instead. Hovering the bar re-opens
-- the main window, anchored at whichever of its corners sits nearest the
-- bar, so it grows toward the middle of the screen rather than off the
-- nearest edge.
--
-- Tracking this with plain OnEnter/OnLeave on the five windows does not
-- work: every button, checkbox, row and slider inside them is its own
-- mouse-enabled frame, and moving onto one of those switches WoW's mouse
-- focus away from its parent, firing the parent's OnLeave even though the
-- cursor never left the window's own rectangle. A ticker that polls
-- IsMouseOver() - a bounds check, not a mouse-focus event - on every
-- relevant frame each tick is what actually reflects "is the mouse still
-- somewhere inside the interface," regardless of which specific child
-- widget is directly under it.
--------------------------------------------------------------------------

local collapseTimer
local collapseWatcher

local function CancelCollapse()
    if collapseTimer then
        collapseTimer:Cancel()
        collapseTimer = nil
    end
end

-- Set only for the duration of a collapse, and read by the main frame's own
-- OnHide. Collapsing is not closing: the list folds away to the bar while
-- Options, Export, Share and Edit stay exactly where they are, to be closed
-- by hand when the user is done with them. Closing the main window yourself
-- still takes all four with it, which is what 1.24.1 added the cascade for.
local collapsingToBar = false

local function CollapseToBar()
    if not AutoCollapseEnabled() then return end
    if frame then
        collapsingToBar = true
        frame:Hide()
        collapsingToBar = false
    end
end

function StopCollapseWatcher()
    if collapseWatcher then
        collapseWatcher:Cancel()
        collapseWatcher = nil
    end
    CancelCollapse()
end

-- A delay rather than an immediate hide, so the mouse has time to cross the
-- gap between the bar and the window, or between the window and a child
-- window, without everything snapping shut mid-move. Only starts one timer -
-- repeated calls while the mouse stays away do not keep pushing it back, or
-- it would never fire.
local function ScheduleCollapse()
    if not AutoCollapseEnabled() then return end
    if collapseTimer then return end
    collapseTimer = C_Timer.NewTimer(K.COLLAPSE_DELAY, function()
        collapseTimer = nil
        CollapseToBar()
    end)
end

-- Frames that belong to a WayBook interaction without being WayBook's own
-- windows: Blizzard's shared dropdown lists, which the Edit window's tag
-- picker opens into, and the shared StaticPopups, which the delete
-- confirmation uses. Both are top-level frames parented to UIParent rather
-- than to anything of WayBook's, so the six checks below never saw them and
-- the mouse moving onto one read as "left the interface entirely".
--
-- This is the 1.26.1 bug one level further out. There the frames the watcher
-- missed were children sitting inside the windows; here they are siblings
-- sitting alongside them. Anything WayBook opens that is not parented to one
-- of its own frames needs adding here.
K.BORROWED_FRAMES = { "DropDownList1", "DropDownList2" }
for i = 1, (STATICPOPUP_NUMDIALOGS or 4) do
    K.BORROWED_FRAMES[#K.BORROWED_FRAMES + 1] = "StaticPopup" .. i
end

local function IsMouseOverInterface()
    if barFrame    and barFrame:IsShown()    and barFrame:IsMouseOver()    then return true end
    if frame       and frame:IsShown()       and frame:IsMouseOver()       then return true end
    if optionsFrame and optionsFrame:IsShown() and optionsFrame:IsMouseOver() then return true end
    if exportFrame and exportFrame:IsShown() and exportFrame:IsMouseOver() then return true end
    if shareFrame  and shareFrame:IsShown()  and shareFrame:IsMouseOver()  then return true end
    if editFrame   and editFrame:IsShown()   and editFrame:IsMouseOver()   then return true end
    for _, name in ipairs(K.BORROWED_FRAMES) do
        local f = _G[name]
        if f and f:IsShown() and f:IsMouseOver() then return true end
    end
    return false
end

function StartCollapseWatcher()
    if collapseWatcher or not AutoCollapseEnabled() then return end
    collapseWatcher = C_Timer.NewTicker(K.WATCH_INTERVAL, function()
        if not AutoCollapseEnabled() then
            StopCollapseWatcher()
            return
        end
        if IsMouseOverInterface() then
            CancelCollapse()
        else
            ScheduleCollapse()
        end
    end)
end

-- Anchors whichever corner of the main window sits nearest the bar to the
-- bar's opposite corner, so the window always grows toward the middle of the
-- screen no matter which corner the player parks the bar in.
local function PositionFrameNearBar()
    if not (frame and barFrame) then return end
    local screenW, screenH = UIParent:GetSize()
    local bx, by = barFrame:GetCenter()
    if not (bx and by) then return end

    local isLeft   = bx < (screenW / 2)
    local isBottom = by < (screenH / 2)

    local frameAnchor = (isBottom and "BOTTOM" or "TOP") .. (isLeft and "LEFT" or "RIGHT")
    local barAnchor   = (isBottom and "TOP" or "BOTTOM") .. (isLeft and "RIGHT" or "LEFT")
    local xOff = isLeft and K.BAR_GAP or -K.BAR_GAP
    local yOff = isBottom and K.BAR_GAP or -K.BAR_GAP

    frame:ClearAllPoints()
    frame:SetPoint(frameAnchor, barFrame, barAnchor, xOff, yOff)
end

local function ExpandFromBar()
    if not AutoCollapseEnabled() then return end
    if frame and not frame:IsShown() then
        PositionFrameNearBar()
        frame:Show()   -- frame's own OnShow starts the collapse watcher
    end
end

local function BuildBarUI()
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil

    barFrame = CreateFrame("Frame", "WayBookBarFrame", UIParent, template)
    barFrame:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    barFrame:SetBackdropColor(0, 0, 0, 0.6)
    barFrame:SetBackdropBorderColor(1, 1, 1, 0.8)
    barFrame:SetMovable(true)
    barFrame:EnableMouse(true)
    barFrame:RegisterForDrag("LeftButton")
    barFrame:SetScript("OnDragStart", barFrame.StartMoving)
    barFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        WayBookDB.barPoint = { point, relPoint, x, y }
    end)
    barFrame:SetClampedToScreen(true)
    barFrame:SetFrameStrata("MEDIUM")
    barFrame:Hide()

    local text = barFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    text:SetPoint("CENTER", barFrame, "CENTER", 0, 0)
    text:SetText("WayBook")
    barFrame:SetSize(text:GetStringWidth() + K.BAR_PADDING * 2,
        text:GetStringHeight() + K.BAR_PADDING)

    -- No OnLeave here: once the frame is shown, the collapse watcher (started
    -- from the frame's own OnShow) is what decides when the mouse has left
    -- the whole interface, bar included.
    barFrame:SetScript("OnEnter", ExpandFromBar)

    if WayBookDB.barPoint then
        local point, relPoint, x, y = unpack(WayBookDB.barPoint)
        barFrame:ClearAllPoints()
        barFrame:SetPoint(point, UIParent, relPoint, x, y)
    else
        barFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 40, -200)
    end

    if AutoCollapseEnabled() then barFrame:Show() end
end

--------------------------------------------------------------------------
-- Main window
--------------------------------------------------------------------------

local function BuildUI()
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil

    frame = CreateFrame("Frame", "WayBookFrame", UIParent, template)
    frame:SetSize(K.FRAME_WIDTH, K.FRAME_HEIGHT)
    frame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    AddOpaqueBackground(frame)
    -- Without this, the main window sits at the default "MEDIUM" strata,
    -- the same one Questie's own tracker uses (TrackerBaseFrame.lua) - a tie
    -- resolved by whichever last got raised, not by which one the player is
    -- actually looking at. A distinctly higher strata wins regardless, same
    -- reasoning as Export needing FULLSCREEN_DIALOG over Options.
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        WayBookDB.point = { point, relPoint, x, y }
    end)
    frame:SetClampedToScreen(true)
    frame:Hide()

    tinsert(UISpecialFrames, "WayBookFrame")

    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOP", frame, "TOP", 0, -16)
    title:SetText("WayBook")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)

    -- Labelled buttons along the bottom: left, center, right.
    local function TextButton(label, anchor, relPoint, x, tipTitle, tipBody, onClick, binding)
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(K.BUTTON_WIDTH, K.BUTTON_HEIGHT)
        b:SetPoint(anchor, frame, relPoint, x, 16)
        b:SetText(label)
        ShrinkOnce(b:GetFontString(), K.BUTTON_FONT_DELTA)
        b:SetScript("OnClick", onClick)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(tipTitle)
            if tipBody then GameTooltip:AddLine(tipBody, 1, 1, 1, true) end
            -- Read live rather than cached, so rebinding shows up immediately.
            local key = binding and GetBindingKey(binding)
            if key then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Bound to " .. GetBindingText(key), 0.6, 0.8, 1)
            elseif binding then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Not bound. Key Bindings, AddOns, WayBook.", 0.6, 0.6, 0.6)
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return b
    end

    TextButton("Add Waypoint", "BOTTOMLEFT", "BOTTOMLEFT", 16,
        "Add Waypoint",
        "With a target selected, saves your position labeled with its name. With no " ..
        "target, saves your position and asks you to name it.",
        AddTargetWaypoint, "WAYBOOK_ADD_TARGET")

    TextButton("Clear Arrow", "BOTTOM", "BOTTOM", 0,
        "Clear Arrow",
        "Drops the crazy arrow's target. Waypoints are untouched.",
        ClearArrow, "WAYBOOK_CLEAR_ARROW")

    TextButton("Options", "BOTTOMRIGHT", "BOTTOMRIGHT", -16,
        "Options",
        "Configure display and behavior options.",
        function() ToggleOptions() end, "WAYBOOK_TOGGLE_OPTIONS")

    -- SearchBoxTemplate brings its own magnifier, placeholder string and clear
    -- button. Auctionator, WeakAuras and Journalator all use it on this client,
    -- so it is present in MoP Classic's FrameXML. Deliberately left at the stock
    -- font size: it is a fixed-height widget, and only list contents follow the
    -- font slider.
    searchBox = CreateFrame("EditBox", "WayBookSearchBox", frame, "SearchBoxTemplate")
    searchBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -40)
    searchBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -22, -40)
    searchBox:SetHeight(K.SEARCH_BOX_HEIGHT)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(60)
    if searchBox.Instructions then
        searchBox.Instructions:SetText("Search labels, zones and notes")
    end

    -- Hooked rather than set, so the template's own handler still runs and keeps
    -- the placeholder and the clear button in step. The clear button writes an
    -- empty string, which comes back through here and drops the filter.
    searchBox:HookScript("OnTextChanged", function(self)
        SetSearchQuery(self:GetText())
        WayBook:Refresh()
    end)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)

    -- Group-by radios and a sort-direction toggle, mirroring the same two
    -- settings in Options rather than replacing them. Both sets stay ticked
    -- in step because MakeCheck's OnClick calls RefreshOptions() and
    -- RefreshMainControls(), so a click in either panel re-syncs the other.
    local function MainGroupRadio(name, label, mode, x)
        return MakeCheck(frame, name, label, x, K.GROUP_ROW_Y,
            function() return GroupMode() == mode end,
            function() SetGroupMode(mode) end)
    end

    local groupNoneCheck = MainGroupRadio("WayBookGroupNone", "None",    "none", 16)
    local groupZoneCheck = MainGroupRadio("WayBookGroupZone", "By Zone", "zone", 78)
    local groupTagCheck  = MainGroupRadio("WayBookGroupTag",  "By Tag",  "tag",  158)

    -- Anchored to the frame's right edge rather than to the last radio, so a
    -- longer label in some future locale pushes nothing off the panel.
    --
    -- UI-SortArrow is one downward arrow; the ascending state flips it by
    -- swapping the texture's top and bottom coords instead of needing a
    -- second asset. The 0.5625 right coord and the highlight texture are both
    -- Altoholic's own numbers for this texture (Templates/SortButton.xml),
    -- which is where it was confirmed present on this client.
    local sortDirBtn = CreateFrame("Button", "WayBookSortDir", frame)
    sortDirBtn:SetSize(22, 22)
    sortDirBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, K.GROUP_ROW_Y - 1)
    sortDirBtn:SetHighlightTexture(
        "Interface\\PaperDollInfoFrame\\UI-Character-Tab-Highlight", "ADD")

    local sortArrow = sortDirBtn:CreateTexture(nil, "ARTWORK")
    sortArrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
    sortArrow:SetSize(13, 12)
    sortArrow:SetPoint("CENTER", sortDirBtn, "CENTER", 0, 0)

    sortDirBtn.Sync = function()
        if SortDescending() then
            sortArrow:SetTexCoord(0, 0.5625, 1, 0)
        else
            sortArrow:SetTexCoord(0, 0.5625, 0, 1)
        end
    end

    sortDirBtn:SetScript("OnClick", function()
        WayBookDB.sortDescending = not SortDescending()
        RefreshOptions()
        RefreshMainControls()
        WayBook:Refresh()
    end)
    sortDirBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Reverse sort order")
        GameTooltip:AddLine(
            ("Currently %s. This flips whichever sort is active - set that " ..
             "under Options."):format(SortDescending() and "reversed" or "normal"),
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    sortDirBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    frame.controls = { groupNoneCheck, groupZoneCheck, groupTagCheck, sortDirBtn }

    countText = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    countText:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -96)
    countText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -34, -96)
    countText:SetJustifyH("LEFT")

    scrollFrame = CreateFrame("ScrollFrame", "WayBookScroll", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -114)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -34, 46)

    content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(K.FRAME_WIDTH - 56, 1)
    scrollFrame:SetScrollChild(content)

    -- Escape closes the frame through UISpecialFrames without going via Toggle,
    -- so keep the saved state in sync from the frame's own handlers.
    frame:SetScript("OnShow", function(self)
        self:Raise()
        WayBookDB.shown = true
        -- Settings can move while this window is hidden (Options stays usable
        -- on its own), so re-tick the row rather than trusting its last state.
        RefreshMainControls()
        WayBook:Refresh()
        if AutoCollapseEnabled() then StartCollapseWatcher() end
    end)
    frame:SetScript("OnHide", function()
        WayBookDB.shown = false
        StopCollapseWatcher()
        -- Drop the filter on the way out. Reopening to a book that is still
        -- hiding most of itself reads as waypoints having gone missing.
        if searchBox then
            searchBox:SetText("")
            searchBox:ClearFocus()
        end
        UpdateDistanceTicker()
        -- Closing the book closes everything it opened - a stray Options,
        -- Export, Share or Edit window left on screen with no main list
        -- behind it doesn't make sense, however it got there.
        --
        -- Skipped while collapsing to the bar. That is the list getting out
        -- of the way, not the user closing anything, and taking a window they
        -- are part way through using with it made the bar unusable for
        -- anything except browsing the list.
        if not collapsingToBar then
            if optionsFrame then optionsFrame:Hide() end
            if exportFrame then exportFrame:Hide() end
            if shareFrame then shareFrame:Hide() end
            if editFrame then editFrame:Hide() end
        end
    end)

    if WayBookDB.point then
        local point, relPoint, x, y = unpack(WayBookDB.point)
        frame:ClearAllPoints()
        frame:SetPoint(point, UIParent, relPoint, x, y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

-- The frame's own OnShow/OnHide handlers record the state.
function Toggle()
    if not frame then return end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

-- TomTom already loads LibDataBroker and LibDBIcon, so the minimap button
-- costs nothing extra and gets drag-positioning and hiding for free.
local function SetupMinimapButton()
    local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
    local icon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not (ldb and icon) then return end

    WayBookDB.minimap = WayBookDB.minimap or {}

    local launcher = ldb:NewDataObject("WayBook", {
        type = "launcher",
        icon = "Interface\\Icons\\INV_Misc_Map_01",
        OnClick = function(_, button)
            if button == "RightButton" then ToggleOptions() else Toggle() end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("WayBook")
            tt:AddLine("Left-click to open your waypoint list", 1, 1, 1)
            tt:AddLine("Right-click for options", 1, 1, 1)
        end,
    })

    icon:Register("WayBook", launcher, WayBookDB.minimap)
end

--------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------

WayBook:RegisterEvent("PLAYER_LOGIN")
WayBook:SetScript("OnEvent", function()
    WayBookDB = WayBookDB or {}
    WayBookDB.notes = WayBookDB.notes or {}

    -- The font setting used to be a relative offset. Fold any saved offset into
    -- an absolute point size and drop the old key.
    if WayBookDB.fontAdjust ~= nil then
        if WayBookDB.listFontSize == nil then
            WayBookDB.listFontSize = math.max(K.MIN_LIST_FONT_SIZE,
                math.min(K.MAX_LIST_FONT_SIZE, K.DEFAULT_LIST_FONT_SIZE + WayBookDB.fontAdjust))
        end
        WayBookDB.fontAdjust = nil
    end

    if not TomTom then
        Print("TomTom is not loaded. WayBook has nothing to read.")
        return
    end

    -- "Keep waypoints on arrival" used to live entirely in TomTom's shared
    -- profile.persistence.cleardistance, which is why it was hijacking other
    -- addons' waypoints too (see ApplyKeepOnArrivalToOwnWaypoints above). Any
    -- existing profile carries that old on/off state only in the global, so
    -- migrate it into WayBook's own setting once, then put the global back to
    -- a normal default so it stops being WayBook's business going forward.
    if WayBookDB.keepOnArrival == nil then
        WayBookDB.keepOnArrival = TomTom.profile.persistence.cleardistance == 0
    end
    TomTom.profile.persistence.cleardistance =
        WayBookDB.savedClearDistance or K.DEFAULT_CLEAR_DISTANCE
    ApplyKeepOnArrivalToOwnWaypoints()
    TomTom:ReloadWaypoints()

    -- The arrow should just go away when its waypoint clears, not jump to
    -- the next-closest one - TomTom's own shipped default
    -- (`arrow.setclosest = true`) does the opposite. Originally a WayBook
    -- checkbox (1.24.4), removed again in 1.24.6 once it was clear nobody
    -- would want to undo this behavior - so it is just enforced
    -- unconditionally every login instead, with no UI to turn it back on.
    TomTom.profile.arrow.setclosest = false

    -- A second grouping axis (first Category in 1.21.0, then Tag in 1.22.0)
    -- meant the old boolean had to become one of several named states, the
    -- same way the old relative font offset above became an absolute size:
    -- fold it once, then drop the old key.
    if WayBookDB.groupBy == nil then
        WayBookDB.groupBy = (WayBookDB.groupByZone == false) and "none" or "zone"
        WayBookDB.groupByZone = nil
    elseif WayBookDB.groupBy == "category" then
        WayBookDB.groupBy = "tag"
    end

    -- 1.21.0 shipped a single free-text category, superseded by several
    -- reusable tags per waypoint. Each old category becomes
    -- a one-tag array and a tag definition, then the old table is gone.
    if WayBookDB.categories then
        for key, category in pairs(WayBookDB.categories) do
            local canonical = DefineTag(category)
            if canonical then
                WayBookDB.tags = WayBookDB.tags or {}
                WayBookDB.tags[key] = { canonical }
            end
        end
        WayBookDB.categories = nil
    end
    if WayBookDB.showCategory ~= nil then
        WayBookDB.showTags = WayBookDB.showCategory
        WayBookDB.showCategory = nil
    end
    WayBookDB.categoryColumnPreGroup = nil

    -- Catches whatever accumulated before 1.25.1 wired PruneUnusedTagDefinitions
    -- into ToggleTag/DeleteWaypoint - existing profiles can carry a long tail of
    -- test tags nothing ever cleaned up. Also just cheap to re-check every login.
    PruneUnusedTagDefinitions()

    -- Existing profiles can have grouping and the Zone column switched on at
    -- once, so reconcile them before the first draw.
    SyncZoneColumn(GroupByZone())

    BuildUI()
    BuildOptionsUI()
    BuildExportUI()
    BuildShareUI()
    BuildEditUI()
    BuildBarUI()
    SetupMinimapButton()

    hooksecurefunc(TomTom, "AddWaypoint", QueueRefresh)
    hooksecurefunc(TomTom, "AddWaypoint", AutoTagQuestieWaypoint)
    hooksecurefunc(TomTom, "RemoveWaypoint", QueueRefresh)
    hooksecurefunc(TomTom, "ReloadWaypoints", QueueRefresh)
    hooksecurefunc(TomTom, "ClearAllWaypoints", QueueRefresh)

    -- Catches every path that sets the arrow: row clicks, /way, /cway and the
    -- autoqueue that fires when a waypoint is created.
    hooksecurefunc(TomTom, "SetCrazyArrow", TrackArrow)

    if WayBookDB.shown then
        frame:Show()
    end

    -- TomTom restores waypoints during its own login pass and re-applies the
    -- stored 'crazy' flag to each, so the last one loaded ends up owning the
    -- arrow. Wait for that to finish, then drop it.
    if ClearArrowOnLogin() then
        C_Timer.After(1, function()
            if TomTom and not TomTom:IsCrazyArrowEmpty() then
                TomTom:SetCrazyArrow(nil)
            end
        end)
    end
end)

--------------------------------------------------------------------------
-- Keybindings
--
-- Bindings.xml calls these by name, so they have to be globals. Grouping comes
-- from the category attribute on each Binding, which is the display string
-- itself. The older BINDING_HEADER_* mechanism buckets you into the generic
-- AddOns list instead, which is where Pawn ends up.
--------------------------------------------------------------------------


function WayBook_ToggleList()    Toggle() end
function WayBook_ToggleOptions() ToggleOptions() end
function WayBook_AddTarget()     AddTargetWaypoint() end
function WayBook_ClearArrow()    ClearArrow() end

SLASH_WAYBOOK1 = "/waybook"
SLASH_WAYBOOK2 = "/wb"
SlashCmdList["WAYBOOK"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "options" or msg == "config" then
        ToggleOptions()
    else
        Toggle()
    end
end
