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

    if LibComplete(libDir, txtFiles, dllName)
        return true

    if !DirExist(libDir)
        DirCreate(libDir)

    srcDir := A_ScriptDir "\lib"
    if FileExist(srcDir "\" dllName) {
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
    if !FileExist(libDir "\" dllName)
        return false
    for f in txtFiles
        if !FileExist(libDir "\" f)
            return false
    return true
}

DownloadBinary(url, path) {
    try {
        Download(url, path)
        if (FileExist(path) && FileGetSize(path) > 10000)
            return true
    }
    try FileDelete(path)
    return false
}

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
