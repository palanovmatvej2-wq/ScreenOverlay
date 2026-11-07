#NoEnv
SetWorkingDir %A_ScriptDir%
#SingleInstance Force
DetectHiddenWindows, On
CoordMode, Mouse, Screen

; Реестр активных окон
global Windows := {}
global PicToGui := {}
global ActiveMenuHwnd := 0
global AllHidden := 0

; --- ХОТКЕИ ---
; Ctrl + Alt + S: Сделать новый скриншот
^!s::
    Clipboard := ""
    Send, #+s

    ; Ожидание снимка в буфере (до 30 сек)
    startTick := A_TickCount
    hasBitmap := false
    Loop {
        if DllCall("IsClipboardFormatAvailable", "Uint", 2) { ; CF_BITMAP = 2
            hasBitmap := true
            break
        }
        if (A_TickCount - startTick > 30000)
            break
        Sleep, 100
    }

    if (!hasBitmap)
        return

    ; Повторные попытки открыть буфер
    opened := false
    Loop, 10 {
        if DllCall("OpenClipboard", "Ptr", 0) {
            opened := true
            break
        }
        Sleep, 50
    }
    if (!opened)
        return

    ; Создаем независимую мастер-копию битмапа
    hClipboardBitmap := DllCall("GetClipboardData", "Uint", 2, "Ptr")
    hMasterBitmap := 0
    if (hClipboardBitmap)
        hMasterBitmap := DllCall("CopyImage", "Ptr", hClipboardBitmap, "Uint", 0, "Int", 0, "Int", 0, "Uint", 0x2000, "Ptr")
    DllCall("CloseClipboard")

    if (!hMasterBitmap)
        return

    ; Корректный размер структуры BITMAP (32 байта для x64 Windows 11, 24 байта для x86)
    bmSize := (A_PtrSize = 8) ? 32 : 24
    VarSetCapacity(bm, bmSize, 0)
    if !DllCall("GetObject", "Ptr", hMasterBitmap, "Int", bmSize, "Ptr", &bm) {
        DllCall("DeleteObject", "Ptr", hMasterBitmap)
        return
    }

    origW := NumGet(bm, 4, "Int")
    origH := NumGet(bm, 8, "Int")

    if (origW <= 0 || origH <= 0) {
        DllCall("DeleteObject", "Ptr", hMasterBitmap)
        return
    }

    ; Создаем НОВОЕ окно GUI
    Gui, New, +AlwaysOnTop -Caption +ToolWindow +Border +HwndhGui
    Gui, Margin, 0, 0

    ; Создаем элемент Pic с дескриптором hPic
    hInitBitmap := DllCall("CopyImage", "Ptr", hMasterBitmap, "Uint", 0, "Int", origW, "Int", origH, "Uint", 0x2000, "Ptr")
    Gui, Add, Pic, x0 y0 w%origW% h%origH% +0xE +HwndhPic, % "HBITMAP:*" . hInitBitmap

    ; Позиционируем окно по центру
    Gui, Show, xCenter yCenter w%origW% h%origH%, PinnedScreenshot

    ; Активируем стиль WS_EX_LAYERED (необходимо для мгновенной и стабильной работы клика насквозь)
    WinSet, Transparent, 255, ahk_id %hGui%

    ; Регистрируем окно в коллекции
    Windows[hGui] := { hPic: hPic, hBitmap: hMasterBitmap, isClickThrough: 0, isHidden: 0, hasBorder: 1, transVal: 255 }
    PicToGui[hPic] := hGui

    ; Регистрируем обработчики перемещения и ПКМ
    OnMessage(0x0201, "WM_LBUTTONDOWN") ; Перетаскивание
    OnMessage(0x0205, "WM_RBUTTONUP")   ; Меню ПКМ
return

; Функция переключения режима "Клик насквозь"
SetClickThrough(hGui, enable) {
    global Windows
    if (!Windows.HasKey(hGui))
        return
    winData := Windows[hGui]
    winData.isClickThrough := enable

    if (enable) {
        ; В Windows 10/11 для пропуска кликов ОБЯЗАТЕЛЕН стиль WS_EX_LAYERED + WS_EX_TRANSPARENT (0x20)
        trans := winData.transVal ? winData.transVal : 255
        WinSet, Transparent, %trans%, ahk_id %hGui%
        WinSet, ExStyle, +0x20, ahk_id %hGui%
        ToolTip, Режим "Клик насквозь" ВКЛЮЧЕН`nНажмите Alt + C чтобы отключить
        SetTimer, RemoveToolTip, -2500
    } else {
        WinSet, ExStyle, -0x20, ahk_id %hGui%
        ToolTip, Режим "Клик насквозь" ВЫКЛЮЧЕН
        SetTimer, RemoveToolTip, -1500
    }
}

; Определение окна под курсором по экранным координатам (работает даже когда включен клик насквозь!)
GetWindowUnderMouse() {
    global Windows
    CoordMode, Mouse, Screen
    MouseGetPos, mX, mY
    for hGui in Windows {
        WinGetPos, wx, wy, ww, wh, ahk_id %hGui%
        if (mX >= wx && mX <= wx + ww && mY >= wy && mY <= wy + wh)
            return hGui
    }
    return 0
}

; Быстрое переключение "Клика насквозь": Alt + C
!c::
    targetHwnd := GetWindowUnderMouse()
    if (!targetHwnd)
        WinGet, targetHwnd, ID, A
    ; Если курсор не над окном, ищем первое окно с включенным кликом насквозь
    if (!Windows.HasKey(targetHwnd)) {
        for hGui, winData in Windows {
            if (winData.isClickThrough) {
                targetHwnd := hGui
                break
            }
        }
    }
    if (Windows.HasKey(targetHwnd)) {
        newState := !Windows[targetHwnd].isClickThrough
        SetClickThrough(targetHwnd, newState)
    }
return

RemoveToolTip:
    ToolTip
return

; Закрытие конкретного окна
CloseGui(hGui) {
    global Windows, PicToGui
    if (!Windows.HasKey(hGui))
        return
    winData := Windows[hGui]
    if (winData.hBitmap)
        DllCall("DeleteObject", "Ptr", winData.hBitmap)
    PicToGui.Delete(winData.hPic)
    Windows.Delete(hGui)
    Gui, %hGui%:Destroy
    ToolTip
}

; Закрыть ВСЕ открытые скриншоты: Ctrl + Alt + Q
^!q::
CloseAllWindows:
    hwnds := []
    for hGui in Windows
        hwnds.Push(hGui)
    for _, hGui in hwnds
        CloseGui(hGui)
    ToolTip
return

; Быстрое закрытие окна под курсором или активного окна: Alt + Q
!q::
    targetHwnd := GetWindowUnderMouse()
    if (!targetHwnd)
        WinGet, targetHwnd, ID, A
    if (Windows.HasKey(targetHwnd))
        CloseGui(targetHwnd)
return

; Закрытие по Escape или Ctrl + W
#IfWinActive PinnedScreenshot
Escape::
^w::
    WinGet, activeHwnd, ID, A
    if (Windows.HasKey(activeHwnd))
        CloseGui(activeHwnd)
return
#If

; Скрыть/показать ВСЕ окна скриншотов одновременно: Alt + V (или Alt + D)
!v::
!d::
ToggleAllWindows:
    AllHidden := !AllHidden
    for hGui, winData in Windows {
        if (AllHidden) {
            Gui, %hGui%:Hide
            winData.isHidden := 1
        } else {
            Gui, %hGui%:Show, NA
            winData.isHidden := 0
        }
    }
return

; Проверка попадания мыши в окно (только когда клик насквозь выключен)
IsInteractiveGuiUnderMouse() {
    global Windows
    h := GetWindowUnderMouse()
    if (h && Windows.HasKey(h) && !Windows[h].isClickThrough)
        return h
    return 0
}

; Обработка мыши над интерактивным окном скриншота
#If IsInteractiveGuiUnderMouse()
; Масштабирование колесиком мыши окна под курсором
WheelUp::
WheelDown::
    targetHwnd := IsInteractiveGuiUnderMouse()
    if (!targetHwnd || !Windows.HasKey(targetHwnd))
        return

    winData := Windows[targetHwnd]
    WinGetPos, curX, curY, curW, curH, ahk_id %targetHwnd%
    scale := (A_ThisHotkey = "WheelUp") ? 1.15 : 0.85
    newW := Round(curW * scale)
    newH := Round(curH * scale)

    if (newW < 40 || newW > A_ScreenWidth * 4 || newH < 40)
        return

    newX := curX - (newW - curW) // 2
    newY := curY - (newH - curH) // 2

    WinMove, ahk_id %targetHwnd%,, %newX%, %newY%, %newW%, %newH%

    ; Качественный ресемплинг через CopyImage
    hScaled := DllCall("CopyImage", "Ptr", winData.hBitmap, "Uint", 0, "Int", newW, "Int", newH, "Uint", 0x2000, "Ptr")
    if (hScaled) {
        hOld := DllCall("SendMessage", "Ptr", winData.hPic, "UInt", 0x172, "Ptr", 0, "Ptr", hScaled, "Ptr") ; STM_SETIMAGE
        if (hOld)
            DllCall("DeleteObject", "Ptr", hOld)
        GuiControl, %targetHwnd%:MoveDraw, % winData.hPic, x0 y0 w%newW% h%newH%
    }
return

; Клик колесиком мыши (СКМ) закрывает окно под курсором
MButton::
    targetHwnd := IsInteractiveGuiUnderMouse()
    if (targetHwnd)
        CloseGui(targetHwnd)
return
#If

; Прямой перехват ПКМ для открытия меню
WM_RBUTTONUP(wParam, lParam, msg, hwnd) {
    global Windows, PicToGui, ActiveMenuHwnd
    targetHwnd := 0
    if (Windows.HasKey(hwnd))
        targetHwnd := hwnd
    else if (PicToGui.HasKey(hwnd))
        targetHwnd := PicToGui[hwnd]

    if (targetHwnd && Windows.HasKey(targetHwnd)) {
        if (Windows[targetHwnd].isClickThrough)
            return
        ActiveMenuHwnd := targetHwnd
        GoSub, ShowContextMenu
        return 0
    }
}

; Контекстное меню для выбранного окна
ShowContextMenu:
    if (!ActiveMenuHwnd || !Windows.HasKey(ActiveMenuHwnd))
        return

    winData := Windows[ActiveMenuHwnd]
    Menu, MyMenu, Add
    Menu, MyMenu, DeleteAll
    Menu, MyMenu, Add, Прозрачность: 100`%, Menu_SetTrans_255
    Menu, MyMenu, Add, Прозрачность: 80`%, Menu_SetTrans_204
    Menu, MyMenu, Add, Прозрачность: 60`%, Menu_SetTrans_153
    Menu, MyMenu, Add, Прозрачность: 40`%, Menu_SetTrans_102
    Menu, MyMenu, Add
    clickItemText := winData.isClickThrough ? "Клик насквозь: [ВКЛ] (отключить)" : "Клик насквозь [Alt+C]"
    Menu, MyMenu, Add, %clickItemText%, Menu_ToggleClickThrough
    borderItemText := winData.hasBorder ? "Рамка краев: [ВКЛ]" : "Рамка краев: [ВЫКЛ]"
    Menu, MyMenu, Add, %borderItemText%, Menu_ToggleBorder
    Menu, MyMenu, Add
    Menu, MyMenu, Add, Скрыть ВСЕ окна (Alt + V), ToggleAllWindows
    Menu, MyMenu, Add, Закрыть ЭТО окно (СКМ / Alt+Q / Esc), Menu_CloseCurrent
    Menu, MyMenu, Add, Закрыть ВСЕ окна (Ctrl+Alt+Q), CloseAllWindows
    Menu, MyMenu, Show
return

Menu_SetTrans_255:
    SetWindowTrans(ActiveMenuHwnd, 255)
return
Menu_SetTrans_204:
    SetWindowTrans(ActiveMenuHwnd, 204)
return
Menu_SetTrans_153:
    SetWindowTrans(ActiveMenuHwnd, 153)
return
Menu_SetTrans_102:
    SetWindowTrans(ActiveMenuHwnd, 102)
return

SetWindowTrans(hGui, trans) {
    global Windows
    if (!Windows.HasKey(hGui))
        return
    Windows[hGui].transVal := trans
    WinSet, Transparent, %trans%, ahk_id %hGui%
}

Menu_ToggleBorder:
    if (!ActiveMenuHwnd || !Windows.HasKey(ActiveMenuHwnd))
        return
    winData := Windows[ActiveMenuHwnd]
    winData.hasBorder := !winData.hasBorder
    if (winData.hasBorder)
        WinSet, Style, +0x800000, ahk_id %ActiveMenuHwnd% ; WS_BORDER
    else
        WinSet, Style, -0x800000, ahk_id %ActiveMenuHwnd%
    WinSet, Redraw,, ahk_id %ActiveMenuHwnd%
return

Menu_ToggleClickThrough:
    if (ActiveMenuHwnd && Windows.HasKey(ActiveMenuHwnd))
        SetClickThrough(ActiveMenuHwnd, !Windows[ActiveMenuHwnd].isClickThrough)
return

Menu_CloseCurrent:
    if (ActiveMenuHwnd)
        CloseGui(ActiveMenuHwnd)
return

; Перетаскивание любого окна при зажатии ЛКМ
WM_LBUTTONDOWN(wParam, lParam, msg, hwnd) {
    global Windows, PicToGui
    targetHwnd := 0
    if (Windows.HasKey(hwnd))
        targetHwnd := hwnd
    else if (PicToGui.HasKey(hwnd))
        targetHwnd := PicToGui[hwnd]

    if (targetHwnd && Windows.HasKey(targetHwnd)) {
        if (!Windows[targetHwnd].isClickThrough)
            PostMessage, 0xA1, 2,,, ahk_id %targetHwnd% ; WM_NCLBUTTONDOWN, HTCAPTION
    }
}