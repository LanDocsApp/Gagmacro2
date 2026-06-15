#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
;  GAG Seed Buyer - LAUNCHER  ("dumb client" / auto-updater)
;
;  This is the ONLY file your users ever download. It:
;    1. Checks the user's subscription (paste-code) against the backend
;    2. Downloads the latest macro code from your server / GitHub
;    3. Caches it locally (so it still works offline)
;    4. Runs it with AutoHotkey -- only for an active subscriber
;
;  To push an update to everyone: just change the macro file at
;  MacroUrl. Users get it automatically the next time they launch.
;
;  Compile this with Ahk2Exe -> SeedBuyer.exe for distribution.
; ============================================================

; ---------------- CONFIG (edit these) ----------------

; Where to fetch the latest macro from.
;  - For testing NOW: leave the placeholder and it runs the local
;    macro.ahk sitting next to this file.
;  - GitHub: use the RAW url, e.g.
;    https://raw.githubusercontent.com/USER/REPO/main/macro.ahk
;  - Later (with backend): your server endpoint that checks the
;    subscription and returns today's macro code.
MacroUrl := "https://raw.githubusercontent.com/LanDocsApp/Gagmacro2/main/macro.ahk"

; Per-user license token. Sent as "Authorization: Bearer <token>".
; Leave blank for now (public URL). The backend will fill this in later.
LicenseToken := ""

; Base URL of your deployed subscription backend (Cloudflare Pages).
; The launcher checks the user's paste-code here before running the macro.
BackendBase := "https://gagmacro.pages.dev"

; -----------------------------------------------------

AppName    := "GAG Seed Buyer"
CacheDir   := A_AppData "\GagSeedBuyer"
CacheFile  := CacheDir "\macro.ahk"
LocalFile  := A_ScriptDir "\macro.ahk"     ; used in testing mode / as last resort
VerifyUrl  := BackendBase "/api/desktop/verify"  ; desktop-token check endpoint
TokenFile  := A_ScriptDir "\token.txt"           ; saved paste-code, next to the launcher

Main()

Main() {
    global TokenFile, AppName

    ; ---- Subscription gate: the macro only runs for an active subscriber ----
    if FileExist(TokenFile) {
        token := ReadToken(TokenFile)
        if (token = "") {
            try FileDelete(TokenFile)            ; blank / garbage file -> start fresh
            ShowActivationGui()
            return
        }
        res := VerifyToken(token)                ; re-check every launch
        if (res.status = "active") {
            LaunchMacro()                        ; verified -> download + run the macro
        } else if (res.status = "inactive") {
            try FileDelete(TokenFile)            ; cancelled / expired / invalid -> revoke
            ShowActivationGui("Your saved access code is no longer active. Re-subscribe, then paste your new code below.")
        } else {
            ; Couldn't reach the backend at all (offline). Don't lock out a paying
            ; user who already activated -> trust the saved token for this launch.
            TrayTip "Offline: couldn't re-check your subscription.`nRunning with your saved access.", AppName
            LaunchMacro()
        }
        return
    }

    ; No saved code yet -> ask the user to get access and activate.
    ShowActivationGui()
}

; The original launcher behaviour: fetch the latest macro (or fall back to the
; cached / local copy) and start it. Only reached once the gate above passes.
LaunchMacro() {
    global MacroUrl, LicenseToken, AppName, CacheDir, CacheFile, LocalFile

    macroToRun := ""

    if IsPlaceholder(MacroUrl) {
        ; ---- Testing mode: no server set yet, just run the local macro ----
        if FileExist(LocalFile) {
            macroToRun := LocalFile
        } else {
            MsgBox "No MacroUrl is set and macro.ahk was not found next to the launcher.`n`n"
                 . "Either set MacroUrl in the launcher, or put macro.ahk in:`n" A_ScriptDir,
                   AppName, "Iconx"
            ExitApp
        }
    } else {
        ; ---- Normal mode: fetch the latest macro from the server ----
        TrayTip "Checking for updates...", AppName
        res := TryDownload(MacroUrl, LicenseToken)

        if (res.ok && IsLikelyAhk(res.code)) {
            EnsureDir(CacheDir)
            SaveText(CacheFile, res.code)        ; cache the fresh copy
            macroToRun := CacheFile
        } else if FileExist(CacheFile) {
            TrayTip "Update failed (" res.err ").`nRunning last saved version.", AppName
            macroToRun := CacheFile
        } else if FileExist(LocalFile) {
            TrayTip "Update failed (" res.err ").`nRunning local copy.", AppName
            macroToRun := LocalFile
        } else {
            MsgBox "Could not download the macro and no saved copy exists.`n`nError: " res.err,
                   AppName, "Iconx"
            ExitApp
        }
    }

    RunMacro(macroToRun)
    ExitApp
}

; ============================================================
;  Subscription gate
; ============================================================

; POST { "token": <code> } to the backend and classify the outcome:
;   "active"   -> HTTP 200 with active:true      -> let the macro run
;   "inactive" -> HTTP 200 active:false, or 401   -> revoke / reject the code
;   "error"    -> request never completed, or a non-conclusive status
;                 (no internet, timeout, 5xx). Callers decide: trust an
;                 already-saved token, but reject a brand-new paste.
VerifyToken(token) {
    global VerifyUrl
    body := '{"token":"' JsonEscape(Trim(token)) '"}'
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        ; resolve, connect, send, receive timeouts (ms)
        req.SetTimeouts(5000, 5000, 5000, 15000)
        req.Open("POST", VerifyUrl, false)
        req.SetRequestHeader("Content-Type", "application/json")
        req.Send(body)
        status := req.Status
        if (status = 200)
            return { status: ResponseIsActive(req.ResponseText) ? "active" : "inactive", err: "" }
        if (status = 401)
            return { status: "inactive", err: "HTTP 401" }
        return { status: "error", err: "HTTP " status }     ; transient / unknown -> inconclusive
    } catch as e {
        return { status: "error", err: e.Message }          ; no internet / DNS / timeout
    }
}

; True if the JSON body has  "active": true  (tolerant of whitespace and case).
ResponseIsActive(text) {
    return RegExMatch(text, 'i)"active"\s*:\s*true') > 0
}

; Minimal JSON-string escaping. The token is signed base64url (no specials), but
; escape defensively so a stray quote/backslash can't break the request body.
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
    try {
        return Trim(FileRead(path, "UTF-8"), " `t`r`n" Chr(0xFEFF))
    } catch {
        return ""
    }
}

; Save the paste-code with no BOM so the raw token round-trips cleanly.
SaveToken(path, text) {
    f := FileOpen(path, "w", "UTF-8-RAW")
    f.Write(text)
    f.Close()
}

; Activation window: get access in the browser, paste the code, activate.
ShowActivationGui(message := "") {
    global AppName

    steps := "1.  Click Get Access to sign in and subscribe in your browser.`n"
           . "2.  Copy the access code it gives you.`n"
           . "3.  Paste the code below and click Activate."

    g := Gui("+AlwaysOnTop", AppName " - Activate")
    g.SetFont("s10", "Segoe UI")

    g.Add("Text", "xm ym w400", "A subscription is required to run " AppName ".")
    g.Add("Text", "xm w400", steps)

    g.Add("Button", "xm w130 h30", "Get Access").OnEvent("Click", (*) => OpenAccessPage())

    g.Add("Text", "xm w400 y+14", "Access code:")
    pasteEdit := g.Add("Edit", "xm w400 r1")

    statusLbl := g.Add("Text", "xm w400 cRed", message)

    activateBtn := g.Add("Button", "xm w130 h30 Default", "Activate")
    activateBtn.OnEvent("Click", (*) => OnActivate(g, pasteEdit, activateBtn, statusLbl))

    g.OnEvent("Close", (*) => ExitApp())
    g.Show()
}

; Verify the pasted code. Save + launch ONLY on a confirmed active subscription;
; never persist a code we couldn't confirm (no offline trust during activation).
OnActivate(g, pasteEdit, activateBtn, statusLbl) {
    global TokenFile

    code := Trim(pasteEdit.Value)
    if (code = "") {
        statusLbl.Text := "Paste your access code first."
        return
    }

    activateBtn.Enabled := false
    statusLbl.Text := "Checking your code..."
    res := VerifyToken(code)
    activateBtn.Enabled := true

    if (res.status = "active") {
        SaveToken(TokenFile, code)               ; only a confirmed code is saved
        g.Destroy()
        LaunchMacro()
    } else if (res.status = "inactive") {
        statusLbl.Text := "That code isn't valid or has no active subscription. Nothing was saved."
    } else {
        statusLbl.Text := "Couldn't reach the server (" res.err "). Check your internet and try again."
    }
}

; Open the subscription site in the user's default browser.
OpenAccessPage() {
    global BackendBase
    try {
        Run(BackendBase)
    } catch {
        try Run("explorer.exe " BackendBase)
    }
}

; Run the macro file with the same AutoHotkey that runs this launcher.
RunMacro(macroFile) {
    global AppName
    ahk := A_AhkPath
    if (!ahk || !FileExist(ahk))
        ahk := "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

    if !FileExist(ahk) {
        MsgBox "AutoHotkey v2 was not found.`nInstall it from https://autohotkey.com", AppName, "Iconx"
        return
    }
    try {
        Run('"' ahk '" "' macroFile '"')
    } catch as e {
        MsgBox "Failed to start the macro:`n" e.Message, AppName, "Iconx"
    }
}

; HTTP GET the macro text. Returns {ok, err, code}.
TryDownload(url, token) {
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        ; resolve, connect, send, receive timeouts (ms)
        req.SetTimeouts(5000, 5000, 5000, 15000)
        req.Open("GET", url, false)
        req.SetRequestHeader("Cache-Control", "no-cache")
        if (token != "")
            req.SetRequestHeader("Authorization", "Bearer " token)
        req.Send()
        if (req.Status != 200)
            return { ok: false, err: "HTTP " req.Status, code: "" }
        return { ok: true, err: "", code: req.ResponseText }
    } catch as e {
        return { ok: false, err: e.Message, code: "" }
    }
}

; Cheap sanity check so we never run a 404 page / garbage as a script.
IsLikelyAhk(code) {
    return (code != "") && (InStr(code, "#Requires") || InStr(code, "::"))
}

IsPlaceholder(url) {
    return (url = "") || InStr(url, "USER/REPO")
}

EnsureDir(dir) {
    if !DirExist(dir)
        DirCreate(dir)
}

SaveText(path, text) {
    f := FileOpen(path, "w", "UTF-8")
    f.Write(text)
    f.Close()
}
