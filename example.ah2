#Include %A_LineFile%\..\SH_Watcher.ah2

some_callback(event_name,psi1,psi2) {
    OutputDebug(event_name ", " psi1 ", " psi2 "`n")
}

watcher:=SH_Watcher(some_callback)
watcher.Add(A_LineFile "\..") ;watch the folder containing this script file

Persistent 1