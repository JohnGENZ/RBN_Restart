<#
.SYNOPSIS
    Monitors SkimSrv.exe and Aggregator v6.5.exe, restarting both if either
    crashes, hangs, or opens a dialog box.

.DESCRIPTION
    This script runs in a continuous loop, checking both applications every
    30 seconds. If either application:
      - Has crashed (process not running)
      - Is hung (window not responding)
      - Has opened a dialog box (modal child window detected)
    Then BOTH applications are stopped and restarted together.

.NOTES
    Run as Administrator for reliable process control.
    Adjust $CheckIntervalSeconds and paths as needed.
#>

# ============================================================================
# CONFIGURATION
# ============================================================================

$SkimSrvPath       = "C:\Program Files (x86)\Afreet\SkimSrv\SkimSrv.exe"
$AggregatorPath    = "C:\CWAggregator\Aggregator v6.7.exe"
$CheckIntervalSeconds = 30
$RestartDelaySeconds  = 5
$LogFile           = "C:\Logs\SkimmerMonitor.log"

# Window class names to ignore during dialog detection.
# SkimSrv is a Delphi application; TMainForm and TApplication are its
# normal windows and must not be treated as error dialogs.
# Add any other harmless class names here.
$AllowedClassNames = @("TMainForm", "TApplication")

# If ANY window title (including child windows) contains one of these
# keywords (case-insensitive), a restart is triggered regardless of
# whether the window class is on the allowed list.
$AlertKeywords = @("error", "violation", "terminated", "unable", "exception", "fault", "failed")

# SkimSrv tray icon monitoring.
# The script captures the SkimSrv notification area icon and compares
# it pixel-by-pixel to a saved baseline image. If the icon changes
# (e.g. error overlay appears), both applications are restarted.
# The baseline is saved to a file and persists across restarts.
# Delete the baseline file to force a new baseline capture.
$StatusGraceSeconds   = 20
$BaselineImagePath    = "C:\Scripts\SkimSrv_baseline.png"

# Ensure log directory exists
$logDir = Split-Path -Parent $LogFile
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# ============================================================================
# WIN32 API SIGNATURES FOR HANG AND DIALOG DETECTION
# ============================================================================

$WindowHelperLoaded = $false

try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public class WindowHelper
{
    [DllImport("user32.dll")]
    public static extern bool IsHungAppWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, StringBuilder lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto, EntryPoint = "SendMessageTimeout")]
    public static extern IntPtr SendMessageTimeoutInt(
        IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public const uint WM_GETTEXT       = 0x000D;
    public const uint WM_GETTEXTLENGTH = 0x000E;
    public const uint SMTO_ABORTIFHUNG = 0x0002;

    public const uint GW_OWNER = 4;
    public const int GWL_STYLE = -16;
    public const int GWL_EXSTYLE = -20;
    public const long WS_EX_DLGMODALFRAME = 0x00000001L;
    public const long WS_POPUP = 0x80000000L;

    /// <summary>
    /// Get all visible top-level window handles belonging to a given process ID.
    /// </summary>
    public static List<IntPtr> GetProcessWindows(uint processId)
    {
        List<IntPtr> windows = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid == processId && IsWindowVisible(hWnd))
            {
                windows.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);
        return windows;
    }

    /// <summary>
    /// Check whether any window of the process is hung.
    /// </summary>
    public static bool IsProcessHung(uint processId)
    {
        List<IntPtr> windows = GetProcessWindows(processId);
        foreach (IntPtr hWnd in windows)
        {
            if (IsHungAppWindow(hWnd))
                return true;
        }
        return false;
    }

    /// <summary>
    /// Returns a string describing each visible window for a process.
    /// Format per window: "ClassName\tWindowTitle"
    /// Windows are separated by newlines.
    /// </summary>
    public static string GetWindowList(uint processId)
    {
        List<IntPtr> windows = GetProcessWindows(processId);
        List<string> entries = new List<string>();

        foreach (IntPtr hWnd in windows)
        {
            StringBuilder className = new StringBuilder(256);
            GetClassName(hWnd, className, 256);

            int len = GetWindowTextLength(hWnd);
            StringBuilder title = new StringBuilder(len + 1);
            if (len > 0)
                GetWindowText(hWnd, title, len + 1);

            entries.Add(className.ToString() + "\t" + title.ToString());
        }
        return String.Join("\n", entries.ToArray());
    }

    /// <summary>
    /// Check whether the process has any unexpected dialog-style windows,
    /// ignoring windows whose class names are in the allowed list.
    /// However, if any window title — including child window titles —
    /// contains an alert keyword (e.g. "error"), it is always flagged
    /// regardless of the allowed list.
    /// Returns empty string if healthy, or a description of the
    /// offending window(s) if a dialog is detected.
    /// </summary>
    public static string CheckForUnexpectedDialogs(uint processId, string[] allowedClassNames, string[] alertKeywords)
    {
        List<IntPtr> windows = GetProcessWindows(processId);
        List<string> problems = new List<string>();

        // Build a case-insensitive set of allowed class names
        HashSet<string> allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (allowedClassNames != null)
        {
            foreach (string name in allowedClassNames)
                allowed.Add(name);
        }

        // Normalise alert keywords to lower case
        List<string> alerts = new List<string>();
        if (alertKeywords != null)
        {
            foreach (string kw in alertKeywords)
                alerts.Add(kw.ToLower());
        }

        foreach (IntPtr hWnd in windows)
        {
            StringBuilder classNameBuf = new StringBuilder(256);
            GetClassName(hWnd, classNameBuf, 256);
            string className = classNameBuf.ToString();

            // Read the window title (needed for alert-keyword check)
            int titleLen = GetWindowTextLength(hWnd);
            StringBuilder titleBuf = new StringBuilder(titleLen + 1);
            if (titleLen > 0) GetWindowText(hWnd, titleBuf, titleLen + 1);
            string windowTitle = titleBuf.ToString();
            string windowTitleLower = windowTitle.ToLower();

            // Alert keyword check on the top-level window title
            bool hasAlertKeyword = false;
            foreach (string kw in alerts)
            {
                if (windowTitleLower.Contains(kw))
                {
                    hasAlertKeyword = true;
                    break;
                }
            }

            if (hasAlertKeyword)
            {
                problems.Add("[" + className + "] " + windowTitle);
                continue;
            }

            // Alert keyword check on CHILD window titles.
            // This catches error dialogs embedded inside allowed parent
            // windows (e.g. a Delphi TMainForm that spawns an error panel
            // or child dialog with "Error" in the title).
            string childAlertInfo = null;
            if (alerts.Count > 0)
            {
                EnumChildWindows(hWnd, delegate(IntPtr hChild, IntPtr lParam)
                {
                    int cLen = GetWindowTextLength(hChild);
                    if (cLen > 0)
                    {
                        StringBuilder cTitleBuf = new StringBuilder(cLen + 1);
                        GetWindowText(hChild, cTitleBuf, cLen + 1);
                        string cTitle = cTitleBuf.ToString();
                        string cTitleLower = cTitle.ToLower();

                        foreach (string kw in alerts)
                        {
                            if (cTitleLower.Contains(kw))
                            {
                                StringBuilder cClassBuf = new StringBuilder(256);
                                GetClassName(hChild, cClassBuf, 256);
                                childAlertInfo = "[child " + cClassBuf.ToString() + "] " + cTitle;
                                return false; // stop enumerating
                            }
                        }
                    }
                    return true;
                }, IntPtr.Zero);
            }

            if (childAlertInfo != null)
            {
                problems.Add("[" + className + "] " + windowTitle + " -> " + childAlertInfo);
                continue;
            }

            // Skip windows whose class is in the allowed list
            if (allowed.Contains(className))
                continue;

            // Check 1: Is this a standard Windows dialog (#32770)?
            if (className == "#32770")
            {
                problems.Add("[" + className + "] " + windowTitle);
                continue;
            }

            // Check 2: Is this a popup with modal dialog frame style?
            long style = GetWindowLong(hWnd, GWL_STYLE);
            long exStyle = GetWindowLong(hWnd, GWL_EXSTYLE);

            if ((style & WS_POPUP) != 0 && (exStyle & WS_EX_DLGMODALFRAME) != 0)
            {
                problems.Add("[" + className + "] " + windowTitle);
                continue;
            }

            // Check 3: Does this window have #32770 child dialogs?
            bool childDialogFound = false;
            EnumChildWindows(hWnd, delegate(IntPtr hChild, IntPtr lParam)
            {
                StringBuilder childClass = new StringBuilder(256);
                GetClassName(hChild, childClass, 256);
                if (childClass.ToString() == "#32770" && IsWindowVisible(hChild))
                {
                    childDialogFound = true;
                    return false;
                }
                return true;
            }, IntPtr.Zero);

            if (childDialogFound)
            {
                problems.Add("[" + className + " with child dialog] " + windowTitle);
            }
        }

        if (problems.Count > 0)
            return String.Join(" | ", problems.ToArray());
        else
            return "";
    }

    /// <summary>
    /// Read the text of a control in another process using SendMessage WM_GETTEXT.
    /// GetWindowText cannot read child control text across processes — it only
    /// reads the cached caption. SendMessage WM_GETTEXT actually asks the control
    /// for its current text. Uses SendMessageTimeout to avoid hanging if the
    /// target window is not responding.
    /// </summary>
    private static string GetControlText(IntPtr hWnd)
    {
        IntPtr result;

        // First ask how long the text is
        SendMessageTimeoutInt(hWnd, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero,
            SMTO_ABORTIFHUNG, 500, out result);
        int len = result.ToInt32();
        if (len <= 0) return "";

        // Now retrieve the text
        StringBuilder buf = new StringBuilder(len + 1);
        SendMessageTimeout(hWnd, WM_GETTEXT, (IntPtr)(len + 1), buf,
            SMTO_ABORTIFHUNG, 500, out result);
        return buf.ToString();
    }

    /// <summary>
    /// Returns all readable text from every child control of every visible
    /// top-level window belonging to a given process. Uses SendMessage
    /// WM_GETTEXT which works across process boundaries, unlike GetWindowText
    /// which only returns captions for cross-process child controls.
    /// </summary>
    public static List<string> GetAllChildControlTexts(uint processId)
    {
        List<IntPtr> windows = GetProcessWindows(processId);
        List<string> texts = new List<string>();

        foreach (IntPtr hWnd in windows)
        {
            // Include the top-level window title
            string topText = GetControlText(hWnd);
            if (topText.Length > 0)
                texts.Add(topText);

            // Enumerate ALL child controls and read their text
            EnumChildWindows(hWnd, delegate(IntPtr hChild, IntPtr lParam)
            {
                string cText = GetControlText(hChild);
                if (cText.Trim().Length > 0)
                    texts.Add(cText.Trim());
                return true;
            }, IntPtr.Zero);
        }
        return texts;
    }
}
"@ -Language CSharp -ErrorAction Stop

    $WindowHelperLoaded = $true
}
catch {
    # If the type is already loaded from a previous run in the same session, check for it
    try {
        [WindowHelper] | Out-Null
        $WindowHelperLoaded = $true
    }
    catch {
        Write-Host "WARNING: Failed to compile WindowHelper: $_"
        Write-Host "Hang and dialog detection will be disabled. Crash detection will still work."
    }
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp  $Message"
    Write-Host $entry
    Add-Content -Path $LogFile -Value $entry
}

function Get-ProcessByPath {
    param([string]$ExePath)
    # Match running processes by their full executable path
    $exeName = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    Get-Process -Name $exeName -ErrorAction SilentlyContinue |
        Where-Object {
            try { $_.Path -eq $ExePath } catch { $false }
        }
}

function Stop-Application {
    param([string]$ExePath, [string]$DisplayName)

    $procs = Get-ProcessByPath -ExePath $ExePath
    if ($procs) {
        Write-Log "Stopping $DisplayName (PID: $(($procs | ForEach-Object { $_.Id }) -join ', '))..."

        # Try graceful close first
        foreach ($proc in $procs) {
            try { $proc.CloseMainWindow() | Out-Null } catch {}
        }
        Start-Sleep -Seconds 3

        # Force kill any survivors
        $procs = Get-ProcessByPath -ExePath $ExePath
        foreach ($proc in $procs) {
            try {
                Write-Log "  Force-killing PID $($proc.Id)..."
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            } catch {
                Write-Log "  WARNING: Could not kill PID $($proc.Id): $_"
            }
        }
    } else {
        Write-Log "$DisplayName is not running."
    }
}

function Start-Application {
    param([string]$ExePath, [string]$DisplayName)

    $workingDir = Split-Path -Parent $ExePath
    Write-Log "Starting $DisplayName..."
    try {
        Start-Process -FilePath $ExePath -WorkingDirectory $workingDir
        Write-Log "  $DisplayName started successfully."
    } catch {
        Write-Log "  ERROR starting $DisplayName - $_"
    }
}

function Restart-BothApplications {
    param([string]$Reason)

    Write-Log "============================================"
    Write-Log "RESTART TRIGGERED: $Reason"
    Write-Log "============================================"

    # Stop both (order: aggregator first, then skimmer)
    Stop-Application -ExePath $AggregatorPath -DisplayName "Aggregator"
    Stop-Application -ExePath $SkimSrvPath    -DisplayName "SkimSrv"

    Write-Log "Waiting $RestartDelaySeconds seconds before restarting..."
    Start-Sleep -Seconds $RestartDelaySeconds

    # Start both (order: skimmer first, then aggregator)
    Start-Application -ExePath $SkimSrvPath    -DisplayName "SkimSrv"
    Start-Sleep -Seconds 2
    Start-Application -ExePath $AggregatorPath -DisplayName "Aggregator"

    Write-Log "Both applications restarted."
    Write-Log "============================================"
}

function Test-ApplicationHealth {
    param(
        [string]$ExePath,
        [string]$DisplayName
    )

    $procs = Get-ProcessByPath -ExePath $ExePath

    # --- Check 1: Is the process running at all? ---
    if (-not $procs) {
        return @{ Healthy = $false; Reason = "$DisplayName has crashed or is not running." }
    }

    # If WindowHelper is not available, skip hang and dialog checks
    if (-not $script:WindowHelperLoaded) {
        return @{ Healthy = $true; Reason = "" }
    }

    foreach ($proc in $procs) {
        $procId = [uint32]$proc.Id

        # --- Check 2: Is the process hung? ---
        try {
            if ([WindowHelper]::IsProcessHung($procId)) {
                return @{
                    Healthy = $false
                    Reason  = "$DisplayName (PID $procId) is hung / not responding."
                }
            }
        } catch {
            Write-Log "  Warning: Could not check hung state for $DisplayName (PID $procId): $_"
        }

        # --- Check 3: Has an unexpected dialog box appeared? ---
        # The allowed class names list is passed directly into C# so that
        # TMainForm, TApplication, and any other normal windows are filtered
        # out before the dialog check even reports a hit.
        try {
            $dialogResult = [WindowHelper]::CheckForUnexpectedDialogs($procId, $script:AllowedClassNames, $script:AlertKeywords)
            if ($dialogResult -ne "") {
                return @{
                    Healthy = $false
                    Reason  = "$DisplayName (PID $procId) has a dialog open: $dialogResult"
                }
            }
        } catch {
            Write-Log "  Warning: Could not check dialogs for $DisplayName (PID $procId): $_"
        }
    }

    return @{ Healthy = $true; Reason = "" }
}

# Tracks when SkimSrv tray icon issue first detected.
$script:StatusFailSince = $null

# Set to $true after first diagnostic so we only log it once.
$script:StatusDiagDone = $false

# Last logged tray icon diff message (suppress repeats).
$script:LastDiffMsg = ""

# Load screen capture helper for icon pixel analysis.
$script:IconCaptureLoaded = $false
try {
    Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class IconCapture
{
    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int nWidth, int nHeight);

    [DllImport("gdi32.dll")]
    public static extern IntPtr SelectObject(IntPtr hdc, IntPtr hObject);

    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr hObject);

    [DllImport("gdi32.dll")]
    public static extern bool DeleteDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    public static extern bool BitBlt(IntPtr hdcDest, int xDest, int yDest,
        int wDest, int hDest, IntPtr hdcSource, int xSrc, int ySrc, int rop);

    [DllImport("shell32.dll", SetLastError = true)]
    public static extern int Shell_NotifyIconGetRect(
        ref NOTIFYICONIDENTIFIER identifier, out RECT iconLocation);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public const int SRCCOPY = 0x00CC0020;

    [StructLayout(LayoutKind.Sequential)]
    public struct NOTIFYICONIDENTIFIER
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public Guid guidItem;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    // Baseline pixel data
    private static byte[] baselineData = null;
    private static int baselineW = 0;
    private static int baselineH = 0;

    /// <summary>
    /// Finds the screen rectangle of a process's notification area icon
    /// by trying Shell_NotifyIconGetRect with every window handle belonging
    /// to the process and uID values 0-10. Returns a RECT with the icon's
    /// screen coordinates, or an empty RECT (all zeros) if not found.
    /// Also returns diagnostic info via the out parameter.
    /// </summary>
    public static RECT FindTrayIconRect(uint processId, out string diagInfo)
    {
        RECT empty = new RECT();
        System.Text.StringBuilder diag = new System.Text.StringBuilder();
        System.Collections.Generic.List<IntPtr> allWindows = new System.Collections.Generic.List<IntPtr>();

        // Find ALL windows for this process (including hidden)
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid == processId)
                allWindows.Add(hWnd);
            return true;
        }, IntPtr.Zero);

        diag.AppendLine("Windows found for PID " + processId + ": " + allWindows.Count);

        // Try each window with uIDs 0-10
        foreach (IntPtr hWnd in allWindows)
        {
            for (uint uID = 0; uID <= 10; uID++)
            {
                NOTIFYICONIDENTIFIER nii = new NOTIFYICONIDENTIFIER();
                nii.cbSize = (uint)Marshal.SizeOf(typeof(NOTIFYICONIDENTIFIER));
                nii.hWnd = hWnd;
                nii.uID = uID;
                nii.guidItem = Guid.Empty;

                RECT rect;
                int hr = Shell_NotifyIconGetRect(ref nii, out rect);
                if (hr == 0) // S_OK
                {
                    int w = rect.Right - rect.Left;
                    int h = rect.Bottom - rect.Top;
                    diag.AppendLine("  Found icon: hWnd=0x" + hWnd.ToString("X") +
                        " uID=" + uID + " rect=(" + rect.Left + "," + rect.Top +
                        "," + rect.Right + "," + rect.Bottom + ") size=" + w + "x" + h);

                    if (w > 0 && h > 0 && w <= 64 && h <= 64)
                    {
                        diagInfo = diag.ToString();
                        return rect;
                    }
                }
            }
        }

        diagInfo = diag.ToString();
        return empty;
    }

    /// <summary>
    /// Captures a screen region and returns its pixel data as RGB bytes.
    /// </summary>
    private static byte[] CaptureRegion(int x, int y, int width, int height, string savePath)
    {
        if (width <= 0 || height <= 0) return null;

        IntPtr hdcScreen = GetDC(IntPtr.Zero);
        IntPtr hdcMem = CreateCompatibleDC(hdcScreen);
        IntPtr hBitmap = CreateCompatibleBitmap(hdcScreen, width, height);
        IntPtr hOld = SelectObject(hdcMem, hBitmap);

        bool ok = BitBlt(hdcMem, 0, 0, width, height, hdcScreen, x, y, SRCCOPY);
        SelectObject(hdcMem, hOld);

        if (!ok)
        {
            DeleteObject(hBitmap);
            DeleteDC(hdcMem);
            ReleaseDC(IntPtr.Zero, hdcScreen);
            return null;
        }

        Bitmap bmp = Bitmap.FromHbitmap(hBitmap);
        DeleteObject(hBitmap);
        DeleteDC(hdcMem);
        ReleaseDC(IntPtr.Zero, hdcScreen);

        if (savePath != null)
        {
            try { bmp.Save(savePath, ImageFormat.Png); } catch { }
        }

        byte[] pixels = new byte[width * height * 3];
        int idx = 0;
        for (int py = 0; py < height; py++)
        {
            for (int px = 0; px < width; px++)
            {
                Color c = bmp.GetPixel(px, py);
                pixels[idx++] = c.R;
                pixels[idx++] = c.G;
                pixels[idx++] = c.B;
            }
        }

        bmp.Dispose();
        return pixels;
    }

    public static bool SetBaseline(int x, int y, int width, int height, string savePath)
    {
        byte[] data = CaptureRegion(x, y, width, height, savePath);
        if (data == null) return false;
        baselineData = data;
        baselineW = width;
        baselineH = height;
        return true;
    }

    public static bool HasBaseline() { return baselineData != null; }

    public static double CompareToBaseline(int x, int y, int width, int height, int channelTolerance)
    {
        if (baselineData == null) return -1.0;
        if (width != baselineW || height != baselineH) return -1.0;

        byte[] current = CaptureRegion(x, y, width, height, null);
        if (current == null) return -1.0;
        if (current.Length != baselineData.Length) return -1.0;

        int totalPixels = width * height;
        int changedPixels = 0;

        for (int i = 0; i < current.Length; i += 3)
        {
            int dR = Math.Abs(current[i]     - baselineData[i]);
            int dG = Math.Abs(current[i + 1] - baselineData[i + 1]);
            int dB = Math.Abs(current[i + 2] - baselineData[i + 2]);

            if (dR > channelTolerance || dG > channelTolerance || dB > channelTolerance)
                changedPixels++;
        }

        return (changedPixels * 100.0) / totalPixels;
    }

    public static void ClearBaseline()
    {
        baselineData = null;
        baselineW = 0;
        baselineH = 0;
    }

    /// <summary>
    /// Loads a baseline from a previously saved PNG file.
    /// Returns true if the file was loaded successfully.
    /// </summary>
    public static bool LoadBaselineFromFile(string path)
    {
        if (!System.IO.File.Exists(path)) return false;

        try
        {
            Bitmap bmp = new Bitmap(path);
            baselineW = bmp.Width;
            baselineH = bmp.Height;
            baselineData = new byte[baselineW * baselineH * 3];
            int idx = 0;
            for (int py = 0; py < baselineH; py++)
            {
                for (int px = 0; px < baselineW; px++)
                {
                    Color c = bmp.GetPixel(px, py);
                    baselineData[idx++] = c.R;
                    baselineData[idx++] = c.G;
                    baselineData[idx++] = c.B;
                }
            }
            bmp.Dispose();
            return true;
        }
        catch
        {
            return false;
        }
    }
}
"@ -ReferencedAssemblies @('System.Drawing') -Language CSharp -ErrorAction Stop

    $script:IconCaptureLoaded = $true
} catch {
    try { [IconCapture] | Out-Null; $script:IconCaptureLoaded = $true } catch {
        Write-Host "WARNING: Failed to compile IconCapture: $_"
    }
}

function Find-SkimmerTrayIcon {
    <#
    .SYNOPSIS
        Finds the SkimSrv notification area icon using Shell_NotifyIconGetRect.
        This Win32 API directly queries the shell for the screen coordinates
        of a tray icon by its owner window handle and ID.
        Returns a hashtable with X, Y, Width, Height, or $null.
    #>
    if (-not $script:IconCaptureLoaded) { return $null }

    $procs = Get-ProcessByPath -ExePath $SkimSrvPath
    if (-not $procs) { return $null }

    foreach ($proc in $procs) {
        $procId = [uint32]$proc.Id
        try {
            $diagInfo = ""
            $rect = [IconCapture]::FindTrayIconRect($procId, [ref]$diagInfo)

            # Log diagnostics on first run
            if (-not $script:StatusDiagDone) {
                foreach ($line in ($diagInfo -split "`n")) {
                    if ($line.Trim()) { Write-Log "    [DIAG] $($line.Trim())" }
                }
            }

            $w = $rect.Right - $rect.Left
            $h = $rect.Bottom - $rect.Top
            if ($w -gt 0 -and $h -gt 0) {
                return @{
                    X      = $rect.Left
                    Y      = $rect.Top
                    Width  = $w
                    Height = $h
                }
            }
        } catch {
            if (-not $script:StatusDiagDone) {
                Write-Log "    [DIAG] Error searching PID $procId : $_"
            }
        }
    }

    return $null
}

function Test-SkimSrvStatus {
    <#
    .SYNOPSIS
        Monitors the SkimSrv system tray icon. Checks:
        1. Icon is present in the notification area (via Shell_NotifyIconGetRect)
        2. Icon pixels changed from baseline by more than 3% (warning/error overlay)
        Implements a grace period before restarting.
    #>

    if (-not $script:IconCaptureLoaded) {
        return @{ Healthy = $true; Reason = "" }
    }

    $procs = Get-ProcessByPath -ExePath $SkimSrvPath
    if (-not $procs) {
        $script:StatusFailSince = $null
        return @{ Healthy = $true; Reason = "" }
    }

    # Find the SkimSrv tray icon
    $icon = Find-SkimmerTrayIcon

    # Diagnostic on first check
    if (-not $script:StatusDiagDone) {
        if ($icon) {
            Write-Log "  [DIAG] SkimSrv tray icon found at ($($icon.X),$($icon.Y)) size $($icon.Width)x$($icon.Height)"
        } else {
            Write-Log "  [DIAG] SkimSrv tray icon NOT found via Shell_NotifyIconGetRect."
        }
        $script:StatusDiagDone = $true
    }

    # Check 1: Is the icon present?
    if (-not $icon) {
        return (Test-StatusGracePeriod -Reason "SkimSrv tray icon not found in notification area")
    }

    # Check 2: Fuzzy pixel comparison of the tray icon
    if ($icon.Width -gt 0 -and $icon.Height -gt 0) {
        try {
            # Load baseline from file if not already in memory
            if (-not [IconCapture]::HasBaseline()) {
                if (Test-Path $BaselineImagePath) {
                    $loaded = [IconCapture]::LoadBaselineFromFile($BaselineImagePath)
                    if ($loaded) {
                        Write-Log "  [DIAG] Baseline loaded from $BaselineImagePath"
                    }
                }
            }

            if (-not [IconCapture]::HasBaseline()) {
                # No saved baseline — capture a new one and save it
                $ok = [IconCapture]::SetBaseline(
                    $icon.X, $icon.Y, $icon.Width, $icon.Height,
                    $BaselineImagePath)
                if ($ok) {
                    Write-Log "  [DIAG] New tray icon baseline captured ($($icon.Width)x$($icon.Height))."
                    Write-Log "  [DIAG] Baseline saved to $BaselineImagePath"
                    Write-Log "  [DIAG] Delete this file to force a new baseline capture."
                }
            } else {
                $diffPct = [IconCapture]::CompareToBaseline(
                    $icon.X, $icon.Y, $icon.Width, $icon.Height, 20)

                if ($diffPct -lt 0) {
                    $msg = "Tray icon diff: capture failed (icon may have moved)"
                } else {
                    $msg = "Tray icon diff: $([math]::Round($diffPct,1))%"
                }
                if ($msg -ne $script:LastDiffMsg) {
                    Write-Log "  $msg"
                    $script:LastDiffMsg = $msg
                }

                if ($diffPct -ge 1.5) {
                    return (Test-StatusGracePeriod -Reason "SkimSrv tray icon changed ($([math]::Round($diffPct,1))% pixels differ from baseline)")
                }
            }
        } catch {
            Write-Log "  Warning: Could not compare tray icon pixels: $_"
        }
    }

    # Everything OK — reset timer
    if ($script:StatusFailSince -ne $null) {
        Write-Log "  SkimSrv tray icon status restored."
    }
    $script:StatusFailSince = $null
    return @{ Healthy = $true; Reason = "" }
}

function Test-StatusGracePeriod {
    param([string]$Reason)

    $now = Get-Date
    if ($script:StatusFailSince -eq $null) {
        $script:StatusFailSince = $now
        Write-Log "  SkimSrv tray warning: $Reason. Grace period started (${StatusGraceSeconds}s)."
        return @{ Healthy = $true; Reason = "" }
    }

    $elapsed = ($now - $script:StatusFailSince).TotalSeconds
    if ($elapsed -ge $script:StatusGraceSeconds) {
        $script:StatusFailSince = $null
        return @{
            Healthy = $false
            Reason  = "$Reason (persisted for $([math]::Round($elapsed,1))s)"
        }
    }

    return @{ Healthy = $true; Reason = "" }
}

# ============================================================================
# INITIAL STARTUP
# ============================================================================

Write-Log "========================================================"
Write-Log "Skimmer & Aggregator Monitor starting."
Write-Log "  SkimSrv:    $SkimSrvPath"
Write-Log "  Aggregator: $AggregatorPath"
Write-Log "  Check interval: ${CheckIntervalSeconds}s"
Write-Log "  Allowed class names: $($AllowedClassNames -join ', ')"
Write-Log "  Alert keywords: $($AlertKeywords -join ', ')"
Write-Log "  Status grace period: ${StatusGraceSeconds}s"
Write-Log "  Baseline image: $BaselineImagePath"
Write-Log "  WindowHelper loaded: $WindowHelperLoaded"
Write-Log "  Tray icon monitor loaded: $IconCaptureLoaded"
Write-Log "========================================================"

# Launch both if not already running
if (-not (Get-ProcessByPath -ExePath $SkimSrvPath)) {
    Start-Application -ExePath $SkimSrvPath -DisplayName "SkimSrv"
    Start-Sleep -Seconds 2
}
if (-not (Get-ProcessByPath -ExePath $AggregatorPath)) {
    Start-Application -ExePath $AggregatorPath -DisplayName "Aggregator"
}

# ============================================================================
# MAIN MONITORING LOOP
# ============================================================================

Write-Log "Entering monitoring loop (Ctrl+C to stop)..."

while ($true) {
    Start-Sleep -Seconds $CheckIntervalSeconds

    $skimResult = Test-ApplicationHealth -ExePath $SkimSrvPath    -DisplayName "SkimSrv"
    $aggResult  = Test-ApplicationHealth -ExePath $AggregatorPath -DisplayName "Aggregator"

    if (-not $skimResult.Healthy) {
        Restart-BothApplications -Reason $skimResult.Reason
    }
    elseif (-not $aggResult.Healthy) {
        Restart-BothApplications -Reason $aggResult.Reason
    }
    else {
        # --- Check 4: Are SkimSrv status indicators present? ---
        $statusResult = Test-SkimSrvStatus
        if (-not $statusResult.Healthy) {
            Restart-BothApplications -Reason $statusResult.Reason
        }
    }
}
