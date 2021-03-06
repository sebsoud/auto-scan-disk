;Purpose - Query optical drive(s) directly via SCSI or SCSI-emulation (ATAPI,USB,Firewire) to find out if their tray/door is open or closed instead of the standard methods which really query whether or not media is loaded (all of the microsoft API calls do)
;TODO - parse returned sense info from 0xBD before assuming data is OK
;TODO - support for non-drive-letter optical drives
;TODO - support for changers (both one LUN and multi-lun ones)

;-----------------------------------------------------
; Setup Globals Environment
;-----------------------------------------------------

#include <APIFilesConstants.au3>
#include <FileConstants.au3>
#include <WinAPIConstants.au3>

Global Const $SCSI_IOCTL_DATA_IN = 0x01
Global Const $SCSI_IOCTL_DATA_OUT = 0x00
Global Const $SCSI_IOCTL_DATA_UNSPECIFIED = 0x02
Global Const $SPTCDBSIZE = 0x10 ; always sixteen, IOCTL_SCSI_PASS_THROUGH requires this - windows checks to make sure the size of $spt = 44.
Global Const $REALCDBSIZE = 0x0c ; twelve - more compatible than sixteen for ATAPI drives
Global Const $SENSEBUFFERSIZE = 0xF0 ;240 is max (was 32, then 255, which was stupid for byte alignment reasons)
Global Const $DATABUFFERSIZE = 0x0400 ;1024 should handle most calls, except IO, firmware and large changers.  Increase? (was 512)

;Global Const $FSCTL_LOCK_VOLUME = 0x00090018
;Global Const $FSCTL_UNLOCK_VOLUME = 0x00090022
;Global Const $IOCTL_STORAGE_EJECT_MEDIA = 0x002D0808

Global $cdb
Global $spt
Global $sptwb


;-----------------------------------------------------
; Main Routine
;-----------------------------------------------------

Func InitForTrayFunctions()

;Call routine to create structures to use with DLLs
CreateDLLStructures()
;Call routine to set up the CDB of this SCSI transaction's SRB, in this case 0xBD - Mechanism Status
PopulateCDB()
;Call routine to set up the SCSI_PASS_THROUGH_WITH_BUFFERS stucture - this is general purpose, though the sizes of globals might need to be adjusted for certain SRBs
PopulateSPTWB()

;Call routine to iterate through all of the Optical drives in the system and report on the tray status (now calls PopulateSPTWB again after each run)
;ShowTrayInfoForAllOpticals()
EndFunc



;-----------------------------------------------------
; Top-level Function Definitions
;-----------------------------------------------------


Func CreateDLLStructures()
    $CDB_STRUCT = ("ubyte[" & String($SPTCDBSIZE) & "]")
; doc: see	https://docs.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddscsi/ns-ntddscsi-_scsi_pass_through
; WARNING: 9th, ubyte is here only for byte alignment!
    $SCSI_PASS_THROUGH = "ushort;ubyte;ubyte;ubyte;ubyte;ubyte;ubyte;ubyte;ubyte[3];uint;uint;uint;uint;ubyte[" & String($SPTCDBSIZE) & "]"
    $SCSI_PASS_THROUGH_WITH_BUFFERS = $SCSI_PASS_THROUGH & ";ubyte[" & String($SENSEBUFFERSIZE) & "];ubyte[" & String($DATABUFFERSIZE) & "]"

    $cdb = DllStructCreate($CDB_STRUCT)
    $spt = DllStructCreate($SCSI_PASS_THROUGH);used only for length calculations
    $sptwb = DllStructCreate($SCSI_PASS_THROUGH_WITH_BUFFERS)
EndFunc   ;==>CreateDLLStructures

Func PopulateCDB()
    $CDBCOMMAND = 0xBD ;Mechanism Status in hex

    DllStructSetData($cdb, 1, $CDBCOMMAND, 1)
    DllStructSetData($cdb, 1, 0x00, 2)
    DllStructSetData($cdb, 1, 0x00, 3)
    DllStructSetData($cdb, 1, 0x00, 4)
    DllStructSetData($cdb, 1, 0x00, 5)
    DllStructSetData($cdb, 1, 0x00, 6)
    DllStructSetData($cdb, 1, 0x00, 7)
    DllStructSetData($cdb, 1, 0x00, 8)
    DllStructSetData($cdb, 1, 0x00, 9)
    DllStructSetData($cdb, 1, 0x08, 10) ;Request that the device returns only 08 bytes, which is the defined size of the header  We could do more if we had a changer, which would want to give more info, but by setting 8 here, we tell the device not to send more than the header anyway.
    DllStructSetData($cdb, 1, 0x00, 11)
    DllStructSetData($cdb, 1, 0x00, 12)
    ;The next four are not used for ATAPI compatibility, but should be set to zero anyway.
    DllStructSetData($cdb, 1, 0x00, 13)
    DllStructSetData($cdb, 1, 0x00, 14)
    DllStructSetData($cdb, 1, 0x00, 15)
    DllStructSetData($cdb, 1, 0x00, 16)
EndFunc   ;==>PopulateCDB

Func PopulateSPTWB()
    $Len_spt = DllStructGetSize($spt)
    ;Are these necessary if the optical drive is at a drive letter and we pass the handle, right?
    ;docs seem to suggest that the port driver fills these in if we are using an enumerated device
    $Bus = 0x00
    $ID = 0x00
    $Lun = 0x00

	; seb comment: see https://docs.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddscsi/ns-ntddscsi-_scsi_pass_through
    DllStructSetData($sptwb, 1, $Len_spt);Length | Length of pre-filler to be set before making call
    DllStructSetData($sptwb, 2, 0x00); ScsiStatus | Checked on return from call
    DllStructSetData($sptwb, 3, $Bus); PathId | SCSI bus # - I believe the port driver fills this in
    DllStructSetData($sptwb, 4, $ID);  TargetId | SCSI ID # - I believe the port driver fills this in
    DllStructSetData($sptwb, 5, $Lun); Lun | SCSI Lun # -I believe the port driver fills this in
    DllStructSetData($sptwb, 6, $REALCDBSIZE); CdbLength | Length of CDB to be set before making call (12 for ATAPI compatibility)?
    DllStructSetData($sptwb, 7, $SENSEBUFFERSIZE); SenseInfoLength | Length of Sense buffer to be set before making call - or always 32?
    DllStructSetData($sptwb, 8, $SCSI_IOCTL_DATA_IN); DataIn | Flag for Data Transfer direction to be set before making call
    ;item #9 is simple a placehold for byte alignment, so ignore it
    DllStructSetData($sptwb, 10, $DATABUFFERSIZE); DataTransferLength | Length of Data buffer to be set before making call - or always 512
    DllStructSetData($sptwb, 11, 0x05); TimeOutValue | Timeout for call - to be set before making call
    DllStructSetData($sptwb, 12, $Len_spt + $SENSEBUFFERSIZE); DataBufferOffset | Offset from first byte to beginning of data buffer
    DllStructSetData($sptwb, 13, $Len_spt);	SenseInfoOffset | Offset from first byte to beginning of sense buffer
    For $i = 1 To $SPTCDBSIZE
        DllStructSetData($sptwb, 14, DllStructGetData($cdb, 1, $i), $i); | Cdb[16] 16 bytes of data representing the CDB
    Next
    DllStructSetData($sptwb, 15, 0x00, 1);Sense Buffer - leave alone before call
    DllStructSetData($sptwb, 16, 0x00, 1);Data Buffer - leave alone before call

EndFunc   ;==>PopulateSPTWB

; returns boolean. if sError<>"" an error occured
Func IsDriveTrayOpen($driveLetter, ByRef $sError)
	$sDriveToTest = $driveLetter & ":" ; must add the : character

	$bIsTrayOpen = False
	$sError = ""

	$hVolume = OpenVolume($sDriveToTest, $sError)
	If ($hVolume == $INVALID_HANDLE_VALUE Or $hVolume == 0) Then
		; $sError is managed by OpenVolume() function itself
	Else
		If IsTrayOpen($hVolume, $sDriveToTest, $sError) Then
			$bIsTrayOpen = True
		EndIf

		_CloseVolume($hVolume)
	EndIf

	PopulateCDB()
	PopulateSPTWB() ; to ensure a fresh SRB each time

	Return $bIsTrayOpen

EndFunc


;-----------------------------------------------------
; Lower-level Function Definitions
;-----------------------------------------------------


Func IsTrayOpen(ByRef $hVolume, $drive, $sError)
    $LONG_type = ("ptr")
    $returnvalue = DllStructCreate($LONG_type)

    ;!!! DeviceIOControl expects ptr;long;ptr;long;ptr;long;ptr;ptr !!!
    $ret = DllCall( _
            "kernel32.dll", "int", _
            "DeviceIoControl", _
            "hwnd", $hVolume, _
            "int", $IOCTL_SCSI_PASS_THROUGH, _
            "ptr", DllStructGetPtr($sptwb), _
            "int", DllStructGetSize($spt), _
            "ptr", DllStructGetPtr($sptwb), _
            "int", DllStructGetSize($sptwb), _
            "int*", $returnvalue, _
            "ptr", 0 _
            )

    If @error Then
        MsgBox(1, "EXITING...", "DeviceIoControl DLLCall failed with error level: " & String(@error) & "!")
        Exit (1)
    EndIf

    If $ret[0] = 0 Then
		$sError = "Error in DeviceIoControl call to IOCTL_SCSI_PASS_THROUGH:" & _GetLastErrorMessage()

;        _GetLastErrorMessage("Error in DeviceIoControl call to IOCTL_SCSI_PASS_THROUGH:")
        Exit (1)
    EndIf

    ;check the sense buffer first, otherwise the data buffer is undefined?
    ;guess I should learn how to do that.

    ;For $i = 1 To $SENSEBUFFERSIZE
    ;   $temp = DllStructGetData($sptwb, 15, $i)
    ;   If $temp = 0x00 Then
    ;   Else
    ;       MsgBox(1, "Sense Buffer Data Found", "Non zero value found at sense buffer byte [" & $i & "]:  [" & $temp & "]")
    ;   EndIf
    ;Next

    ;For $i = 1 To $DATABUFFERSIZE
    ;   $temp = DllStructGetData($sptwb, 16, $i)
    ;   If $temp = 0x00 Then
    ;   Else
    ;       MsgBox(1, "Data Buffer Data Found", "Non zero value found at data buffer byte [" & $i & "]:  [" & $temp & "]")
    ;   EndIf
    ;Next


    $second_byte = DllStructGetData($sptwb, 16, 2) ;should be the second byte
    ;now we need the bit here 00010000

    $traystatus = BitAND($second_byte, 0x10)
    If $traystatus = 0x10 Then
        Return (True)
        ;MsgBox(1, "Tray Status", "The Tray for drive " & $drive & " is open.")
    Else
        Return (False)
        ;MsgBox(1, "Tray Status", "The Tray for drive " & $drive & " is closed.")
    EndIf


EndFunc   ;==>IsTrayOpen

; if sError<>"" an error occured
Func OpenVolume($cDriveLetter, ByRef $sError)

    ;   From AUTOIT forums
    Local $hVolume, $uDriveType, $szVolumeName, $dwAccessFlags

	If StringLen($cDriveLetter) = 1 Then
        $cDriveLetter = $cDriveLetter & ":"
    ElseIf StringLen($cDriveLetter) = 2 Then
        ;do nothing
    ElseIf StringLen($cDriveLetter) = 3 Then
        $cDriveLetter = StringLeft($cDriveLetter, 2)
    Else
		$sError = "OpenVolume error: $cDriveLetter="  & $cDriveLetter & " invalid format"
        Return $INVALID_HANDLE_VALUE
    EndIf

    Local $szRootName = $cDriveLetter & "\"

    $uDriveType = DriveGetType($szRootName)
    Select
        Case $uDriveType == "Removable"
            $dwAccessFlags = BitOR($GENERIC_READ, $GENERIC_WRITE)
        Case $uDriveType == "CDROM"
            ;We need write access in order to send scsi commands.
            $dwAccessFlags = BitOR($GENERIC_READ, $GENERIC_WRITE)
            ;$dwAccessFlags = $GENERIC_READ
        Case Else
			$sError = "OpenVolume error. DriveGetType returned " & $uDriveType
            Return $INVALID_HANDLE_VALUE
    EndSelect

    $szVolumeName = "\\.\" & $cDriveLetter & ""
    ;$szVolumeName = "\\.\CdRom0"

    ;in addition to getting the handle, the following also verifies write access, which is required to use the scsi pass through
    $hVolume = DllCall( _
            "kernel32.dll", "hwnd", _
            "CreateFile", _
            "str", $szVolumeName, _
            "long", $dwAccessFlags, _
            "long", BitOR($FILE_SHARE_READ, $FILE_SHARE_WRITE), _
            "ptr", 0, _
            "long", $OPEN_EXISTING, _
            "long", 0, _
            "long", 0 _
            )

    If @error Then
		$sError = "OpenVolume error. DllCall call to CreateFile failed with @error=" & @error
        Return(0)
    EndIf

    Return $hVolume[0]
EndFunc   ;==>OpenVolume

Func _CloseVolume($hVolume)
    Local $rVal = DllCall("kernel32.dll", "hwnd", "CloseHandle", "hwnd", $hVolume)
    If @error Then Return SetError(-1, -1, 0)
    Return $rVal[0]
EndFunc   ;==>_CloseVolume

;===============================================
;    _GetLastErrorMessage($DisplayMsgBox="")
;    Format the last windows error as a string and return it
;    if $DisplayMsgBox <> "" Then it will display a message box w/ the error
;    Return        Window's error as a string
;===============================================
Func _GetLastErrorMessage($DisplayMsgBox = "")
    Local $ret, $s
    Local $p = DllStructCreate("char[4096]")
    Local Const $FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000

    If @error Then Return ""

    $ret = DllCall("Kernel32.dll", "int", "GetLastError")
    $LastError = $ret[0]
    $ret = DllCall("kernel32.dll", "int", "FormatMessage", _
            "int", $FORMAT_MESSAGE_FROM_SYSTEM, _
            "ptr", 0, _
            "int", $LastError, _
            "int", 0, _
            "ptr", DllStructGetPtr($p), _
            "int", 4096, _
            "ptr", 0)
    $s = DllStructGetData($p, 1)
    If $DisplayMsgBox <> "" Then MsgBox(0, "_GetLastErrorMessage", $DisplayMsgBox & @CRLF & String($LastError) & "-" & $s)
    Return $s
EndFunc   ;==>_GetLastErrorMessage