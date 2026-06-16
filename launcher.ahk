#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
;  Garden Macro - LAUNCHER  ("dumb client" / auto-updater)
;
;  This is the ONLY file your users ever download. It:
;    1. Downloads the latest macro code from your server / GitHub
;    2. Caches it locally (so it still works offline)
;    3. Runs it with AutoHotkey
;
;  The macro itself is FREE for everyone. The last few "premium" seeds are
;  locked inside the macro's own UI until the user unlocks them with a
;  subscription code (Get access -> sign in -> paste code). All of that
;  licensing now lives in the macro, so this launcher just keeps it updated.
;
;  To push an update to everyone: just change the macro file at MacroUrl.
;  Users get it automatically the next time they launch.
;
;  Compile this with Ahk2Exe -> GardenMacro.exe for distribution.
; ============================================================

; ---------------- CONFIG (edit these) ----------------

; Where to fetch the latest macro from.
;  - For testing NOW: leave the placeholder and it runs the local
;    macro.ahk sitting next to this file.
;  - GitHub: use the RAW url, e.g.
;    https://raw.githubusercontent.com/USER/REPO/main/macro.ahk
MacroUrl := "https://raw.githubusercontent.com/LanDocsApp/Gagmacro2/main/macro.ahk"

; Optional per-user token sent as "Authorization: Bearer <token>".
; Not needed for a public raw URL.
LicenseToken := ""

; -----------------------------------------------------

AppName    := "Garden Macro"
CacheDir   := A_AppData "\GardenMacro"
CacheFile  := CacheDir "\macro.ahk"
LocalFile  := A_ScriptDir "\macro.ahk"     ; used in testing mode / as last resort

LaunchMacro()

; Fetch the latest macro (or fall back to the cached / local copy) and start it.
; The macro is free; premium seeds are gated inside the macro itself.
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

    ; The macro #Includes lib\WebView2.ahk and loads lib\WebView2Loader.dll
    ; relative to its own folder, so make sure lib/ sits next to it.
    SplitPath(macroToRun, , &runDir)
    if !EnsureLib(runDir) {
        MsgBox "Couldn't get the app's components (the lib files).`n`n"
             . "Check your internet connection and try again.", AppName, "Iconx"
        ExitApp
    }

    RunMacro(macroToRun)
    ExitApp
}

; Make sure the macro's lib/ dependencies sit next to the macro that's about to
; run. WebView2.ahk pulls in ComVar.ahk + Promise.ahk and the WebView2 control
; loads WebView2Loader.dll, all resolved relative to the script's own folder.
;
; We ship a single .ahk (no compiled exe to embed files in), so the lib files
; are fetched from the same public GitHub repo as the macro and cached. They're
; stable, so only what's missing is downloaded.
;   - Dev/source: copy from the lib/ next to this launcher if it's there.
;   - Distribution: download each file from GitHub (the DLL as raw binary).
; Returns true once every lib file is present on disk.
EnsureLib(destDir) {
    global MacroUrl, AppName
    libDir   := destDir "\lib"
    txtFiles := ["WebView2.ahk", "ComVar.ahk", "Promise.ahk"]
    dllName  := "WebView2Loader.dll"

    if LibComplete(libDir, txtFiles, dllName)
        return true

    if !DirExist(libDir)
        DirCreate(libDir)

    ; Dev/source case: copy straight from the lib/ next to the launcher.
    srcDir := A_ScriptDir "\lib"
    if FileExist(srcDir "\" dllName) {
        for f in txtFiles
            try FileCopy(srcDir "\" f, libDir "\" f, true)   ; running macro may lock the DLL
        try FileCopy(srcDir "\" dllName, libDir "\" dllName, true)
        return LibComplete(libDir, txtFiles, dllName)
    }

    ; Distribution case: download the lib files from the macro's repo.
    libBase := RegExReplace(MacroUrl, "[^/]+$", "") "lib/"    ; ".../main/" + "lib/"
    TrayTip "Getting app components...", AppName
    for f in txtFiles {
        if FileExist(libDir "\" f)
            continue
        res := TryDownload(libBase f, "")
        if (res.ok && res.code != "")
            SaveText(libDir "\" f, res.code)
    }
    if !FileExist(libDir "\" dllName)
        DownloadBinary(libBase dllName, libDir "\" dllName)

    return LibComplete(libDir, txtFiles, dllName)
}

; True only if every lib file is present on disk.
LibComplete(libDir, txtFiles, dllName) {
    if !FileExist(libDir "\" dllName)
        return false
    for f in txtFiles
        if !FileExist(libDir "\" f)
            return false
    return true
}

; Download a binary file (e.g. the WebView2 loader DLL) to `path`. Uses
; ADODB.Stream to write the raw response bytes. Returns true on success.
DownloadBinary(url, path) {
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(5000, 5000, 5000, 30000)
        req.Open("GET", url, false)
        req.SetRequestHeader("Cache-Control", "no-cache")
        req.Send()
        if (req.Status != 200)
            return false
        stream := ComObject("ADODB.Stream")
        stream.Type := 1                 ; adTypeBinary
        stream.Open()
        stream.Write(req.ResponseBody)   ; raw bytes
        stream.SaveToFile(path, 2)       ; adSaveCreateOverWrite
        stream.Close()
        return true
    } catch {
        return false
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
