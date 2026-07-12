#Requires AutoHotkey v2.0
#SingleInstance Force
#Include lib\WebView2.ahk

; ============================================================
;  Garden Macro  -  Roblox seed-shop & gear-shop macro
;
;  Pick which seeds to buy in the window, set the quantity,
;  then press Start (or F1). The macro:
;    0. Focuses Roblox + small mouse nudge
;    1. Clicks the shop at (697, 103), presses "e"
;    2. Presses "\" for keyboard UI nav, snaps to position 1
;       (Up 5x, Down 5x, then hold Up 3s), then moves onto the first ticked seed.
;  Steps 0-2 (Setup) run ONCE. The shop UI then stays open and the
;  cursor stays put, so each restock only repeats the buy pass:
;    3. From the first ticked seed, walk DOWN buying each ticked seed
;       N times, then walk back UP to the first ticked seed.
;
;  Setup runs on Start; the buy pass then repeats every 5 minutes
;  (restock loop) until you press Stop.
;
;  The window has two tabs: "Seeds" (above) and "Gears". The Gears tab
;  buys from the in-game GEAR SHOP and differs only in setup: you must
;  already be standing in the open Gear Shop UI when you press Start, so
;  it skips the shop click + "e". It presses "\" for keyboard nav, then
;  Up 5x + Down 5x + hold Up 3s to land on position 1 (the first gear), then walks down onto
;  the first ticked gear. From there the buy pass is identical to seeds.
;
;  Controls:
;    Start button / F1 -> run
;    Stop  button / F2 -> stop (releases held keys)
;    Close window     -> quit the script
;
;  The window is a WebView2 (Edge) control rendering the HTML/CSS/JS
;  UI below. AHK stays the automation engine; the UI just sends it
;  messages ("start" / "stop" / current selection + quantity) and
;  AHK pushes status + run-state back to the page.
; ============================================================

; Send keys a little slower so the game reliably registers them.
SetKeyDelay 50, 50

global Running    := false          ; a single buy pass is currently executing
global LoopActive := false          ; the repeat loop is armed
global IntervalMs := 5 * 60 * 1000  ; how often to repeat: 5 minutes
global FirstSel   := 0              ; index of first ticked item (locked at Start)
global LastSel    := 0              ; index of last ticked item (locked at Start)
global PassQty    := 20             ; fixed quantity bought per item each pass
global SessionStart := 0            ; A_TickCount when the current run's buying began (0 = idle)

; Which shop the macro drives: "seeds" or "gears".
global UiActiveMode := "seeds"      ; tab currently shown in the UI (live)
global ActiveMode   := "seeds"      ; tab locked in for the running pass
global ActiveItems  := []           ; item list for the running pass (Seeds or Gears)

; Live UI state, kept in sync by messages from the page. Each tab keeps its own
; ticked set; the active tab's set is snapshotted into SelSet at Start.
global SeedSel := []                ; sorted 1-based seed indices currently ticked
global GearSel := []                ; sorted 1-based gear indices currently ticked
global SelSet  := Map()             ; locked-at-Start lookup: index -> true

; WebView2 / window handles (kept global so they are not garbage-collected).
global MainGui    := 0
global controller := 0
global wv         := 0

; --- Free version: the macro is free, but the BEST seeds (bottom of the list)
;     are locked until the user unlocks them with a subscription paste-code (the
;     same Google + Stripe auth the website already uses).
;
;     The lock is a drip funnel: on the install day the best `BaseLock` (2) seeds are
;     locked, so a brand-new user still gets almost the whole list free on day one but
;     immediately sees that the very best seeds are Pro (the paywall exists from minute
;     one, without spiking day-one bounce); every calendar day after that, `DailyLock`
;     (2) more lock from best toward worst, until the whole list is locked. The gentle
;     ramp keeps day-one users from getting frustrated and bouncing to a different macro
;     before they've felt the value.
;
;     The free region is anchored on the seeds that existed AT INSTALL, matched by
;     NAME (not by list position). At install we snapshot the ordered seed names;
;     the free seeds are the worst `freeWorst` of that snapshot, and freeWorst
;     shrinks each calendar day. Because the anchor is by name, ANY seed that
;     wasn't in the install snapshot -- no matter where it's inserted in the list
;     -- is locked, and a seed that was already free stays free. This is what lets
;     new seeds be added ANYWHERE in the list (to match the in-game shop order)
;     without re-locking a previously free seed (see ComputeFreeNames). FreeNames
;     + PremiumCount are computed once at startup; the page gets a per-seed locked
;     flag (__LOCKED__), so it never has to assume the locked seeds are "the last N".
global BaseLock     := 2      ; best seeds locked on the install day (day 0) -> the best 2 are locked from day one
global DailyLock    := 2      ; extra best seeds locked per calendar day after install
global PremiumCount := 0      ; locked-seed count THIS session (set at startup; UI copy)
; Per-restock in-game appearance chance of EACH seed of a rarity. Drives the
; post-run "what you missed" upsell estimate (see MaybeShowUpgradeHint). The
; estimate always multiplies by the FULL count of that rarity in the list, not
; the locked count.
global SuperChance  := 0.003  ; ~0.3% per restock per super seed
global MythicChance := 0.014  ; ~1.4% per restock per mythic seed
global FreeNames    := Map()  ; seed NAME -> true for seeds outside the paywall (set at startup)
global Unlocked     := false                          ; premium unlocked this session?
global InstallFile  := A_AppData "\GardenMacro\install.txt"  ; first-run stamp + seed-name snapshot

; Version shown in the window's bottom corner. Bump AppVersion on real releases;
; the build time is taken from this file's last-modified date, so it changes every
; time you save the script -> an easy "did my latest change actually load?" check.
global AppVersion := "1.1.0"
global BackendBase  := "https://gardenmacro.com"   ; subscription backend
global VerifyUrl    := BackendBase "/api/desktop/verify"
global PingUrl      := BackendBase "/api/ping"              ; anonymous usage stats
global TutorialUrl  := "https://www.youtube.com/watch?v=2-K89sp8H4o"  ; "Video setup" link -> YouTube walkthrough
global TokenFile    := A_AppData "\GardenMacro\token.txt"   ; saved paste-code
global DeviceFile   := A_AppData "\GardenMacro\device.txt"  ; random anon install id
global DeviceId     := ""           ; set at startup (see GetOrCreateDeviceId)
global HeartbeatReq := 0            ; keeps the async ping COM object alive in-flight
global EventReq     := 0            ; keeps the async funnel-event ping alive in-flight

; --- Update check: the launcher downloads the newest macro.ahk from GitHub `main`
;     at LAUNCH, so you always start on the latest build. But this macro runs for
;     hours/days at a time (re-buying every restock), so a version shipped WHILE a
;     session is open won't be picked up until the user relaunches. So we re-read the
;     AppVersion published on `main` at startup and every UpdateCheckMs; if it's newer
;     than the running build we show a red "restart to update" banner in the UI. The
;     source of truth is the SAME raw URL the launcher pulls from, so there is exactly
;     one version to bump per release (AppVersion above) -- nothing else to keep in sync.
global UpdateSrcUrl   := "https://raw.git" "hubusercontent.com/LanD" "ocsApp/Gag" "macro2/main/macro.ahk"
global UpdateCheckMs  := 60 * 60 * 1000   ; re-check for a newer build hourly while open
global UpdateNotified := false            ; banner already shown this session? (only nag once)
global UpdateReq      := 0                ; keeps the update-check COM object alive in-flight

; --- Loyalty discount: as a user accumulates macro runtime (added up across every
;     session) they earn a 50%-off code for Pro at each hour-milestone in DiscountMiles
;     -- so it shows at 5h, then again at 20h. Each milestone fires once, on the Stop
;     that first crosses it, and takes priority over the post-run upsell hint. The
;     cumulative runtime + how many milestones have been shown (DiscountStage) are
;     persisted so it survives restarts and never repeats a milestone. Pro users never
;     see it (nothing left to sell).
global UsageFile     := A_AppData "\GardenMacro\usage.txt"  ; cumulative runtime + milestone stage
global DiscountMiles := [5, 20]      ; ascending total-hours milestones; each shows the 50%-off code once
global DiscountCode  := "promacro"   ; 50%-off code shown at each milestone
global TotalRunMs    := 0            ; cumulative macro runtime in ms (loaded at startup)
global DiscountStage := 0            ; how many DiscountMiles milestones have been shown so far

; --- Creator promo codes: on the FIRST Start ever, the user is asked whether they
;     have a promo code. A valid one (see PromoValid) is then shown in the window
;     corner as a "use CODE at checkout for N% off" reminder, reported to the stats
;     dashboard (carried on the usage heartbeat's "promo" field -> gardenmacro.com/stats),
;     and -- because the user already holds a discount code -- it suppresses the 5h
;     loyalty 50%-off popup. "Skip" dismisses the prompt for good. Stored UPPER-cased.
;
;     Each code carries its own discount percent (PromoValid maps CODE -> percent):
;     most creator codes are 10%, but LION is a 20% code. The percent is data-driven
;     -- it isn't persisted (it's re-derived from the code via PromoPercent), so the
;     saved promo.txt format is unchanged and the badge copy follows the code.
global PromoFile  := A_AppData "\GardenMacro\promo.txt"   ; "<asked 0|1>|<CODE>"
global PromoValid := Map(                                 ; the only codes we accept (CODE -> % off; keys UPPER, looked up case-insensitively)
    "OVER",   10,
    "ROOKIE", 10,
    "JUKEM",  10,
    "VEXY",   20,
    "LION",   20)
global PromoAsked := false        ; has the first-launch promo prompt been answered?
global PromoCode  := ""           ; the accepted code (UPPER-cased), "" if none / skipped
global PromoPct   := 0            ; the accepted code's discount percent (0 if none / skipped)

; --- Acquisition source: on the FIRST launch ever, BEFORE the creator-code prompt,
;     the user is asked "where did you hear about the macro?" (Reddit / TikTok /
;     YouTube / Google / AI / ...). The chosen channel is reported to the stats
;     dashboard (carried on the usage heartbeat's "src" field -> gardenmacro.com/stats)
;     so we can see which channels bring users. "Skip" dismisses it for good; stored
;     lowercase. Answering OR skipping chains into the creator-code prompt (see
;     ChooseSource / SkipSource -> ContinueToPromo). Pure attribution -- it never
;     affects how the macro runs.
global SourceFile  := A_AppData "\GardenMacro\source.txt"  ; "<asked 0|1>|<key>"
global SourceValid := Map(                                 ; accepted channel keys (lowercase) -> display label
    "reddit",  "Reddit",
    "tiktok",  "TikTok",
    "youtube", "YouTube",
    "google",  "Google search",
    "ai",      "AI (Claude, ChatGPT, Gemini)",
    "discord", "Discord",
    "friend",  "Friend",
    "other",   "Other")
global SourceAsked := false       ; has the first-launch acquisition-source prompt been answered?
global Source      := ""          ; chosen channel key (e.g. "reddit"), "" if skipped

; --- Seed list in the SAME top-to-bottom order as the in-game shop ---
;
;  ADDING A NEW SEED:  drop it in at the position that matches the in-game shop
;  order -- ANYWHERE in this list, top, middle, or bottom. Nothing else to do:
;  no count to bump, no config. Keep this list in the exact shop order, because
;  the macro navigates by counting Down presses (order = correctness).
;
;  The drip-lock funnel auto-adjusts: any seed that wasn't present at install is
;  treated as premium and locks immediately, and every seed that was already free
;  stays free -- regardless of where the new seed is inserted. The lock is
;  anchored by seed NAME (snapshotted at install), not by list position, so a
;  mid-list insert no longer shifts the anchor.  (See ComputeFreeNames.)
global Seeds := [
    {name: "Carrot",          rarity: "Common"},
    {name: "Strawberry",      rarity: "Common"},
    {name: "Blueberry",       rarity: "Common"},
    {name: "Tulip",           rarity: "Uncommon"},
    {name: "Tomato",          rarity: "Uncommon"},
    {name: "Apple",           rarity: "Uncommon"},
    {name: "Bamboo",          rarity: "Rare"},
    {name: "Corn",            rarity: "Rare"},
    {name: "Cactus",          rarity: "Rare"},
    {name: "Pineapple",       rarity: "Rare"},
    {name: "Mushroom",        rarity: "Epic"},
    {name: "Green Bean",      rarity: "Epic"},
    {name: "Banana",          rarity: "Epic"},
    {name: "Grape",           rarity: "Epic"},
    {name: "Coconut",         rarity: "Epic"},
    {name: "Mango",           rarity: "Epic"},
    {name: "Dragon Fruit",    rarity: "Legendary"},
    {name: "Acorn",           rarity: "Legendary"},
    {name: "Cherry",          rarity: "Legendary"},
    {name: "Sunflower",       rarity: "Legendary"},
    {name: "Fire Fern",       rarity: "Legendary"},
    {name: "Venus Fly Trap",  rarity: "Mythic"},
    {name: "Pomegranate",     rarity: "Mythic"},
    {name: "Poison Apple",    rarity: "Mythic"},
    {name: "Venom Spitter",   rarity: "Mythic"},
    {name: "Moon Bloom",      rarity: "Super"},
    {name: "Hypno Bloom",     rarity: "Super"},
    {name: "Dragon's Breath", rarity: "Super"}
]

; --- Gear list in the SAME top-to-bottom order as the in-game GEAR SHOP ---
;
;  The Gears tab is fully FREE (no drip-lock funnel applies to it). Order matters:
;  it must match the shop exactly, because the macro navigates purely by counting
;  Down presses. Rarity is cosmetic only -- it drives the same name flair as seeds
;  (Legendary glow / Mythic glow / Super rainbow); other rarities render plain.
global Gears := [
    {name: "Common Watering Can",  rarity: "Common"},
    {name: "Common Sprinkler",     rarity: "Common"},
    {name: "Sign",                 rarity: "Common"},
    {name: "Uncommon Sprinkler",   rarity: "Uncommon"},
    {name: "Trowel",               rarity: "Uncommon"},
    {name: "Rare Sprinkler",       rarity: "Rare"},
    {name: "Jump Mushroom",        rarity: "Rare"},
    {name: "Speed Mushroom",       rarity: "Rare"},
    {name: "Megaphone",            rarity: "Rare"},
    {name: "Shrink Mushroom",      rarity: "Epic"},
    {name: "Supersize Mushroom",   rarity: "Epic"},
    {name: "Gnome",                rarity: "Epic"},
    {name: "Flashbang",            rarity: "Epic"},
    {name: "Basic Pot",            rarity: "Common"},
    {name: "Legendary Sprinkler",  rarity: "Legendary"},
    {name: "Invisibility Mushroom",rarity: "Legendary"},
    {name: "Wheelbarrow",          rarity: "Legendary"},
    {name: "Player Magnet",        rarity: "Mythic"},
    {name: "Strawberry Sniper",    rarity: "Mythic"},
    {name: "Super Watering Can",   rarity: "Super"},
    {name: "Super Sprinkler",      rarity: "Super"}
]

; Work out which seeds are free this session (drip funnel; the locked set grows
; each calendar day after install). Must run after Seeds is defined and before
; BuildUi, which injects the per-seed locked flags + count into the page.
FreeNames    := ComputeFreeNames()
PremiumCount := CountLocked()

; Restore the lifetime macro runtime + whether the loyalty discount has been shown,
; and any promo code the user entered (shown in the corner; suppresses the 50%-off popup).
LoadUsage()
LoadPromo()
LoadSource()

BuildUi()

; Re-check any previously saved access code in the background so returning
; subscribers see the premium seeds already unlocked, without blocking the UI.
SetTimer(CheckSavedLicense, -800)

; Anonymous usage heartbeat: one random install id, a ping now and every 60s
; while the macro is open. Powers the live/today/week counts. Fire-and-forget
; and async, so it can never stall the UI or block anything.
DeviceId := GetOrCreateDeviceId()
; One-shot wrapper for the first beat. It MUST be a different function than
; SendHeartbeat: SetTimer keys on the callback, so scheduling SendHeartbeat both
; repeating and as a -one-shot would collapse into a single one-shot timer (the
; last call wins) and we'd only ever ping once per launch.
SetTimer(StartHeartbeat, -1500)     ; first beat shortly after launch, then repeat

; First-launch onboarding, shown ONCE shortly after the window is up (and after the
; saved-license check has had a chance to mark returning Pro users). Tied to app
; launch, NOT to pressing Start -- a brand-new user sees it right away. Two prompts
; run in sequence: first "where did you hear about the macro?" (attribution -> stats
; dashboard), then the creator-code prompt. Answering/skipping the first chains into
; the second (see ChooseSource / SkipSource -> ContinueToPromo).
SetTimer(MaybeAskSource, -1800)

; Update check: a few seconds after launch (after the license check + onboarding
; have had their turn), then hourly. If a newer macro.ahk has shipped to `main`
; while this session is open, show a red "restart to update" banner. Best-effort
; and never blocks the UI meaningfully (small ranged fetch, short timeouts).
SetTimer(StartUpdateChecks, -4000)

; ============================================================
;  UI  (WebView2 window + HTML/CSS/JS)
; ============================================================
BuildUi() {
    global MainGui, controller, wv, PremiumCount, Seeds, Gears, PromoCode, PromoPct, TokenFile
    global SourceAsked, PromoAsked

    dllPath := A_ScriptDir "\lib\WebView2Loader.dll"
    dataDir := A_AppData "\GardenMacro\WebView2"   ; writable user-data folder
    DirCreate dataDir

    MainGui := Gui("+Resize +AlwaysOnTop", "Garden Macro")
    MainGui.MarginX := 0
    MainGui.MarginY := 0
    MainGui.BackColor := 0xFFFFFF
    ; Light title bar (Win11) to match the white UI. Harmless if unsupported.
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", MainGui.Hwnd, "int", 20, "int*", 0, "int", 4)
    MainGui.OnEvent("Size",  OnGuiSize)
    MainGui.OnEvent("Close", (*) => ExitApp())
    MainGui.Show("w560 h600")

    ; Create the Edge WebView2 control filling the window. Pass the loader DLL
    ; path explicitly and a writable data dir (the default would sit next to the
    ; AutoHotkey exe in Program Files, which isn't writable).
    controller := WebView2.create(MainGui.Hwnd, , 0, dataDir, "", 0, dllPath)
    wv := controller.CoreWebView2

    s := wv.Settings                          ; lock it down so it feels like an app
    s.AreDefaultContextMenusEnabled := false
    s.AreDevToolsEnabled            := false
    s.IsZoomControlEnabled          := false
    s.IsStatusBarEnabled            := false
    try s.AreBrowserAcceleratorKeysEnabled := false

    wv.add_WebMessageReceived(OnWebMessage)

    html := StrReplace(HtmlTemplate(), "__SEEDS__", BuildItemsJs(Seeds))
    html := StrReplace(html, "__GEARS__", BuildItemsJs(Gears))
    html := StrReplace(html, "__LOCKED__", BuildLockedJs())
    html := StrReplace(html, "__PREMIUM__", PremiumCount)
    html := StrReplace(html, "__VERSION__", VersionLabel())
    html := StrReplace(html, "__PROMO__", PromoCode)   ; "" if none/skipped -> badge stays hidden
    html := StrReplace(html, "__PROMOPCT__", PromoPct) ; the code's discount percent (0 if none) -> badge "N% off"
    hasToken := (FileExist(TokenFile) && ReadToken(TokenFile) != "") ? "1" : "0"  ; returning user? -> skip the promo wall
    ; A first-launch onboarding wall arrives ~1.8s after load (see MaybeAskSource), so the
    ; fully-rendered app would flash until then. If a wall IS going to show, tell the page to
    ; paint a plain cover from the very first frame; the real wall cross-dissolves in over it.
    ;   source wall shows <=> source not yet answered
    ;   promo  wall shows <=> source done, promo not asked, and not (likely) Pro -- a saved
    ;                         token means a returning user (already onboarded / probably Pro).
    willOnboard := (!SourceAsked) || (!PromoAsked && hasToken = "0")
    html := StrReplace(html, "__ONBOARD__", willOnboard ? "1" : "0")
    wv.NavigateToString(html)
}

; Keep the WebView2 control sized to the window's client area.
OnGuiSize(thisGui, minMax, w, h) {
    global controller
    if controller
        controller.Fill()
}

; Build an item list (Seeds or Gears) as a JS array literal injected into the page.
BuildItemsJs(list) {
    out := "["
    for i, it in list {
        out .= "{n:" JsStr(it.name) ",r:" JsStr(it.rarity) "}"
        if i < list.Length
            out .= ","
    }
    return out "]"
}

; Build a JS array of 0/1 locked flags, one per seed, in Seeds order (1 = locked).
; The page uses this to mark premium rows directly, so it never has to assume the
; locked seeds are a contiguous block at the bottom (they are in practice, but a
; mid-list insert into the free region wouldn't break the UI this way).
BuildLockedJs() {
    global Seeds, FreeNames
    out := "["
    for i, it in Seeds {
        out .= FreeNames.Has(it.name) ? "0" : "1"
        if i < Seeds.Length
            out .= ","
    }
    return out "]"
}

; Version string for the bottom-corner label, e.g. "1.0.0  built Jun 17 14:32".
; The build time comes from this script file's last-modified date, so it updates
; every time you save -> a quick visual check that the running build is current.
VersionLabel() {
    global AppVersion
    label := AppVersion
    try label .= "  built " FormatTime(FileGetTime(A_ScriptFullPath, "M"), "MMM d HH:mm")
    return label
}

; JSON/JS-safe double-quoted string.
JsStr(str) {
    str := StrReplace(str, "\", "\\")
    str := StrReplace(str, '"', '\"')
    return '"' str '"'
}

; ============================================================
;  Messages from the page  ->  AHK
;  Formats (pipe-delimited strings):
;    "sel|1,3,5"   selection changed (csv of 1-based indices; may be empty)
;    "start"       run / arm the loop
;    "stop"        stop
; ============================================================
OnWebMessage(sender, args) {
    global SeedSel, GearSel, UiActiveMode
    msg := args.TryGetWebMessageAsString()
    parts := StrSplit(msg, "|")
    cmd := parts.Length >= 1 ? parts[1] : ""

    switch cmd {
        case "sel":
            ; "sel|<tab>|<csv>" -> store into that tab's selection array.
            tab := parts.Length >= 2 ? parts[2] : "seeds"
            csv := parts.Length >= 3 ? parts[3] : ""
            arr := []
            if csv != "" {
                for token in StrSplit(csv, ",") {
                    if IsInteger(token)
                        arr.Push(Integer(token))
                }
            }
            if (tab = "gears")
                GearSel := arr
            else
                SeedSel := arr
        case "tab":
            ; "tab|<name>" -> remember which tab is showing so F1 starts the right one.
            UiActiveMode := (parts.Length >= 2 && parts[2] = "gears") ? "gears" : "seeds"
        case "start":
            StartMacro()
        case "stop":
            StopMacro()
        case "openaccess":
            OpenAccessPage()
        case "openhelp":
            OpenHelpPage()
        case "opentutorial":
            OpenTutorialPage()
        case "paste":
            PasteAccessCode()
        case "activate":
            p := InStr(msg, "|")            ; rest-of-line: the pasted code
            ActivateCode(p ? SubStr(msg, p + 1) : "")
        case "promoapply":
            p := InStr(msg, "|")            ; rest-of-line: the entered promo code
            ApplyPromo(p ? SubStr(msg, p + 1) : "")
        case "promoskip":
            SkipPromo()
        case "source":
            p := InStr(msg, "|")            ; rest-of-line: the chosen acquisition channel
            ChooseSource(p ? SubStr(msg, p + 1) : "")
        case "sourceskip":
            SkipSource()
        case "ev":
            ; "ev|<name>" -> forward a one-off funnel event from the WebView (popup
            ; shown/copied/dismissed). The backend allowlists which names it accepts.
            if parts.Length >= 2 && parts[2] != ""
                SendEvent(parts[2])
        case "fit":
            if parts.Length >= 2 && IsInteger(parts[2])
                FitWindowHeight(Integer(parts[2]))
    }
}

; Shrink the window so its client area is exactly `clientH` physical px tall.
; The page measures the height it needs (through the Start/Stop row) and asks
; for it via a "fit" message; width is left unchanged.
FitWindowHeight(clientH) {
    global MainGui, controller
    if (!MainGui || clientH < 100)
        return
    hwnd := MainGui.Hwnd
    WinGetPos(&wx, &wy, &winW, &winH, hwnd)
    WinGetClientPos( , , , &cliH, hwnd)
    chrome := winH - cliH                 ; title bar + borders (physical px)
    WinMove(wx, wy, winW, clientH + chrome, hwnd)
    if controller
        controller.Fill()
}

; ---- Push to the page ----
Post(str) {
    global wv
    if wv
        try wv.PostWebMessageAsString(str)
}
UiStatus(text)  => Post("status|" text)            ; status line text
UiState(on)     => Post("state|"  (on ? "1" : "0")) ; running? -> button enable/disable

; ============================================================
;  Hotkeys
; ============================================================
F1:: StartMacro()
F2:: StopMacro()

StartMacro() {
    global LoopActive, Running, IntervalMs, FirstSel, LastSel, PassQty
    global SeedSel, GearSel, SelSet, Unlocked, MainGui, SessionStart
    global UiActiveMode, ActiveMode, ActiveItems, Seeds, Gears

    if LoopActive               ; loop already armed -> ignore
        return

    ; Snapshot which tab/shop we're running plus its item list + selection.
    ActiveMode  := (UiActiveMode = "gears") ? "gears" : "seeds"
    ActiveItems := (ActiveMode = "gears") ? Gears : Seeds
    src         := (ActiveMode = "gears") ? GearSel : SeedSel

    ; Gears is a Pro feature -- if it isn't unlocked, don't run; open the unlock UI.
    if (ActiveMode = "gears" && !Unlocked) {
        UiStatus("Gears is a Pro feature.")
        Post("access|open")
        return
    }

    ; Drop any locked premium seeds unless they've been unlocked (seeds only -- the
    ; gear tab has no lock). The UI already prevents ticking them; defense in depth.
    picks := []
    for idx in src {
        if (ActiveMode = "seeds" && !Unlocked && IsPremiumIndex(idx))
            continue
        picks.Push(idx)
    }

    if picks.Length = 0 {
        UiStatus("Nothing selected.")
        noun := (ActiveMode = "gears") ? "gear" : "seed"
        MsgBox "No " noun "s selected. Tick at least one " noun "."
        return
    }

    ; Lock in the selection + quantity for this whole loop session.
    FirstSel := picks[1]
    LastSel  := picks[picks.Length]
    SelSet   := Map()
    for idx in picks
        SelSet[idx] := true
    PassQty := 20               ; fixed buy amount per item

    LoopActive := true
    Running := true
    UiState(true)

    ; Get out of the way: minimize the macro window so Roblox is in full view.
    ; (Setup focuses Roblox next; use F2 to stop while it's running.)
    try MainGui.Minimize()

    ; One-time setup: get into the shop UI and land on the first selected item.
    if !Setup() {
        Running := false
        LoopActive := false
        UiState(false)
        try MainGui.Restore()   ; setup failed -> bring the window back so the error is visible
        return
    }
    SessionStart := A_TickCount ; setup done -> start timing the run (drives the post-run upsell hint)
    BuyPass()                   ; first buy pass (ends on the first selected item)
    Running := false

    if LoopActive {             ; still armed -> schedule the repeats
        SetTimer(DoPass, IntervalMs)
        UiStatus("Done. Waiting for next restock...  (Stop / F2 to end)")
    }
}

; One repeat: only the buy pass, no setup. Guarded so passes never overlap.
DoPass() {
    global Running, LoopActive
    if Running                  ; previous pass still going -> skip this tick
        return
    if !LoopActive              ; loop was stopped between ticks
        return
    Running := true
    BuyPass()
    Running := false
    if LoopActive
        UiStatus("Done. Waiting for next restock...  (Stop / F2 to end)")
}

StopMacro() {
    global Running, LoopActive, SessionStart
    LoopActive := false
    SetTimer(DoPass, 0)         ; cancel the 5-minute loop
    Running := false            ; interrupt any pass in progress
    ; Make sure no arrow key is left stuck down.
    Send "{Up up}"
    Send "{Down up}"
    UiState(false)
    UiStatus("Stopped.")

    ; End of a real run. Bank this session toward the lifetime total, then decide
    ; what to show: a user who has just crossed a runtime milestone (5h, then 20h)
    ; gets the 50%-off code; everyone else may get the "what the locked seeds would
    ; have earned you" upsell. Guarded so a Stop with no run does nothing.
    if (SessionStart > 0) {
        elapsed := A_TickCount - SessionStart
        SessionStart := 0
        AddRuntime(elapsed)                 ; add this run to the lifetime total + save
        if MaybeShowLoyaltyDiscount()       ; crossed a 5h/20h milestone -> show 50%-off, skip the hint
            return
        MaybeShowUpgradeHint(elapsed)
    }
}

; ============================================================
;  Free version: premium unlock (best seeds, drip funnel)
;  The macro runs free; the best seeds stay locked until the user pastes a valid
;  subscription code, checked against the same backend the website uses
;  (/api/desktop/verify). The locked set is not fixed -- it grows each calendar
;  day after install (see ComputeFreeNames), locking from best to worst. Which
;  seeds are free is decided by NAME, so new seeds can be inserted anywhere.
; ============================================================

; True if seed index `i` (1-based) is a locked premium seed. Decided by name via
; the precomputed FreeNames set, so list position / insert order doesn't matter.
IsPremiumIndex(i) {
    global Seeds, FreeNames
    if (i < 1 || i > Seeds.Length)
        return false
    return !FreeNames.Has(Seeds[i].name)
}

; Count of locked seeds in the current list (for the UI upsell copy).
CountLocked() {
    global Seeds, FreeNames
    n := 0
    for it in Seeds
        if !FreeNames.Has(it.name)
            n++
    return n
}

; Count seeds of a given rarity in the current list (ALL of them, locked or not).
; Read live from Seeds so the upsell estimate tracks the list -- adding a seed of
; that rarity raises the number on its own; nothing is hardcoded.
CountSeedsByRarity(rarity) {
    global Seeds
    n := 0
    for it in Seeds
        if (it.rarity = rarity)
            n++
    return n
}

; Count LOCKED seeds of a given rarity right now (the premium ones behind the
; paywall). Used only to decide WHICH tiers the popup mentions, not the estimate.
CountLockedSeedsByRarity(rarity) {
    global Seeds, FreeNames
    n := 0
    for it in Seeds
        if (it.rarity = rarity && !FreeNames.Has(it.name))
            n++
    return n
}

; After a run, optionally show a free user what the locked premium seeds would
; have earned them this session. Per-rarity estimate = (restocks the run spanned,
; one every IntervalMs) x (the FULL count of that rarity in the list) x (that
; rarity's per-restock appearance chance). The multiplier is always the full
; rarity count, never the locked count. Two tiers:
;   - If ANY mythic seed is locked, gate on mythics (1.4% each -> fires on a
;     realistic ~1-2h session) and show BOTH the mythic and super counts.
;   - Otherwise gate on supers alone (0.3% each -> long session), the original
;     behavior, shown super-only.
; Skipped entirely when nothing is locked (already Pro, or day-one fully-free).
; Counts are rounded to the nearest whole and floored at 1, so the popup never
; shows a fraction (e.g. an in-progress 0.1 super reads as 1).
MaybeShowUpgradeHint(elapsedMs) {
    global Unlocked, PremiumCount, IntervalMs, MainGui, SuperChance, MythicChance, PromoCode
    if (Unlocked || PremiumCount <= 0)      ; everything already unlocked -> nothing to sell
        return
    if (PromoCode != "")                    ; holds a creator discount code -> never show a rival code
        return                              ; (Stripe codes don't stack; protect the creator's code)
    restocks := 1 + (elapsedMs // IntervalMs)
    superExp := restocks * CountSeedsByRarity("Super") * SuperChance

    if (CountLockedSeedsByRarity("Mythic") > 0) {
        ; Mythic tier: mythics are common enough that this fires on a real session.
        mythicExp := restocks * CountSeedsByRarity("Mythic") * MythicChance
        if (mythicExp < 1)                  ; too short to have averaged a mythic -> stay quiet
            return
        try MainGui.Restore()               ; un-minimize so the hint is actually seen
        Post("hint|" HintCount(mythicExp) "|" HintCount(superExp))
        SendEvent("hint_shown")             ; funnel: the post-session upsell popup was shown
        return
    }

    ; Super-only tier (no mythic locked yet): original long-session behavior.
    if (superExp < 1)                       ; too short to have averaged a super seed
        return
    try MainGui.Restore()
    Post("hint|0|" HintCount(superExp))
    SendEvent("hint_shown")                 ; funnel: the post-session upsell popup was shown
}

; Round an expected count for display: nearest whole, never below 1, so a small
; fraction still reads as "1" rather than 0 or a decimal.
HintCount(expected) {
    n := Round(expected)
    return n < 1 ? 1 : n
}

; ---- Loyalty discount (runtime milestones -> 50% off Pro) ----

; Load the lifetime runtime + milestone stage saved across sessions. File format:
; "<totalMs>|<stage>". Missing / unreadable -> zero usage, stage 0. Back-compat: the
; old "shown" flag stored 0/1, which already maps to stage 0 / 1 (the first milestone).
LoadUsage() {
    global UsageFile, TotalRunMs, DiscountStage
    if !FileExist(UsageFile)
        return
    raw := ""
    try raw := Trim(FileRead(UsageFile, "UTF-8"), " `t`r`n" Chr(0xFEFF))
    parts := StrSplit(raw, "|")
    if (parts.Length >= 1 && IsInteger(parts[1]))
        TotalRunMs := Integer(parts[1])
    if (parts.Length >= 2 && IsInteger(parts[2]))
        DiscountStage := Integer(parts[2])
}

; Persist the lifetime runtime + milestone stage (no BOM; create the folder if needed).
SaveUsage() {
    global UsageFile, TotalRunMs, DiscountStage
    try {
        SplitPath(UsageFile, , &dir)
        if (dir != "" && !DirExist(dir))
            DirCreate(dir)
        f := FileOpen(UsageFile, "w", "UTF-8-RAW")
        f.Write(TotalRunMs "|" DiscountStage)
        f.Close()
    }
}

; Add this run's elapsed ms to the lifetime total and persist it.
AddRuntime(ms) {
    global TotalRunMs
    if (ms > 0)
        TotalRunMs += ms
    SaveUsage()
}

; After a run, if the lifetime total has reached a new DiscountMiles milestone (5h,
; then 20h) that hasn't been shown yet, show the 50%-off code. Each milestone fires
; once, is skipped for Pro users, and takes priority over the upsell hint. Returns
; true if it showed the popup, so the caller can skip the hint.
MaybeShowLoyaltyDiscount() {
    global Unlocked, TotalRunMs, DiscountStage, DiscountMiles, DiscountCode, MainGui, PromoCode
    if (Unlocked)                           ; already Pro -> nothing to sell
        return false
    if (PromoCode != "")                    ; already holds a creator discount code -> don't pile on
        return false
    ; How many hour-milestones the lifetime total has now passed (DiscountMiles ascending).
    hours   := TotalRunMs / 3600000.0
    reached := 0
    for h in DiscountMiles
        if (hours >= h)
            reached++
    if (reached <= DiscountStage)           ; no new milestone crossed since last time -> stay quiet
        return false
    DiscountStage := reached
    SaveUsage()
    try MainGui.Restore()                   ; un-minimize so the offer is actually seen
    ; Carry the milestone hours just crossed so the popup copy reads "over 5/20 hours".
    Post("discount|" DiscountCode "|" DiscountMiles[reached])
    SendEvent("loyalty_shown")              ; funnel: the 50%-off loyalty popup was shown
    return true
}

; Current seed names, in list order.
SeedNames() {
    global Seeds
    out := []
    for it in Seeds
        out.Push(it.name)
    return out
}

; Work out which seeds are FREE right now and return them as a name -> true Map.
; Anchored on the seed list AT INSTALL (matched by name): the worst
; `(installCount - BaseLock)` seeds start free, and that free pool shrinks by
; DailyLock every calendar day, so the lock spreads from best to worst until
; nothing is free. Because the anchor is by name, ANY seed not in the install
; snapshot is locked no matter where it's inserted, and a seed that was already
; free is never re-locked by an insert.
ComputeFreeNames() {
    global Seeds, BaseLock, DailyLock
    rec  := GetInstallRecord()
    days := CalendarDaysSince(rec.stamp)

    ; Install-era ordered names. Old records stored only a count (no names) -- fall
    ; back to the current list's prefix for naming, but keep the install-time COUNT
    ; (rec.count) as the drip anchor so existing users' locked set doesn't move.
    ; The prefix matches the real install-era worst seeds as long as nothing was
    ; inserted into that install's free region (the worst seeds; never happens).
    src       := rec.names.Length ? rec.names : SeedNames()
    baseCount := rec.count

    freeWorst := (baseCount - BaseLock) - DailyLock * days   ; worst seeds still free
    if (freeWorst < 0)
        freeWorst := 0
    ; Never free more than the list holds. With BaseLock 2 the best 2 seeds stay locked
    ; even on day 0 (days = 0): the cap holds that day-0 baseline no matter how the day
    ; math works out, so the paywall is present from the very first launch.
    maxFree := Seeds.Length - Min(BaseLock, Seeds.Length)
    if (freeWorst > maxFree)
        freeWorst := maxFree

    free := Map()
    Loop Min(freeWorst, src.Length)
        free[src[A_Index]] := true
    return free
}

; Read (or, on first run, create) the install record: the first-run timestamp plus
; an ordered snapshot of the seed names at that moment, stored as
; "<YYYYMMDDHHMMSS>|name1|name2|...". Returns { stamp, names, count }: `count` is
; the install-era seed count (the drip anchor). Old records used "<stamp>|<count>";
; those read back with an empty `names` (count from the file) so the drip math is
; unchanged for existing users; ComputeFreeNames falls back to the current names.
GetInstallRecord() {
    global InstallFile, Seeds
    if FileExist(InstallFile) {
        raw := ""
        try raw := Trim(FileRead(InstallFile, "UTF-8"), " `t`r`n" Chr(0xFEFF))
        parts := StrSplit(raw, "|")
        stamp := parts.Length >= 1 ? parts[1] : ""
        if (stamp != "" && IsInteger(stamp) && StrLen(stamp) >= 8) {
            names := []
            ; New format: stamp|name1|name2|...  (the second field is non-numeric).
            ; Old format: stamp|count -> keep names empty, take count from the file.
            if (parts.Length >= 2 && !IsInteger(parts[2])) {
                Loop parts.Length - 1
                    names.Push(parts[A_Index + 1])
                return { stamp: stamp, names: names, count: names.Length }
            }
            if (parts.Length >= 2 && IsInteger(parts[2]))
                return { stamp: stamp, names: names, count: Integer(parts[2]) }
            return { stamp: stamp, names: names, count: Seeds.Length }
        }
    }
    ; First run: stamp "now" and snapshot the current ordered seed names.
    rec := { stamp: A_Now, names: SeedNames(), count: Seeds.Length }
    try {
        SplitPath(InstallFile, , &dir)
        if (dir != "" && !DirExist(dir))
            DirCreate(dir)
        f := FileOpen(InstallFile, "w", "UTF-8-RAW")
        body := rec.stamp
        for nm in rec.names
            body .= "|" nm
        f.Write(body)
        f.Close()
    }
    return rec
}

; Whole calendar days from the install date to today (install day = 0). Compares
; the date parts only so a rollover past midnight counts as a new day.
CalendarDaysSince(stamp) {
    today   := SubStr(A_Now, 1, 8) "000000"
    install := SubStr(stamp,  1, 8) "000000"
    d := DateDiff(today, install, "Days")
    return d < 0 ? 0 : d
}

; Background check on startup: if a saved code is still active, unlock live.
CheckSavedLicense() {
    global TokenFile, Unlocked
    if Unlocked
        return
    if !FileExist(TokenFile)
        return
    token := ReadToken(TokenFile)
    if (token = "")
        return
    res := VerifyToken(token)
    if (res.status = "active") {
        Unlocked := true
        Post("unlock|1")
    } else if (res.status = "inactive") {
        ; Server is CERTAIN there's no active subscription -> stay locked this session.
        ; We deliberately do NOT delete the saved code. If this "inactive" were ever a
        ; transient backend false-negative, deleting would permanently lock out a paying
        ; user; instead the next launch re-verifies and unlocks again. A genuinely
        ; cancelled code just keeps returning inactive (and re-unlocks automatically if
        ; the user resubscribes, since it's tied to their account, not a one-time grant).
    } else {
        ; Offline / server unreachable / status undetermined: trust the saved code for
        ; this session, like the launcher does, so paying users aren't locked out.
        Unlocked := true
        Post("unlock|1")
    }
}

; "Get access" -> open the sign-in / subscribe page in the default browser.
; Minimize the macro window so the browser sign-in page is in full view.
OpenAccessPage() {
    global BackendBase, MainGui
    ; Count this as a funnel step: an install that clicked through to the pay page.
    SendEvent("get_access")
    url := BackendBase "/signin.html"
    try
        Run(url)
    catch
        try Run("explorer.exe " url)
    try MainGui.Minimize()
}

; "Help & setup" -> open the setup guide / Discord help page in the browser.
OpenHelpPage() {
    global BackendBase
    url := BackendBase "/help.html"
    try
        Run(url)
    catch
        try Run("explorer.exe " url)
}

; "Video setup" -> open the YouTube walkthrough in the default browser.
; Same open-in-browser fallback as OpenHelpPage.
OpenTutorialPage() {
    global TutorialUrl
    try
        Run(TutorialUrl)
    catch
        try Run("explorer.exe " TutorialUrl)
}

; "Paste" button in the unlock popup. The page is served via NavigateToString (a
; non-secure origin) where the browser clipboard API is blocked, so read the
; Windows clipboard here and push the text into the code field on the page.
PasteAccessCode() {
    code := Trim(A_Clipboard)
    if (code = "") {
        Post("licensemsg|Your clipboard is empty. Copy your access code first.")
        return
    }
    Post("pastecode|" code)
}

; Verify a pasted code. On a confirmed active subscription: save it and unlock
; the locked premium seeds live. Otherwise tell the page what went wrong.
ActivateCode(code) {
    global TokenFile, Unlocked
    code := Trim(code)
    if (code = "") {
        Post("licensemsg|Paste your access code first.")
        return
    }
    res := VerifyToken(code)
    if (res.status = "active") {
        SaveToken(TokenFile, code)
        Unlocked := true
        Post("unlock|1")
    } else if (res.status = "inactive") {
        Post("licensemsg|That code isn't valid or has no active subscription.")
    } else {
        Post("licensemsg|Couldn't reach the server (" res.err "). Check your internet and try again.")
    }
}

; ============================================================
;  Creator promo codes (first-LAUNCH prompt -> discount corner badge)
;  Asked once, shortly after the app's first launch (see MaybeAskPromo) -- NOT on
;  Start. A valid code is shown in the corner as a checkout reminder ("use CODE for
;  N% off"), reported to the stats dashboard, and suppresses the 5h popup. The
;  percent is per-code (PromoValid), e.g. LION = 20%.
; ============================================================

; Show the first-launch "do you have a creator code?" prompt, once ever. Skipped if
; it's already been answered (PromoAsked) or the user is Pro (nothing to discount).
; Returns true if it actually opened the prompt, false if it suppressed it (already
; asked, or Pro) -- so the onboarding chain knows whether a wall is now showing.
MaybeAskPromo() {
    global PromoAsked, Unlocked
    if (PromoAsked || Unlocked)
        return false
    Post("promoask")
    return true
}

; True if `code` matches one of the accepted promo codes (case-insensitive).
IsValidPromo(code) {
    global PromoValid
    return PromoValid.Has(StrUpper(Trim(code)))   ; keys are stored UPPER -> normalize to match
}

; The discount percent for `code` (0 if it isn't an accepted code).
PromoPercent(code) {
    global PromoValid
    code := StrUpper(Trim(code))
    return PromoValid.Has(code) ? PromoValid[code] : 0
}

; Apply a promo code entered in the first-launch prompt. Valid -> store it UPPER-cased,
; report it to the dashboard, show the corner badge, and close the prompt. Invalid ->
; tell the page and leave the prompt open to retry or skip.
ApplyPromo(code) {
    global PromoAsked, PromoCode, PromoPct
    code := Trim(code)
    if (code = "") {
        Post("promobad|Enter a code.")
        return
    }
    if !IsValidPromo(code) {
        Post("promobad|That code isn't valid.")
        return
    }
    PromoCode  := StrUpper(code)             ; corner badge shows it in caps
    PromoPct   := PromoPercent(PromoCode)    ; per-code discount (e.g. LION -> 20)
    PromoAsked := true
    SavePromo()
    SendHeartbeat()                          ; report the code to gardenmacro.com/stats now
    Post("promook|" PromoCode "|" PromoPct)  ; show corner badge ("N% off") + close the prompt
}

; "Skip" in the first-launch prompt: remember we asked (so it never shows again) with
; no code. The page closes its own prompt; nothing else happens (the macro is unaffected).
SkipPromo() {
    global PromoAsked, PromoCode, PromoPct
    PromoAsked := true
    PromoCode  := ""
    PromoPct   := 0
    SavePromo()
}

; Load the saved promo state. File format: "<asked 0|1>|<CODE>". Missing -> not asked.
LoadPromo() {
    global PromoFile, PromoAsked, PromoCode, PromoPct
    if !FileExist(PromoFile)
        return
    raw := ""
    try raw := Trim(FileRead(PromoFile, "UTF-8"), " `t`r`n" Chr(0xFEFF))
    parts := StrSplit(raw, "|")
    if (parts.Length >= 1 && parts[1] = "1")
        PromoAsked := true
    if (parts.Length >= 2)
        PromoCode := StrUpper(Trim(parts[2]))
    PromoPct := PromoPercent(PromoCode)     ; percent isn't persisted -> re-derive from the saved code
}

; Persist the promo state (no BOM; create the folder if needed).
SavePromo() {
    global PromoFile, PromoAsked, PromoCode
    try {
        SplitPath(PromoFile, , &dir)
        if (dir != "" && !DirExist(dir))
            DirCreate(dir)
        f := FileOpen(PromoFile, "w", "UTF-8-RAW")
        f.Write((PromoAsked ? "1" : "0") "|" PromoCode)
        f.Close()
    }
}

; ============================================================
;  Acquisition source (first-LAUNCH prompt -> stats dashboard)
;  Asked once, shortly after first launch and BEFORE the creator-code prompt: "Where
;  did you hear about the macro?" The chosen channel (Reddit / TikTok / YouTube /
;  Google / AI / ...) is reported to the stats dashboard (carried on the usage
;  heartbeat's "src" field) so we can see which channels bring users. "Skip" dismisses
;  it for good. Answering or skipping chains into the creator-code prompt. Pure
;  attribution -- it never changes how the macro runs.
; ============================================================

; Show the first-launch "where did you hear about us?" prompt, once ever. If it has
; already been answered, skip it and go straight to the creator-code prompt.
MaybeAskSource() {
    global SourceAsked
    if SourceAsked {
        ContinueToPromo()        ; already answered before -> chain to the promo prompt
        return
    }
    Post("sourceask")
}

; The page reports the chosen channel as "source|<key>". Record + persist it, report
; it to the stats dashboard now, then chain into the creator-code prompt. An unknown
; key is folded into "other" so it's still counted.
ChooseSource(key) {
    global SourceAsked, Source, SourceValid
    key := StrLower(Trim(key))
    if !SourceValid.Has(key)
        key := "other"
    Source := key
    SourceAsked := true
    SaveSource()
    SendHeartbeat()              ; report the channel to gardenmacro.com/stats now
    ContinueToPromo()
}

; "Skip" the source prompt: remember we asked (so it never shows again) with no
; channel, then chain into the creator-code prompt.
SkipSource() {
    global SourceAsked, Source
    SourceAsked := true
    Source := ""
    SaveSource()
    ContinueToPromo()
}

; Once the source question is settled, show the creator-code prompt if it still
; applies; otherwise tell the page to close the onboarding wall and reveal the app.
ContinueToPromo() {
    ; The promo-suppression guard lives solely in MaybeAskPromo. If it opens the promo
    ; wall, that wall replaces the source wall (openPromoAsk closes ours -> no flash);
    ; if it suppresses the prompt (already asked / Pro), close our wall to reveal the app.
    if !MaybeAskPromo()
        Post("sourcedone")
}

; Load the saved source state. File format: "<asked 0|1>|<key>". Missing -> not asked.
LoadSource() {
    global SourceFile, SourceAsked, Source
    if !FileExist(SourceFile)
        return
    raw := ""
    try raw := Trim(FileRead(SourceFile, "UTF-8"), " `t`r`n" Chr(0xFEFF))
    parts := StrSplit(raw, "|")
    if (parts.Length >= 1 && parts[1] = "1")
        SourceAsked := true
    if (parts.Length >= 2)
        Source := StrLower(Trim(parts[2]))
}

; Persist the source state (no BOM; create the folder if needed).
SaveSource() {
    global SourceFile, SourceAsked, Source
    try {
        SplitPath(SourceFile, , &dir)
        if (dir != "" && !DirExist(dir))
            DirCreate(dir)
        f := FileOpen(SourceFile, "w", "UTF-8-RAW")
        f.Write((SourceAsked ? "1" : "0") "|" Source)
        f.Close()
    }
}

; ---- Backend verification + token storage (mirrors the launcher) ----

; POST { "token": <code> } and classify the outcome:
;   "active"   -> HTTP 200 with active:true     -> unlock
;   "inactive" -> HTTP 200 active:false, or 401  -> reject the code
;   "error"    -> request never completed / non-conclusive (offline, 5xx)
VerifyToken(token) {
    global VerifyUrl
    body := '{"token":"' JsonEscape(Trim(token)) '"}'
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(5000, 5000, 5000, 15000)    ; resolve, connect, send, receive (ms)
        req.Open("POST", VerifyUrl, false)
        req.SetRequestHeader("Content-Type", "application/json")
        req.Send(body)
        status := req.Status
        if (status = 200)
            return { status: ResponseIsActive(req.ResponseText) ? "active" : "inactive", err: "" }
        if (status = 401)
            return { status: "inactive", err: "HTTP 401" }
        return { status: "error", err: "HTTP " status }
    } catch as e {
        return { status: "error", err: e.Message }
    }
}

; True if the JSON body has  "active": true  (tolerant of whitespace and case).
ResponseIsActive(text) {
    return RegExMatch(text, 'i)"active"\s*:\s*true') > 0
}

; Minimal JSON-string escaping for the token (signed base64url, but escape
; defensively so a stray quote/backslash can't break the request body).
JsonEscape(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", "")
    s := StrReplace(s, "`n", "")
    s := StrReplace(s, "`t", "")
    return s
}

; Read the saved paste-code (BOM-safe), trimmed. "" if missing / unreadable.
ReadToken(path) {
    try
        return Trim(FileRead(path, "UTF-8"), " `t`r`n" Chr(0xFEFF))
    catch
        return ""
}

; Save the code with no BOM; create the folder if needed.
SaveToken(path, text) {
    SplitPath(path, , &dir)
    if (dir != "" && !DirExist(dir))
        DirCreate(dir)
    f := FileOpen(path, "w", "UTF-8-RAW")
    f.Write(text)
    f.Close()
}

; ---- Anonymous usage stats (heartbeat) ----

; Return this install's random anonymous id, creating + saving one on first run.
; It's just a GUID — no account, email, or machine info — used only to count
; distinct installs (live / today / this week) on the backend.
GetOrCreateDeviceId() {
    global DeviceFile
    id := ReadToken(DeviceFile)
    if (id != "" && RegExMatch(id, "^[A-Za-z0-9-]{8,64}$"))
        return id
    id := NewGuid()
    SaveToken(DeviceFile, id)        ; reuses the BOM-free saver
    return id
}

; A fresh GUID via the Windows API, e.g. "3F2504E0-4F89-41D3-9A0C-0305E82C3301".
NewGuid() {
    buf := Buffer(16, 0)
    if (DllCall("ole32\CoCreateGuid", "ptr", buf) != 0)
        return Format("{:08x}{:08x}", Random(0, 0xFFFFFFFF), Random(0, 0xFFFFFFFF))
    out := Buffer(80, 0)
    DllCall("ole32\StringFromGUID2", "ptr", buf, "ptr", out, "int", 39)
    return RegExReplace(StrGet(out, "UTF-16"), "[{}]", "")
}

; First beat after launch, then arm the repeating 60s heartbeat. Kept separate
; from SendHeartbeat so the two timers have distinct callbacks (see SetTimer note
; at startup) — otherwise the repeat would never run.
StartHeartbeat() {
    SendHeartbeat()
    SetTimer(SendHeartbeat, 60000)
}

; Fire-and-forget usage ping. Async (Open with bAsync=true) and never waited on,
; so it returns instantly and can't stall the UI; we keep the COM object in a
; global so it isn't collected before the request finishes.
SendHeartbeat() {
    global PingUrl, DeviceId, AppVersion, HeartbeatReq, PromoCode, Source
    if (DeviceId = "")
        return
    ; Carry the entered promo code + acquisition source (if any) so the stats
    ; dashboard can attribute the install.
    promo := (PromoCode != "") ? ',"promo":"' JsonEscape(PromoCode) '"' : ""
    src   := (Source != "")    ? ',"src":"'   JsonEscape(Source)    '"' : ""
    body := '{"id":"' JsonEscape(DeviceId) '","v":"' JsonEscape(AppVersion) '"' promo src '}'
    try {
        HeartbeatReq := ComObject("WinHttp.WinHttpRequest.5.1")
        HeartbeatReq.SetTimeouts(3000, 3000, 3000, 8000)
        HeartbeatReq.Open("POST", PingUrl, true)      ; true = async, don't block
        HeartbeatReq.SetRequestHeader("Content-Type", "application/json")
        HeartbeatReq.Send(body)
    }
}

; Fire a one-off funnel-event ping (a heartbeat tagged with "ev"), e.g. when the
; user clicks "Get access". Lets the stats dashboard count distinct installs that
; reached the sign-in page. Same fire-and-forget style as SendHeartbeat: async,
; never waited on, kept alive in a global so it isn't collected mid-flight.
SendEvent(ev) {
    global PingUrl, DeviceId, AppVersion, EventReq
    if (DeviceId = "" || ev = "")
        return
    body := '{"id":"' JsonEscape(DeviceId) '","v":"' JsonEscape(AppVersion) '","ev":"' JsonEscape(ev) '"}'
    try {
        EventReq := ComObject("WinHttp.WinHttpRequest.5.1")
        EventReq.SetTimeouts(3000, 3000, 3000, 8000)
        EventReq.Open("POST", PingUrl, true)          ; true = async, don't block
        EventReq.SetRequestHeader("Content-Type", "application/json")
        EventReq.Send(body)
    }
}

; ============================================================
;  Update check ("restart to update" banner)
; ============================================================

; First check shortly after launch, then arm the hourly re-check. Split from
; CheckForUpdate for the same reason as StartHeartbeat/SendHeartbeat: SetTimer keys
; on the callback, so a function used as BOTH a one-shot and a repeat collapses into
; a single one-shot -- distinct callbacks keep both the first check and the repeat.
StartUpdateChecks() {
    global UpdateCheckMs
    CheckForUpdate()
    SetTimer(CheckForUpdate, UpdateCheckMs)
}

; Compare the AppVersion published on `main` against the running build; if `main`
; is newer, tell the page to show the red "restart to update" banner. Best-effort:
; any failure (offline, CDN hiccup, version not found in the fetched slice) leaves
; the banner hidden -- we never nag on a false positive. Fires once per session,
; then cancels the repeat so we stop fetching after the user has been told.
CheckForUpdate() {
    global AppVersion, UpdateNotified
    if UpdateNotified
        return
    latest := FetchLatestVersion()
    if (latest != "" && IsNewerVersion(latest, AppVersion)) {
        UpdateNotified := true
        SetTimer(CheckForUpdate, 0)      ; told them -> stop the hourly re-check
        Post("update|" latest)
    }
}

; Read the published AppVersion from the raw macro.ahk on `main`. Only a small slice
; is needed (AppVersion sits near the top of the file), so we ask for the first 16 KB
; with a Range header; GitHub's CDN answers 206 (partial) when honored or 200 (whole
; file) when not -- either works. Returns "" on any failure so callers stay quiet.
FetchLatestVersion() {
    global UpdateSrcUrl, UpdateReq
    try {
        UpdateReq := ComObject("WinHttp.WinHttpRequest.5.1")
        UpdateReq.SetTimeouts(3000, 3000, 3000, 5000)   ; resolve, connect, send, receive (ms)
        UpdateReq.Open("GET", UpdateSrcUrl, false)
        UpdateReq.SetRequestHeader("Cache-Control", "no-cache")
        UpdateReq.SetRequestHeader("Range", "bytes=0-16383")   ; only need the top of the file
        UpdateReq.Send()
        if (UpdateReq.Status != 200 && UpdateReq.Status != 206)
            return ""
        ; Match the definition line ( AppVersion := "x.y.z" ), not the comments that
        ; merely mention "AppVersion" -- only the assignment has ":=".
        if RegExMatch(UpdateReq.ResponseText, 'AppVersion\s*:=\s*"([\d.]+)"', &m)
            return m[1]
    }
    return ""
}

; True if dotted-numeric version `a` is strictly newer than `b`, compared component
; by component so "1.0.10" > "1.0.9" (a plain string compare would get that wrong).
; Missing / non-numeric components count as 0 (e.g. "1.1" > "1.0.9").
IsNewerVersion(a, b) {
    pa := StrSplit(a, "."), pb := StrSplit(b, ".")
    n := Max(pa.Length, pb.Length)
    Loop n {
        va := (A_Index <= pa.Length && IsInteger(pa[A_Index])) ? Integer(pa[A_Index]) : 0
        vb := (A_Index <= pb.Length && IsInteger(pb[A_Index])) ? Integer(pb[A_Index]) : 0
        if (va != vb)
            return va > vb
    }
    return false
}

; ============================================================
;  Setup (runs once) + Buy pass (repeats)
; ============================================================

; One-time setup: focus Roblox, get into the shop UI, enter keyboard navigation,
; snap to a known anchor, then move down onto the FIRST selected item.
;
;   Seeds:  click the shop at (697,103), press "e", then "\". Anchor = position 1
;           (the first seed) via Down 5x + hold Up 5s. The first seed sits ON the
;           anchor, so reaching seed N takes N-1 Down presses.
;   Gears:  you must already be standing in the open Gear Shop UI, so NO click and
;           NO "e" -- just "\". Anchor = position 1 (the first gear) via Down 2x, so
;           reaching gear N takes N-1 Down presses (same as seeds).
;
; Returns false if stopped or Roblox is missing.
Setup() {
    global ActiveMode, FirstSel
    CoordMode "Mouse", "Screen"

    ; 0. Focus the Roblox window.
    UiStatus("Focusing Roblox...")
    if WinExist("ahk_exe RobloxPlayerBeta.exe") {
        WinActivate
        WinWaitActive("ahk_exe RobloxPlayerBeta.exe", , 3)
    } else {
        UiStatus("Roblox not found.")
        MsgBox "Roblox window not found. Launch Roblox first."
        return false
    }
    if !Wait(500)
        return false

    ; Small nudge so Roblox registers the window focus / input.
    MouseGetPos &mx, &my
    MouseMove mx + 5, my + 5, 0
    MouseMove mx, my, 0
    if !Wait(200)
        return false

    ; 1. Open the shop. Gears: you're already inside the Gear Shop UI, so skip the
    ;    shop click and the "e". Seeds: nudge to the shop, click it, press "e".
    if (ActiveMode != "gears") {
        MouseMove 697 + 5, 103 + 5, 0
        MouseMove 697, 103, 0
        if !Wait(150)
            return false
        Click 697, 103
        if !Wait(300)
            return false

        Send "e"
        if !Wait(3500)
            return false
    }

    ; 2. Enter keyboard navigation of the UI by pressing the "\" / VK_OEM_5 key.
    ;    Every OTHER key here (e, arrows, Enter) worked but this one didn't, and
    ;    the reason is HOW it was sent. "{SC02B}" is a scancode-only event, so it
    ;    can reach Roblox with no virtual key attached -> Roblox reads the virtual
    ;    key and ignores it. So send vkDC (VK_OEM_5 = BackSlash) AND sc02B, as a
    ;    real down -> brief hold -> up. The hold matters too: SendInput fires
    ;    down+up instantly (SetKeyDelay is ignored in this mode) and Roblox can
    ;    miss a zero-length tap; a human press is held tens of ms. (On a Slovenian
    ;    QWERTZ that physical key types "zcaron" but still reports vk=DC sc=02B,
    ;    so this matches a real keypress on every layout.)
    Send "{vkDCsc02B down}"
    Sleep 60
    Send "{vkDCsc02B up}"
    if !Wait(300)
        return false

    if (ActiveMode = "gears") {
        ; 2b-gears. Snap to position 1 (the first gear): Up 5x then Down 5x to shake
        ;           the cursor into the list, then HOLD Up for 3s. A held key scrolls
        ;           all the way to the very top regardless of list length.
        UiStatus("Resetting to position 1...")
        Loop 5 {
            Send "{Up}"
            if !Wait(500)
                return false
        }
        Loop 5 {
            Send "{Down}"
            if !Wait(500)
                return false
        }
        Send "{Up down}"                 ; hold Up...
        if !Wait(3000) {                 ; ...for 3s (interruptible by Stop)
            Send "{Up up}"               ; release before bailing so no key is left stuck
            return false
        }
        Send "{Up up}"                   ; release Up -> now on position 1
        ; 2c-gears. Position 1 is the first gear, so reach gear FirstSel with
        ;           FirstSel-1 Down presses (same as seeds).
        downsToFirst := FirstSel - 1
    } else {
        ; 2b-seeds. Snap to position 1: Up 5x then Down 5x to shake the cursor into
        ;           the list, then HOLD Up for 3s. A held key scrolls all the way to
        ;           the very top regardless of list length, settling on the first seed.
        UiStatus("Resetting to position 1...")
        Loop 5 {
            Send "{Up}"
            if !Wait(500)
                return false
        }
        Loop 5 {
            Send "{Down}"
            if !Wait(500)
                return false
        }
        Send "{Up down}"                 ; hold Up...
        if !Wait(3000) {                 ; ...for 3s (interruptible by Stop)
            Send "{Up up}"               ; release before bailing so no key is left stuck
            return false
        }
        Send "{Up up}"                   ; release Up -> now on position 1
        ; 2c-seeds. Position 1 is the first seed, so reach seed FirstSel with
        ;           FirstSel-1 Down presses.
        downsToFirst := FirstSel - 1
    }

    ; 3. Move down from the anchor onto the FIRST selected item.
    Loop downsToFirst {
        Send "{Down}"
        if !Wait(300)
            return false
    }
    return true
}

; One buy pass. Assumes the cursor is on the FIRST selected seed.
; Walks DOWN buying each ticked seed, then walks back UP to the first
; selected seed -> ends where it started, ready to repeat with no setup.
BuyPass() {
    global Running, ActiveItems, SelSet, FirstSel, LastSel, PassQty

    ; Keep Roblox focused (this does NOT move the UI cursor).
    if WinExist("ahk_exe RobloxPlayerBeta.exe")
        WinActivate

    ; Walk DOWN from the first to the last selected seed, buying ticked ones.
    i := FirstSel
    Loop {
        if !Running
            return
        if SelSet.Has(i) {
            UiStatus(Format("Buying {} x{}", ActiveItems[i].name, PassQty))
            if !BuyHere(PassQty)
                return
        }
        if i >= LastSel
            break
        Send "{Down}"
        if !Wait(300)
            return
        i += 1
    }

    ; Walk back UP to the first selected seed for the next pass.
    Loop LastSel - FirstSel {
        if !Running
            return
        Send "{Up}"
        if !Wait(300)
            return
    }
}

; Buy the item at the current UI position `times` times.
; Steps: Enter (open) -> Down (to buy) -> Enter x times -> Up -> Enter.
; The Down/Up cancel out, so the cursor ends on the same position.
; Returns false if stopped, true otherwise.
BuyHere(times) {
    Send "{Enter}"          ; open / select the item on this position
    if !Wait(300)
        return false

    Send "{Down}"           ; move down to the buy button
    if !Wait(300)
        return false

    Loop times {            ; confirm the purchase `times` times (hot loop -> fast)
        Send "{Enter}"
        if !Wait(40)
            return false
    }

    Send "{Up}"             ; move back up
    if !Wait(300)
        return false

    Send "{Enter}"          ; finish -> back on the original position
    if !Wait(300)
        return false

    return true
}

; Sleep in small chunks so Stop / F2 can interrupt.
; Returns false if the run was stopped, true otherwise.
Wait(ms) {
    global Running
    elapsed := 0
    while (elapsed < ms) {
        if !Running
            return false
        Sleep 50
        elapsed += 50
    }
    return true
}

; ============================================================
;  HTML / CSS / JS  (the entire UI). __SEEDS__ is replaced at runtime.
;  ASCII-only on purpose (glyphs use CSS \unicode / HTML entities) so the
;  script file's encoding can never mangle the UI.
; ============================================================
HtmlTemplate() {
    return "
(
<!DOCTYPE html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width, initial-scale=1'>
<style>
  *{box-sizing:border-box}
  html,body{height:100%;margin:0}
  body{
    font-family:'Segoe UI',system-ui,-apple-system,sans-serif;
    background:#fff; color:#1a1a1a;
    display:flex; flex-direction:column; height:100vh;
    padding:16px 18px; gap:12px;
    -webkit-user-select:none; user-select:none; -webkit-font-smoothing:antialiased;
  }
  h1{margin:0;font-size:16px;font-weight:600}
  .sub{font-size:12px;color:#888;display:flex;justify-content:space-between;align-items:baseline;gap:10px}
  .sub a{color:#555;cursor:pointer;text-decoration:none}
  .sub a:hover{color:#000;text-decoration:underline}
  .sub a.help{color:#dc2626}
  .sub a.help:hover{color:#b91c1c}
  /* Tabs (Seeds / Gears) */
  .tabs{display:flex;gap:4px;border-bottom:1px solid #eee}
  .tab{appearance:none;border:none;background:none;font-family:inherit;font-size:13px;
       font-weight:600;color:#9a9a9a;cursor:pointer;padding:7px 13px;border-radius:7px 7px 0 0;
       border-bottom:2px solid transparent;margin-bottom:-1px}
  .tab:hover{color:#555}
  .tab.on{color:#1a1a1a;border-bottom-color:#1a1a1a}
  /* "Open the gear shop first" banner on the Gears tab */
  .note{display:flex;align-items:flex-start;gap:8px;padding:9px 11px;margin-bottom:2px;
        background:#fff8e6;border:1px solid #ffe6a8;border-radius:8px;
        font-size:12px;color:#8a6d1a;line-height:1.45}
  .note .ni{font-size:13px;line-height:1.2;flex-shrink:0}
  .note b{color:#6f5512}
  /* Subtle, persistent setup reminder (placeholder until a real onboarding/tutorial).
     Styled like the muted premium bar so it never fights the minimalist UI. */
  .setupnote{display:flex;align-items:center;gap:8px;padding:8px 11px;
        background:#fafafa;border-radius:8px;font-size:11.5px;color:#777;line-height:1.4}
  .setupnote .sni{font-size:13px;opacity:.65;flex-shrink:0}
  .setupnote b{color:#555;font-weight:600}
  /* Gears = Pro feature: the menu opens but is grayed out behind a lock */
  .prowrap{position:relative}
  .prodim{opacity:.5;filter:grayscale(100%);pointer-events:none;user-select:none}
  .prolock{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;
        justify-content:center;gap:9px;text-align:center;padding:16px;
        background:rgba(248,248,248,.55);backdrop-filter:blur(1px);border-radius:8px}
  .prolock .pl-ic{width:46px;height:46px;border-radius:50%;background:#e4e4e4;color:#8a8a8a;
        display:flex;align-items:center;justify-content:center;font-size:21px;
        box-shadow:0 3px 10px rgba(0,0,0,.10)}
  .prolock .pl-t{font-size:14.5px;font-weight:700;color:#3a3a3a}
  .prolock .pl-s{font-size:12px;color:#888;max-width:250px;line-height:1.45;margin-top:-3px}
  .prolock .btn{margin-top:3px}
  /* List */
  .list{flex:none;overflow:hidden;border-radius:8px;
        display:grid;grid-auto-flow:column;grid-auto-columns:1fr;align-content:start;
        background:linear-gradient(#f0f0f0,#f0f0f0) no-repeat 50% 0 / 1px 100%}
  .row{display:flex;align-items:center;gap:10px;padding:5px 12px;cursor:pointer;min-width:0;
       border-bottom:1px solid #f0f0f0}
  .row:hover{background:#f7f7f7}
  .row.sel{background:#f2f2f2}
  .box{width:16px;height:16px;flex-shrink:0;border:1.5px solid #bbb;border-radius:4px;position:relative}
  .row.sel .box{background:#1a1a1a;border-color:#1a1a1a}
  .row.sel .box::after{content:'\2713';position:absolute;inset:0;color:#fff;font-size:11px;font-weight:700;
        display:flex;align-items:center;justify-content:center}
  .name{flex:1;font-size:13.5px;position:relative}
  .row.sel .name{font-weight:600}
  /* High-rarity flair: glowing names + twinkling particles */
  .name.lg,.name.my,.name.sp{font-weight:700;overflow:visible}
  .name.lg{color:#e8a31a;text-shadow:0 0 6px rgba(240,180,40,.65),0 0 13px rgba(240,170,20,.4);
        animation:glowpulse 2s ease-in-out infinite}
  .name.my{color:#a855f7;text-shadow:0 0 6px rgba(168,85,247,.7),0 0 13px rgba(150,70,255,.45);
        animation:glowpulse 2.2s ease-in-out infinite}
  .name.sp{background:linear-gradient(90deg,#ff2d55,#ff8a00,#ffe600,#34c759,#00c7ff,#8b5cff,#ff2d55);
        background-size:200% auto;-webkit-background-clip:text;background-clip:text;
        -webkit-text-fill-color:transparent;color:transparent;
        filter:drop-shadow(0 0 6px rgba(255,255,255,.55));
        animation:rainbow 3s linear infinite}
  @keyframes glowpulse{0%,100%{filter:brightness(1)}50%{filter:brightness(1.35)}}
  @keyframes rainbow{to{background-position:200% center}}
  .spark{position:absolute;width:3px;height:3px;border-radius:50%;pointer-events:none;
        top:50%;left:0;opacity:0;animation:twinkle 1.6s ease-in-out infinite}
  .spark.lg{background:#ffd76b;box-shadow:0 0 5px #ffcb45}
  .spark.my{background:#d8b4fe;box-shadow:0 0 5px #b56bff}
  .spark.sp{background:#fff;box-shadow:0 0 5px #fff;animation:twinkle 1.6s ease-in-out infinite,hue 3s linear infinite}
  @keyframes twinkle{0%{opacity:0;transform:translateY(2px) scale(.3)}
        35%{opacity:1;transform:translateY(-3px) scale(1)}
        100%{opacity:0;transform:translateY(-11px) scale(.3)}}
  @keyframes hue{to{filter:hue-rotate(360deg)}}
  /* Footer */
  .footer{display:flex;align-items:center;gap:10px}
  .footer label{font-size:12px;color:#888}
  .btn{border:1px solid #d8d8d8;border-radius:7px;padding:9px 16px;font-size:13px;font-weight:500;
       cursor:pointer;font-family:inherit;background:#fff;color:#1a1a1a}
  .btn:hover{background:#f3f3f3}
  .btn.primary{background:#1a1a1a;color:#fff;border-color:#1a1a1a}
  .btn.primary:hover{background:#000}
  .btn:disabled{opacity:.35;cursor:default}
  .hk{font-size:11px;font-weight:600;opacity:.55;margin-left:6px;
      font-family:'Consolas','JetBrains Mono',monospace}
  .ver{margin-left:auto;font-size:11px;color:#bbb;white-space:nowrap;
       font-family:'Consolas','JetBrains Mono',monospace}
  /* "Restart to update" banner. Shown (in red) when a newer macro.ahk has shipped
     to `main` while this session was running (see CheckForUpdate). Sits right under
     the title so it's seen on every tab; hidden until AHK sends "update|<version>". */
  .updatebar{display:none;text-align:center;font-size:12px;font-weight:600;line-height:1.4;
       color:#b91c1c;background:#fef2f2;border:1px solid #fecaca;border-radius:8px;
       padding:8px 12px;margin-bottom:12px}
  .updatebar.show{display:block}
  .updatebar b{font-weight:800}
  /* Free version: locked premium seeds + Get-access bar + unlock modal */
  /* Locked premium rows keep their FULL rarity colors + glow + sparks (they
     sell the upgrade). The only "locked" cue is a clean lock badge on the box. */
  .row.locked{cursor:pointer}
  .row.locked:hover{background:#f7f7f7}
  .row.locked .box{border-color:#cfcfcf;background:#f4f4f4}
  .row.locked .box::after{content:'\1F512';position:absolute;inset:0;font-size:9px;
        color:#9a9a9a;display:flex;align-items:center;justify-content:center}
  .pbar{display:flex;align-items:center;gap:9px;padding:10px 12px;
        background:#fafafa;border-radius:8px;font-size:12.5px;color:#666;cursor:pointer}
  .pbar:hover{background:#f3f3f3;border-color:#dcdcdc}
  .pbar .plock{opacity:.55;font-size:13px}
  .pbar .pget{margin-left:auto;font-weight:600;color:#16a34a}
  .pbar.ok{background:#ecfdf5;border-color:#bbf7d0;color:#15803d;cursor:default;font-weight:500}
  .overlay{position:fixed;inset:0;background:rgba(20,20,20,.45);display:flex;
        align-items:center;justify-content:center;padding:20px;z-index:50}
  .modal{background:#fff;border-radius:14px;border:1px solid #e6e6e6;max-width:380px;width:100%;
        padding:20px;box-shadow:0 20px 50px rgba(0,0,0,.25)}
  .mh{display:flex;align-items:center;gap:9px;margin-bottom:10px}
  .mh h2{font-size:15px;font-weight:600;margin:0}
  .mlock{font-size:16px}
  .mx{margin-left:auto;border:none;background:none;font-size:21px;line-height:1;color:#aaa;
        cursor:pointer;padding:0 2px}
  .mx:hover{color:#333}
  .mdesc{font-size:12.5px;color:#777;margin:0 0 12px;line-height:1.5}
  .msteps{margin:0 0 14px 18px;padding:0;font-size:12.5px;color:#555;line-height:1.5}
  .msteps li{margin-bottom:4px}
  .btn.block{width:100%;margin-bottom:10px}
  .btn.green{background:#16a34a;color:#fff;border-color:#16a34a}
  .btn.green:hover{background:#15803d;border-color:#15803d}
  /* Creator-code wall: a solid full-window panel (not a floating modal popup) shown
     once on first launch. Covers the whole app window until the user confirms / skips. */
  .wall{position:fixed;inset:0;background:#fff;z-index:60;display:flex;
        align-items:center;justify-content:center;padding:24px;
        opacity:1;transition:opacity .36s ease}
  .wallinner{width:100%;max-width:320px;text-align:center;
        transition:opacity .36s ease,transform .36s ease}
  /* Onboarding transitions: walls cross-dissolve, their content fades + rises. */
  .wall.entering{opacity:0}
  .wall.entering .wallinner{opacity:0;transform:translateY(14px)}
  .wall.leaving{opacity:0}
  .wall.leaving .wallinner{opacity:0;transform:translateY(-10px)}
  .wall h2{font-size:22px;font-weight:800;margin:0 0 18px;color:#111}
  /* Welcome screen: the warm "you're in" finale after onboarding. */
  .welcome h2{margin:0;font-size:26px}
  .brandLogo{display:block;margin:0 auto 10px}
  .wall #promoInput{width:100%;text-align:center;font-size:16px;letter-spacing:1px;
        text-transform:uppercase;margin-bottom:4px}
  .wall .lmsg{text-align:center;margin:6px 0 12px}
  .wall .btn.block{width:100%}
  /* Source wall: "where did you hear about us?" -> a 2-col grid of channel buttons. */
  .srcgrid{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin:0 0 14px}
  .srcgrid .btn{width:100%;margin:0}
  .srcgrid .wide{grid-column:1 / -1}
  .wall .skip{display:inline-block;font-size:13px;color:#999;cursor:pointer}
  .wall .skip:hover{color:#555;text-decoration:underline}
  .prow{display:flex;gap:8px}
  #codeInput,#promoInput{flex:1;background:#fff;border:1px solid #d8d8d8;border-radius:7px;padding:8px 10px;
        font-size:13px;outline:none;font-family:inherit}
  #codeInput:focus,#promoInput:focus{border-color:#16a34a}
  .lmsg{font-size:12px;color:#888;margin-top:10px;min-height:15px;line-height:1.4}
  /* Post-run upsell hint: what the locked premium seeds would have earned */
  .hintwrap{display:flex;flex-direction:column;gap:2px;margin:6px 0 10px}
  .hintbig{font-size:27px;font-weight:800;line-height:1.2;text-align:center}
  .hintbig.sp{background:linear-gradient(90deg,#ff2d55,#ff8a00,#ffe600,#34c759,#00c7ff,#8b5cff,#ff2d55);
        background-size:200% auto;-webkit-background-clip:text;background-clip:text;
        -webkit-text-fill-color:transparent;color:transparent;animation:rainbow 3s linear infinite}
  .hintbig.my{color:#a855f7;text-shadow:0 0 7px rgba(168,85,247,.6),0 0 14px rgba(150,70,255,.4);
        animation:glowpulse 2.2s ease-in-out infinite}
  .hintDismiss{display:block;text-align:center;margin-top:8px;font-size:12px;color:#999;cursor:pointer}
  .hintDismiss:hover{color:#555;text-decoration:underline}
  /* Loyalty discount popup: the 50%-off code chip */
  .off{color:#16a34a;font-weight:800}
  .codebox{display:flex;align-items:center;gap:9px;margin:4px 0 14px}
  .codeval{flex:1;text-align:center;color:#15803d;background:#ecfdf5;border:1.5px dashed #86efac;
        border-radius:9px;padding:11px 12px;font-size:21px;font-weight:800;letter-spacing:2px;
        text-transform:uppercase;font-family:'Consolas','JetBrains Mono',monospace;
        -webkit-user-select:text;user-select:text}
  /* Promo-code corner badge: "USE CODE LION FOR 20% OFF" (only if a code was entered) */
  .promobadge{position:fixed;top:13px;right:14px;z-index:40;cursor:pointer;
        font-size:10.5px;font-weight:700;letter-spacing:.4px;text-transform:uppercase;
        color:#15803d;background:#ecfdf5;border:1px solid #bbf7d0;border-radius:999px;
        padding:4px 10px;line-height:1.3;font-family:'Consolas','JetBrains Mono',monospace}
  .promobadge:hover{background:#dcfce7;border-color:#86efac}
  .promobadge b{font-weight:800}
  /* Account tab: subscription management (Pro only) */
  .acard{padding:2px 0}
  .astatus{display:flex;align-items:center;gap:8px;font-size:13.5px;font-weight:600;color:#15803d;margin:2px 0 6px}
  .adot{width:8px;height:8px;border-radius:50%;background:#16a34a;box-shadow:0 0 0 3px rgba(22,163,74,.15);flex-shrink:0}
  .adesc{font-size:12.5px;color:#777;margin:0 0 12px;line-height:1.5}
  [hidden]{display:none !important}
</style>
</head>
<body>
  <div id='promoBadge' class='promobadge' hidden onclick='openAccess()'>Use code <b id='promoBadgeCode'></b> for <b id='promoBadgePct'></b>% off</div>
  <h1>Garden Macro</h1>
  <div id='updateBar' class='updatebar'>&#128260; A new version<span id='updateVer'></span> is available &mdash; <b>close and reopen the macro</b> to update.</div>
  <div class='tabs'>
    <button id='tabSeeds' class='tab on' onclick='switchTab("seeds")'>Seeds</button>
    <button id='tabGears' class='tab'    onclick='switchTab("gears")'>Gears</button>
    <button id='tabAccount' class='tab' hidden onclick='switchTab("account")'>Account</button>
  </div>
  <div class='sub'>
    <span id='count'>0 selected</span>
    <span><a onclick='send("openhelp")'>Help &amp; setup</a> &middot; <a class='help' onclick='send("opentutorial")'>Video setup</a> &middot; <a onclick='setAll(true)'>Select all</a> &middot; <a onclick='setAll(false)'>Clear</a></span>
  </div>

  <div id='seedsPane'>
    <div id='list' class='list'></div>
    <div id='premiumBar' class='pbar' onclick='openAccess()'>
      <span class='plock'>&#128274;</span>
      <span id='pbarText'>Best seeds are locked</span>
      <span class='pget'>Get access &rarr;</span>
    </div>
  </div>

  <div id='gearsPane' hidden>
    <div class='prowrap'>
      <div id='gearContent'>
        <div id='gearList' class='list'></div>
      </div>
      <div id='gearLock' class='prolock'>
        <span class='pl-ic'>&#128274;</span>
        <div class='pl-t'>Get Pro</div>
        <div class='pl-s'>The Gears macro is a Pro feature. Unlock it with Garden Macro Pro.</div>
        <button class='btn green' onclick='openAccess()'>Get Pro &rarr;</button>
      </div>
    </div>
  </div>

  <div id='accountPane' hidden>
    <div class='acard'>
      <div class='astatus'><span class='adot'></span> Garden Macro Pro is active</div>
      <p class='adesc'>To manage your subscription visit the <b>GardenMacro</b> website.</p>
    </div>
  </div>

  <div id='setupNote' class='setupnote' style='flex-direction:column;align-items:stretch;gap:3px'>
    <div style='display:flex;align-items:center;gap:8px'>
      <span class='sni'>&#9881;</span>
      <span>Turn on <b>UI Navigation</b> in Roblox settings for the macro to work.</span>
    </div>
    <div style='display:flex;align-items:center;gap:8px'>
      <span class='sni'>&#8635;</span>
      <span>Make sure you <b>rejoin the game</b> before starting the macro.</span>
    </div>
    <div style='display:flex;align-items:center;gap:8px'>
      <span class='sni'>&#9776;</span>
      <span>Make sure you are <b>inside the shop menu</b> when you start the macro.</span>
    </div>
    <div style='display:flex;align-items:center;gap:8px'>
      <span class='sni'>&#10227;</span>
      <span>The macro re-buys automatically <b style='color:#dc2626;font-weight:800'>every 5 minutes</b> on each restock.</span>
    </div>
  </div>

  <div id='footer' class='footer'>
    <button id='startBtn' class='btn primary' onclick='send("start")'>Start <span class='hk'>F1</span></button>
    <button id='stopBtn'  class='btn'         onclick='send("stop")'>Stop <span class='hk'>F2</span></button>
    <span class='ver'>v__VERSION__</span>
  </div>

  <div id='overlay' class='overlay' hidden>
    <div class='modal'>
      <div class='mh'>
        <span class='mlock'>&#128274;</span>
        <h2 id='modalTitle'>Unlock the best seeds</h2>
        <button class='mx' onclick='closeAccess()'>&times;</button>
      </div>
      <p class='mdesc'>Premium seeds and the Gears macro need Garden Macro Pro. Subscribe once, then paste your code to unlock them here.</p>
      <ol class='msteps'>
        <li>Open the sign-in page and subscribe with Google.</li>
        <li>Copy the access code it shows you.</li>
        <li>Paste it below and click Unlock.</li>
      </ol>
      <button class='btn green block' onclick='send("openaccess")'>Open sign-in page to get access &rarr;</button>
      <div class='prow'>
        <input id='codeInput' type='text' placeholder='Paste your access code' spellcheck='false' autocomplete='off'>
        <button class='btn' onclick='pasteCode()'>Paste</button>
        <button class='btn green' onclick='activate()'>Unlock</button>
      </div>
      <div id='licenseMsg' class='lmsg'></div>
    </div>
  </div>

  <div id='hintOverlay' class='overlay' hidden>
    <div class='modal'>
      <div class='mh'>
        <span class='mlock'>&#11088;</span>
        <h2 id='hintTitle'>You left rare seeds on the table</h2>
        <button class='mx' onclick='dismissHint()'>&times;</button>
      </div>
      <p class='mdesc'>If you had upgraded, this session would have bought you on average</p>
      <div class='hintwrap'>
        <div id='hintMythic' class='hintbig my'><span id='hintMythicNum'>0</span> <span id='hintMythicNoun'>mythic seeds</span></div>
        <div id='hintSuper' class='hintbig sp'><span id='hintSuperNum'>0</span> <span id='hintSuperNoun'>super seeds</span></div>
      </div>
      <p class='mdesc'>These are among the rarest seeds in the game and stay locked on the free plan. Upgrade and the macro grabs them for you on every restock &mdash; and here&#39;s <span class='off'>20% off</span> to get started:</p>
      <div class='codebox'>
        <span id='hintCode' class='codeval'>superseed</span>
        <button class='btn' onclick='copyCode(this, "hintCode")'>Copy</button>
      </div>
      <button class='btn green block' onclick='ctaHint()'>Unlock the best seeds &mdash; 20% off &rarr;</button>
      <a class='hintDismiss' onclick='dismissHint()'>Maybe later</a>
    </div>
  </div>

  <div id='discountOverlay' class='overlay' hidden>
    <div class='modal'>
      <div class='mh'>
        <span class='mlock'>&#127881;</span>
        <h2>You&#39;ve unlocked <span class='off'>50% off</span>!</h2>
        <button class='mx' onclick='dismissDiscount()'>&times;</button>
      </div>
      <p class='mdesc'>Thanks for running Garden Macro for over <span id='discountHours'>5</span> hours. Here&#39;s <b>50% off</b> Garden Macro Pro &mdash; enter this code at checkout:</p>
      <div class='codebox'>
        <span id='discountCode' class='codeval'>promacro</span>
        <button class='btn' onclick='copyDiscount(this)'>Copy</button>
      </div>
      <button class='btn green block' onclick='ctaDiscount()'>Get Pro &mdash; 50% off &rarr;</button>
      <a class='hintDismiss' onclick='dismissDiscount()'>Maybe later</a>
    </div>
  </div>

  <!-- First-launch cover: painted from frame 1 (when onboarding is pending) so the app is
       never visible before the first wall dissolves in over it. Placed BEFORE the walls so
       they stack on top of it during the cross-dissolve. -->
  <div id='bootCover' class='wall' hidden>
    <div class='wallinner welcome'>
      <svg class='brandLogo' width='58' height='58' viewBox='0 0 64 64' fill='none' xmlns='http://www.w3.org/2000/svg'>
        <rect width='64' height='64' rx='16' fill='#16a34a'/>
        <path d='M32 52 V30' stroke='#fff' stroke-width='3.6' stroke-linecap='round'/>
        <path d='M32 36 C22 36 17 28 18 19 C28 20 33 27 32 36 Z' fill='#fff'/>
        <path d='M32 40 C42 40 47 32 46 23 C36 24 31 31 32 40 Z' fill='#fff'/>
      </svg>
      <h2>Garden Macro</h2>
    </div>
  </div>

  <div id='sourceOverlay' class='wall' hidden>
    <div class='wallinner'>
      <h2>Where did you hear about the macro?</h2>
      <div class='srcgrid'>
        <button class='btn' onclick='chooseSource("reddit")'>Reddit</button>
        <button class='btn' onclick='chooseSource("tiktok")'>TikTok</button>
        <button class='btn' onclick='chooseSource("youtube")'>YouTube</button>
        <button class='btn' onclick='chooseSource("google")'>Google search</button>
        <button class='btn wide' onclick='chooseSource("ai")'>AI (Claude, ChatGPT, Gemini)</button>
        <button class='btn' onclick='chooseSource("discord")'>Discord</button>
        <button class='btn' onclick='chooseSource("friend")'>Friend</button>
        <button class='btn wide' onclick='chooseSource("other")'>Other</button>
      </div>
      <a class='skip' onclick='skipSource()'>Skip</a>
    </div>
  </div>

  <div id='promoOverlay' class='wall' hidden>
    <div class='wallinner'>
      <h2>Do you have a creator code?</h2>
      <input id='promoInput' type='text' placeholder='Enter code' spellcheck='false' autocomplete='off' onkeydown='if(event.key==="Enter")applyPromo()'>
      <div id='promoMsg' class='lmsg'></div>
      <button class='btn green block' onclick='applyPromo()'>Confirm</button>
      <button class='btn block' onclick='skipPromo()'>Skip</button>
    </div>
  </div>

  <div id='welcomeOverlay' class='wall' hidden>
    <div class='wallinner welcome'>
      <svg class='brandLogo' width='50' height='50' viewBox='0 0 64 64' fill='none' xmlns='http://www.w3.org/2000/svg'>
        <rect width='64' height='64' rx='16' fill='#16a34a'/>
        <path d='M32 52 V30' stroke='#fff' stroke-width='3.6' stroke-linecap='round'/>
        <path d='M32 36 C22 36 17 28 18 19 C28 20 33 27 32 36 Z' fill='#fff'/>
        <path d='M32 40 C42 40 47 32 46 23 C36 24 31 31 32 40 Z' fill='#fff'/>
      </svg>
      <h2>Welcome!</h2>
    </div>
  </div>

<script>
  var SEEDS = __SEEDS__;
  var GEARS = __GEARS__;
  var LOCKED = __LOCKED__;            /* per-seed 0/1 lock flags, aligned to SEEDS */
  var PREMIUM = __PREMIUM__;          /* number of locked seeds (for the upsell copy) */
  var PROMO = '__PROMO__';            /* entered promo code (UPPER), '' if none -> no corner badge */
  var PROMO_PCT = __PROMOPCT__;       /* that code's discount percent (0 if none) -> badge "N% off" */
  var WILL_ONBOARD = !!__ONBOARD__;   /* a first-launch wall is coming ~1.8s after load -> paint a cover
                                         from frame 1 so the app never flashes before onboarding */
  var unlocked = false;              /* premium (seeds) unlocked this session? */
  var seedSel = {};                  /* 1-based index -> true (seeds tab) */
  var gearSel = {};                  /* 1-based index -> true (gears tab) */
  var activeTab = 'seeds';           /* which tab the footer Start applies to */
  var sawWall = false;               /* did onboarding actually show a wall? -> welcome finale */
  var wv = window.chrome.webview;

  function send(s){ wv.postMessage(s); }

  function items(tab){ return tab === 'gears' ? GEARS : SEEDS; }
  function selMap(tab){ return tab === 'gears' ? gearSel : seedSel; }
  /* Only seeds carry the premium drip-lock; every gear is always free. The lock
     flag is per-seed (decided by name in the macro), so insert order doesn't
     matter -- we don't assume the locked seeds are the last N. */
  function isLocked(tab, n){
    return tab === 'seeds' && !unlocked && !!LOCKED[n - 1];
  }

  function selectedList(tab){
    var m = selMap(tab), arr = [];
    for (var k in m){ if (m[k]) arr.push(parseInt(k,10)); }
    arr.sort(function(a,b){ return a-b; });
    return arr;
  }
  function pushSel(tab){
    send('sel|' + tab + '|' + selectedList(tab).join(','));
    if (tab === activeTab) updateCount();
  }
  function updateCount(){
    document.getElementById('count').textContent =
      selectedList(activeTab).length + ' selected';
  }

  var RARECLASS = {Legendary:'lg', Mythic:'my', Super:'sp'};
  function addSparks(nameEl, cls){
    for (var k = 0; k < 5; k++){
      var sp = document.createElement('i');
      sp.className = 'spark ' + cls;
      sp.style.left = (8 + Math.random() * 84) + '%';
      sp.style.top  = (Math.random() * 100) + '%';
      sp.style.animationDelay = (Math.random() * 1.6) + 's';
      sp.style.animationDuration = (1.2 + Math.random() * 1.3) + 's';
      nameEl.appendChild(sp);
    }
  }

  /* Keep the upsell copy in step with however many seeds are locked today. */
  function lockText(){
    return (PREMIUM >= SEEDS.length) ? 'All seeds are locked'
                                     : 'Last ' + PREMIUM + ' seeds are locked';
  }
  function applyLockUi(){
    var t = document.getElementById('pbarText');
    if (t) t.textContent = lockText();
    var h = document.getElementById('modalTitle');
    /* PREMIUM can be 0 on day one (whole list free) -- the modal is then only
       reachable via the always-Pro Gears lock, so keep the title generic. */
    if (h) h.textContent = (PREMIUM <= 0)           ? 'Unlock Garden Macro Pro'
                         : (PREMIUM >= SEEDS.length) ? 'Unlock all seeds'
                                                     : 'Unlock the last ' + PREMIUM + ' seeds';
    var bar = document.getElementById('premiumBar');
    if (bar) bar.hidden = unlocked || PREMIUM <= 0;
  }
  /* Gears is a Pro feature: gray out the menu + show the lock until unlocked. */
  function applyGearLock(){
    var locked = !unlocked;
    var c = document.getElementById('gearContent');
    var l = document.getElementById('gearLock');
    if (c) c.classList.toggle('prodim', locked);
    if (l) l.hidden = !locked;
  }

  function renderList(tab, listEl){
    var arr = items(tab), m = selMap(tab);
    listEl.innerHTML = '';
    /* fill straight down the left column, then continue down the right */
    listEl.style.gridTemplateRows = 'repeat(' + Math.ceil(arr.length / 2) + ', auto)';
    arr.forEach(function(s,i){
      var n = i + 1;
      var locked = isLocked(tab, n);
      var row = document.createElement('div');
      row.className = 'row' + (locked ? ' locked' : '') + (m[n] ? ' sel' : '');
      var box = document.createElement('span'); box.className = 'box';
      var name = document.createElement('span'); name.className = 'name';
      var cls = RARECLASS[s.r];
      name.textContent = s.n;          /* set text first, then layer sparks on top */
      /* Locked seeds keep their full rarity flair on purpose -- the pretty
         premium seeds are what makes people want to unlock them. */
      if (cls){ name.classList.add(cls); addSparks(name, cls); }
      row.appendChild(box); row.appendChild(name);
      row.onclick = function(){
        if (isLocked(tab, n)) { openAccess(); return; }
        if (m[n]) { delete m[n]; row.classList.remove('sel'); }
        else { m[n] = true; row.classList.add('sel'); }
        pushSel(tab);
      };
      listEl.appendChild(row);
    });
  }
  function renderAll(){
    renderList('seeds', document.getElementById('list'));
    renderList('gears', document.getElementById('gearList'));
  }

  function setAll(v){
    var tab = activeTab;
    if (tab === 'gears' && !unlocked){ openAccess(); return; }  /* Pro-locked */
    var arr = items(tab), m = selMap(tab);
    for (var i = 0; i < arr.length; i++){
      var n = i + 1;
      if (v && !isLocked(tab, n)) m[n] = true; else delete m[n];
    }
    renderAll();
    pushSel(tab);
  }

  function switchTab(tab){
    if (tab === activeTab) return;
    activeTab = tab;
    document.getElementById('seedsPane').hidden = (tab !== 'seeds');
    document.getElementById('gearsPane').hidden = (tab !== 'gears');
    document.getElementById('accountPane').hidden = (tab !== 'account');
    document.getElementById('tabSeeds').classList.toggle('on', tab === 'seeds');
    document.getElementById('tabGears').classList.toggle('on', tab === 'gears');
    document.getElementById('tabAccount').classList.toggle('on', tab === 'account');
    /* The selection bar + Start/Stop drive the seed/gear lists, not Account. */
    var acct = (tab === 'account');
    document.querySelector('.sub').hidden = acct;
    document.getElementById('setupNote').hidden = acct;
    document.getElementById('footer').hidden = acct;
    if (!acct){ updateCount(); send('tab|' + tab); }   /* so F1 starts whichever list tab is showing */
    requestAnimationFrame(function(){ requestAnimationFrame(fitWindow); });
  }

  /* Premium / unlock flow (seeds only) */
  function openAccess(){
    document.getElementById('overlay').hidden = false;
    var inp = document.getElementById('codeInput');
    setTimeout(function(){ inp.focus(); }, 30);
  }
  function closeAccess(){ document.getElementById('overlay').hidden = true; }

  /* Post-run upsell: AHK sends "hint|<mythic>|<super>" with the average seed
     counts it estimated for the run. A 0 mythic means "no mythic locked yet" ->
     super-only popup; otherwise both lines show. Values are already >= 1. */
  function showHint(m, s){
    m = parseInt(m, 10) || 0;
    s = parseInt(s, 10) || 0;
    var mEl = document.getElementById('hintMythic');
    if (m > 0){
      document.getElementById('hintMythicNum').textContent = m;
      document.getElementById('hintMythicNoun').textContent = 'mythic seed' + (m === 1 ? '' : 's');
      mEl.hidden = false;
    } else {
      mEl.hidden = true;
    }
    document.getElementById('hintSuperNum').textContent = s;
    document.getElementById('hintSuperNoun').textContent = 'super seed' + (s === 1 ? '' : 's');
    document.getElementById('hintSuper').hidden = (s <= 0);
    document.getElementById('hintTitle').textContent =
      (m > 0) ? 'You left rare seeds on the table' : 'You left super seeds on the table';
    document.getElementById('hintOverlay').hidden = false;
  }
  function closeHint(){ document.getElementById('hintOverlay').hidden = true; }

  /* Loyalty discount: AHK sends "discount|<code>" once the user has run the macro
     for 5h total. Show the 50%-off code and let them copy it. */
  function showDiscount(code, hours){
    if (code) document.getElementById('discountCode').textContent = code;
    if (hours) document.getElementById('discountHours').textContent = hours;
    document.getElementById('discountOverlay').hidden = false;
  }
  function closeDiscount(){ document.getElementById('discountOverlay').hidden = true; }

  /* Update banner: AHK sends "update|<version>" when a newer macro.ahk has shipped to
     `main` while this session is running. Show the red "restart to update" bar (once)
     and grow the window to fit it. */
  function showUpdate(v){
    var el = document.getElementById('updateBar');
    if (!el) return;
    if (v){ var s = document.getElementById('updateVer'); if (s) s.textContent = ' (v' + v + ')'; }
    el.classList.add('show');
    requestAnimationFrame(function(){ requestAnimationFrame(fitWindow); });
  }
  /* Copy the promo code in element `id` to the clipboard, with a graceful
     fallback for the non-secure NavigateToString origin, then flash "Copied". */
  function copyCode(btn, id){
    var el = document.getElementById(id), code = el.textContent;
    var ok = false;
    try { navigator.clipboard.writeText(code); ok = true; } catch(e){}
    if (!ok){
      try {
        var r = document.createRange(); r.selectNode(el);
        var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r);
        document.execCommand('copy'); sel.removeAllRanges();
      } catch(e2){}
    }
    if (id === 'hintCode') send('ev|hint_copied');         /* funnel: post-session upsell code copied */
    else if (id === 'discountCode') send('ev|loyalty_copied'); /* funnel: loyalty code copied */
    if (btn){ var t = btn.textContent; btn.textContent = 'Copied'; setTimeout(function(){ btn.textContent = t; }, 1400); }
  }
  function copyDiscount(btn){ copyCode(btn, 'discountCode'); }
  /* Dismissals (X / "Maybe later") log a funnel event; the CTA buttons do NOT (they
     route to openAccess instead), so dismiss counts only true "not now" closes. */
  function dismissHint(){ send('ev|hint_dismiss'); closeHint(); }
  function dismissDiscount(){ send('ev|loyalty_dismiss'); closeDiscount(); }
  /* CTA = clicked through to the access page (strongest intent). Logs a popup event
     AND opens access (openAccess fires its own get_access funnel event). */
  function ctaHint(){ send('ev|hint_cta'); closeHint(); openAccess(); }
  function ctaDiscount(){ send('ev|loyalty_cta'); closeDiscount(); openAccess(); }

  /* Promo codes. AHK sends "promoask" shortly after first launch; the page shows the
     prompt. Apply (or Enter) -> AHK validates and replies "promook|<CODE>|<PCT>" (badge
     + close) or "promobad|<msg>" (stay open). Skip -> close + tell AHK we skipped. */
  function applyPromoBadge(){
    var b = document.getElementById('promoBadge');
    if (PROMO){
      document.getElementById('promoBadgeCode').textContent = PROMO;
      document.getElementById('promoBadgePct').textContent = PROMO_PCT;
      b.hidden = false;
    } else b.hidden = true;
  }
  /* Source ("where did you hear about us?") wall. AHK sends "sourceask" on first
     launch, BEFORE the promo prompt. Picking a channel (or Skip) -> AHK records +
     reports it, then opens the promo wall, or sends "sourcedone" if there is nothing
     more to ask. The overlay stays up until AHK replies, so there is no flash. */
  /* --- Onboarding wall transitions (source -> promo -> welcome) ---
     Walls share a solid white background, so we cross-dissolve: the next wall fades in
     OVER the current one (no app flash), then the old one is dropped. Content fades and
     rises via the .entering/.leaving classes. WALL_FADE must match the CSS .36s. */
  var WALL_FADE = 360;
  function enterWall(id, after){
    var el = document.getElementById(id);
    el.hidden = false;
    el.classList.remove('leaving');
    el.classList.add('entering');                        /* start hidden (opacity 0, content low) */
    requestAnimationFrame(function(){ requestAnimationFrame(function(){
      el.classList.remove('entering');                   /* -> triggers the fade + rise in */
      if (after) setTimeout(after, WALL_FADE);
    }); });
  }
  function exitWall(id, after){
    var el = document.getElementById(id);
    el.classList.remove('entering');
    el.classList.add('leaving');                         /* fade the whole wall out -> reveal app */
    setTimeout(function(){
      el.hidden = true;
      el.classList.remove('leaving');
      if (after) after();
    }, WALL_FADE);
  }
  /* Bring `toId` up over `fromId`, then drop `fromId` once it's fully covered. */
  function crossWall(fromId, toId, after){
    enterWall(toId, function(){
      var f = document.getElementById(fromId);
      if (f){ f.hidden = true; f.classList.remove('entering','leaving'); }
      if (after) after();
    });
  }
  /* End of onboarding: dissolve the final wall into the welcome screen, hold, fade to app. */
  function goWelcome(fromId){
    crossWall(fromId, 'welcomeOverlay', function(){
      setTimeout(function(){ exitWall('welcomeOverlay'); }, 1800);
    });
  }

  /* First-launch app cover (see WILL_ONBOARD). It's painted from frame 1 so the app never
     shows before the first wall; the first wall then dissolves in over it and drops it. */
  function coverUp(){ return !document.getElementById('bootCover').hidden; }
  function showBootCover(){ document.getElementById('bootCover').hidden = false; }

  function openSourceAsk(){
    sawWall = true;
    if (coverUp()) crossWall('bootCover', 'sourceOverlay');   /* dissolve cover -> source */
    else enterWall('sourceOverlay');
  }
  function closeSource(){ document.getElementById('sourceOverlay').hidden = true; }
  function chooseSource(key){ send('source|' + key); }
  function skipSource(){ send('sourceskip'); }

  function openPromoAsk(){
    sawWall = true;
    /* Normally the source wall is showing; on the source-already-answered path the boot
       cover is still up instead. Dissolve whichever is visible into the promo wall. */
    crossWall(coverUp() ? 'bootCover' : 'sourceOverlay', 'promoOverlay', function(){
      document.getElementById('promoInput').focus();
    });
  }
  function setPromoMsg(t){ document.getElementById('promoMsg').textContent = t; }
  function applyPromo(){
    var code = document.getElementById('promoInput').value.trim();
    if (!code){ return; }                 /* empty -> do nothing (they can type or Skip) */
    setPromoMsg('Checking...');
    send('promoapply|' + code);
  }
  function skipPromo(){
    send('promoskip');
    goWelcome('promoOverlay');                 /* skipped -> welcome finale */
  }
  function promoAccepted(code, pct){
    PROMO = code;
    PROMO_PCT = pct;
    applyPromoBadge();
    setPromoMsg('');
    goWelcome('promoOverlay');                 /* valid code -> welcome finale */
  }
  function setLicenseMsg(t){ document.getElementById('licenseMsg').textContent = t; }
  /* Paste button: the page runs from NavigateToString (a non-secure origin) where
     navigator.clipboard.readText() is blocked, so ask AHK to read the Windows
     clipboard and send it back as 'pastecode|<text>' (handled below). */
  function pasteCode(){ send('paste'); }
  function activate(){
    var code = document.getElementById('codeInput').value.trim();
    if (!code){ setLicenseMsg('Paste your access code first.'); return; }
    setLicenseMsg('Checking your code...');
    send('activate|' + code);
  }
  function unlockPremium(){
    unlocked = true;
    closeAccess();
    var bar = document.getElementById('premiumBar');
    if (bar) bar.hidden = true;          /* access granted -> no upsell bar needed */
    applyGearLock();                     /* Pro -> the Gears tab is now usable */
    document.getElementById('tabAccount').hidden = false;  /* Pro -> show the Account tab */
    renderAll();
    pushSel('seeds');
    requestAnimationFrame(function(){ requestAnimationFrame(fitWindow); });
  }
  function setRunning(on){
    document.getElementById('startBtn').disabled = on;
    document.getElementById('stopBtn').disabled  = !on;
  }
  wv.addEventListener('message', function(e){
    var data = '' + e.data;
    var i = data.indexOf('|');
    var type = (i < 0) ? data : data.substring(0, i);
    var rest = (i < 0) ? ''   : data.substring(i + 1);
    if (type === 'status') { /* status line removed from UI */ }
    else if (type === 'state') setRunning(rest === '1');
    else if (type === 'unlock') unlockPremium();
    else if (type === 'licensemsg') setLicenseMsg(rest);
    else if (type === 'pastecode') {            /* AHK read the clipboard -> fill the code field */
      var inp = document.getElementById('codeInput');
      if (inp){ inp.value = rest; inp.focus(); }
      setLicenseMsg('');
    }
    else if (type === 'access') openAccess();   /* tried to Start a Pro-locked tab */
    else if (type === 'hint') { var hp = rest.split('|'); showHint(hp[0], hp[1]); }  /* post-run upsell */
    else if (type === 'discount') { var dp = rest.split('|'); showDiscount(dp[0], dp[1]); }   /* loyalty 50%-off code + milestone hours */
    else if (type === 'update') showUpdate(rest);   /* newer build on `main` -> restart to update */
    else if (type === 'sourceask') openSourceAsk();     /* first-launch acquisition prompt (before promo) */
    else if (type === 'sourcedone') {                        /* settled: nothing more to ask */
      if (sawWall) goWelcome('sourceOverlay');               /* a wall showed -> welcome finale */
      else if (coverUp()) exitWall('bootCover');             /* covered but nothing to ask -> reveal app */
      else closeSource();
    }
    else if (type === 'promoask') openPromoAsk();       /* first-launch promo prompt */
    else if (type === 'promook') { var pp = rest.split('|'); promoAccepted(pp[0], pp[1]); }  /* valid code -> badge + close */
    else if (type === 'promobad') setPromoMsg(rest);    /* invalid code -> keep prompt open */
  });

  /* Ask AHK to shrink the window to end right at the Start/Stop row. */
  function fitWindow(){
    /* Measure to the footer normally; on the Account tab the footer is hidden,
       so measure to the account card instead. */
    var f = document.getElementById('footer');
    var ref;
    if (f && !f.hidden) ref = f;
    else ref = document.querySelector('#accountPane .acard');
    if (!ref) return;
    var cssH = ref.getBoundingClientRect().bottom + 16;   /* + body bottom padding */
    send('fit|' + Math.ceil(cssH * (window.devicePixelRatio || 1)));
  }

  /* init */
  if (WILL_ONBOARD) showBootCover();   /* cover the app now, before first paint, so it never
                                          flashes before the onboarding wall arrives (~1.8s) */
  renderAll();
  applyLockUi();
  applyGearLock();
  applyPromoBadge();
  pushSel('seeds');
  pushSel('gears');
  setRunning(false);
  requestAnimationFrame(function(){ requestAnimationFrame(fitWindow); });
</script>
</body>
</html>
)"
}
