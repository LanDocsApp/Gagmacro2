#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
;  GAG Seed Buyer  -  Roblox seed-shop macro
;
;  Pick which seeds to buy in the window, set the quantity,
;  then press Start (or F1). The macro:
;    0. Focuses Roblox + small mouse nudge
;    1. Opens chat ("/"), types a message, presses Enter
;    2. Clicks the shop at (697, 103), presses "e"
;    3. Presses "\" for keyboard UI nav, snaps to position 1
;       (down 5x, hold Up 5s), then moves onto the first ticked seed.
;  Steps 0-3 (Setup) run ONCE. The shop UI then stays open and the
;  cursor stays put, so each restock only repeats the buy pass:
;    4. From the first ticked seed, walk DOWN buying each ticked seed
;       N times, then walk back UP to the first ticked seed.
;
;  Setup runs on Start; the buy pass then repeats every 5 minutes
;  (restock loop) until you press Stop.
;
;  Controls:

;    Start button / F1 -> run
;    Stop  button / F2 -> stop (releases held keys)
;    Close window / Esc -> quit the script
; ============================================================

; Send keys a little slower so the game reliably registers them.
SetKeyDelay 50, 50

global Running    := false          ; a single buy pass is currently executing
global LoopActive := false          ; the repeat loop is armed
global IntervalMs := 5 * 60 * 1000  ; how often to repeat: 5 minutes
global FirstSel   := 0              ; index of first ticked seed (locked at Start)
global LastSel    := 0              ; index of last ticked seed (locked at Start)
global PassQty    := 20             ; quantity per seed (locked at Start)

; --- Seed list in the SAME top-to-bottom order as the in-game shop ---
global Seeds := [
    {name: "Carrot",          rarity: "Common",    price: "1"},
    {name: "Strawberry",      rarity: "Common",    price: "10"},
    {name: "Blueberry",       rarity: "Common",    price: "25"},
    {name: "Tulip",           rarity: "Uncommon",  price: "40"},
    {name: "Tomato",          rarity: "Uncommon",  price: "200"},
    {name: "Apple",           rarity: "Uncommon",  price: "400"},
    {name: "Bamboo",          rarity: "Rare",      price: "700"},
    {name: "Corn",            rarity: "Rare",      price: "2,500"},
    {name: "Cactus",          rarity: "Rare",      price: "5,000"},
    {name: "Pineapple",       rarity: "Rare",      price: "10,000"},
    {name: "Mushroom",        rarity: "Epic",      price: "15,000"},
    {name: "Green Bean",      rarity: "Epic",      price: "20,000"},
    {name: "Banana",          rarity: "Epic",      price: "30,000"},
    {name: "Grape",           rarity: "Epic",      price: "50,000"},
    {name: "Coconut",         rarity: "Epic",      price: "140,000"},
    {name: "Mango",           rarity: "Epic",      price: "300,000"},
    {name: "Dragon Fruit",    rarity: "Legendary", price: "120,000"},
    {name: "Acorn",           rarity: "Legendary", price: "700,000"},
    {name: "Cherry",          rarity: "Legendary", price: "1,200,000"},
    {name: "Sunflower",       rarity: "Legendary", price: "5,000,000"},
    {name: "Venus Fly Trap",  rarity: "Mythic",    price: "7,000,000"},
    {name: "Pomegranate",     rarity: "Mythic",    price: "12,000,000"},
    {name: "Poison Apple",    rarity: "Mythic",    price: "25,000,000"},
    {name: "Moon Bloom",      rarity: "Super",     price: "65,000,000"},
    {name: "Dragon's Breath", rarity: "Super",     price: "90,000,000"}
]

global Checks := []          ; checkbox controls, same index as Seeds
global QtyEdit := ""         ; quantity input control
global StatusText := ""      ; status line control

BuildGui()

; ============================================================
;  GUI
; ============================================================
BuildGui() {
    global Seeds, Checks, QtyEdit, StatusText

    MyGui := Gui("+AlwaysOnTop", "GAG Seed Buyer")
    MyGui.SetFont("s9", "Segoe UI")
    MyGui.Add("Text", "xm ym", "Tick seeds, set a quantity, then Start. Buys now, then repeats every 5 minutes.")

    ; Two columns of checkboxes.
    rows   := Ceil(Seeds.Length / 2)
    startX := 10
    startY := 32
    colW   := 250
    rowH   := 24

    for i, s in Seeds {
        col := (i - 1) // rows
        row := Mod(i - 1, rows)
        x := startX + col * colW
        y := startY + row * rowH
        label := s.name "  (" s.rarity ", " s.price ")"
        Checks.Push(MyGui.Add("Checkbox", Format("x{} y{} w240", x, y), label))
    }

    bottomY := startY + rows * rowH + 12

    MyGui.Add("Text", Format("x{} y{} w160", startX, bottomY + 4), "Buy quantity per seed:")
    QtyEdit := MyGui.Add("Edit", Format("x{} y{} w70", startX + 160, bottomY))
    MyGui.Add("UpDown", "Range1-99999", 20)

    btnY := bottomY + 34
    selAll   := MyGui.Add("Button", Format("x{} y{} w90",  startX,       btnY), "Select All")
    clrAll   := MyGui.Add("Button", Format("x{} y{} w90",  startX + 100, btnY), "Clear All")
    startBtn := MyGui.Add("Button", Format("x{} y{} w120", startX + 250, btnY), "Start Loop (F1)")
    stopBtn  := MyGui.Add("Button", Format("x{} y{} w100", startX + 390, btnY), "Stop (F2)")

    StatusText := MyGui.Add("Text", Format("x{} y{} w480", startX, btnY + 36), "Idle.")

    note := MyGui.Add("Text", Format("x{} y{} w480", startX, btnY + 60),
        "NOTE: make sure you are facing the seed shop before you start.")
    note.SetFont("Bold cRed")

    selAll.OnEvent("Click",   (*) => SetAll(true))
    clrAll.OnEvent("Click",   (*) => SetAll(false))
    startBtn.OnEvent("Click", (*) => StartMacro())
    stopBtn.OnEvent("Click",  (*) => StopMacro())
    MyGui.OnEvent("Close",    (*) => ExitApp())

    MyGui.Show()
}

SetAll(val) {
    global Checks
    for c in Checks
        c.Value := val
}

SetStatus(txt) {
    global StatusText
    StatusText.Text := txt
}

GetQty() {
    global QtyEdit
    val := QtyEdit.Value
    if !IsNumber(val) || Integer(val) < 1
        return 1
    return Integer(val)
}

; ============================================================
;  Hotkeys
; ============================================================
F1:: StartMacro()
F2:: StopMacro()
Esc:: ExitApp

StartMacro() {
    global LoopActive, Running, IntervalMs, FirstSel, LastSel, PassQty, Checks

    if LoopActive               ; loop already armed -> ignore
        return

    ; Lock in the selection for this whole loop session.
    FirstSel := 0
    LastSel  := 0
    for i, c in Checks {
        if c.Value {
            if !FirstSel
                FirstSel := i
            LastSel := i
        }
    }
    if !FirstSel {
        SetStatus("Nothing selected.")
        MsgBox "No seeds selected. Tick at least one seed."
        return
    }
    PassQty := GetQty()

    LoopActive := true
    Running := true
    ; One-time setup: open the shop UI and land on the first selected seed.
    if !Setup() {
        Running := false
        LoopActive := false
        return
    }
    BuyPass()                   ; first buy pass (ends on the first selected seed)
    Running := false

    if LoopActive {             ; still armed -> schedule the repeats
        SetTimer(DoPass, IntervalMs)
        SetStatus("Done. Waiting for next restock...  (Stop / F2 to end)")
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
        SetStatus("Done. Waiting for next restock...  (Stop / F2 to end)")
}

StopMacro() {
    global Running, LoopActive
    LoopActive := false
    SetTimer(DoPass, 0)         ; cancel the 5-minute loop
    Running := false            ; interrupt any pass in progress
    ; Make sure no arrow key is left stuck down.
    Send "{Up up}"
    Send "{Down up}"
    SetStatus("Stopped.")
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
    SetStatus("Focusing Roblox...")
    if WinExist("ahk_exe RobloxPlayerBeta.exe") {
        WinActivate
        WinWaitActive("ahk_exe RobloxPlayerBeta.exe", , 3)
    } else {
        SetStatus("Roblox not found.")
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

    ; 1. Open chat with "/", type the message, then send it.
    Send "/"
    if !Wait(400)
        return false
    SendText "hi!"
    if !Wait(200)
        return false
    Send "{Enter}"
    if !Wait(500)
        return false

    ; 2. Nudge the mouse to the target, then click (absolute screen position).
    MouseMove 697 + 5, 103 + 5, 0
    MouseMove 697, 103, 0
    if !Wait(150)
        return false
    Click 697, 103
    if !Wait(300)
        return false

    Send "e"
    if !Wait(1500)
        return false

    ; 3. Press backslash to enter keyboard navigation of the UI.
    Send "\"
    if !Wait(300)
        return false

    ; 3b. Snap to the FIRST position: go down 5 times, then hold Up for
    ;     5 seconds to scroll all the way back to the top -> position 1.
    SetStatus("Resetting to position 1...")
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

    ; 3c. Move down from position 1 onto the FIRST selected seed.
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
    global Running, Seeds, Checks, FirstSel, LastSel, PassQty

    ; Keep Roblox focused (this does NOT move the UI cursor).
    if WinExist("ahk_exe RobloxPlayerBeta.exe")
        WinActivate

    ; Walk DOWN from the first to the last selected seed, buying ticked ones.
    i := FirstSel
    Loop {
        if !Running
            return
        if Checks[i].Value {
            SetStatus(Format("Buying {} x{}", Seeds[i].name, PassQty))
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

    Loop times {            ; confirm the purchase `times` times
        Send "{Enter}"
        if !Wait(300)
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
