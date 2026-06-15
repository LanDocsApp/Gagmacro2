#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
;  GAG Seed Buyer - LAUNCHER  ("dumb client" / auto-updater)
;
;  This is the ONLY file your users ever download. It:
;    1. Downloads the latest macro code from your server / GitHub
;    2. Caches it locally (so it still works offline)
;    3. Runs it with AutoHotkey
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

; -----------------------------------------------------

AppName    := "GAG Seed Buyer"
CacheDir   := A_AppData "\GagSeedBuyer"
CacheFile  := CacheDir "\macro.ahk"
LocalFile  := A_ScriptDir "\macro.ahk"     ; used in testing mode / as last resort

Main()

Main() {
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
