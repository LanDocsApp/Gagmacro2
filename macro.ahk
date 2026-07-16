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
;    2. Presses "\" for keyboard UI nav, then snaps to position 1
;       (Up 5x, Down 5x, then hold Up 3s) and stays there.
;  Steps 0-2 (Setup) run ONCE. The shop UI then stays open and the
;  cursor stays put on position 1, so each restock only repeats the buy pass:
;    3. From position 1, walk DOWN buying each ticked seed N times,
;       then walk back UP to position 1.
;
;  Setup runs on Start; the buy pass then repeats every 5 minutes
;  (restock loop) until you press Stop.
;
;  The window has two tabs: "Seeds" (above) and "Gears". The Gears tab
;  buys from the in-game GEAR SHOP and differs only in setup: you must
;  already be standing in the open Gear Shop UI when you press Start, so
;  it skips the shop click + "e". It presses "\" for keyboard nav, then
;  Up 5x + Down 5x + hold Up 3s to land on position 1 (the first gear) and
;  stays there. From there the buy pass is identical to seeds.
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
global LastSel    := 0              ; index of last ticked item (locked at Start)
global PassQty    := 20             ; fixed quantity bought per item each pass

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
global FreeNames    := Map()  ; seed NAME -> true for seeds outside the paywall (set at startup)
global Unlocked     := false                          ; premium unlocked this session?
global InstallFile  := A_AppData "\GardenMacro\install.txt"  ; first-run stamp + seed-name snapshot

; Version shown in the window's bottom corner. Bump AppVersion on real releases;
; the build time is taken from this file's last-modified date, so it changes every
; time you save the script -> an easy "did my latest change actually load?" check.
global AppVersion := "1.1.1"
; Giveaway code shown under the version line in the footer. Players type this on the
; giveaway page (gardenmacro.com/giveaway) to prove they have the macro -> +2 entries.
; A single shared code by design; keep it in sync with functions/_lib/giveaways.js MACRO_CODE.
global GiveawayCode := "3QIHX"
global BackendBase  := "https://gardenmacro.com"   ; subscription backend
global VerifyUrl    := BackendBase "/api/desktop/verify"
global PingUrl      := BackendBase "/api/ping"              ; anonymous usage stats
global GiveawayUrl  := BackendBase "/giveaway"             ; top banner "Enter giveaway" link
global TutorialUrl  := "https://www.youtube.com/watch?v=2-K89sp8H4o"  ; "Video setup" link -> YouTube walkthrough
; Microsoft's Evergreen WebView2 bootstrapper. Offered if the window can't be created
; because the runtime is missing (preinstalled on Win11, not on every Win10 build).
global WebView2RuntimeUrl := "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
global TokenFile    := A_AppData "\GardenMacro\token.txt"   ; saved paste-code
global DeviceFile   := A_AppData "\GardenMacro\device.txt"  ; random anon install id
global DeviceId     := ""           ; set at startup (see GetOrCreateDeviceId)
global HeartbeatReq := 0            ; keeps the async ping COM object alive in-flight
global EventReq     := 0            ; keeps the async funnel-event ping alive in-flight
; "Report a bug" (footer) submissions POST straight to this Discord webhook -- no
; backend hop, so it works even if the site is down. Best-effort; a bad URL or a
; Discord outage can never crash the macro (see SendBugReport).
global BugReportWebhook := "https://discord.com/api/webhooks/1526917578927112244/yMU9Ma9lp03dY5GGd320GFex_cwuabhaSuOMt2ztZOSt8bguaEGdKEi2xuic643nKYZP"

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

; --- Flash deal: a limited-time discount on the FIRST month of Pro, A/B tested
;     across three discount depths (75% / 65% / 50% off first month). Every install is randomly assigned a
;     variant (1/2/3) ONCE and it never changes, so the split stays even and each user
;     always sees the same price. For 24h after first launch the macro shows a live
;     countdown (a persistent banner + a one-time popup) and opens the sign-in page with
;     ?offer=<variant> so the matching Stripe promotion code AUTO-APPLIES at checkout --
;     no code to paste. Suppressed for Pro users and anyone holding a creator code (Stripe
;     discounts don't stack). Conversion + net revenue per arm show on the stats
;     dashboard's "Flash deal" panel. KEEP IN SYNC: the variant->code mapping lives in
;     functions/_lib/creators.js (FLASH_CODES); OfferUsd below must reflect those
;     percentages applied to the US price.
global OfferFile     := A_AppData "\GardenMacro\offer.txt"   ; "<variant 1|2|3>|<window-start YYYYMMDDHHMMSS>"
global OfferVariant  := 0                                    ; this install's arm (0 = not assigned yet)
global OfferStamp    := ""                                   ; when the 24h window started (first launch on this build)
global OfferWindowMs := 24 * 60 * 60 * 1000                  ; deal is live for 24h after first launch
; OfferUsd = the (rounded) first-month price shown in the deal per variant. The real
; charge is the Stripe %-off coupon applied to the $5.93 US price (75%->$1.48, 65%->$2.08,
; 50%->$2.97); we show clean $1.50 / $2 / $3. Keep in sync if the FLASH_CODES percentages
; change (75/65/50 for variants 1/2/3).
global OfferUsd      := Map(1, "$1.50", 2, "$2", 3, "$3")
global OfferShownSession := false                            ; banner/popup already shown this session?
global WillOnboard   := false                                ; a first-launch onboarding wall runs this launch?

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
    {name: "Sun Bloom",       rarity: "Super"},
    {name: "Hypno Bloom",     rarity: "Super"},
    {name: "Dragon's Breath", rarity: "Super"},
    {name: "Star Fruit",      rarity: "Super"}
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

; Restore any promo code the user entered (shown in the corner as a checkout reminder).
LoadPromo()
LoadSource()
LoadOrCreateOffer()   ; assign (or restore) this install's flash-deal A/B price variant

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

; Flash deal: the 24h countdown (banner + one-time popup) is NOT shown on a timer -- a fixed
; delay used to race the creator-code prompt (source prompt at 1.8s, this at 2.6s) and show the
; deal to code holders before they'd finished entering their code. Instead it's triggered once
; onboarding has FULLY settled and a creator code is therefore known, from SkipPromo /
; ContinueToPromo (ApplyPromo needs no trigger -- an applied code always suppresses the deal).
; Still a no-op if the user is Pro, holds a creator code, or the window elapsed (see OfferActive).

; ============================================================
;  UI  (WebView2 window + HTML/CSS/JS)
; ============================================================
BuildUi() {
    global MainGui, controller, wv, PremiumCount, Seeds, Gears, PromoCode, PromoPct, TokenFile
    global SourceAsked, PromoAsked, WillOnboard, GiveawayCode

    dllPath := A_ScriptDir "\lib\WebView2Loader.dll"
    dataDir := A_AppData "\GardenMacro\WebView2"   ; writable user-data folder
    DirCreate dataDir

    PreflightWebView(dllPath)   ; exits with a readable message if the window can't work here

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
    try
        controller := WebView2.create(MainGui.Hwnd, , 0, dataDir, "", 0, dllPath)
    catch as e
        WebViewFailed(e)                      ; explains the fix, then exits
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
    ; Giveaway entry code shown under the version. If the user holds a creator code, show THAT
    ; instead of the generic shared code -- a creator code also proves they have the macro (+2
    ; giveaway entries), and on the giveaway page it swaps the generic 30%-off chip for the
    ; creator's own code + percent. Updated live if a code is entered this session (promoAccepted).
    giveCode := (PromoCode != "") ? PromoCode : GiveawayCode
    html := StrReplace(html, "__GIVEAWAY__", giveCode)
    ; Inline the giveaway banner image (Moon Bloom seed) as a data URI so the top banner
    ; renders with no network dependency. Prefer the on-disk file (local dev), but fall back
    ; to the copy embedded in this script: the launcher only downloads macro.ahk from GitHub,
    ; so a separate .webp won't sit next to the running script -- the image has to travel
    ; INSIDE the file. Keep GiveawayImgDataUri in sync if the on-disk image changes.
    giveImg := FileToDataUri(A_ScriptDir "\MoonBloomSeed.webp", "image/webp")
    if (giveImg = "")
        giveImg := GiveawayImgDataUri()
    html := StrReplace(html, "__GIVEAWAYIMG__", giveImg)
    html := StrReplace(html, "__PROMO__", PromoCode)   ; "" if none/skipped -> badge stays hidden
    html := StrReplace(html, "__PROMOPCT__", PromoPct) ; the code's discount percent (0 if none) -> badge "N% off"
    hasToken := (FileExist(TokenFile) && ReadToken(TokenFile) != "") ? "1" : "0"  ; returning user? -> skip the promo wall
    ; A first-launch onboarding wall arrives ~1.8s after load (see MaybeAskSource), so the
    ; fully-rendered app would flash until then. If a wall IS going to show, tell the page to
    ; paint a plain cover from the very first frame; the real wall cross-dissolves in over it.
    ;   source wall shows <=> source not yet answered
    ;   promo  wall shows <=> source done, promo not asked, and not (likely) Pro -- a saved
    ;                         token means a returning user (already onboarded / probably Pro).
    ; Drives __ONBOARD__ -> the page's boot cover. (The flash popup no longer keys off this:
    ; it's always requested, and the page defers it until any onboarding wall has cleared.)
    WillOnboard := (!SourceAsked) || (!PromoAsked && hasToken = "0")
    html := StrReplace(html, "__ONBOARD__", WillOnboard ? "1" : "0")
    wv.NavigateToString(html)
}

; ============================================================
;  WebView2 preflight
;
;  Everything the window needs before WebView2.create can work. Each of these
;  used to surface as AutoHotkey's raw "Failed to load DLL" box -- true, but not
;  something a player can act on, and the macro then just never appeared.
;
;  Returns only when the window has a real chance of building; otherwise it says
;  what to do and exits.
; ============================================================
PreflightWebView(dllPath) {
    ; 1. Bitness. WebView2Loader.dll is x64-only, so under 32-bit AutoHotkey
    ;    LoadLibrary refuses it. A user gets here when their .ahk association
    ;    points at AutoHotkey32.exe: the launcher runs the macro with whatever
    ;    interpreter opened the launcher itself. Re-run under the 64-bit build
    ;    rather than making them fix the association.
    if (A_PtrSize = 4) {
        ahk64 := Find64BitAhk()
        if (A_Is64bitOS && ahk64 != "") {
            try {
                Run('"' ahk64 '" "' A_ScriptFullPath '"')
                ExitApp
            }
        }
        MsgBox(A_Is64bitOS
            ? "Garden Macro needs the 64-bit build of AutoHotkey v2.`n`n"
            . "Reinstall AutoHotkey v2 from autohotkey.com, keep the default 64-bit option, then start the macro again."
            : "Garden Macro needs 64-bit Windows and can't run on this PC.",
            "Garden Macro", "Iconx")
        ExitApp
    }

    ; 2. The loader itself: missing (antivirus quarantine, or the macro started on
    ;    its own) or corrupt (an interrupted download, or an HTML error page saved
    ;    under the .dll name). Corrupt is the nastier case -- the file looks present,
    ;    so the launcher's old FileExist check never replaced it and EVERY launch
    ;    failed from then on, forever.
    ;
    ;    Repair it HERE rather than leaning on the launcher: the launcher already on
    ;    a user's disk never updates itself, so this file is the only fix that can
    ;    reach an install that's already broken.
    if !DllOk(dllPath) {
        try FileDelete(dllPath)
        if !RepairLoaderDll(dllPath) {
            MsgBox("Garden Macro couldn't repair one of its components (WebView2Loader.dll).`n`n"
                 . "Check your internet connection and start it again.`n`n"
                 . "If your antivirus keeps removing the file, allow this folder:`n" A_ScriptDir "\lib",
                   "Garden Macro", "Iconx")
            ExitApp
        }
    }
}

; Re-download the loader from the same GitHub source the launcher pulls from.
; True only once a valid 64-bit loader is actually in place.
RepairLoaderDll(dllPath) {
    global UpdateSrcUrl
    url := RegExReplace(UpdateSrcUrl, "[^/]+$", "") "lib/WebView2Loader.dll"
    SplitPath(dllPath, , &dir)
    if !DirExist(dir)
        try DirCreate(dir)
    try Download(url, dllPath)
    if DllOk(dllPath)
        return true
    try FileDelete(dllPath)
    return false
}

; True only for a real 64-bit WebView2Loader.dll -- FileExist can't tell the real
; thing from a truncated download or a saved error page. Mirrors the launcher's
; copy; the two scripts stand alone and can't share a lib (the launcher runs
; before lib/ exists).
DllOk(path) {
    if (!FileExist(path) || FileGetSize(path) < 50000)
        return false
    return PeMachine(path) = 0x8664
}

; The PE header's machine field (0x8664 = x64), or 0 if this isn't a PE file.
PeMachine(path) {
    try {
        f := FileOpen(path, "r")
        if !f
            return 0
        f.Pos := 0
        if (f.RawRead(mz := Buffer(2), 2) < 2 || NumGet(mz, 0, "UShort") != 0x5A4D)   ; "MZ"
            return (f.Close(), 0)
        f.Pos := 0x3C
        if (f.RawRead(off := Buffer(4), 4) < 4)
            return (f.Close(), 0)
        f.Pos := NumGet(off, 0, "UInt")
        n := f.RawRead(sig := Buffer(6), 6)
        f.Close()
        if (n < 6 || NumGet(sig, 0, "UInt") != 0x00004550)                            ; "PE\0\0"
            return 0
        return NumGet(sig, 4, "UShort")
    } catch {
        return 0
    }
}

; Called when WebView2.create throws. The runtime check lives HERE rather than in
; the preflight on purpose: the loader finds the runtime through the registry and
; so can succeed from install paths we don't scan, and wrongly blocking a working
; PC is worse than a slightly late message.
WebViewFailed(e) {
    global WebView2RuntimeUrl, BackendBase

    if !EdgeRuntimeInstalled() {
        if (MsgBox("Garden Macro needs the Microsoft Edge WebView2 runtime, and it isn't installed on this PC.`n`n"
                 . "Open Microsoft's free download page? Install it, then start the macro again.",
                   "Garden Macro", "YesNo Iconi") = "Yes")
            OpenExternal(WebView2RuntimeUrl)
        ExitApp
    }

    if (MsgBox("Garden Macro couldn't open its window.`n`n"
             . e.Message "`n`n"
             . "Open the setup guide for help?", "Garden Macro", "YesNo Iconx") = "Yes")
        OpenExternal(BackendBase "/help.html")
    ExitApp
}

; The 64-bit interpreter, or "" if there isn't one. Note this runs under 32-bit
; AutoHotkey, where A_ProgramFiles is the (x86) folder -- ProgramW6432 is the
; real one.
Find64BitAhk() {
    cands := []
    if (A_AhkPath != "") {
        SplitPath(A_AhkPath, , &dir)
        cands.Push(dir "\AutoHotkey64.exe", dir "\v2\AutoHotkey64.exe")
    }
    for root in [EnvGet("ProgramW6432"), A_ProgramFiles]
        if (root != "")
            cands.Push(root "\AutoHotkey\v2\AutoHotkey64.exe", root "\AutoHotkey\AutoHotkey64.exe")
    for c in cands
        if FileExist(c)
            return c
    return ""
}

; Same roots WebView2.ahk scans for the runtime, plus the 64-bit Program Files.
EdgeRuntimeInstalled() {
    for root in [EnvGet("ProgramFiles(x86)"), EnvGet("ProgramW6432"), A_AppData "\..\Local"] {
        if (root = "")
            continue
        loop files root "\Microsoft\EdgeWebView\Application\*", "D"
            if RegExMatch(A_LoopFileName, "^[\d.]+$")
                return true
    }
    return false
}

; Open a URL in the default browser, with the same explorer.exe fallback the
; other external links use.
OpenExternal(url) {
    try
        Run(url)
    catch
        try Run("explorer.exe " url)
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

; Read a (small) binary file and return it as a base64 "data:" URI. Used to inline the
; giveaway banner image into the WebView page so it renders with NO network dependency
; (the page is served via NavigateToString, so relative paths don't resolve and an
; external URL would break the banner offline). Returns "" if the file is missing or
; unreadable, so the banner's <img> can just hide itself gracefully.
FileToDataUri(path, mime) {
    if !FileExist(path)
        return ""
    try {
        f := FileOpen(path, "r")
        if !f
            return ""
        size := f.Length
        buf  := Buffer(size)
        f.RawRead(buf, size)
        f.Close()
        ; CryptBinaryToString, flags 0x40000001 = CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF
        ; (NOCRLF keeps it on one line so it can sit in an HTML attribute).
        flags := 0x40000001, len := 0
        DllCall("crypt32\CryptBinaryToStringW", "ptr", buf, "uint", size, "uint", flags, "ptr", 0, "uint*", &len)
        out := Buffer(len * 2)
        if !DllCall("crypt32\CryptBinaryToStringW", "ptr", buf, "uint", size, "uint", flags, "ptr", out, "uint*", &len)
            return ""
        return "data:" mime ";base64," StrGet(out, "UTF-16")
    } catch {
        return ""
    }
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
        case "flashclaim":
            OpenFlashCheckout()
        case "openhelp":
            OpenHelpPage()
        case "opentutorial":
            OpenTutorialPage()
        case "opengiveaway":
            OpenGiveawayPage()
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
            ; "ev|<name>[|<variant>]" -> forward a one-off funnel event from the WebView
            ; (popup shown/copied/dismissed). The optional 3rd field is the flash-deal A/B
            ; arm (1/2/3), tagged onto flash_* events. The backend allowlists the names.
            if parts.Length >= 2 && parts[2] != ""
                SendEvent(parts[2], parts.Length >= 3 ? parts[3] : "")
        case "fit":
            if parts.Length >= 2 && IsInteger(parts[2])
                FitWindowHeight(Integer(parts[2]))
        case "bug":
            ; "bug|<contact>|<detail>" -> forward a user bug report to Discord.
            ; The detail is free text that may itself contain "|" and newlines, so
            ; take it as the unsplit remainder (MaxParts 3); the page already strips
            ; delimiters from the short optional contact field.
            bp := StrSplit(msg, "|", , 3)
            SendBugReport(bp.Length >= 3 ? bp[3] : "", bp.Length >= 2 ? bp[2] : "")
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
    global LoopActive, Running, IntervalMs, LastSel, PassQty
    global SeedSel, GearSel, SelSet, Unlocked, MainGui
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

    ; Lock in the selection + quantity for this whole loop session. The macro
    ; anchors at position 1 and only needs the LAST ticked index as the walk's
    ; lower bound; SelSet decides which rows actually get bought.
    LastSel := picks[picks.Length]
    SelSet  := Map()
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

; ---- Flash deal (24h post-install first-month discount, A/B priced) ----

; Restore the persisted flash-deal variant + window start, or create them on first run
; of this build. Every install gets a stable 1/2/3 arm (kept forever) so the A/B split
; is even and a user always sees the same price; the window start is when this build
; first ran, so EXISTING users also get a fresh 24h deal (not just brand-new installs).
LoadOrCreateOffer() {
    global OfferFile, OfferVariant, OfferStamp
    if FileExist(OfferFile) {
        raw := ""
        try raw := Trim(FileRead(OfferFile, "UTF-8"), " `t`r`n" Chr(0xFEFF))
        parts := StrSplit(raw, "|")
        v := parts.Length >= 1 ? parts[1] : ""
        if (v = "1" || v = "2" || v = "3") {
            OfferVariant := Integer(v)
            if (parts.Length >= 2 && IsInteger(parts[2]) && StrLen(parts[2]) >= 8) {
                OfferStamp := parts[2]
            } else {
                OfferStamp := A_Now     ; legacy variant-only file -> start the window now + persist
                SaveOffer()
            }
            return
        }
    }
    OfferVariant := Random(1, 3)
    OfferStamp := A_Now
    SaveOffer()
}

; Persist the variant + window start (no BOM; create the folder if needed).
SaveOffer() {
    global OfferFile, OfferVariant, OfferStamp
    try {
        SplitPath(OfferFile, , &dir)
        if (dir != "" && !DirExist(dir))
            DirCreate(dir)
        f := FileOpen(OfferFile, "w", "UTF-8-RAW")
        f.Write(OfferVariant "|" OfferStamp)
        f.Close()
    }
}

; Seconds left in the 24h flash window (0 once expired). Anchored to OfferStamp (this
; build's first launch), so it survives restarts and expires exactly 24h in.
OfferSecondsLeft() {
    global OfferWindowMs, OfferStamp
    if (OfferStamp = "")
        return 0
    elapsedS := DateDiff(A_Now, OfferStamp, "Seconds")   ; both are YYYYMMDDHHMMSS timestamps
    if (elapsedS < 0)
        elapsedS := 0
    leftS := (OfferWindowMs // 1000) - elapsedS
    return leftS > 0 ? leftS : 0
}

; Is the flash deal live for this user right now? Not Pro, no creator code (Stripe
; discounts don't stack), a variant assigned, and still inside the 24h window.
OfferActive() {
    global Unlocked, PromoCode, OfferVariant
    if (Unlocked || PromoCode != "" || OfferVariant = 0)
        return false
    return OfferSecondsLeft() > 0
}

; Show the flash-deal countdown: the persistent banner plus a one-time modal popup.
; Fires the flash_shown funnel impression once per session, tagged with the arm.
; Called once onboarding has settled (SkipPromo / ContinueToPromo), NOT on a timer, so the
; creator code is already known -- OfferActive() then reliably suppresses it for code holders.
; We ALWAYS request the popup; if a first-launch onboarding wall (the "Welcome!" finale) is
; still animating, the PAGE defers the popup until that wall clears rather than letting it
; pop underneath -- so it shows on first launch too, just after onboarding settles.
MaybeShowFlashOffer() {
    global OfferVariant, OfferUsd, OfferShownSession, MainGui
    if (OfferShownSession || !OfferActive())
        return
    OfferShownSession := true
    secs := OfferSecondsLeft()
    usd  := OfferUsd.Has(OfferVariant) ? OfferUsd[OfferVariant] : "$3"
    try MainGui.Restore()                   ; un-minimize so the popup is actually seen
    Post("flash|" OfferVariant "|" usd "|" secs "|1")
    SendEvent("flash_shown", OfferVariant)  ; funnel: the flash countdown was shown (A/B denominator)
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
        ; NOTE: no "unlock" funnel event here on purpose. This path only ever runs when a
        ; saved token already exists, i.e. on RELAUNCHES after the user first pasted a code.
        ; The upgrade is logged once at that first paste (ActivateCode) so the install->
        ; upgrade timing measures the real first upgrade, not every subsequent relaunch.
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
    global BackendBase, MainGui, OfferVariant, PromoCode
    ; Count this as a funnel step: an install that clicked through to the pay page.
    SendEvent("get_access")
    url := BackendBase "/signin.html"
    ; During the 24h flash window, carry the price variant so the discount auto-applies
    ; at checkout (the sign-in page stashes it in a cookie across the Google login).
    ; Otherwise, if the user entered a creator code, carry that instead so IT auto-applies
    ; the same way -- no code to paste. The two are mutually exclusive (OfferActive() is
    ; false whenever a creator code is held), so at most one query param is ever added.
    ; PromoCode is pre-validated + UPPER-cased and is plain A-Z, so it needs no escaping.
    if OfferActive()
        url .= "?offer=" OfferVariant
    else if (PromoCode != "")
        url .= "?code=" PromoCode
    try
        Run(url)
    catch
        try Run("explorer.exe " url)
    try MainGui.Minimize()
}

; Flash-deal "Claim" -> open the browser STRAIGHT to Stripe checkout with the discount
; applied. /api/checkout redirects to Google login first if needed, then (via the
; callback's gag_offer handling) back into checkout, so the coupon still applies. No
; in-app unlock modal. The ?offer=<variant> is what selects the coupon at checkout.
OpenFlashCheckout() {
    global BackendBase, MainGui, OfferVariant
    SendEvent("get_access")                  ; funnel: clicked through to the pay page
    url := BackendBase "/api/checkout"
    if OfferActive()
        url .= "?offer=" OfferVariant
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

; Top giveaway banner -> open the giveaway page in the default browser. The page reads
; the shared macro code the footer already shows (+2 entries). Same open-in-browser
; fallback as the other external links.
OpenGiveawayPage() {
    global GiveawayUrl
    try
        Run(GiveawayUrl)
    catch
        try Run("explorer.exe " GiveawayUrl)
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
        ; Funnel: the user just upgraded (pasted a valid code, first activation on this
        ; install). Device-linked so /stats can measure install -> upgrade time. Fired only
        ; here (not on relaunch re-verify) so it marks the true first upgrade, once.
        SendEvent("unlock")
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
    MaybeShowFlashOffer()   ; onboarding settled with no creator code -> now safe to show the flash
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
    if !MaybeAskPromo() {
        Post("sourcedone")
        MaybeShowFlashOffer()   ; onboarding settled with no code prompt -> now safe to show the flash
    }
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

; Like JsonEscape but PRESERVES line breaks as \n escape sequences. Bug-report
; text is multi-line free text, so flattening newlines (as JsonEscape does) would
; run every line together. Backslash MUST be escaped first, before we introduce
; the \n / \t escapes, or those backslashes would get doubled.
JsonEscapeText(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r`n", "\n")
    s := StrReplace(s, "`r", "\n")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
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
SendEvent(ev, variant := "") {
    global PingUrl, DeviceId, AppVersion, EventReq
    if (DeviceId = "" || ev = "")
        return
    ; Flash-deal events carry the A/B price arm (1/2/3) in "var"; other events omit it.
    varField := (variant != "" && variant != 0) ? ',"var":"' JsonEscape(variant "") '"' : ""
    body := '{"id":"' JsonEscape(DeviceId) '","v":"' JsonEscape(AppVersion) '","ev":"' JsonEscape(ev) '"' varField '}'
    try {
        EventReq := ComObject("WinHttp.WinHttpRequest.5.1")
        EventReq.SetTimeouts(3000, 3000, 3000, 8000)
        EventReq.Open("POST", PingUrl, true)          ; true = async, don't block
        EventReq.SetRequestHeader("Content-Type", "application/json")
        EventReq.Send(body)
    }
}

; ============================================================
;  Bug reports  ("Report a bug" in the footer -> Discord webhook)
; ============================================================
; Post a user-submitted bug report straight to the Discord webhook and tell the page
; whether it actually landed ("bugok" / "bugfail|<msg>"). Synchronous on purpose so
; the confirmation the user sees is real (delivered), not optimistic -- the send is a
; deliberate one-off click, so the brief block is fine. Fully guarded: bad input, an
; offline machine, or a Discord outage can never crash the macro.
SendBugReport(detail, contact) {
    global BugReportWebhook, AppVersion, DeviceId
    detail  := Trim(detail)
    contact := Trim(contact)
    ; Server-side floor mirrors the page's 100-char minimum. The page disables Send
    ; below it, so this only trips if the UI was somehow bypassed.
    if (StrLen(detail) < 100) {
        Post("bugfail|Please add more detail (at least 100 characters).")
        return
    }
    ; Discord limits: embed description <= 4096 chars, field value <= 1024. Trim well
    ; under so the JSON escaping can grow the string without breaching the cap.
    if (StrLen(detail) > 3800)
        detail := SubStr(detail, 1, 3800) "..."
    if (StrLen(contact) > 300)
        contact := SubStr(contact, 1, 300)
    contactVal := (contact != "") ? contact : "(not provided)"
    ts := FormatTime(A_NowUTC, "yyyy-MM-dd'T'HH:mm:ss'Z'")   ; ISO 8601 UTC for the embed
    ; One-line body (auto-concat), matching SendEvent/SendHeartbeat. color 15548997 = Discord red.
    body := '{"embeds":[{"title":"New bug report","description":"' JsonEscapeText(detail) '","color":15548997,"fields":[{"name":"Contact","value":"' JsonEscapeText(contactVal) '","inline":true},{"name":"Version","value":"' JsonEscape(AppVersion) '","inline":true},{"name":"Device","value":"' JsonEscape(DeviceId) '","inline":false}],"timestamp":"' ts '"}]}'
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(4000, 4000, 4000, 8000)   ; resolve, connect, send, receive (ms)
        req.Open("POST", BugReportWebhook, false)
        req.SetRequestHeader("Content-Type", "application/json")
        req.Send(body)
        ; Discord webhooks answer 204 No Content on success (200 only with ?wait=true).
        if (req.Status = 204 || req.Status = 200) {
            Post("bugok")
            return
        }
        Post("bugfail|Could not send (HTTP " req.Status "). Please try again.")
    } catch as e {
        Post("bugfail|Could not send. Check your connection and try again.")
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
; and snap to position 1 (the anchor the buy pass counts down from). It leaves the
; cursor ON position 1 -- the buy pass does all the down-walking itself.
;
;   Seeds:  click the shop at (697,103), press "e", then "\", then snap to
;           position 1 (Up 5x + Down 5x + hold Up 3s -> the first seed).
;   Gears:  you must already be standing in the open Gear Shop UI, so NO click and
;           NO "e" -- just "\", then the same snap to position 1 (the first gear).
;
; Returns false if stopped or Roblox is missing.
Setup() {
    global ActiveMode
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

    ; 2b. Snap to position 1 (the first item): Up 5x then Down 5x to shake the cursor
    ;     into the list, then HOLD Up for 3s. A held key scrolls all the way to the
    ;     very top regardless of list length, settling on position 1. Identical for
    ;     seeds and gears -- position 1 is the anchor the buy pass counts down from.
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

    ; Setup leaves the cursor ON position 1 (the anchor). The buy pass counts its
    ; own Down presses from here, so there's nothing more for setup to move onto.
    return true
}

; One buy pass. Assumes the cursor is on position 1 (where Setup leaves it).
; Walks DOWN from position 1 buying each ticked seed, then walks back UP to
; position 1 -> ends where it started, ready to repeat with no setup.
BuyPass() {
    global Running, ActiveItems, SelSet, LastSel, PassQty

    ; Keep Roblox focused (this does NOT move the UI cursor).
    if WinExist("ahk_exe RobloxPlayerBeta.exe")
        WinActivate

    ; Walk DOWN from position 1 to the last selected seed, buying ticked ones.
    i := 1
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

    ; Walk back UP to position 1 for the next pass.
    Loop LastSel - 1 {
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

; Embedded copy of the giveaway banner image (MoonBloomSeed.webp) as a base64 data URI.
; The launcher downloads only macro.ahk from GitHub and runs it from %AppData%, where the
; .webp is NOT present -- so the banner image has to travel INSIDE this file. BuildUi uses
; the on-disk file when present (local dev) and falls back to this. To refresh it after a
; prize change, re-encode MoonBloomSeed.webp as one-line base64 and replace the string.
GiveawayImgDataUri() {
    return "data:image/webp;base64,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"
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
  /* One-tap link to the setup video; replaces the old wall of text reminders.
     Clicking opens the walkthrough and dismisses this row for good (the top
     "Video setup" link stays as the permanent way back). */
  .setupvid{display:inline-flex;align-items:center;align-self:flex-start;margin-top:-6px;gap:7px;
        cursor:pointer;border:1px solid #eee;transition:background .12s,border-color .12s}
  .setupvid:hover{background:#f3f4f6;border-color:#e0e0e0}
  .setupvid b{color:#333}
  /* Little YouTube glyph: red rounded badge with a white play triangle. */
  .setupvid .ytlogo{position:relative;width:19px;height:13px;background:#ff0000;
        border-radius:4px;flex-shrink:0}
  .setupvid .ytlogo::after{content:'';position:absolute;top:50%;left:50%;
        transform:translate(-50%,-50%);border-style:solid;border-width:3.5px 0 3.5px 6px;
        border-color:transparent transparent transparent #fff}
  .setupvid .svarrow{color:#bbb;font-weight:700;flex-shrink:0}
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
  .verwrap{margin-left:auto;display:flex;flex-direction:column;align-items:flex-end;gap:1px;line-height:1.25}
  .ver{font-size:11px;color:#bbb;white-space:nowrap;
       font-family:'Consolas','JetBrains Mono',monospace}
  .give{font-size:10px;color:#9aa0a6;white-space:nowrap;
        font-family:'Consolas','JetBrains Mono',monospace}
  .give b{color:#16a34a;font-weight:700;letter-spacing:.05em}
  /* "Report a bug": a small muted gray button pinned to the bottom-right corner,
     sitting just above the version line (the verwrap is a right-aligned column). */
  .reportbtn{align-self:flex-end;margin-bottom:7px;border:1px solid #d5d7db;background:#e6e8eb;
        color:#5b616b;font-family:inherit;font-size:12px;font-weight:600;border-radius:6px;
        padding:5px 12px;cursor:pointer;line-height:1.2}
  .reportbtn:hover{background:#dcdfe3;color:#3f444c;border-color:#c8cbd0}
  /* "Restart to update" banner. Shown (in red) when a newer macro.ahk has shipped
     to `main` while this session was running (see CheckForUpdate). Sits right under
     the title so it's seen on every tab; hidden until AHK sends "update|<version>". */
  .updatebar{display:none;text-align:center;font-size:12px;font-weight:600;line-height:1.4;
       color:#b91c1c;background:#fef2f2;border:1px solid #fecaca;border-radius:8px;
       padding:8px 12px;margin-bottom:12px}
  .updatebar.show{display:block}
  .updatebar b{font-weight:800}
  /* Giveaway banner: a persistent blue promo bar under the title (blue to match the Moon
     Bloom seed image). A "Free giveaway" eyebrow + "Enter" button make it read as a free
     prize draw, not another paid upsell. Clicking anywhere on it -- or the Enter button --
     opens the giveaway page. The seed image is inlined as a data URI (see FileToDataUri) so
     it shows with no network, over a soft blue glow. */
  .givebar{display:flex;align-items:center;gap:11px;cursor:pointer;text-decoration:none;
       background:#eff6ff;border:1px solid #bfdbfe;border-radius:10px;padding:8px 10px 8px 9px;
       transition:background .12s,border-color .12s}
  .givebar:hover{background:#e4efff;border-color:#93c5fd}
  .givebar .gb-imgwrap{position:relative;display:grid;place-items:center;flex-shrink:0;width:56px;height:56px}
  .givebar .gb-imgwrap::before{content:'';position:absolute;width:56px;height:56px;border-radius:50%;
       background:radial-gradient(circle,rgba(59,130,246,.45),rgba(59,130,246,.14) 55%,transparent 72%)}
  .givebar .gb-img{position:relative;width:46px;height:46px;object-fit:contain}
  .givebar .gb-txt{flex:1;display:flex;flex-direction:column;line-height:1.25;min-width:0}
  .givebar .gb-eyebrow{font-size:9.5px;font-weight:800;letter-spacing:.1em;text-transform:uppercase;color:#2563eb;margin-bottom:2px}
  .givebar .gb-title{font-size:13px;font-weight:700;color:#1e3a8a}
  .givebar .gb-sub{font-size:11px;color:#5578c0;margin-top:1px}
  .givebar .gb-cta{flex-shrink:0;background:#2563eb;color:#fff;font-size:12.5px;font-weight:700;
       border-radius:7px;padding:7px 18px;line-height:1.3}
  .givebar:hover .gb-cta{background:#1d4ed8}
  /* Flash-deal countdown banner: a green deal bar under the title, shown for 24h after
     install (see MaybeShowFlashOffer). Hidden until AHK sends "flash|..."; the page
     ticks the timer down itself and hides the bar at zero. Clicking it opens checkout. */
  .flashbar{display:none;align-items:center;gap:12px;
       background:#fef2f2;border:1px solid #fecaca;border-radius:8px;padding:8px 10px 8px 13px}
  .flashbar.show{display:flex;animation:flashDrop .32s ease-out both}
  .flashbar .fbinfo{display:flex;flex-direction:column;line-height:1.25;min-width:0}
  .flashbar .fblabel{font-size:10px;font-weight:800;letter-spacing:.6px;text-transform:uppercase;color:#b91c1c}
  .flashbar .fbmain{font-size:12.5px;color:#444}
  .flashbar .fbprice{font-weight:800;color:#dc2626}
  .flashbar .fbtime{margin-left:auto;font-family:'Consolas','JetBrains Mono',monospace;
       font-size:24px;font-weight:800;color:#dc2626;letter-spacing:.5px}
  .flashbar .fbbtn{flex-shrink:0;background:#dc2626;color:#fff;border:none;border-radius:6px;
       padding:9px 20px;font-size:13px;font-weight:700;cursor:pointer;font-family:inherit}
  .flashbar .fbbtn:hover{background:#b91c1c}
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
  .pbar:hover{background:#f3f3f3}
  .pbar .plock{opacity:.55;font-size:13px}
  .pbar .pget{margin-left:auto;font-weight:700;color:#16a34a;white-space:nowrap;flex-shrink:0}
  .pbar:hover .pget{color:#15803d}
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
  /* "Maybe later" dismiss link, shared by the flash-deal popup */
  .hintDismiss{display:block;text-align:center;margin-top:8px;font-size:12px;color:#999;cursor:pointer}
  .hintDismiss:hover{color:#555;text-decoration:underline}
  /* Flash-deal popup (red): big price + big live countdown */
  .flashmodal{text-align:center;position:relative}
  .flashmodal .mx{position:absolute;top:-2px;right:0}
  .flasheyebrow{font-size:11px;font-weight:800;letter-spacing:1.4px;text-transform:uppercase;color:#dc2626;margin-bottom:14px}
  .flashlead{font-size:13px;color:#555;margin:0}
  .flashbig{font-size:54px;font-weight:800;color:#dc2626;line-height:1.02;letter-spacing:-1.5px;margin:2px 0}
  .flashsub{font-size:12.5px;color:#888;margin:0 0 16px}
  .flashtimer{font-family:'Consolas','JetBrains Mono',monospace;font-size:40px;font-weight:800;color:#dc2626;
        background:#fef2f2;border:1.5px solid #fecaca;border-radius:10px;padding:12px 8px;margin:0 0 16px;letter-spacing:1px}
  .btn.red{background:#dc2626;color:#fff;border-color:#dc2626}
  /* Flash entrance: ease the backdrop, modal, and banner in so nothing snaps in abruptly
     ~3s after launch. The old instant reveal (flashOverlay.hidden=false) read as a jump-scare.
     Scoped to #flashOverlay so the onboarding walls' in-place swap logic is untouched. */
  @keyframes flashFade{from{opacity:0}to{opacity:1}}
  @keyframes flashPop{from{opacity:0;transform:translateY(10px) scale(.94)}to{opacity:1;transform:none}}
  @keyframes flashDrop{from{opacity:0;transform:translateY(-8px)}to{opacity:1;transform:none}}
  #flashOverlay:not([hidden]){animation:flashFade .3s ease-out both}
  #flashOverlay .modal{animation:flashPop .4s cubic-bezier(.2,.85,.25,1) both}
  @media (prefers-reduced-motion:reduce){
    #flashOverlay:not([hidden]),#flashOverlay .modal,.flashbar.show{animation-duration:.01ms}}
  .btn.red:hover{background:#b91c1c;border-color:#b91c1c}
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
  /* Bug-report modal */
  .modal.bugmodal{max-height:calc(100vh - 36px);overflow:auto}
  .bugintro{font-size:12.5px;color:#777;margin:0 0 14px;line-height:1.5}
  .bugintro b{color:#444;font-weight:600}
  .bugfield{position:relative;margin-bottom:12px}
  .buglabel{display:block;font-size:12px;font-weight:600;color:#555;margin-bottom:5px}
  .buglabel .opt{font-weight:500;color:#aaa}
  .buglabel .req{color:#dc2626;font-weight:700}
  #bugDetail{width:100%;min-height:118px;resize:none;background:#fff;border:1px solid #d8d8d8;
        border-radius:8px;padding:10px 11px 22px;font-size:13px;line-height:1.5;font-family:inherit;
        outline:none;color:#1a1a1a}
  #bugDetail:focus{border-color:#16a34a}
  .bugcount{position:absolute;right:9px;bottom:8px;font-size:10.5px;color:#bbb;pointer-events:none;
        font-family:'Consolas','JetBrains Mono',monospace;background:#fff;padding:0 3px;border-radius:4px}
  .bugcount.ok{color:#16a34a}
  .bugcontact{display:flex;align-items:center;gap:8px;background:#fff;border:1px solid #d8d8d8;
        border-radius:8px;padding:0 11px}
  .bugcontact:focus-within{border-color:#16a34a}
  .bugcontact .cicons{display:flex;align-items:center;gap:5px;flex-shrink:0;color:#b4b4b4}
  .bugcontact .cicons svg{display:block}
  #bugContact{flex:1;min-width:0;border:none;outline:none;background:none;padding:9px 0;font-size:13px;
        font-family:inherit;color:#1a1a1a}
  .bugmsg{font-size:12px;color:#888;margin:2px 0 12px;min-height:15px;line-height:1.4}
  .bugmsg.err{color:#dc2626}
  .bugmsg.ok{color:#16a34a}
  [hidden]{display:none !important}
</style>
</head>
<body>
  <div id='promoBadge' class='promobadge' hidden onclick='openAccess()'>Use code <b id='promoBadgeCode'></b> for <b id='promoBadgePct'></b>% off</div>
  <h1>Garden Macro</h1>
  <div id='updateBar' class='updatebar'>&#128260; A new version<span id='updateVer'></span> is available &mdash; <b>close and reopen the macro</b> to update.</div>
  <!-- Giveaway promo banner. Static title/image, like the site's OG card -- update the text
       and MoonBloomSeed.webp here if the prize changes. Opens gardenmacro.com/giveaway. -->
  <div id='giveBanner' class='givebar' onclick='openGiveaway()'>
    <span class='gb-imgwrap'>
      <img class='gb-img' src='__GIVEAWAYIMG__' alt='' onerror='this.style.display="none"'>
    </span>
    <span class='gb-txt'>
      <span class='gb-eyebrow'>Free giveaway</span>
      <span class='gb-title'>Win 10x Moon Bloom Seeds</span>
      <span class='gb-sub'>Enter for a chance to win</span>
    </span>
    <span class='gb-cta'>Enter</span>
  </div>
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
      <span id='pbarText'>Unlock the best seeds</span>
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

  <div id='setupNote' class='setupnote setupvid' onclick='watchSetup()'>
    <span class='ytlogo'></span>
    <span>Watch the <b>setup guide</b> video</span>
    <span class='svarrow'>&rarr;</span>
  </div>

  <div id='flashBar' class='flashbar'>
    <span class='fbinfo'>
      <span class='fblabel'>Limited time deal</span>
      <span class='fbmain'>Get Pro for just <b class='fbprice' id='flashUsd'>$1.50</b></span>
    </span>
    <span class='fbtime' id='flashTime'>24:00:00</span>
    <button class='fbbtn' onclick='barFlash()'>Claim</button>
  </div>

  <div id='footer' class='footer'>
    <button id='startBtn' class='btn primary' onclick='send("start")'>Start <span class='hk'>F1</span></button>
    <button id='stopBtn'  class='btn'         onclick='send("stop")'>Stop <span class='hk'>F2</span></button>
    <div class='verwrap'>
      <button class='reportbtn' onclick='openBug()'>Report a bug</button>
      <span class='ver'>v__VERSION__</span>
      <span class='give' title='Enter this code at gardenmacro.com/giveaway for +2 giveaway entries'>Giveaway code: <b id='giveCode'>__GIVEAWAY__</b></span>
    </div>
  </div>

  <div id='overlay' class='overlay' hidden>
    <div class='modal'>
      <div class='mh'>
        <span class='mlock'>&#128274;</span>
        <h2 id='modalTitle'>Unlock the best seeds</h2>
        <button class='mx' onclick='closeAccess()'>&times;</button>
      </div>
      <p class='mdesc' id='modalDesc'>Premium seeds and the Gears macro need Garden Macro Pro. Subscribe once, then paste your code to unlock them here.</p>
      <ol class='msteps' id='modalSteps'>
        <li>Open the sign-in page and subscribe with Google.</li>
        <li>Copy the access code it shows you.</li>
        <li>Paste it below and click Unlock.</li>
      </ol>
      <button id='openSigninBtn' class='btn green block' style='font-size:16px;font-weight:800' onclick='send("openaccess")'>Get access</button>
      <div class='prow'>
        <input id='codeInput' type='text' placeholder='Paste your access code' spellcheck='false' autocomplete='off'>
        <button class='btn' onclick='pasteCode()'>Paste</button>
        <button class='btn green' onclick='activate()'>Unlock</button>
      </div>
      <div id='licenseMsg' class='lmsg'></div>
    </div>
  </div>

  <div id='flashOverlay' class='overlay' hidden>
    <div class='modal flashmodal'>
      <button class='mx' onclick='dismissFlash()'>&times;</button>
      <div class='flasheyebrow'>Limited time deal</div>
      <p class='flashlead'>Get Pro for just</p>
      <div class='flashbig' id='flashPopUsd'>$1.50</div>
      <p class='flashsub'>first month</p>
      <div class='flashtimer'><span id='flashPopTime'>24:00:00</span></div>
      <button class='btn red block' onclick='ctaFlash()'>Claim</button>
      <a class='hintDismiss' onclick='dismissFlash()'>Maybe later</a>
    </div>
  </div>

  <div id='bugOverlay' class='overlay' hidden>
    <div class='modal bugmodal'>
      <div class='mh'>
        <h2>Report a bug</h2>
        <button class='mx' onclick='closeBug()'>&times;</button>
      </div>
      <p class='bugintro'>Please describe the bug in <b>as much detail as you can</b>. The more detail you give, the faster I can find and fix it. I may reach out by email if anything is unclear, and <b>I reply very, very fast</b>.</p>

      <div class='bugfield'>
        <label class='buglabel' for='bugDetail'>What went wrong? <span class='req'>*</span></label>
        <textarea id='bugDetail' placeholder='What were you doing, what happened, and what did you expect instead? Steps to reproduce it help a lot.' spellcheck='true' oninput='updateBugCount()'></textarea>
        <span id='bugCount' class='bugcount'>100 more characters needed</span>
      </div>

      <div class='bugfield'>
        <label class='buglabel' for='bugContact'>Contact <span class='opt'>(optional)</span></label>
        <div class='bugcontact'>
          <span class='cicons'>
            <svg width='14' height='14' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><rect x='2' y='4' width='20' height='16' rx='2'/><path d='m2 6 10 7 10-7'/></svg>
            <svg width='15' height='15' viewBox='0 0 24 24' fill='currentColor'><path d='M20.317 4.369a19.79 19.79 0 0 0-4.885-1.515.074.074 0 0 0-.079.037c-.211.375-.445.865-.608 1.25a18.27 18.27 0 0 0-5.487 0 12.64 12.64 0 0 0-.617-1.25.077.077 0 0 0-.079-.037A19.736 19.736 0 0 0 3.677 4.37a.07.07 0 0 0-.032.027C.533 9.046-.32 13.58.099 18.057a.082.082 0 0 0 .031.057 19.9 19.9 0 0 0 5.993 3.03.078.078 0 0 0 .084-.028c.462-.63.874-1.295 1.226-1.994a.076.076 0 0 0-.041-.106 13.1 13.1 0 0 1-1.872-.892.077.077 0 0 1-.008-.128c.126-.094.252-.192.372-.291a.074.074 0 0 1 .077-.01c3.928 1.793 8.18 1.793 12.062 0a.074.074 0 0 1 .078.009c.12.099.246.198.373.292a.077.077 0 0 1-.006.127 12.3 12.3 0 0 1-1.873.892.077.077 0 0 0-.041.107c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.028 19.84 19.84 0 0 0 6.002-3.03.077.077 0 0 0 .032-.055c.5-5.177-.838-9.674-3.549-13.66a.061.061 0 0 0-.031-.03zM8.02 15.331c-1.182 0-2.157-1.085-2.157-2.419 0-1.333.956-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.956 2.418-2.157 2.418zm7.975 0c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.946 2.418-2.157 2.418z'/></svg>
          </span>
          <input id='bugContact' type='text' placeholder='Email or Discord username' spellcheck='false' autocomplete='off'>
        </div>
      </div>

      <div id='bugMsg' class='bugmsg'></div>
      <button id='bugSend' class='btn green block' onclick='submitBug()' disabled>Add at least 100 characters first</button>
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
    if (PREMIUM >= SEEDS.length) return 'Unlock all seeds';
    return 'Unlock the ' + PREMIUM + ' best seed' + (PREMIUM === 1 ? '' : 's');
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
  /* The access box is shared. Called plain for the normal "subscribe first" flow (upsell
     hint, loyalty, locked Start), or openAccess(true) from a flash claim -- where the browser
     was ALREADY sent straight to checkout, so we drop the "open sign-in page" step and just
     tell them to finish in the browser and paste the code. The normal copy is snapshotted
     from the HTML once, so flash mode can restore it when the box is next opened normally. */
  var _accessCopy = null;
  function openAccess(flash){
    var titleEl = document.getElementById('modalTitle');
    var descEl  = document.getElementById('modalDesc');
    var stepsEl = document.getElementById('modalSteps');
    var signBtn = document.getElementById('openSigninBtn');
    if (!_accessCopy)
      _accessCopy = { title: titleEl.textContent, desc: descEl.textContent, steps: stepsEl.innerHTML };
    if (flash){
      titleEl.textContent = 'Finish unlocking Pro';
      descEl.textContent  = 'Checkout just opened in your browser. Finish it there, then copy the access code it gives you and paste it below.';
      stepsEl.innerHTML   = '<li>Finish checkout in the browser tab that opened.</li><li>Copy the access code it shows you.</li><li>Paste it below and click Unlock.</li>';
      signBtn.hidden = true;
    } else {
      titleEl.textContent = _accessCopy.title;
      descEl.textContent  = _accessCopy.desc;
      stepsEl.innerHTML   = _accessCopy.steps;
      signBtn.hidden = false;
    }
    document.getElementById('overlay').hidden = false;
    var inp = document.getElementById('codeInput');
    setTimeout(function(){ inp.focus(); }, 30);
  }
  function closeAccess(){ document.getElementById('overlay').hidden = true; }

  /* Bug report modal. Send stays disabled until the detail field reaches the 100-char
     minimum; submit -> AHK posts it to Discord and replies 'bugok' or 'bugfail|<msg>'. */
  var BUG_MIN = 100;
  function openBug(){
    document.getElementById('bugOverlay').hidden = false;
    setBugMsg('');
    updateBugCount();
    setTimeout(function(){ document.getElementById('bugDetail').focus(); }, 30);
  }
  function closeBug(){ document.getElementById('bugOverlay').hidden = true; }
  function setBugMsg(t, cls){
    var m = document.getElementById('bugMsg');
    m.textContent = t || '';
    m.className = 'bugmsg' + (cls ? ' ' + cls : '');
  }
  /* Live counter in the corner of the textarea + gate the Send button on the minimum.
     Phrased as a minimum still-to-reach ("N more needed"), not "N / 100" -- a fraction
     reads like an upper cap. The disabled button also spells out WHY it's greyed out. */
  function updateBugCount(){
    var n = document.getElementById('bugDetail').value.trim().length;
    var ok = n >= BUG_MIN;
    var c = document.getElementById('bugCount');
    c.textContent = ok ? (n + ' characters') : ((BUG_MIN - n) + ' more characters needed');
    c.className = 'bugcount' + (ok ? ' ok' : '');
    var btn = document.getElementById('bugSend');
    btn.disabled = !ok;
    btn.textContent = ok ? 'Send report' : ('Add at least ' + BUG_MIN + ' characters first');
  }
  function submitBug(){
    var detail = document.getElementById('bugDetail').value.trim();
    if (detail.length < BUG_MIN){
      setBugMsg('Please add more detail (at least ' + BUG_MIN + ' characters).', 'err');
      return;
    }
    /* Strip the message delimiter + newlines from the short contact field so it can't
       break the pipe-delimited bridge; the detail is sent as the unsplit remainder. */
    var contact = document.getElementById('bugContact').value.trim().replace(/[|\r\n]+/g, ' ');
    setBugMsg('Sending...', '');
    var btn = document.getElementById('bugSend');
    btn.disabled = true;
    btn.textContent = 'Sending...';
    send('bug|' + contact + '|' + detail);
  }

  /* Setup video row: open the walkthrough in the browser. The row stays put so
     it's always one tap away. */
  function watchSetup(){ send('opentutorial'); }

  /* Giveaway banner: open the giveaway page in the browser (whole bar + Enter button click). */
  function openGiveaway(){ send('opengiveaway'); }

  /* Flash deal: AHK sends "flash|<variant>|<usd>|<secondsLeft>|<popup 0|1>" shortly after
     launch, for 24h after install. <usd> is the first-month price shown (e.g. "$1.50").
     Show the red countdown banner (always) + optionally the modal popup, then tick the timer
     down locally and hide everything at zero. Clicking Claim goes STRAIGHT to Stripe checkout
     with the discount applied (or Google login first) -- no in-app unlock modal. */
  var flashVariant = 0, flashTimer = null, flashEnd = 0, flashPopupPending = false;
  function fmtDur(s){
    function p(n){ return (n < 10 ? '0' : '') + n; }
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
    return p(h) + ':' + p(m) + ':' + p(x);
  }
  /* Reveal the flash popup modal. Kept separate so a deferred popup (see showFlash) can be
     opened later, once the onboarding walls have cleared. */
  function openFlashPopup(){ flashPopupPending = false; document.getElementById('flashOverlay').hidden = false; }
  function showFlash(variant, usd, secs, popup){
    flashVariant = parseInt(variant, 10) || 0;
    secs = parseInt(secs, 10) || 0;
    if (secs <= 0) return;
    flashEnd = Date.now() + secs * 1000;
    document.getElementById('flashUsd').textContent = usd;
    document.getElementById('flashPopUsd').textContent = usd;   /* set now; the overlay may reveal later */
    document.getElementById('flashBar').classList.add('show');
    tickFlash();
    if (flashTimer) clearInterval(flashTimer);
    flashTimer = setInterval(tickFlash, 1000);
    if (popup === '1' || popup === 1){
      /* Never pop UNDER a first-launch onboarding wall (the "Welcome!" finale is still up
         when AHK fires this). Defer instead; exitWall shows it once the walls have cleared. */
      if (onboardingUp()) flashPopupPending = true;
      else openFlashPopup();
    }
    requestAnimationFrame(function(){ requestAnimationFrame(fitWindow); });
  }
  function tickFlash(){
    var left = Math.round((flashEnd - Date.now()) / 1000);
    if (left <= 0){ endFlash(); return; }
    var t = fmtDur(left);
    document.getElementById('flashTime').textContent = t;
    var pt = document.getElementById('flashPopTime'); if (pt) pt.textContent = t;
  }
  function endFlash(){
    if (flashTimer){ clearInterval(flashTimer); flashTimer = null; }
    var bar = document.getElementById('flashBar'); if (bar) bar.classList.remove('show');
    closeFlash();
    requestAnimationFrame(function(){ requestAnimationFrame(fitWindow); });
  }
  function closeFlash(){ var o = document.getElementById('flashOverlay'); if (o) o.hidden = true; }
  function dismissFlash(){ send('ev|flash_dismiss|' + flashVariant); closeFlash(); }
  /* Both CTAs (popup button + banner) = clicked through: log flash_cta, then pop the access
     box open so the paste-code field is already waiting when the user returns from Stripe with
     the code /api/success hands them, and finally redirect to checkout ('flashclaim' ->
     OpenFlashCheckout, which opens /api/checkout?offer=<variant> and minimizes the window).
     The box is SUPPRESSED for creator-code holders (PROMO set) -- their discount doesn't stack
     so they never see the flash anyway (see OfferActive), but guard it here too to be sure. */
  function ctaFlash(){ send('ev|flash_cta|' + flashVariant); closeFlash(); if (!PROMO) openAccess(true); send('flashclaim'); }
  function barFlash(){ send('ev|flash_cta|' + flashVariant); if (!PROMO) openAccess(true); send('flashclaim'); }

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
      /* Onboarding just fully cleared -> release a flash popup deferred during it (see showFlash). */
      if (flashPopupPending && !onboardingUp()) openFlashPopup();
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
  /* True while any onboarding surface (boot cover or a wall, including the welcome finale)
     is still on screen. Used to defer the flash popup so it never opens behind one. */
  function onboardingUp(){
    var ids = ['bootCover', 'sourceOverlay', 'promoOverlay', 'welcomeOverlay'];
    for (var i = 0; i < ids.length; i++){
      var el = document.getElementById(ids[i]);
      if (el && !el.hidden) return true;
    }
    return false;
  }

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
    /* The giveaway code in the footer becomes the creator code, so the audience enters
       gardenmacro.com/giveaway with the same code they know (still +2 entries). */
    var gc = document.getElementById('giveCode');
    if (gc && code) gc.textContent = code;
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
    else if (type === 'unlock') { unlockPremium(); endFlash(); }  /* Pro now -> drop the flash deal */
    else if (type === 'licensemsg') setLicenseMsg(rest);
    else if (type === 'pastecode') {            /* AHK read the clipboard -> fill the code field */
      var inp = document.getElementById('codeInput');
      if (inp){ inp.value = rest; inp.focus(); }
      setLicenseMsg('');
    }
    else if (type === 'access') openAccess();   /* tried to Start a Pro-locked tab */
    else if (type === 'flash') { var xp = rest.split('|'); showFlash(xp[0], xp[1], xp[2], xp[3]); }   /* 24h flash-deal countdown (variant|usd|secs|popup) */
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
    else if (type === 'bugok') {                        /* report delivered -> thank + auto-close */
      setBugMsg('Thanks! Your report was sent. I reply very fast.', 'ok');
      document.getElementById('bugDetail').value = '';
      document.getElementById('bugContact').value = '';
      updateBugCount();
      setTimeout(closeBug, 1500);
    }
    else if (type === 'bugfail') {                      /* delivery failed -> show why, keep it open */
      setBugMsg(rest || 'Could not send. Please try again.', 'err');
      updateBugCount();                                 /* re-enable Send if still over the minimum */
    }
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
