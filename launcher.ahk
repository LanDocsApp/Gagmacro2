#Requires AutoHotkey v2.0
#SingleInstance Force

MacroUrl := "https://raw.git" "hubusercontent.com/LanD" "ocsApp/Gag" "macro2/main/macro.ahk"
LicenseToken := ""

AppName    := "Garden Macro"
CacheDir   := A_AppData "\GardenMacro"
CacheFile  := CacheDir "\macro.ahk"
LocalFile  := A_ScriptDir "\macro.ahk"

LaunchMacro()

LaunchMacro() {
    global MacroUrl, LicenseToken, AppName, CacheDir, CacheFile, LocalFile

    macroToRun := ""

    if IsPlaceholder(MacroUrl) {
        if FileExist(LocalFile) {
            macroToRun := LocalFile
        } else {
            MsgBox "No MacroUrl is set and macro.ahk was not found next to the launcher.`n`n"
                 . "Either set MacroUrl in the launcher, or put macro.ahk in:`n" A_ScriptDir,
                   AppName, "Iconx"
            ExitApp
        }
    } else {
        TrayTip "Checking for updates...", AppName
        res := TryDownload(MacroUrl, LicenseToken)

        if (res.ok && IsLikelyAhk(res.code)) {
            EnsureDir(CacheDir)
            SaveText(CacheFile, res.code)
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

    SplitPath(macroToRun, , &runDir)
    if !EnsureLib(runDir) {
        MsgBox "Couldn't get the app's components (the lib files).`n`n"
             . "Check your internet connection and try again.", AppName, "Iconx"
        ExitApp
    }

    RunMacro(macroToRun)
    ExitApp
}

EnsureLib(destDir) {
    global MacroUrl, AppName
    libDir   := destDir "\lib"
    txtFiles := ["WebView2.ahk", "ComVar.ahk", "Promise.ahk"]
    dllName  := "WebView2Loader.dll"

    for f in txtFiles {
        if (FileExist(libDir "\" f) && HasDoubleBom(libDir "\" f))
            try FileDelete(libDir "\" f)
    }
    ; A half-written DLL from an interrupted download passes FileExist and then
    ; dies inside the macro as "Failed to load DLL". Drop it so it re-downloads.
    if (FileExist(libDir "\" dllName) && !DllOk(libDir "\" dllName))
        try FileDelete(libDir "\" dllName)

    if LibComplete(libDir, txtFiles, dllName)
        return true

    if !DirExist(libDir)
        DirCreate(libDir)

    srcDir := A_ScriptDir "\lib"
    if DllOk(srcDir "\" dllName) {   ; a bad local copy falls through to the download below
        for f in txtFiles
            try FileCopy(srcDir "\" f, libDir "\" f, true)
        try FileCopy(srcDir "\" dllName, libDir "\" dllName, true)
        return LibComplete(libDir, txtFiles, dllName)
    }

    libBase := RegExReplace(MacroUrl, "[^/]+$", "") "lib/"
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

HasDoubleBom(path) {
    try {
        f := FileOpen(path, "r")
        if !f
            return false
        f.Pos := 0
        n := f.RawRead(buf := Buffer(6), 6)
        f.Close()
        if (n < 6)
            return false
        Loop 6 {
            expect := [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF][A_Index]
            if (NumGet(buf, A_Index - 1, "UChar") != expect)
                return false
        }
        return true
    } catch {
        return false
    }
}

LibComplete(libDir, txtFiles, dllName) {
    if !DllOk(libDir "\" dllName)
        return false
    for f in txtFiles
        if !FileExist(libDir "\" f)
            return false
    return true
}

; True only for a real 64-bit WebView2Loader.dll. Guards against the two files a
; failed download leaves behind that FileExist can't tell apart from the real
; thing: a truncated copy, and an HTML error page saved under the .dll name.
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

DownloadBinary(url, path) {
    try {
        Download(url, path)
        if DllOk(path)
            return true
    }
    try FileDelete(path)
    return false
}

RunMacro(macroFile) {
    global AppName
    ahk := PickInterpreter()

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

; Which AutoHotkey runs the macro. The macro's window is an Edge WebView2 control
; and WebView2Loader.dll is x64-only, so it MUST be AutoHotkey64.exe. This used to
; pass on A_AhkPath -- whichever interpreter opened the launcher -- so a user whose
; .ahk association points at the 32-bit build got the macro's window dying on AHK's
; raw "Failed to load DLL". Fall back to A_AhkPath only where nothing better exists
; (the macro's own preflight explains it from there).
PickInterpreter() {
    cands := []
    if (A_AhkPath != "") {
        SplitPath(A_AhkPath, , &dir)
        cands.Push(dir "\AutoHotkey64.exe", dir "\v2\AutoHotkey64.exe")
    }
    for root in [EnvGet("ProgramW6432"), A_ProgramFiles]
        if (root != "")
            cands.Push(root "\AutoHotkey\v2\AutoHotkey64.exe", root "\AutoHotkey\AutoHotkey64.exe")
    if A_Is64bitOS
        for c in cands
            if FileExist(c)
                return c
    return A_AhkPath
}

TryDownload(url, token) {
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
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
    if (SubStr(text, 1, 1) = Chr(0xFEFF))
        text := SubStr(text, 2)
    f := FileOpen(path, "w", "UTF-8")
    f.Write(text)
    f.Close()
}
