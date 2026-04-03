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

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

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
Write-Log "  WindowHelper loaded: $WindowHelperLoaded"
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
}
