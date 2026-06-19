#Requires AutoHotkey v2.0
#SingleInstance Force
#Include lib\WebView2.ahk

; ============================================================
;  Garden Macro  -  Roblox seed-shop macro
;
;  Pick which seeds to buy in the window, set the quantity,
;  then press Start (or F1). The macro:
;    0. Focuses Roblox + small mouse nudge
;    1. Clicks the shop at (697, 103), presses "e"
;    2. Presses "\" for keyboard UI nav, snaps to position 1
;       (down 5x, hold Up 5s), then moves onto the first ticked seed.
;  Steps 0-2 (Setup) run ONCE. The shop UI then stays open and the
;  cursor stays put, so each restock only repeats the buy pass:
;    3. From the first ticked seed, walk DOWN buying each ticked seed
;       N times, then walk back UP to the first ticked seed.
;
;  Setup runs on Start; the buy pass then repeats every 5 minutes
;  (restock loop) until you press Stop.
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
global FirstSel   := 0              ; index of first ticked seed (locked at Start)
global LastSel    := 0              ; index of last ticked seed (locked at Start)
global PassQty    := 20             ; fixed quantity bought per seed each pass

; Live UI state, kept in sync by messages from the page.
global SelIndices := []             ; sorted 1-based indices currently ticked
global SelSet     := Map()          ; locked-at-Start lookup: index -> true

; WebView2 / window handles (kept global so they are not garbage-collected).
global MainGui    := 0
global controller := 0
global wv         := 0

; --- Free version: the macro is free, but the BEST seeds (bottom of the list)
;     are locked until the user unlocks them with a subscription paste-code (the
;     same Google + Stripe auth the website already uses).
;
;     The lock is a drip funnel: on the install day the best `BaseLock` (5) seeds
;     are locked; every calendar day after that, `DailyLock` (4) more lock from
;     best toward worst, until the whole list is locked. The unlocked region is
;     anchored on the seed count AT INSTALL, so new seeds (always appended to the
;     bottom = best end) join the locked block without ever freeing a previously
;     locked seed -- i.e. any seed better than a locked one is locked too. The
;     live locked count is computed once at startup into PremiumCount (see
;     ComputeLockedCount); everything downstream still just locks "the last N".
global BaseLock     := 5      ; best seeds locked on the install day (day 0)
global DailyLock    := 4      ; extra best seeds locked per calendar day after install
global PremiumCount := 5      ; locked best-seed count THIS session (set at startup)
global Unlocked     := false                          ; premium unlocked this session?
global InstallFile  := A_AppData "\GardenMacro\install.txt"  ; first-run stamp + seed count

; Version shown in the window's bottom corner. Bump AppVersion on real releases;
; the build time is taken from this file's last-modified date, so it changes every
; time you save the script -> an easy "did my latest change actually load?" check.
global AppVersion := "1.0.0"
global BackendBase  := "https://gardenmacro.com"   ; subscription backend
global VerifyUrl    := BackendBase "/api/desktop/verify"
global TokenFile    := A_AppData "\GardenMacro\token.txt"   ; saved paste-code

; --- Seed list in the SAME top-to-bottom order as the in-game shop ---
;
;  ADDING A NEW SEED:  just APPEND it to the BOTTOM of this list. Nothing else --
;  no count to bump, no config. The drip-lock funnel auto-adjusts: the new seed
;  becomes the new best, locks immediately, and every already-locked seed stays
;  locked (the UI reads the same injected count, so page + engine stay in sync).
;
;  IMPORTANT:  new seeds MUST go at the bottom (best end). The lock anchor counts
;  the free seeds from the TOP (worst end), so appending preserves every existing
;  seed's index and the anchor holds. INSERTING a seed in the MIDDLE shifts the
;  indices above it and throws the anchor off -- don't do that. For this game it
;  never happens (new seeds are always the new top tier), but it's the one rule
;  to follow when editing this list.  (See ComputeLockedCount for the mechanism.)
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
    {name: "Venus Fly Trap",  rarity: "Mythic"},
    {name: "Pomegranate",     rarity: "Mythic"},
    {name: "Poison Apple",    rarity: "Mythic"},
    {name: "Moon Bloom",      rarity: "Super"},
    {name: "Dragon's Breath", rarity: "Super"}
]

; Work out how many best seeds are locked for this session (drip funnel; the
; count grows each calendar day after install). Must run after Seeds is defined
; and before BuildUi, which injects the count into the page.
PremiumCount := ComputeLockedCount()

BuildUi()

; Re-check any previously saved access code in the background so returning
; subscribers see the premium seeds already unlocked, without blocking the UI.
SetTimer(CheckSavedLicense, -800)

; ============================================================
;  UI  (WebView2 window + HTML/CSS/JS)
; ============================================================
BuildUi() {
    global MainGui, controller, wv, PremiumCount

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

    html := StrReplace(HtmlTemplate(), "__SEEDS__", BuildSeedsJs())
    html := StrReplace(html, "__PREMIUM__", PremiumCount)
    html := StrReplace(html, "__VERSION__", VersionLabel())
    wv.NavigateToString(html)
}

; Keep the WebView2 control sized to the window's client area.
OnGuiSize(thisGui, minMax, w, h) {
    global controller
    if controller
        controller.Fill()
}

; Build the seed list as a JS array literal injected into the page.
BuildSeedsJs() {
    global Seeds
    out := "["
    for i, sd in Seeds {
        out .= "{n:" JsStr(sd.name) ",r:" JsStr(sd.rarity) "}"
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
    global SelIndices
    msg := args.TryGetWebMessageAsString()
    parts := StrSplit(msg, "|")
    cmd := parts.Length >= 1 ? parts[1] : ""

    switch cmd {
        case "sel":
            SelIndices := []
            csv := parts.Length >= 2 ? parts[2] : ""
            if csv != "" {
                for token in StrSplit(csv, ",") {
                    if IsInteger(token)
                        SelIndices.Push(Integer(token))
                }
            }
        case "start":
            StartMacro()
        case "stop":
            StopMacro()
        case "openaccess":
            OpenAccessPage()
        case "openhelp":
            OpenHelpPage()
        case "activate":
            p := InStr(msg, "|")            ; rest-of-line: the pasted code
            ActivateCode(p ? SubStr(msg, p + 1) : "")
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
    global SelIndices, SelSet, Unlocked, MainGui

    if LoopActive               ; loop already armed -> ignore
        return

    ; Drop any locked premium seeds unless they've been unlocked. The UI already
    ; prevents ticking them; this is just defense in depth.
    picks := []
    for idx in SelIndices {
        if (!Unlocked && IsPremiumIndex(idx))
            continue
        picks.Push(idx)
    }

    if picks.Length = 0 {
        UiStatus("Nothing selected.")
        MsgBox "No seeds selected. Tick at least one seed."
        return
    }

    ; Lock in the selection + quantity for this whole loop session.
    FirstSel := picks[1]
    LastSel  := picks[picks.Length]
    SelSet   := Map()
    for idx in picks
        SelSet[idx] := true
    PassQty := 20               ; fixed buy amount per seed

    LoopActive := true
    Running := true
    UiState(true)

    ; Get out of the way: minimize the macro window so Roblox is in full view.
    ; (Setup focuses Roblox next; use F2 to stop while it's running.)
    try MainGui.Minimize()

    ; One-time setup: open the shop UI and land on the first selected seed.
    if !Setup() {
        Running := false
        LoopActive := false
        UiState(false)
        try MainGui.Restore()   ; setup failed -> bring the window back so the error is visible
        return
    }
    BuyPass()                   ; first buy pass (ends on the first selected seed)
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
    global Running, LoopActive
    LoopActive := false
    SetTimer(DoPass, 0)         ; cancel the 5-minute loop
    Running := false            ; interrupt any pass in progress
    ; Make sure no arrow key is left stuck down.
    Send "{Up up}"
    Send "{Down up}"
    UiState(false)
    UiStatus("Stopped.")
}

; ============================================================
;  Free version: premium unlock (best N seeds, drip funnel)
;  The macro runs free; the best `PremiumCount` seeds stay locked until the user
;  pastes a valid subscription code, checked against the same backend the website
;  uses (/api/desktop/verify). PremiumCount is not fixed -- it grows each calendar
;  day after install (see ComputeLockedCount), locking from best to worst.
; ============================================================

; True if seed index `i` (1-based) is one of the locked premium seeds.
IsPremiumIndex(i) {
    global Seeds, PremiumCount
    start := Seeds.Length - PremiumCount + 1
    if (start < 1)
        start := 1
    return i >= start
}

; How many of the BEST seeds are locked right now. Anchored on the seed count at
; install: the worst `(installCount - BaseLock)` seeds start free, and that free
; pool shrinks by DailyLock every calendar day, so the lock spreads from best to
; worst until nothing is free. Because the anchor uses the INSTALL-time count,
; seeds later appended to the bottom (best end) join the locked block and never
; free a seed that was already locked.
ComputeLockedCount() {
    global Seeds, BaseLock, DailyLock
    rec  := GetInstallRecord()
    days := CalendarDaysSince(rec.stamp)

    freeWorst := (rec.count - BaseLock) - DailyLock * days   ; worst seeds still free
    if (freeWorst < 0)
        freeWorst := 0

    locked := Seeds.Length - freeWorst
    minLock := Min(BaseLock, Seeds.Length)   ; always keep at least the day-0 baseline
    if (locked < minLock)
        locked := minLock
    if (locked > Seeds.Length)
        locked := Seeds.Length
    return locked
}

; Read (or, on first run, create) the install record: the timestamp of first run
; plus the seed count at that moment. Stored as "<YYYYMMDDHHMMSS>|<count>".
GetInstallRecord() {
    global InstallFile, Seeds
    if FileExist(InstallFile) {
        raw := ""
        try raw := Trim(FileRead(InstallFile, "UTF-8"), " `t`r`n" Chr(0xFEFF))
        parts := StrSplit(raw, "|")
        stamp := parts.Length >= 1 ? parts[1] : ""
        cnt   := parts.Length >= 2 ? parts[2] : ""
        if (stamp != "" && IsInteger(stamp) && StrLen(stamp) >= 8) {
            count := (cnt != "" && IsInteger(cnt)) ? Integer(cnt) : Seeds.Length
            return { stamp: stamp, count: count }
        }
    }
    ; First run: stamp "now" and snapshot the current seed count.
    rec := { stamp: A_Now, count: Seeds.Length }
    try {
        SplitPath(InstallFile, , &dir)
        if (dir != "" && !DirExist(dir))
            DirCreate(dir)
        f := FileOpen(InstallFile, "w", "UTF-8-RAW")
        f.Write(rec.stamp "|" rec.count)
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
        try FileDelete(TokenFile)           ; cancelled / expired -> stay locked
    } else {
        ; Offline / server unreachable: trust the saved code for this session,
        ; like the launcher does, so paying users aren't locked out offline.
        Unlocked := true
        Post("unlock|1")
    }
}

; "Get access" -> open the sign-in / subscribe page in the default browser.
; Minimize the macro window so the browser sign-in page is in full view.
OpenAccessPage() {
    global BackendBase, MainGui
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

; Verify a pasted code. On a confirmed active subscription: save it and unlock
; the last 5 seeds live. Otherwise tell the page what went wrong.
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

; ============================================================
;  Setup (runs once) + Buy pass (repeats)
; ============================================================

; One-time setup: focus Roblox, open the shop, enter keyboard navigation,
; snap to position 1, then move down onto the FIRST selected seed.
; Returns false if stopped or Roblox is missing.
Setup() {
    global FirstSel
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

    ; 1. Nudge the mouse to the target, then click (absolute screen position).
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

    ; 2b. Snap to the FIRST position: go down 5 times, then hold Up for
    ;     5 seconds to scroll all the way back to the top -> position 1.
    UiStatus("Resetting to position 1...")
    Loop 5 {
        Send "{Down}"
        if !Wait(300)
            return false
    }
    Send "{Up down}"
    Wait(5000)
    Send "{Up up}"
    if !Wait(300)
        return false

    ; 2c. Move down from position 1 onto the FIRST selected seed.
    Loop FirstSel - 1 {
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
    global Running, Seeds, SelSet, FirstSel, LastSel, PassQty

    ; Keep Roblox focused (this does NOT move the UI cursor).
    if WinExist("ahk_exe RobloxPlayerBeta.exe")
        WinActivate

    ; Walk DOWN from the first to the last selected seed, buying ticked ones.
    i := FirstSel
    Loop {
        if !Running
            return
        if SelSet.Has(i) {
            UiStatus(Format("Buying {} x{}", Seeds[i].name, PassQty))
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
  .prow{display:flex;gap:8px}
  #codeInput{flex:1;background:#fff;border:1px solid #d8d8d8;border-radius:7px;padding:8px 10px;
        font-size:13px;outline:none;font-family:inherit}
  #codeInput:focus{border-color:#16a34a}
  .lmsg{font-size:12px;color:#888;margin-top:10px;min-height:15px;line-height:1.4}
  [hidden]{display:none !important}
</style>
</head>
<body>
  <h1>Garden Macro</h1>
  <div class='sub'>
    <span id='count'>0 selected</span>
    <span><a onclick='send("openhelp")'>Help &amp; setup</a> &middot; <a onclick='setAll(true)'>Select all</a> &middot; <a onclick='setAll(false)'>Clear</a></span>
  </div>

  <div id='list' class='list'></div>

  <div id='premiumBar' class='pbar' onclick='openAccess()'>
    <span class='plock'>&#128274;</span>
    <span id='pbarText'>Last 5 seeds are locked</span>
    <span class='pget'>Get access &rarr;</span>
  </div>

  <div class='footer'>
    <button id='startBtn' class='btn primary' onclick='send("start")'>Start <span class='hk'>F1</span></button>
    <button id='stopBtn'  class='btn'         onclick='send("stop")'>Stop <span class='hk'>F2</span></button>
    <span class='ver'>v__VERSION__</span>
  </div>

  <div id='overlay' class='overlay' hidden>
    <div class='modal'>
      <div class='mh'>
        <span class='mlock'>&#128274;</span>
        <h2 id='modalTitle'>Unlock the last 5 seeds</h2>
        <button class='mx' onclick='closeAccess()'>&times;</button>
      </div>
      <p class='mdesc'>These premium seeds need Garden Macro access. Subscribe once, then paste your code to unlock them here. The rest of the macro stays free.</p>
      <ol class='msteps'>
        <li>Open the sign-in page and subscribe with Google.</li>
        <li>Copy the access code it shows you.</li>
        <li>Paste it below and click Unlock.</li>
      </ol>
      <button class='btn block' onclick='send("openaccess")'>Open sign-in page</button>
      <div class='prow'>
        <input id='codeInput' type='text' placeholder='Paste your access code' spellcheck='false' autocomplete='off'>
        <button class='btn green' onclick='activate()'>Unlock</button>
      </div>
      <div id='licenseMsg' class='lmsg'></div>
    </div>
  </div>

<script>
  var SEEDS = __SEEDS__;
  var PREMIUM = __PREMIUM__;          /* number of locked seeds at the bottom */
  var unlocked = false;              /* premium unlocked this session? */
  var selected = {};                 /* 1-based index -> true */
  var wv = window.chrome.webview;

  function send(s){ wv.postMessage(s); }

  function selectedList(){
    var arr = [];
    for (var k in selected){ if (selected[k]) arr.push(parseInt(k,10)); }
    arr.sort(function(a,b){ return a-b; });
    return arr;
  }
  function pushSel(){
    var arr = selectedList();
    send('sel|' + arr.join(','));
    document.getElementById('count').textContent = arr.length + ' selected';
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
  function isLocked(n){ return !unlocked && n > SEEDS.length - PREMIUM; }
  /* Keep the upsell copy in step with however many seeds are locked today. */
  function lockText(){
    return (PREMIUM >= SEEDS.length) ? 'All seeds are locked'
                                     : 'Last ' + PREMIUM + ' seeds are locked';
  }
  function applyLockUi(){
    var t = document.getElementById('pbarText');
    if (t) t.textContent = lockText();
    var h = document.getElementById('modalTitle');
    if (h) h.textContent = (PREMIUM >= SEEDS.length) ? 'Unlock all seeds'
                                                     : 'Unlock the last ' + PREMIUM + ' seeds';
    var bar = document.getElementById('premiumBar');
    if (bar) bar.hidden = unlocked || PREMIUM <= 0;
  }
  function render(){
    var list = document.getElementById('list');
    list.innerHTML = '';
    /* fill straight down the left column, then continue down the right */
    list.style.gridTemplateRows = 'repeat(' + Math.ceil(SEEDS.length / 2) + ', auto)';
    SEEDS.forEach(function(s,i){
      var n = i + 1;
      var locked = isLocked(n);
      var row = document.createElement('div');
      row.className = 'row' + (locked ? ' locked' : '') + (selected[n] ? ' sel' : '');
      var box = document.createElement('span'); box.className = 'box';
      var name = document.createElement('span'); name.className = 'name';
      var cls = RARECLASS[s.r];
      name.textContent = s.n;        /* set text first, then layer sparks on top */
      /* Locked seeds keep their full rarity flair on purpose -- the pretty
         premium seeds are what makes people want to unlock them. */
      if (cls){ name.classList.add(cls); addSparks(name, cls); }
      row.appendChild(box); row.appendChild(name);
      row.onclick = function(){
        if (isLocked(n)) { openAccess(); return; }
        if (selected[n]) { delete selected[n]; row.classList.remove('sel'); }
        else { selected[n] = true; row.classList.add('sel'); }
        pushSel();
      };
      list.appendChild(row);
    });
  }
  function setAll(v){
    for (var i = 0; i < SEEDS.length; i++){
      var n = i + 1;
      if (v && !isLocked(n)) selected[n] = true; else delete selected[n];
    }
    render();
    pushSel();
  }
  /* Premium / unlock flow */
  function openAccess(){
    document.getElementById('overlay').hidden = false;
    var inp = document.getElementById('codeInput');
    setTimeout(function(){ inp.focus(); }, 30);
  }
  function closeAccess(){ document.getElementById('overlay').hidden = true; }
  function setLicenseMsg(t){ document.getElementById('licenseMsg').textContent = t; }
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
    render();
    pushSel();
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
  });

  /* Ask AHK to shrink the window to end right at the Start/Stop row. */
  function fitWindow(){
    var f = document.querySelector('.footer');
    if (!f) return;
    var cssH = f.getBoundingClientRect().bottom + 16;   /* + body bottom padding */
    send('fit|' + Math.ceil(cssH * (window.devicePixelRatio || 1)));
  }

  /* init */
  render();
  applyLockUi();
  pushSel();
  setRunning(false);
  requestAnimationFrame(function(){ requestAnimationFrame(fitWindow); });
</script>
</body>
</html>
)"
}
