class SH_Watcher {
    static SHCNE_RENAMEITEM:=0x00000001
    static SHCNE_CREATE:=0x00000002
    static SHCNE_DELETE:=0x00000004
    static SHCNE_MKDIR:=0x00000008
    static SHCNE_RMDIR:=0x00000010
    static SHCNE_UPDATEDIR:=0x00001000
    static SHCNE_UPDATEITEM:=0x00002000
    static SHCNE_RENAMEFOLDER:=0x00020000
    ;static SHCNE_ATTRIBUTES:=0x00000800 (changing attributes seems to trigger SHCNE_UPDATEITEM instead)

    static WM_INC:=0x4c8

    ;`callback`: some_callback(event_name,psi1,psi2) {
    __New(callback) {
        this.callback:=callback
        this.watching_map:=Map()
        this.paused:=false
        this.WM_UNIQUE:=SH_Watcher.WM_INC
        ++SH_Watcher.WM_INC

        WM_WEDONTKNOW(wParam, lParam, msg, hwnd) {
            static map_SHCNE := Map(0x00000001,"SHCNE_RENAMEITEM",0x00000002,"SHCNE_CREATE",0x00000004,"SHCNE_DELETE",0x00000008,"SHCNE_MKDIR",0x00000010,"SHCNE_RMDIR",0x00001000,"SHCNE_UPDATEDIR",0x00002000,"SHCNE_UPDATEITEM",0x00020000,"SHCNE_RENAMEFOLDER")

            hNotifyLock:=DllCall("shell32\SHChangeNotification_Lock","Ptr",wParam,"Ptr",lParam,"Ptr*",&PIDLIST_ABSOLUTE:=0,"Int*",&lEvent:=0,"Ptr")

            psi1:=NumGet(PIDLIST_ABSOLUTE,0x0,"Ptr")
            psi2:=NumGet(PIDLIST_ABSOLUTE,A_PtrSize,"Ptr")

            psi1_str:=SH_Watcher._PIDLIST_to_string(psi1)
            psi2_str:=SH_Watcher._PIDLIST_to_string(psi2)

            event_name:=map_SHCNE[lEvent]

            this.callback.Call(event_name,psi1_str,psi2_str)

            DllCall("shell32\SHChangeNotification_Unlock","Ptr",hNotifyLock)
        }

        OnMessage(this.WM_UNIQUE,WM_WEDONTKNOW)
        this.WM_WEDONTKNOW := WM_WEDONTKNOW
    }

    ;param `whatToWatch` defaults to Everything..
    ;recuse:=1 seems to only emit `SHCNE_UPDATEITEM` on the containing folder when a file is created (so no `SHCNE_CREATE` when the subfolder is too deep ?)
    Add(Folder,whatToWatch:=0x0002301f,recurse:=0) {
        PIDLIST_ABSOLUTE:=SH_Watcher._string_to_PIDLIST(Folder)
        normalized_name:=SH_Watcher._PIDLIST_to_string(PIDLIST_ABSOLUTE)

        ;always Remove previous
        if (this.watching_map.Has(normalized_name)) {
            if (!this.paused) { ;in the paused state, nothing is actually registered
                DllCall("shell32\SHChangeNotifyDeregister","Uint",this.watching_map[normalized_name].ulID)
            }
            this.watching_map.Delete(normalized_name)
        }

        ;free PIDLIST_ABSOLUTE later since it can be reused in UnPause()
        obj:={whatToWatch:whatToWatch,recurse:recurse,PIDLIST_ABSOLUTE:PIDLIST_ABSOLUTE}
        if (this.paused) {
            this.watching_map[normalized_name]:=obj
            return
        }

        this.watching_map[normalized_name] := this._register(obj)
    }

    Remove(Folder) {
        normalized_name:=SH_Watcher._PIDLIST_to_string(SH_Watcher._string_to_PIDLIST(Folder))

        obj:=this.watching_map[normalized_name]
        DllCall("shell32\SHChangeNotifyDeregister","Uint",obj.ulID)
        DllCall("ole32\CoTaskMemFree","Ptr",obj.PIDLIST_ABSOLUTE)
        this.watching_map.Delete(normalized_name)
    }

    Pause() {
        this.paused:=true
        for normalized_name, obj in this.watching_map {
            DllCall("shell32\SHChangeNotifyDeregister","Uint",obj.ulID)
            ;do not .Delete(), keep everything in, for UnPause()
        }
    }

    UnPause() {
        for normalized_name, obj in this.watching_map {
            this._register(obj) ;`.ulID` gets added to `obj`
        }
        this.paused:=false
    }

    RemoveAll() {
        for normalized_name, obj in this.watching_map {
            DllCall("shell32\SHChangeNotifyDeregister","Uint",obj.ulID)
            DllCall("ole32\CoTaskMemFree","Ptr",obj.PIDLIST_ABSOLUTE)
            ;no need to .Delete() if we reset the Map()
        }
        this.watching_map.Clear()
    }

    __Delete() {
        this.RemoveAll()
        OnMessage(this.WM_UNIQUE,this.WM_WEDONTKNOW,0) ;Specify 0 to unregister the function previously identified by Function.
    }

    static _string_to_PIDLIST(Folder) {
        pszPath:=Buffer(StrPut(Folder,"UTF-16")) ;assume that a resolved path is always shorter
        StrPut(Folder,pszPath,"UTF-16")
        success:=DllCall("shell32\PathResolve","Ptr",pszPath,"Ptr",0,"Uint",0x0001) ;PRF_VERIFYEXISTS
        resolved_path:=StrGet(pszPath,"UTF-16")
        if (!success) {
            rest:=", path was: " Folder "`nresolved_path: " resolved_path
            switch A_LastError {
                case 2:throw "ERROR_FILE_NOT_FOUND" rest
                case 3:throw "ERROR_PATH_NOT_FOUND" rest
                default:throw "unknown error" rest
            }
        }
        DllCall("shell32\SHParseDisplayName","WStr",resolved_path,"Ptr",0,"Ptr*",&PIDLIST_ABSOLUTE:=0,"Uint",0,"Ptr",0)
        if (!PIDLIST_ABSOLUTE) {
            throw "path probably incorrect: " Folder
        }
        return PIDLIST_ABSOLUTE
    }
    static _PIDLIST_to_string(PIDLIST) {
        if (PIDLIST) {
            pszPath:=Buffer(260*2+2) ;MAX_PATH WCHAR + zero-terminator
            DllCall("shell32\SHGetPathFromIDListW","Ptr",PIDLIST,"Ptr",pszPath)
            return StrGet(pszPath,"UTF-16")
        } else {
            return 0
        }
    }

    ;returns `obj` with `.ulID` added to it
    _register(obj) {
        SHChangeNotifyEntry:=Buffer(A_PtrSize+0x4)

        NumPut("Ptr",obj.PIDLIST_ABSOLUTE,SHChangeNotifyEntry,0x0) ;pidl
        NumPut("Int",obj.recurse,SHChangeNotifyEntry,A_PtrSize) ;fRecursive

        ulID:=DllCall("shell32\SHChangeNotifyRegister","Ptr",A_ScriptHwnd,"Int",0x8003,"Int",obj.whatToWatch,"Uint",this.WM_UNIQUE,"Int",1,"Ptr",SHChangeNotifyEntry,"Uint")
        obj.ulID:=ulID

        return obj
    }
}