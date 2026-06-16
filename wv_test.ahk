#Requires AutoHotkey v2.0
#SingleInstance Force
#Include lib\WebView2.ahk

; ---- Self-verifying WebView2 smoke test ----------------------------------
; Opens a small window, renders HTML, round-trips a message JS<->AHK, then
; logs PASS/FAIL to wv_test.log and exits. Run it, then read the log.

LogFile := A_ScriptDir "\wv_test.log"
try FileDelete(LogFile)
Log(msg) => FileAppend(A_Now " " msg "`n", LogFile, "UTF-8")

dllPath := A_ScriptDir "\lib\WebView2Loader.dll"
dataDir := A_AppData "\GardenMacro\WebView2"
DirCreate dataDir

global controller := 0, wv := 0

try {
    g := Gui("+Resize", "WebView2 Smoke Test")
    g.OnEvent("Size", (gg, mm, w, h) => (controller ? controller.Fill() : 0))
    g.OnEvent("Close", (*) => ExitApp())
    g.Show("w560 h360")

    Log("creating webview... dll=" dllPath)
    controller := WebView2.create(g.Hwnd, , 0, dataDir, "", 0, dllPath)
    wv := controller.CoreWebView2
    Log("controller+core created OK")

    wv.add_WebMessageReceived(OnWebMessage)
    wv.add_NavigationCompleted(OnNavDone)

    html := "
    (
    <!DOCTYPE html>
    <html><head><meta charset='utf-8'><style>
      body{font-family:'Segoe UI',sans-serif;background:#14161c;color:#e8eaf0;
           display:flex;flex-direction:column;align-items:center;justify-content:center;
           height:100vh;margin:0}
      button{background:#3b82f6;color:#fff;border:0;padding:12px 22px;border-radius:10px;
             font-size:15px;cursor:pointer}
      button:hover{background:#2f6fd6}
      #out{margin-top:18px;opacity:.85}
    </style></head><body>
      <h2>WebView2 is alive</h2>
      <button onclick='ping()'>Ping AHK</button>
      <div id='out'>waiting...</div>
      <script>
        function ping(){ window.chrome.webview.postMessage('ping-from-js'); }
        window.chrome.webview.addEventListener('message', function(e){
          document.getElementById('out').textContent = 'AHK says: ' + e.data;
        });
        window.chrome.webview.postMessage('auto-ping-on-load');
      </script>
    </body></html>
    )"

    wv.NavigateToString(html)
    Log("NavigateToString called")
} catch as e {
    Log("FAIL exception: " e.Message "`n  " e.Extra)
    ExitApp 1
}

OnNavDone(sender, args) {
    Log("NavigationCompleted IsSuccess=" args.IsSuccess " err=" args.WebErrorStatus)
}

OnWebMessage(sender, args) {
    msg := args.TryGetWebMessageAsString()
    Log("PASS got web message: '" msg "'")
    wv.PostWebMessageAsString("hello-from-ahk (" msg ")")
    ; First round-trip proves the bridge; close shortly after.
    SetTimer(() => ExitApp(), -1500)
}
