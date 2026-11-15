param(
    [string]$Launch = '',
    [string]$Install = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WinoidActivate {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
public class WinoidDrive {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "DefineDosDeviceW")]
    public static extern bool DefineDosDevice(uint flags, string name, string target);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "QueryDosDeviceW")]
    public static extern uint QueryDosDevice(string name, StringBuilder target, uint max);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotify(int eventId, uint flags, string item1, string item2);
}
"@

$script:baseDir = $PSScriptRoot
$script:requestDir = Join-Path $env:LOCALAPPDATA 'Winoid\queue'
$script:instanceMutex = New-Object System.Threading.Mutex($false, 'Local\WinoidManager')
if (-not $script:instanceMutex.WaitOne(0)) {
    $queued = $false
    if ($Launch -or $Install) {
        try {
            if (-not (Test-Path -LiteralPath $script:requestDir)) {
                New-Item -ItemType Directory -Path $script:requestDir -Force | Out-Null
            }
            $action = 'launch'
            $target = $Launch
            if (-not $Launch) { $action = 'install'; $target = $Install }
            $req = [ordered]@{
                action  = $action
                target  = $target
                created = (Get-Date).ToString('o')
            } | ConvertTo-Json -Compress
            $name = 'req-{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
            $tmp = Join-Path $script:requestDir ($name + '.tmp')
            [System.IO.File]::WriteAllText($tmp, $req, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $tmp -Destination (Join-Path $script:requestDir $name) -ErrorAction Stop
            $queued = $true
        } catch { }
    }
    $existing = [WinoidActivate]::FindWindow($null, 'Winoid')
    if ($existing -ne [IntPtr]::Zero) {
        [void][WinoidActivate]::ShowWindow($existing, 9)
        [void][WinoidActivate]::SetForegroundWindow($existing)
    } elseif (-not $queued) {
        [System.Windows.MessageBox]::Show('Winoid уже запущен.', 'Winoid') | Out-Null
    }
    exit
}

Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public class NativeWin {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFO bi, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr hdc);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER {
        public int biSize; public int biWidth; public int biHeight;
        public short biPlanes; public short biBitCount; public int biCompression;
        public int biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter;
        public int biClrUsed; public int biClrImportant;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFO { public BITMAPINFOHEADER bmiHeader; }
    public delegate bool EnumProc(IntPtr h, IntPtr lp);

    public static IntPtr FindWindowContains(string needle, string exclude) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, lp) => {
            if (!IsWindowVisible(h)) return true;
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            var t = sb.ToString();
            if (t.Length == 0) return true;
            if (!String.IsNullOrEmpty(exclude) && t.IndexOf(exclude, StringComparison.OrdinalIgnoreCase) >= 0) return true;
            if (t.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static void ForceForeground(IntPtr h) {
        IntPtr fg = GetForegroundWindow();
        uint fgPid; uint fgThread = GetWindowThreadProcessId(fg, out fgPid);
        uint myThread = GetCurrentThreadId();
        if (fgThread != 0 && fgThread != myThread) {
            AttachThreadInput(myThread, fgThread, true);
            SetForegroundWindow(h);
            AttachThreadInput(myThread, fgThread, false);
        } else {
            SetForegroundWindow(h);
        }
    }
}

public class FrameGrabber : IDisposable {
    public readonly int W, H, Stride, ByteSize;
    IntPtr _memDc, _dib, _old, _screenDc, _bits;
    public long LastMs;

    public FrameGrabber(int w, int h) {
        W = w; H = h; Stride = w * 4; ByteSize = Stride * h;
        _screenDc = NativeWin.GetDC(IntPtr.Zero);
        _memDc = NativeWin.CreateCompatibleDC(_screenDc);
        var bi = new NativeWin.BITMAPINFO();
        bi.bmiHeader.biSize = Marshal.SizeOf(typeof(NativeWin.BITMAPINFOHEADER));
        bi.bmiHeader.biWidth = w;
        bi.bmiHeader.biHeight = -h;
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = 0;
        _dib = NativeWin.CreateDIBSection(_screenDc, ref bi, 0, out _bits, IntPtr.Zero, 0);
        _old = NativeWin.SelectObject(_memDc, _dib);
    }

    public IntPtr Bits { get { return _bits; } }

    public bool Capture(IntPtr hwnd) {
        var sw = Stopwatch.StartNew();
        bool ok = NativeWin.PrintWindow(hwnd, _memDc, 2);
        LastMs = sw.ElapsedMilliseconds;
        return ok;
    }

    public double MeanLuma() {
        long sum = 0; int n = 0;
        int count = W * H;
        for (int i = 0; i < count; i += 53) {
            int off = i * 4;
            sum += Marshal.ReadByte(_bits, off) + Marshal.ReadByte(_bits, off + 1) + Marshal.ReadByte(_bits, off + 2);
            n++;
        }
        return n == 0 ? 0 : sum / (double)n / 3.0;
    }

    public void Dispose() {
        try { NativeWin.SelectObject(_memDc, _old); } catch { }
        try { NativeWin.DeleteObject(_dib); } catch { }
        try { NativeWin.DeleteDC(_memDc); } catch { }
        try { NativeWin.ReleaseDC(IntPtr.Zero, _screenDc); } catch { }
    }
}

public class AdbShell : IDisposable {
    Process _p;
    BlockingCollection<string> _lines = new BlockingCollection<string>();

    public AdbShell(string adb, string serial) : this(adb, serial, new string[0]) { }

    public AdbShell(string adb, string serial, string[] prefixArgs) {
        var psi = new ProcessStartInfo(adb);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        foreach (var a in prefixArgs) { psi.ArgumentList.Add(a); }
        psi.ArgumentList.Add("-s");
        psi.ArgumentList.Add(serial);
        psi.ArgumentList.Add("shell");
        _p = Process.Start(psi);
        _p.OutputDataReceived += (s, e) => { if (e.Data != null) { try { _lines.Add(e.Data); } catch { } } };
        _p.ErrorDataReceived += (s, e) => { if (e.Data != null) { try { _lines.Add(e.Data); } catch { } } };
        _p.BeginOutputReadLine();
        _p.BeginErrorReadLine();
    }

    public bool Running { get { return _p != null && !_p.HasExited; } }

    public void Send(string cmd) {
        if (!Running) throw new InvalidOperationException("adb shell is not running");
        _p.StandardInput.WriteLine(cmd);
        _p.StandardInput.Flush();
    }

    public long SendSync(string cmd, int timeoutMs) {
        string marker = "M" + Guid.NewGuid().ToString("N");
        var sw = Stopwatch.StartNew();
        _p.StandardInput.WriteLine(cmd + "; echo " + marker);
        _p.StandardInput.Flush();
        string line;
        while (sw.ElapsedMilliseconds < timeoutMs) {
            if (_lines.TryTake(out line, 25)) {
                if (line == marker) break;
            }
        }
        sw.Stop();
        return sw.ElapsedMilliseconds;
    }

    public void Dispose() {
        try { _p.StandardInput.WriteLine("exit"); _p.StandardInput.Flush(); } catch { }
        try { if (!_p.WaitForExit(400)) _p.Kill(); } catch { }
    }
}
"@

$script:wsl = "$env:SystemRoot\System32\wsl.exe"
$script:sessionRunning = $false
$script:apps = @()
$script:launchState = $null
$script:pendingAndroidWindow = $null
$script:installJob = $null
$script:installTicks = 0
$script:sessionJob = $null
$script:sessionTicks = 0
$script:sessionWaiting = $false
$script:wslKeepAlive = $null
$script:msrdcId = 0

$script:wrappers = New-Object System.Collections.ArrayList
$script:wrapByImage = @{}
$script:wrapByWindow = @{}
$script:bounceWrap = $null
$script:adb = $null
$script:adbPath = $null
$script:adbNextTry = [DateTime]::MinValue
$script:adbSerial = '192.168.240.112:5555'
$script:adbCheckedAt = [DateTime]::MinValue
$script:wslDistro = ''
$script:wslHome = ''
$script:wslUser = ''
$script:androidDrive = ''
$script:androidDriveTarget = ''
$script:androidDriveMode = ''
$script:androidDriveAclDone = $false

# One-time migration from the old Winndroid data directory.
function Initialize-WinoidData {
    $newRoot = Join-Path $env:LOCALAPPDATA 'Winoid'
    $oldRoot = Join-Path $env:LOCALAPPDATA 'Winndroid'
    $moved = $false
    if ((Test-Path -LiteralPath $oldRoot) -and -not (Test-Path -LiteralPath $newRoot)) {
        try {
            Move-Item -LiteralPath $oldRoot -Destination $newRoot -ErrorAction Stop
            $moved = $true
        } catch { }
    }
    if ($moved) {
        try {
            $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
            if (Test-Path -LiteralPath $wslConfig) {
                $changed = $false
                $out = foreach ($line in @(Get-Content -LiteralPath $wslConfig)) {
                    if ($line -match '^\s*kernel=' -and $line -match '[\\/]Winndroid[\\/]') {
                        $changed = $true
                        $line.Replace('\\Winndroid\\', '\\Winoid\\').Replace('\Winndroid\', '\Winoid\')
                    } else { $line }
                }
                if ($changed) {
                    Copy-Item -LiteralPath $wslConfig -Destination ("$wslConfig.winoid-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak') -Force
                    Set-Content -LiteralPath $wslConfig -Value ($out -join "`r`n") -Encoding utf8NoBOM
                }
            }
        } catch {
            try {
                if (-not (Test-Path -LiteralPath $oldRoot) -and (Test-Path -LiteralPath $newRoot)) {
                    Move-Item -LiteralPath $newRoot -Destination $oldRoot -ErrorAction Stop
                }
            } catch { }
            return $oldRoot
        }
    }
    if (Test-Path -LiteralPath $newRoot) { return $newRoot }
    return $oldRoot
}

# Optional config: %LOCALAPPDATA%\Winoid\config.json
# { "wslDistro": "Winoid", "adbSerial": "192.168.240.112:5555" }
$script:dataRoot = Initialize-WinoidData
$script:configDir = $script:dataRoot
$script:configPath = Join-Path $script:configDir 'config.json'
if (Test-Path -LiteralPath $script:configPath) {
    try {
        $cfg = Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json
        if ($cfg.wslDistro) { $script:wslDistro = [string]$cfg.wslDistro }
        if ($cfg.adbSerial) { $script:adbSerial = [string]$cfg.adbSerial }
    } catch { }
}
if ($env:WINOID_WSL_DISTRO) { $script:wslDistro = $env:WINOID_WSL_DISTRO }
if ($env:WINOID_ADB_SERIAL) { $script:adbSerial = $env:WINOID_ADB_SERIAL }

$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Winoid" Height="700" Width="1040" MinHeight="520" MinWidth="820"
        WindowStartupLocation="CenterScreen" Background="#141519" Foreground="#F1F3F5"
        FontFamily="Segoe UI" AllowDrop="True" UseLayoutRounding="True">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#26282F"/>
      <Setter Property="Foreground" Value="#F1F3F5"/>
      <Setter Property="BorderBrush" Value="#34363E"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,10"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#31343C"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="#3A3D46"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Background" Value="#3D7EFF"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,12"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#518CFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="#2F6BEA"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="8" Padding="8">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#20222A"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#25314D"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#26282F"/>
      <Setter Property="Foreground" Value="#F1F3F5"/>
      <Setter Property="BorderBrush" Value="#34363E"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="ToggleButton" Focusable="False" ClickMode="Press"
                            Content="{TemplateBinding SelectionBoxItem}"
                            ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                            ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Bd" Background="#26282F" BorderBrush="#34363E" BorderThickness="1" CornerRadius="6">
                      <Grid>
                        <ContentPresenter Margin="10,0,30,0" VerticalAlignment="Center"/>
                        <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,11,0"
                              Data="M 0 0 L 4 4 L 8 0" Stroke="#A9AEBA" StrokeThickness="1.5"/>
                      </Grid>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#4A4D58"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                <Border Background="#26282F" BorderBrush="#34363E" BorderThickness="1" CornerRadius="6"
                        Margin="0,4,0,0" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="240">
                  <ScrollViewer>
                    <ItemsPresenter/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#F1F3F5"/>
      <Setter Property="Background" Value="#26282F"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" CornerRadius="4">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#25314D"/>
              </Trigger>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#3D7EFF"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="0,0,0,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock Text="Winoid" FontSize="28" FontWeight="SemiBold"/>
        <TextBlock Text="Android-приложения в отдельных окнах Windows" FontSize="12" Foreground="#8D929C" Margin="0,2,0,0"/>
      </StackPanel>
      <Border Grid.Column="1" Background="#1E2027" BorderBrush="#2E3139" BorderThickness="1" CornerRadius="20" Padding="14,7" VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#F5A623" Margin="0,0,8,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="StatusText" Text="Проверка…" FontSize="12"/>
        </StackPanel>
      </Border>
    </Grid>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="320"/>
      </Grid.ColumnDefinitions>

      <Border Background="#191A1F" BorderBrush="#2A2C33" BorderThickness="1" CornerRadius="12" Padding="10">
        <DockPanel>
          <Grid DockPanel.Dock="Top" Margin="4,2,4,10">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Border Background="#202127" CornerRadius="8" Padding="10,6">
              <TextBox x:Name="SearchBox" Background="Transparent" BorderThickness="0" Foreground="#F1F3F5" FontSize="13" VerticalContentAlignment="Center"/>
            </Border>
            <Button x:Name="RefreshBtn" Grid.Column="1" Content="Обновить" Margin="8,0,0,0" Padding="12,7"/>
          </Grid>
          <ListBox x:Name="AppsList" Background="Transparent" BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
            <ListBox.ItemTemplate>
              <DataTemplate>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="44"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <Border Width="34" Height="34" CornerRadius="9" Background="#2A2F3A" VerticalAlignment="Center">
                    <TextBlock Text="A" FontSize="16" FontWeight="Bold" Foreground="#7EA6FF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <StackPanel Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center">
                    <TextBlock Text="{Binding Name}" FontSize="14" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                    <TextBlock Text="{Binding Package}" FontSize="11" Foreground="#A9AEBA" TextTrimming="CharacterEllipsis"/>
                  </StackPanel>
                  <TextBlock Grid.Column="2" Text="↗" FontSize="16" Foreground="#5E6470" VerticalAlignment="Center" Margin="8,0,4,0"/>
                </Grid>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
        </DockPanel>
      </Border>

      <ScrollViewer Grid.Column="1" Margin="16,0,0,0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel>
        <Button x:Name="LaunchBtn" Style="{StaticResource Primary}" Content="Запустить в отдельном окне" IsEnabled="False"/>
        <Button x:Name="ShortcutBtn" Content="Ярлык на рабочем столе" IsEnabled="False"/>
        <Button x:Name="DriveBtn" Content="Открыть диск Android"/>
        <Button x:Name="FullUiBtn" Content="Перезапустить Android"/>
        <Button x:Name="SettingsBtn" Content="Настройки Android"/>
        <Button x:Name="InstallBtn" Content="Установить APK…"/>
        <Button x:Name="BackendBtn" Content="Настроить Android" Visibility="Collapsed"/>
        <Border Height="1" Background="#2A2C33" Margin="0,8,0,14"/>
        <TextBlock Text="Размер нового окна" FontSize="12" Foreground="#8D929C" Margin="2,0,0,6"/>
        <ComboBox x:Name="SizeBox" Background="#26282F" Foreground="#F1F3F5" BorderBrush="#34363E" Padding="8,6" Margin="0,0,0,12">
          <ComboBoxItem Content="Как есть (на весь экран)" IsSelected="True"/>
          <ComboBoxItem Content="1280 × 800"/>
          <ComboBoxItem Content="1600 × 900"/>
          <ComboBoxItem Content="1920 × 1080"/>
        </ComboBox>
        <CheckBox x:Name="AutoHideCheck" Content="Скрывать индикатор после появления окна" Foreground="#C9CDD4" IsChecked="True" Margin="2,0,0,14"/>
        <TextBlock x:Name="HintText" TextWrapping="Wrap" FontSize="12" Foreground="#A9AEBA"
                   Text="Перетащите APK в окно, чтобы установить. Двойной клик по приложению запускает его в отдельном окне. Кнопка «Ярлык на рабочем столе» создаёт ярлык с родной иконкой приложения. «Настройки Android» открывает системные настройки, «Диск Android» — общую память Android в проводнике, «Перезапустить Android» возвращает окна, если графика WSL зависла. Окно Winoid можно открыть ярлыком на рабочем столе, в меню Пуск или файлом Winoid.cmd."/>
        </StackPanel>
      </ScrollViewer>
    </Grid>

    <TextBlock x:Name="FooterText" Grid.Row="2" Margin="2,14,0,0" FontSize="12" Foreground="#A9AEBA" Text="Готово"/>
  </Grid>
</Window>
'@

$loaderXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinoidLoader" Width="500" Height="248"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" WindowStartupLocation="CenterScreen" ResizeMode="NoResize">
  <Border Background="#1D1F25" BorderBrush="#3A3D46" BorderThickness="1" CornerRadius="16" Padding="24">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <StackPanel Orientation="Horizontal">
        <Border Width="34" Height="34" CornerRadius="9" Background="#2A3550" Margin="0,0,12,0">
          <TextBlock Text="A" Foreground="#7EA6FF" FontSize="17" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock x:Name="LoaderTitle" Text="Запуск…" FontSize="17" FontWeight="SemiBold" Foreground="#F1F3F5"/>
          <TextBlock x:Name="LoaderElapsed" Text="0 сек" FontSize="11" Foreground="#8D929C"/>
        </StackPanel>
      </StackPanel>
      <TextBlock x:Name="LoaderSub" Grid.Row="1" Margin="0,14,0,0" TextWrapping="Wrap" Foreground="#B9BEC7" FontSize="12"
                 Text="Открываю приложение в отдельном окне."/>
      <ProgressBar x:Name="LoaderBar" Grid.Row="2" Height="4" Margin="0,16,0,0" IsIndeterminate="True"
                   Foreground="#3D7EFF" Background="#2A2C33" BorderThickness="0"/>
      <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button x:Name="ShowWindowBtn" Content="Показать окно" Margin="0,0,8,0" Padding="12,8"
                Background="#2A2C33" Foreground="#F1F3F5" BorderBrush="#3A3D46" BorderThickness="1"/>
        <Button x:Name="HideLoaderBtn" Content="Скрыть" Padding="12,8"
                Background="#3D7EFF" Foreground="White" BorderThickness="0"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

$script:wrapperXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1280" Height="820" MinWidth="360" MinHeight="260"
        WindowStartupLocation="CenterScreen" Background="#0B0C0E">
  <Grid>
    <Image x:Name="View" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
    <Border x:Name="Loading" Background="#E60B0C0E">
      <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
        <Border Width="46" Height="46" CornerRadius="12" Background="#2A3550" HorizontalAlignment="Center">
          <TextBlock Text="A" Foreground="#7EA6FF" FontSize="22" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <TextBlock x:Name="LoadingText" Text="Приложение запускается…" Foreground="#D6DAE2" FontSize="14" Margin="0,16,0,0" HorizontalAlignment="Center"/>
      </StackPanel>
    </Border>
    <Border x:Name="Hint" Background="#CC101318" CornerRadius="10" Padding="14,10"
            HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,18">
      <TextBlock Text="Нажмите на окно — ввод пойдёт в Android" Foreground="#D6DAE2" FontSize="12"/>
    </Border>
  </Grid>
</Window>
'@

$window = [System.Windows.Markup.XamlReader]::Parse($mainXaml)
$loader = [System.Windows.Markup.XamlReader]::Parse($loaderXaml)

$script:appIcon = $null
$iconPath = Join-Path $PSScriptRoot 'assets\android.ico'
if (Test-Path -LiteralPath $iconPath) {
    try {
        $script:appIcon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($iconPath))
        $window.Icon = $script:appIcon
        $loader.Icon = $script:appIcon
    } catch { }
}

$statusDot     = $window.FindName('StatusDot')
$statusText    = $window.FindName('StatusText')
$searchBox     = $window.FindName('SearchBox')
$refreshBtn    = $window.FindName('RefreshBtn')
$appsList      = $window.FindName('AppsList')
$launchBtn     = $window.FindName('LaunchBtn')
$shortcutBtn   = $window.FindName('ShortcutBtn')
$driveBtn      = $window.FindName('DriveBtn')
$fullUiBtn     = $window.FindName('FullUiBtn')
$settingsBtn   = $window.FindName('SettingsBtn')
$installBtn    = $window.FindName('InstallBtn')
$backendBtn    = $window.FindName('BackendBtn')
$sizeBox       = $window.FindName('SizeBox')
$autoHideCheck = $window.FindName('AutoHideCheck')
$footerText    = $window.FindName('FooterText')

$loaderTitle   = $loader.FindName('LoaderTitle')
$loaderSub     = $loader.FindName('LoaderSub')
$loaderElapsed = $loader.FindName('LoaderElapsed')
$loaderBar     = $loader.FindName('LoaderBar')
$showWindowBtn = $loader.FindName('ShowWindowBtn')
$hideLoaderBtn = $loader.FindName('HideLoaderBtn')

function Set-Status([string]$text, [string]$color) {
    $statusText.Text = $text
    $statusDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color)
}

function Set-Footer([string]$text) {
    $footerText.Text = $text
}

function Get-WslBase {
    param([switch]$Root)
    $a = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($script:wslDistro)) {
        [void]$a.Add('-d'); [void]$a.Add($script:wslDistro)
    }
    if ($Root) {
        [void]$a.Add('-u'); [void]$a.Add('root')
    }
    return @($a)
}

function Invoke-Wsl {
    param([string[]]$Arguments, [int]$TimeoutMs = 20000)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:wsl
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ Out = ''; Err = 'timeout'; Code = -1 }
    }
    return [pscustomobject]@{ Out = $outTask.Result; Err = $errTask.Result; Code = $p.ExitCode }
}

function Get-WslDistroName {
    if (-not [string]::IsNullOrWhiteSpace($script:wslDistro)) { return $script:wslDistro }
    try {
        $out = & $script:wsl -l -q 2>$null
        $text = ($out | Out-String) -replace "`0", ''
        $name = @($text -split "`r?`n" | Where-Object { $_.Trim() })[0]
        if ($name) { $script:wslDistro = $name.Trim() }
    } catch { }
    return $script:wslDistro
}

function Get-WslUserName {
    if (-not [string]::IsNullOrWhiteSpace($script:wslUser)) { return $script:wslUser }
    $r = Invoke-Wsl ((Get-WslBase) + @('--', 'bash', '-lc', 'id -un')) 12000
    if ($r.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.Out)) {
        $script:wslUser = $r.Out.Trim()
    }
    return $script:wslUser
}

function Get-WslHome {
    if (-not [string]::IsNullOrWhiteSpace($script:wslHome)) { return $script:wslHome }
    $r = Invoke-Wsl ((Get-WslBase) + @('--', 'bash', '-lc', 'printf %s "$HOME"')) 12000
    if ($r.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.Out)) {
        $script:wslHome = $r.Out.Trim()
    }
    return $script:wslHome
}

# Waydroid keeps its Android images and /sdcard in the session user's home.
# The files are owned by Android's media_rw (1023), so grant the WSL user an
# ACL instead of changing ownership (Android still sees its normal uids).
function Get-AndroidStorageInfo {
    param([switch]$ApplyAcl)
    $linuxHome = Get-WslHome
    if ([string]::IsNullOrWhiteSpace($linuxHome)) { return $null }

    # Keep the shell command free of variables: WSL's -lc argument handling
    # strips $name expansions when the script is passed through CreateProcess.
    $storage = ''
    foreach ($candidate in @("$linuxHome/.local/share/waydroid/data/media/0", '/var/lib/waydroid/data/media/0')) {
        $cmd = "test -d '$candidate' && printf %s '$candidate'"
        $r = Invoke-Wsl ((Get-WslBase -Root) + @('--', 'bash', '-lc', $cmd)) 15000
        if ($r.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.Out)) {
            $storage = $r.Out.Trim()
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($storage)) { return $null }

    if ($ApplyAcl) {
        $user = Get-WslUserName
        if ([string]::IsNullOrWhiteSpace($user)) { $user = 'winoid' }
        $cmd = "if command -v setfacl >/dev/null 2>&1; then setfacl -R -m u:$user:rwx '$storage' 2>/dev/null; setfacl -R -d -m u:$user:rwx '$storage' 2>/dev/null; else chmod -R o+rwX '$storage' 2>/dev/null; fi; printf %s '$storage'"
        $r = Invoke-Wsl ((Get-WslBase -Root) + @('--', 'bash', '-lc', $cmd)) 120000
        if ($r.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.Out)) {
            return $r.Out.Trim()
        }
    }
    return $storage
}

function Get-FreeDriveLetter {
    try {
        $used = @{}
        foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $used[$d.Name] = $true
        }
        foreach ($letter in @('W', 'V', 'X', 'Y', 'Z', 'T', 'S', 'R', 'Q', 'P', 'O', 'N', 'M', 'L', 'K', 'J', 'I', 'H', 'G', 'F')) {
            if ($used.ContainsKey($letter)) { continue }
            $sb = New-Object System.Text.StringBuilder 1024
            if ([WinoidDrive]::QueryDosDevice("${letter}:", $sb, 1024) -ne 0) { continue }
            if (Test-Path -LiteralPath "${letter}:\") { continue }
            return $letter
        }
    } catch { }
    return $null
}

function Set-DriveAppearance([string]$Letter) {
    try {
        $base = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$Letter"
        New-Item -Path "$base\DefaultLabel" -Force | Out-Null
        Set-Item -Path "$base\DefaultLabel" -Value 'Android'
        $icon = Join-Path $script:baseDir 'assets\android.ico'
        if (Test-Path -LiteralPath $icon) {
            New-Item -Path "$base\DefaultIcon" -Force | Out-Null
            Set-Item -Path "$base\DefaultIcon" -Value $icon
        }
    } catch { }
}

# A drive can have a stack of DOS-device mappings. P9Rdr targets need
# DDD_RAW_TARGET_PATH, ordinary UNC targets do not.
function Remove-DriveMapping([string]$Letter) {
    for ($i = 0; $i -lt 12; $i++) {
        $sb = New-Object System.Text.StringBuilder 1024
        $n = [WinoidDrive]::QueryDosDevice("${Letter}:", $sb, 1024)
        if ($n -eq 0) { break }
        $target = $sb.ToString()
        $flags = if ($target.StartsWith('\Device\')) { 7 } else { 6 }
        if (-not [WinoidDrive]::DefineDosDevice($flags, "${Letter}:", $target)) { break }
    }
    try { & net.exe use "${Letter}:" /delete /y 2>&1 | Out-Null } catch { }
}

function Mount-AndroidDrive {
    param([switch]$Open)
    if (-not [string]::IsNullOrWhiteSpace($script:androidDrive) -and (Test-Path -LiteralPath "${script:androidDrive}\")) {
        if ($Open) { Start-Process -FilePath 'explorer.exe' -ArgumentList "${script:androidDrive}\" }
        return $true
    }

    $storage = Get-AndroidStorageInfo -ApplyAcl:(-not $script:androidDriveAclDone)
    if ([string]::IsNullOrWhiteSpace($storage)) {
        Set-Footer 'Не нашёл хранилище Android в WSL.'
        return $false
    }
    $script:androidDriveAclDone = $true

    $distro = Get-WslDistroName
    if ([string]::IsNullOrWhiteSpace($distro)) {
        Set-Footer 'Не удалось определить дистрибутив WSL.'
        return $false
    }
    $uncRoot = "\\wsl.localhost\$distro"
    if (-not (Test-Path -LiteralPath $uncRoot)) {
        $uncRoot = "\\wsl`$\$distro"
    }
    if (-not (Test-Path -LiteralPath $uncRoot)) {
        Set-Footer "WSL-дистрибутив $distro недоступен."
        return $false
    }

    $letter = Get-FreeDriveLetter
    if ([string]::IsNullOrWhiteSpace($letter)) {
        Set-Footer 'Нет свободной буквы диска для Android.'
        return $false
    }

    Set-DriveAppearance $letter
    Set-Footer 'Подключаю диск Android…'
    $target = ''
    $mode = ''
    $ok = $false

    # Connect the WSL share to the letter, then point the letter at /sdcard
    # through the same Plan 9 device. This keeps Explorer seeing a connected
    # network drive rather than a disconnected UNC mapping.
    try { & net.exe use "${letter}:" $uncRoot /persistent:no 2>&1 | Out-Null } catch { }
    if ($LASTEXITCODE -eq 0) {
        $sb = New-Object System.Text.StringBuilder 1024
        if ([WinoidDrive]::QueryDosDevice("${letter}:", $sb, 1024) -gt 0) {
            $base = $sb.ToString()
            if ($base.StartsWith('\Device\P9Rdr\')) {
                $target = $base + ($storage -replace '/', '\')
                if ([WinoidDrive]::DefineDosDevice(9, "${letter}:", $target)) {
                    $ok = $true
                    $mode = 'p9'
                }
            }
        }
    }

    if (-not $ok) {
        try { & net.exe use "${letter}:" /delete /y 2>&1 | Out-Null } catch { }
        $target = $uncRoot + ($storage -replace '/', '\')
        if ([WinoidDrive]::DefineDosDevice(8, "${letter}:", $target)) {
            $ok = $true
            $mode = 'unc'
        }
    }

    if (-not $ok) {
        Remove-Item -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$letter" -Recurse -Force -ErrorAction SilentlyContinue
        Set-Footer 'Не удалось подключить диск Android.'
        return $false
    }

    $script:androidDrive = "${letter}:"
    $script:androidDriveTarget = $target
    $script:androidDriveMode = $mode
    try {
        [WinoidDrive]::SHChangeNotify(0x100, 0x5, "${letter}:\", $null)
        [WinoidDrive]::SHChangeNotify(0x2000, 0x5, "${letter}:\", $null)
    } catch { }
    Set-Footer "Диск Android подключён: ${letter}:"
    if ($Open) { Start-Process -FilePath 'explorer.exe' -ArgumentList "${letter}:\" }
    return $true
}

function Disconnect-AndroidDrive {
    if ([string]::IsNullOrWhiteSpace($script:androidDrive)) { return }
    $letter = $script:androidDrive.TrimEnd(':')
    try { Remove-DriveMapping $letter } catch { }
    try { [WinoidDrive]::SHChangeNotify(0x80, 0x5, "${letter}:\", $null) } catch { }
    Remove-Item -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$letter" -Recurse -Force -ErrorAction SilentlyContinue
    $script:androidDrive = ''
    $script:androidDriveTarget = ''
    $script:androidDriveMode = ''
}

function Start-WslDetached {
    param([string[]]$Arguments)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:wsl
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [void][System.Diagnostics.Process]::Start($psi)
}

# WSL stops the VM after about a minute without an active wsl.exe client.
# A sleeping client keeps the Android session alive while the manager is open.
function Start-WslKeepAlive {
    if ($script:wslKeepAlive -and -not $script:wslKeepAlive.HasExited) { return }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:wsl
    foreach ($a in ((Get-WslBase) + @('--', 'bash', '-lc', 'exec sleep 86400'))) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    try {
        $script:wslKeepAlive = [System.Diagnostics.Process]::Start($psi)
    } catch {
        $script:wslKeepAlive = $null
    }
}

function Get-WaydroidStatus {
    $r = Invoke-Wsl ((Get-WslBase -Root) + @('--', 'waydroid', 'status')) 15000
    if ($r.Out -match '(?m)^Session:\s*(\S+)') { return $matches[1] }
    return 'STOPPED'
}

function Test-Backend {
    $cmd = 'command -v waydroid >/dev/null 2>&1 && echo WINOID_BACKEND_OK'
    $r = Invoke-Wsl ((Get-WslBase) + @('--', 'bash', '-lc', $cmd)) 10000
    return ($r.Out -match 'WINOID_BACKEND_OK')
}

function Test-Session {
    if ((Get-WaydroidStatus) -eq 'RUNNING') {
        $script:sessionRunning = $true
        Set-Status 'Android работает' '#3DDC84'
        $backendBtn.Visibility = 'Collapsed'
        return $true
    }
    $script:sessionRunning = $false
    if (-not (Test-Backend)) {
        Set-Status 'Бэкенд не настроен' '#E5484D'
        $backendBtn.Visibility = 'Visible'
        Set-Footer 'Waydroid не найден в WSL. Нажмите «Настроить Android» или откройте README.'
        return $false
    }
    Set-Status 'Android остановлен' '#F5A623'
    $backendBtn.Visibility = 'Collapsed'
    return $false
}

function Update-AppFilter {
    $q = $searchBox.Text.Trim()
    if ($q.Length -gt 0) {
        $escaped = [regex]::Escape($q)
        $view = @($script:apps | Where-Object { $_.Name -match $escaped -or $_.Package -match $escaped })
    } else {
        $view = $script:apps
    }
    $appsList.ItemsSource = $view
    if ($view.Count -gt 0) { $appsList.SelectedIndex = 0 }
    $launchBtn.IsEnabled = ($view.Count -gt 0)
    $shortcutBtn.IsEnabled = ($view.Count -gt 0)
}

function Get-LauncherApps {
    $dex = Join-Path $script:baseDir 'assets\winoid-icon.dex'
    if (-not (Test-Path -LiteralPath $dex)) { return @() }
    $remoteDex = '/data/local/tmp/winoid-icon.dex'
    $linuxDex = ConvertTo-WslPath $dex
    $cmd = "CLASSPATH=$remoteDex app_process /system/bin WinoidIcon --list"
    $out = ''

    # WSL adb reaches the Waydroid container even when a Windows VPN
    # swallows the route to 192.168.240.0/24.
    try {
        $stateArgs = (Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'get-state')
        $r = Invoke-Wsl $stateArgs 10000
        if ($r.Out -notmatch 'device') {
            $null = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', 'connect', $script:adbSerial)) 10000
            $r = Invoke-Wsl $stateArgs 10000
        }
        if ($r.Out -match 'device') {
            $null = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'push', $linuxDex, $remoteDex)) 15000
            $res = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'shell', $cmd)) 20000
            if ($res.Out) { $out = $res.Out }
        }
    } catch { }

    if (-not $out -and $script:adbPath) {
        try {
            $null = Invoke-AdbCli -Arguments @('-s', $script:adbSerial, 'push', $dex, $remoteDex) -TimeoutMs 15000
            $res = Invoke-AdbCli -Arguments @('-s', $script:adbSerial, 'shell', $cmd) -TimeoutMs 20000
            if ($res) { $out = $res }
        } catch { }
    }

    $byPackage = @{}
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '^([^\t]+)\t(\S+)$') {
            $name = $matches[1].Trim()
            $pkg = $matches[2].Trim()
            if (-not $byPackage.ContainsKey($pkg)) {
                $byPackage[$pkg] = [pscustomobject]@{ Name = $name; Package = $pkg }
            }
        }
    }
    return @($byPackage.Values | Sort-Object Name)
}

function Refresh-Apps {
    if (-not (Test-Backend)) {
        $script:apps = @()
        Update-AppFilter
        $backendBtn.Visibility = 'Visible'
        Set-Footer 'Waydroid не найден в WSL. Нажмите «Настроить Android» или откройте README.'
        return
    }
    Set-Footer 'Чтение списка приложений…'

    $script:apps = @(Get-LauncherApps)
    if ($script:apps.Count -eq 0) {
        # Fallback for an older helper build or a failed app_process run.
        $cmd = 'export DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/$(id -u); waydroid app list'
        $r = Invoke-Wsl ((Get-WslBase) + @('--', 'bash', '-lc', $cmd)) 30000
        if ($r.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.Out)) {
            $list = New-Object System.Collections.ArrayList
            $blocks = ($r.Out -split '(?m)^Name:\s*') | Select-Object -Skip 1
            foreach ($b in $blocks) {
                $name = (($b -split "`r?`n")[0]).Trim()
                if ($b -notmatch 'packageName:\s*(\S+)') { continue }
                $pkg = $matches[1].Trim()
                if ($b -notmatch 'android\.intent\.category\.LAUNCHER') { continue }
                [void]$list.Add([pscustomobject]@{ Name = $name; Package = $pkg })
            }
            $script:apps = @($list | Sort-Object Name)
        }
    }

    if ($script:apps.Count -eq 0) {
        Update-AppFilter
        Set-Footer 'Список пуст. Android ещё запускается? Нажмите «Обновить».'
        return
    }
    Update-AppFilter
    Set-Footer "Приложений: $($script:apps.Count)"
}

function Get-SelectedSize {
    switch ($sizeBox.SelectedIndex) {
        1 { return [pscustomobject]@{ Width = 1280; Height = 800 } }
        2 { return [pscustomobject]@{ Width = 1600; Height = 900 } }
        3 { return [pscustomobject]@{ Width = 1920; Height = 1080 } }
        default { return $null }
    }
}

# --- ADB input ---

function Find-AdbExe {
    $candidates = New-Object System.Collections.ArrayList
    [void]$candidates.Add((Join-Path $PSScriptRoot 'platform-tools\adb.exe'))
    [void]$candidates.Add((Join-Path $script:configDir 'platform-tools\adb.exe'))
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { [void]$candidates.Add($cmd.Source) }
    [void]$candidates.Add("$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe")
    [void]$candidates.Add('C:\platform-tools\adb.exe')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Invoke-AdbCli {
    param([string[]]$Arguments, [int]$TimeoutMs = 6000)
    if (-not $script:adbPath) { return $null }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:adbPath
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill($true) } catch { try { $p.Kill() } catch { } }
        try { [void]$p.WaitForExit(2000) } catch { }
    }
    # Never touch Result on a process that survived Kill: adb connect can
    # hang on a VPN-blackholed route and would freeze the UI thread.
    if (-not $p.HasExited) { return '' }
    return (($outTask.Result + ' ' + $errTask.Result) -replace '\s+', ' ').Trim()
}

function Initialize-Adb {
    if ($script:adb -and $script:adb.Running) { return }
    if (-not $script:adbPath) { $script:adbPath = Find-AdbExe }

    # Prefer the WSL-side adb server: it sees the Waydroid container even
    # when a Windows VPN blackholes 192.168.240.0/24.
    $r = $null
    try {
        $r = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'get-state')) 8000
    } catch { }
    if ($r -and $r.Out -match 'device') {
        $prefix = New-Object System.Collections.ArrayList
        if (-not [string]::IsNullOrWhiteSpace($script:wslDistro)) { [void]$prefix.Add('-d'); [void]$prefix.Add($script:wslDistro) }
        [void]$prefix.Add('--'); [void]$prefix.Add('adb')
        try { $script:adb = [AdbShell]::new($script:wsl, $script:adbSerial, [string[]]$prefix) } catch { $script:adb = $null }
        return
    }

    if (-not $script:adbPath) { return }
    if ((Get-Date) -lt $script:adbNextTry) { return }
    $out = Invoke-AdbCli @('connect', $script:adbSerial)
    if ($out -match 'connected to|already connected') {
        try { $script:adb = [AdbShell]::new($script:adbPath, $script:adbSerial) } catch { $script:adb = $null }
    } else {
        $script:adbNextTry = (Get-Date).AddSeconds(60)
    }
}

function Send-Android([string]$cmd) {
    if ($null -eq $script:adb -or -not $script:adb.Running) {
        Initialize-Adb
    }
    if ($null -eq $script:adb -or -not $script:adb.Running) { return }
    try { $script:adb.Send($cmd) } catch { }
}

# --- wrappers ---

function Find-WrapperByPackage([string]$package) {
    foreach ($w in @($script:wrappers)) {
        if (-not $w.Closed -and $w.Package -eq $package) { return $w }
    }
    return $null
}

function Map-WrapperPoint($w, $pos) {
    $cw = $w.Image.ActualWidth; $ch = $w.Image.ActualHeight
    if ($cw -le 0 -or $ch -le 0) { return $null }
    $scale = [math]::Min($cw / $w.SrcW, $ch / $w.SrcH)
    if ($scale -le 0) { return $null }
    $ox = ($cw - $w.SrcW * $scale) / 2
    $oy = ($ch - $w.SrcH * $scale) / 2
    $sx = [int](($pos.X - $ox) / $scale)
    $sy = [int](($pos.Y - $oy) / $scale)
    if ($sx -lt 0) { $sx = 0 }; if ($sy -lt 0) { $sy = 0 }
    if ($sx -ge $w.SrcW) { $sx = $w.SrcW - 1 }; if ($sy -ge $w.SrcH) { $sy = $w.SrcH - 1 }
    return @($sx, $sy)
}

function Restore-Source($w) {
    if (-not [NativeWin]::IsWindow($w.Source)) { return }
    [void][NativeWin]::SetWindowLong($w.Source, -20, $w.OrigExStyle)
    $r = $w.OrigRect
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $r.Left; $y = $r.Top
    if ($x -ge $wa.Right -or $y -ge $wa.Bottom) { $x = 0; $y = 0 }
    [void][NativeWin]::SetWindowPos($w.Source, [IntPtr]::Zero, $x, $y, [Math]::Max(320, $r.Right - $r.Left), [Math]::Max(240, $r.Bottom - $r.Top), 0x0010)
    if ($w.WasZoomed) { [void][NativeWin]::ShowWindow($w.Source, 3) }
}

function Remove-Wrapper($w, [bool]$closeSource) {
    if ($null -eq $w -or $w.Closed) { return }
    $w.Closed = $true
    try { $w.Grab.Dispose() } catch { }
    try { $script:wrapByImage.Remove($w.Image) } catch { }
    try { $script:wrapByWindow.Remove($w.Window) } catch { }
    try { [void]$script:wrappers.Remove($w) } catch { }
    if ($closeSource -and [NativeWin]::IsWindow($w.Source)) {
        [void][NativeWin]::PostMessage($w.Source, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    }
    try { $w.Window.Close() } catch { }
}

function Focus-Wrapper($w) {
    if ($null -eq $w -or $w.Closed) { return }
    try {
        if ($w.Window.WindowState -eq 'Minimized') { $w.Window.WindowState = 'Normal' }
        $w.Window.Activate()
        [NativeWin]::ForceForeground([System.Windows.Interop.WindowInteropHelper]::new($w.Window).Handle)
    } catch { }
}

function New-AppWrapper($app, [IntPtr]$source, $size) {
    foreach ($old in @($script:wrappers)) {
        if (-not $old.Closed -and $old.Source -eq $source) { Focus-Wrapper $old; return $old }
    }

    $cr = New-Object NativeWin+RECT
    [void][NativeWin]::GetClientRect($source, [ref]$cr)
    $srcW = $cr.Right; $srcH = $cr.Bottom
    if ($srcW -lt 100 -or $srcH -lt 100) { return $null }

    $wr = New-Object NativeWin+RECT
    [void][NativeWin]::GetWindowRect($source, [ref]$wr)
    $origEx = [NativeWin]::GetWindowLong($source, -20)
    $wasZoomed = [NativeWin]::IsZoomed($source)

    # Park the RAIL window off the visible desktop and keep it out of the taskbar.
    # A maximized window ignores SetWindowPos until it has finished restoring.
    if ($wasZoomed) {
        [void][NativeWin]::ShowWindow($source, 9)
        for ($i = 0; $i -lt 20 -and [NativeWin]::IsZoomed($source); $i++) {
            [System.Threading.Thread]::Sleep(25)
        }
    }
    $parkedEx = (($origEx -bor 0x00000080) -band (-bnot 0x00040000))
    [void][NativeWin]::SetWindowLong($source, -20, $parkedEx)
    [void][NativeWin]::SetWindowPos($source, [IntPtr]::Zero, 3000, 0, $srcW, $srcH, 0x0010)
    if ($wasZoomed) {
        [System.Threading.Thread]::Sleep(120)
        [void][NativeWin]::SetWindowPos($source, [IntPtr]::Zero, 3000, 0, $srcW, $srcH, 0x0010)
    }

    $w = @{}
    $w.Package = $app.Package
    $w.AppName = $app.Name
    $w.Source = $source
    $w.SrcW = $srcW
    $w.SrcH = $srcH
    $w.WasZoomed = $wasZoomed
    $w.OrigExStyle = (($origEx -bor 0x00040000) -band (-bnot 0x00000080))
    $w.OrigRect = $wr
    $w.Closed = $false
    $w.Settled = $false
    $w.LoadPhase = 0
    $w.LoadStart = [DateTime]::UtcNow
    $w.Frames = 0
    $w.DragX = 0; $w.DragY = 0; $w.DragT = [DateTime]::MinValue
    $w.LastMoveT = [DateTime]::MinValue

    $win = [System.Windows.Markup.XamlReader]::Parse($script:wrapperXaml)
    $win.Title = "$($app.Name) — Winoid"
    if ($null -ne $script:appIcon) { $win.Icon = $script:appIcon }
    $image = $win.FindName('View')
    $hint = $win.FindName('Hint')
    $loading = $win.FindName('Loading')
    $loadingText = $win.FindName('LoadingText')

    $wb = New-Object System.Windows.Media.Imaging.WriteableBitmap($srcW, $srcH, 96, 96, [System.Windows.Media.PixelFormats]::Bgr32, $null)
    $image.Source = $wb
    $grab = [FrameGrabber]::new($srcW, $srcH)

    $w.Window = $win
    $w.Image = $image
    $w.Hint = $hint
    $w.Loading = $loading
    $w.LoadingText = $loadingText
    $w.Wb = $wb
    $w.Grab = $grab
    $w.Rect = [System.Windows.Int32Rect]::new(0, 0, $srcW, $srcH)

    $image.Add_MouseLeftButtonDown({
        param($sender, $e)
        $w = $script:wrapByImage[$sender]
        if ($null -eq $w -or $w.Closed) { return }
        try {
            $p = Map-WrapperPoint $w $e.GetPosition($sender)
            if ($null -eq $p) { return }
            [NativeWin]::ForceForeground($w.Source)
            Send-Android "input motionevent DOWN $($p[0]) $($p[1])"
            $w.DragX = $p[0]; $w.DragY = $p[1]; $w.DragT = [DateTime]::UtcNow
            $w.Hint.Visibility = 'Collapsed'
            [void]$sender.CaptureMouse()
        } catch { }
    })
    $image.Add_MouseMove({
        param($sender, $e)
        $w = $script:wrapByImage[$sender]
        if ($null -eq $w -or $w.Closed) { return }
        try {
            if ($e.LeftButton -ne 'Pressed') { return }
            $p = Map-WrapperPoint $w $e.GetPosition($sender)
            if ($null -eq $p) { return }
            if ([math]::Abs($p[0] - $w.DragX) -lt 3 -and [math]::Abs($p[1] - $w.DragY) -lt 3) { return }
            $now = [DateTime]::UtcNow
            if (($now - $w.LastMoveT).TotalMilliseconds -lt 45) { return }
            $w.LastMoveT = $now
            $w.DragX = $p[0]; $w.DragY = $p[1]
            Send-Android "input motionevent MOVE $($p[0]) $($p[1])"
        } catch { }
    })
    $image.Add_MouseLeftButtonUp({
        param($sender, $e)
        $w = $script:wrapByImage[$sender]
        if ($null -eq $w -or $w.Closed) { return }
        try {
            $p = Map-WrapperPoint $w $e.GetPosition($sender)
            if ($null -eq $p) { return }
            Send-Android "input motionevent UP $($p[0]) $($p[1])"
            [void]$sender.ReleaseMouseCapture()
        } catch { }
    })
    $image.Add_MouseWheel({
        param($sender, $e)
        $w = $script:wrapByImage[$sender]
        if ($null -eq $w -or $w.Closed) { return }
        try {
            $p = Map-WrapperPoint $w $e.GetPosition($sender)
            if ($null -eq $p) { return }
            $dy = if ($e.Delta -gt 0) { -320 } else { 320 }
            Send-Android "input swipe $($p[0]) $($p[1]) $($p[0]) $($p[1] + $dy) 220"
        } catch { }
    })
    $win.Add_Activated({
        param($sender, $e)
        $w = $script:wrapByWindow[$sender]
        if ($null -eq $w -or $w.Closed) { return }
        $script:bounceWrap = $w
        $script:bounceTimer.Stop()
        $script:bounceTimer.Start()
    })
    $win.Add_Closing({
        param($sender, $e)
        $w = $script:wrapByWindow[$sender]
        if ($null -eq $w -or $w.Closed) { return }
        Remove-Wrapper $w $true
    })

    $script:wrapByImage[$image] = $w
    $script:wrapByWindow[$win] = $w
    [void]$script:wrappers.Add($w)

    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($null -ne $size) { $cw = $size.Width; $ch = $size.Height }
    else { $cw = $srcW; $ch = $srcH }
    $cw = [Math]::Min($cw, $wa.Width - 24)
    $ch = [Math]::Min($ch, $wa.Height - 64)
    $win.Width = $cw + 16
    $win.Height = $ch + 39
    $win.Show()
    $win.UpdateLayout()
    Focus-Wrapper $w
    try {
        $h = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle
        $wcr = New-Object NativeWin+RECT
        $wwr = New-Object NativeWin+RECT
        [void][NativeWin]::GetClientRect($h, [ref]$wcr)
        [void][NativeWin]::GetWindowRect($h, [ref]$wwr)
        $bw = ($wwr.Right - $wwr.Left) - $wcr.Right
        $bh = ($wwr.Bottom - $wwr.Top) - $wcr.Bottom
        $win.Width = $cw + $bw
        $win.Height = $ch + $bh
    } catch { }
    return $w
}

$script:bounceTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:bounceTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$script:bounceTimer.Add_Tick({
    try {
        $script:bounceTimer.Stop()
        $w = $script:bounceWrap
        if ($null -eq $w -or $w.Closed) { return }
        if ($w.Window.IsActive -and $w.Window.WindowState -ne 'Minimized' -and [System.Windows.Input.Mouse]::LeftButton -eq 'Released') {
            [NativeWin]::ForceForeground($w.Source)
        }
    } catch { }
})

$script:frameTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:frameTimer.Interval = [TimeSpan]::FromMilliseconds(40)
$script:frameTimer.Add_Tick({
    try {
        $list = $script:wrappers
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        for ($i = $list.Count - 1; $i -ge 0; $i--) {
            if ($i -ge $list.Count) { continue }
            $w = $list[$i]
            if ($w.Closed) { continue }
            if (-not [NativeWin]::IsWindow($w.Source)) { Remove-Wrapper $w $false; continue }
            if ([NativeWin]::IsIconic($w.Source)) {
                [void][NativeWin]::ShowWindow($w.Source, 9)
            }
            $sr = New-Object NativeWin+RECT
            [void][NativeWin]::GetWindowRect($w.Source, [ref]$sr)
            if ($sr.Left -lt $wa.Right -and $sr.Right -gt $wa.Left -and $sr.Top -lt $wa.Bottom -and $sr.Bottom -gt $wa.Top) {
                if ([NativeWin]::IsZoomed($w.Source)) { [void][NativeWin]::ShowWindow($w.Source, 9) }
                [void][NativeWin]::SetWindowPos($w.Source, [IntPtr]::Zero, 3000, 0, $w.SrcW, $w.SrcH, 0x0010)
            }
            if (-not $w.Window.IsVisible -or $w.Window.WindowState -eq 'Minimized') { continue }
            [void]$w.Grab.Capture($w.Source)
            $w.Wb.WritePixels($w.Rect, $w.Grab.Bits, $w.Grab.ByteSize, $w.Grab.Stride)
            $w.Frames++
            if (-not $w.Settled -and ($w.Frames % 8) -eq 0) {
                $elapsed = ([DateTime]::UtcNow - $w.LoadStart).TotalSeconds
                if ($elapsed -ge 1 -and $w.Grab.MeanLuma() -ge 8) {
                    $w.Settled = $true
                    $w.Loading.Visibility = 'Collapsed'
                } elseif ($elapsed -ge 45 -and $w.LoadPhase -lt 2) {
                    $w.LoadPhase = 2
                    $w.LoadingText.Text = 'Кадр не появился за 45 секунд. Приложение может быть несовместимо с Waydroid или ждать ответа сервера.'
                } elseif ($elapsed -ge 10 -and $w.LoadPhase -lt 1) {
                    $w.LoadPhase = 1
                    $w.LoadingText.Text = 'Приложение ещё загружается…'
                }
            }
        }
        if (([DateTime]::UtcNow - $script:adbCheckedAt).TotalSeconds -ge 5) {
            $script:adbCheckedAt = [DateTime]::UtcNow
            if ($null -eq $script:wslKeepAlive -or $script:wslKeepAlive.HasExited) { Start-WslKeepAlive }
            if ($null -eq $script:adb -or -not $script:adb.Running) {
                if ($script:adb) { try { $script:adb.Dispose() } catch { }; $script:adb = $null }
                if ($script:sessionRunning) { Initialize-Adb }
            }
            # WSLg restarts msrdc after a Weston crash. All RAIL windows die
            # with it, so tell the user how to bring Android windows back.
            $msrdc = @(Get-Process msrdc -ErrorAction SilentlyContinue)
            if ($msrdc.Count -gt 0) {
                if ($script:msrdcId -ne 0 -and $msrdc[0].Id -ne $script:msrdcId) {
                    Set-Footer 'Графика WSL перезапустилась. Нажмите «Перезапустить Android», чтобы вернуть окна Android.'
                }
                $script:msrdcId = $msrdc[0].Id
            }
        }
    } catch { }
})

$launchTimer = [System.Windows.Threading.DispatcherTimer]::new()
$launchTimer.Interval = [TimeSpan]::FromSeconds(1)
$launchTimer.Add_Tick({
    if (-not $script:launchState) { $launchTimer.Stop(); return }
    $st = $script:launchState
    $st.Ticks++
    $sec = $st.Ticks
    if ($sec -lt 60) { $loaderElapsed.Text = "$sec сек" } else { $loaderElapsed.Text = ('{0}:{1:00}' -f [int]($sec / 60), ($sec % 60)) }

    if ($sec -eq 5) { $loaderSub.Text = 'Приложение открывается…' }
    elseif ($sec -eq 25) { $loaderSub.Text = 'Окно пока не появилось. Если графика WSL зависла, нажмите «Перезапустить Android» в главном окне Winoid.' }
    elseif ($sec -eq 30) { $loaderSub.Text = 'Идёт первый запуск. Android распаковывает данные и транслирует ARM-код — это может занять несколько минут.' }
    elseif ($sec -eq 90) { $loaderSub.Text = 'Всё ещё загружается. Не закрывайте приложение; индикатор можно скрыть.' }

    $h = [NativeWin]::FindWindowContains($st.App.Name, 'Winoid')
    if ($h -ne [IntPtr]::Zero) {
        $st.Hwnd = $h
        if (-not $st.Wrapped) {
            $w = New-AppWrapper $st.App $h $st.Size
            if ($null -ne $w) {
                $st.Wrapped = $true
                Set-Footer "Окно «$($st.App.Name)» открыто."
            }
        }
        if ($st.Wrapped) {
            if ($autoHideCheck.IsChecked) {
                $loader.Hide()
                $launchTimer.Stop()
            } else {
                $loaderSub.Text = 'Окно открыто. Если оно чёрное — приложение ещё загружается; первый запуск может быть долгим.'
            }
        }
    }

    if ($sec -ge 900) {
        $loader.Hide()
        $launchTimer.Stop()
        Set-Footer 'Окно не появилось за 15 минут. Проверьте состояние Android.'
    }
})

function Start-AppLaunch($app) {
    if ($null -eq $app) { return }
    if (-not (Test-Backend)) {
        $backendBtn.Visibility = 'Visible'
        Set-Footer 'Waydroid не найден в WSL. Нажмите «Настроить Android» или откройте README.'
        return
    }
    $existing = Find-WrapperByPackage $app.Package
    if ($null -ne $existing) {
        Focus-Wrapper $existing
        Set-Footer "Окно «$($app.Name)» уже открыто."
        return
    }

    if ($app.Package -eq 'com.android.vending') {
        $answer = [System.Windows.MessageBox]::Show(
            $window,
            'Play Store в WSL2 иногда роняет графику WSL, и окна Android могут исчезнуть. Если это случится, нажмите «Перезапустить Android» в главном окне Winoid и попробуйте снова. Продолжить?',
            'Winoid — Play Store',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning,
            [System.Windows.MessageBoxResult]::No)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
            Set-Footer 'Play Store не запущен.'
            return
        }
    }

    $script:launchState = [pscustomobject]@{
        App = $app
        Ticks = 0
        Hwnd = [IntPtr]::Zero
        Wrapped = $false
        Size = Get-SelectedSize
    }

    $loaderTitle.Text = "Запуск: $($app.Name)"
    $loaderSub.Text = 'Открываю приложение в отдельном окне.'
    $loaderElapsed.Text = '0 сек'
    $loader.Show()
    $loaderBar.IsIndeterminate = $true
    $launchTimer.Start()
    Set-Footer "Запуск $($app.Name)…"

    $cmd = "export DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/`$(id -u); waydroid app launch $($app.Package)"
    Start-WslDetached ((Get-WslBase) + @('--', 'bash', '-lc', $cmd))
}

$installTimer = [System.Windows.Threading.DispatcherTimer]::new()
$installTimer.Interval = [TimeSpan]::FromSeconds(1)
$installTimer.Add_Tick({
    $script:installTicks++
    $sec = $script:installTicks
    if ($sec -lt 60) { $loaderElapsed.Text = "$sec сек" } else { $loaderElapsed.Text = ('{0}:{1:00}' -f [int]($sec / 60), ($sec % 60)) }
    if ($null -eq $script:installJob) { $installTimer.Stop(); return }
    if ($script:installJob.State -in @('Completed', 'Failed', 'Stopped')) {
        $out = @(Receive-Job -Job $script:installJob -ErrorAction SilentlyContinue) | Out-String
        Remove-Job -Job $script:installJob -Force -ErrorAction SilentlyContinue
        $script:installJob = $null
        $installTimer.Stop()
        $loader.Hide()
        Refresh-Apps
        $last = (($out -split "`r?`n") | Where-Object { $_.Trim().Length -gt 0 -and $_ -notmatch '^WINOID_INSTALL_EXIT=' } | Select-Object -Last 1)
        if ($out -match 'WINOID_INSTALL_EXIT=0') { Set-Footer 'APK установлен.' }
        elseif ($last) { Set-Footer "Установка не удалась: $last" }
        else { Set-Footer 'Установка не удалась. Подробности: %LOCALAPPDATA%\Winoid\install.log' }
    }
})

function Install-Apk([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { return }
    $apk = (Resolve-Path -LiteralPath $path).Path
    Initialize-Adb
    if (-not $script:adbPath) {
        Set-Footer 'ADB не найден. Установите platform-tools или положите adb.exe рядом с Winoid.ps1.'
        return
    }

    $script:installTicks = 0
    $loaderTitle.Text = 'Установка APK'
    $loaderSub.Text = "Отправляю $(Split-Path -Leaf $apk) в Android…"
    $loaderElapsed.Text = '0 сек'
    $loader.Show()
    $loaderBar.IsIndeterminate = $true
    Set-Footer 'Установка APK…'

    $jobAdb = $script:adbPath
    $jobSerial = $script:adbSerial
    $script:installJob = Start-Job -ScriptBlock {
        param($adbExe, $serial, $apkPath)
        $lines = New-Object System.Collections.ArrayList
        $out = & $adbExe -s $serial install -r $apkPath 2>&1
        $code = $LASTEXITCODE
        foreach ($l in @($out)) { [void]$lines.Add([string]$l) }
        [void]$lines.Add("install exit=$code")
        try {
            $logRoot = $script:dataRoot
            if (-not (Test-Path -LiteralPath $logRoot)) { New-Item -ItemType Directory -Path $logRoot -Force | Out-Null }
            Add-Content -LiteralPath (Join-Path $logRoot 'install.log') -Value (($lines -join "`r`n") + "`r`nWINOID_INSTALL_EXIT=$code") -Encoding UTF8
        } catch { }
        foreach ($l in $lines) { $l }
        "WINOID_INSTALL_EXIT=$code"
    } -ArgumentList $jobAdb, $jobSerial, $apk
    $installTimer.Start()
}

function ConvertTo-WslPath([string]$path) {
    $full = [System.IO.Path]::GetFullPath($path)
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        return '/mnt/' + $matches[1].ToLowerInvariant() + '/' + ($matches[2] -replace '\\', '/')
    }
    return ($full -replace '\\', '/')
}

function Convert-PngToIco([string]$pngPath, [string]$icoPath) {
    Add-Type -AssemblyName System.Drawing
    $src = [System.Drawing.Image]::FromFile($pngPath)
    try {
        $sizes = @(16, 24, 32, 48, 64, 128, 256)
        $pngs = New-Object System.Collections.Generic.List[byte[]]
        foreach ($s in $sizes) {
            $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $scale = [Math]::Min($s / $src.Width, $s / $src.Height)
            $w = [Math]::Max(1, [int][Math]::Round($src.Width * $scale))
            $h = [Math]::Max(1, [int][Math]::Round($src.Height * $scale))
            $x = [int](($s - $w) / 2)
            $y = [int](($s - $h) / 2)
            $g.DrawImage($src, $x, $y, $w, $h)
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $pngs.Add($ms.ToArray())
            $ms.Dispose(); $g.Dispose(); $bmp.Dispose()
        }

        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter $ms
        $bw.Write([UInt16]0)
        $bw.Write([UInt16]1)
        $bw.Write([UInt16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $s = $sizes[$i]
            $bw.Write([Byte]$(if ($s -ge 256) { 0 } else { $s }))
            $bw.Write([Byte]$(if ($s -ge 256) { 0 } else { $s }))
            $bw.Write([Byte]0)
            $bw.Write([Byte]0)
            $bw.Write([UInt16]1)
            $bw.Write([UInt16]32)
            $bw.Write([UInt32]$pngs[$i].Length)
            $bw.Write([UInt32]$offset)
            $offset += $pngs[$i].Length
        }
        foreach ($png in $pngs) { $bw.Write($png) }
        $bw.Flush()
        $dir = Split-Path -Parent $icoPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($icoPath, $ms.ToArray())
        $bw.Dispose(); $ms.Dispose()
    } finally {
        $src.Dispose()
    }
}

function Get-AppIconPath($app) {
    $generic = Join-Path $script:baseDir 'assets\android.ico'
    $dex = Join-Path $script:baseDir 'assets\winoid-icon.dex'
    if (-not (Test-Path -LiteralPath $dex)) { return $generic }

    $iconsDir = Join-Path $script:dataRoot 'icons'
    if (-not (Test-Path -LiteralPath $iconsDir)) { New-Item -ItemType Directory -Path $iconsDir -Force | Out-Null }
    $ico = Join-Path $iconsDir ($app.Package + '.ico')
    $remoteDex = '/data/local/tmp/winoid-icon.dex'
    $remotePng = '/data/local/tmp/winoid-icon-' + $app.Package + '.png'
    $localPng = Join-Path $env:TEMP ('winoid-icon-' + [Guid]::NewGuid().ToString('N') + '.png')
    $ok = $false

    # Windows ADB is preferred; WSL ADB is the fallback when a VPN swallows
    # the route to the Waydroid subnet.
    if ($script:adbPath) {
        try {
            $state = Invoke-AdbCli -Arguments @('-s', $script:adbSerial, 'get-state') -TimeoutMs 8000
            if ($state -notmatch '^device') {
                $null = Invoke-AdbCli -Arguments @('connect', $script:adbSerial) -TimeoutMs 12000
                $state = Invoke-AdbCli -Arguments @('-s', $script:adbSerial, 'get-state') -TimeoutMs 8000
            }
            if ($state -match '^device') {
                $null = Invoke-AdbCli -Arguments @('-s', $script:adbSerial, 'push', $dex, $remoteDex) -TimeoutMs 20000
                $cmd = "CLASSPATH=$remoteDex app_process /system/bin WinoidIcon $($app.Package) $remotePng"
                $res = Invoke-AdbCli -Arguments @('-s', $script:adbSerial, 'shell', $cmd) -TimeoutMs 25000
                if ($res -match 'OK') {
                    $null = Invoke-AdbCli -Arguments @('-s', $script:adbSerial, 'pull', $remotePng, $localPng) -TimeoutMs 20000
                    if (Test-Path -LiteralPath $localPng) { $ok = $true }
                }
            }
        } catch { }
    }

    if (-not $ok) {
        try {
            $stateArgs = (Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'get-state')
            $r = Invoke-Wsl $stateArgs 15000
            if ($r.Out -notmatch 'device') {
                $null = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', 'connect', $script:adbSerial)) 15000
                $r = Invoke-Wsl $stateArgs 15000
            }
            if ($r.Code -eq 0 -and $r.Out -match 'device') {
                $linuxDex = ConvertTo-WslPath $dex
                $linuxPng = ConvertTo-WslPath $localPng
                $null = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'push', $linuxDex, $remoteDex)) 20000
                $cmd = "CLASSPATH=$remoteDex app_process /system/bin WinoidIcon $($app.Package) $remotePng"
                $res = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'shell', $cmd)) 25000
                if ($res.Out -match 'OK') {
                    $null = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'pull', $remotePng, $linuxPng)) 20000
                    if (Test-Path -LiteralPath $localPng) { $ok = $true }
                }
            }
        } catch { }
    }

    if ($ok) {
        try {
            Convert-PngToIco $localPng $ico
            Remove-Item -LiteralPath $localPng -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $ico) { return $ico }
        } catch { }
    }
    Remove-Item -LiteralPath $localPng -Force -ErrorAction SilentlyContinue
    return $generic
}

function Update-AppShortcutIconAsync($app, [string]$lnkPath) {
    $generic = Join-Path $script:baseDir 'assets\android.ico'
    $dex = Join-Path $script:baseDir 'assets\winoid-icon.dex'
    $worker = Join-Path $script:baseDir 'assets\iconjob.ps1'
    if (-not (Test-Path -LiteralPath $dex) -or -not (Test-Path -LiteralPath $worker) -or -not (Test-Path -LiteralPath $lnkPath)) { return }
    $iconsDir = Join-Path $script:dataRoot 'icons'
    $ico = Join-Path $iconsDir ($app.Package + '.ico')

    try {
        $args = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $worker,
            '-Package', $app.Package,
            '-Serial', $script:adbSerial,
            '-WslExe', $script:wsl,
            '-Distro', $script:wslDistro,
            '-Dex', $dex,
            '-Ico', $ico,
            '-Lnk', $lnkPath,
            '-Generic', $generic
        )
        # Start-Process joins -ArgumentList with spaces and does not quote
        # paths, and the Winoid folder can contain spaces.
        $quoted = @($args | ForEach-Object { '"' + ([string]$_) + '"' })
        Start-Process -FilePath 'pwsh.exe' -ArgumentList $quoted -WindowStyle Hidden | Out-Null
    } catch { }
}

function New-AppShortcut($app) {
    if ($null -eq $app) { return }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $safe = ($app.Name -replace '[\\/:*?"<>|]', '_').Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = $app.Package }
    if ($safe.Length -gt 64) { $safe = $safe.Substring(0, 64).Trim() }

    $target = Join-Path $script:baseDir 'Winoid.cmd'
    $arguments = '-Launch "' + $app.Package + '"'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = Join-Path $desktop ($safe + '.lnk')
    if (Test-Path -LiteralPath $lnk) {
        try {
            $old = $shell.CreateShortcut($lnk)
            if ($old.TargetPath -ne $target) {
                $lnk = Join-Path $desktop ($safe + ' (' + $app.Package + ').lnk')
            }
        } catch { }
    }

    $generic = Join-Path $script:baseDir 'assets\android.ico'
    $sc = $shell.CreateShortcut($lnk)
    $sc.TargetPath = $target
    $sc.Arguments = $arguments
    $sc.WorkingDirectory = $script:baseDir
    if (Test-Path -LiteralPath $generic) { $sc.IconLocation = "$generic,0" }
    $sc.Description = "$($app.Name) — Android-приложение (Winoid)"
    $sc.Save()
    Set-Footer "Ярлык «$([System.IO.Path]::GetFileNameWithoutExtension($lnk))» создан. Обновляю иконку приложения…"
    Update-AppShortcutIconAsync $app $lnk
}

function Process-Requests {
    if (-not (Test-Path -LiteralPath $script:requestDir)) { return }
    $files = @(Get-ChildItem -LiteralPath $script:requestDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object CreationTime)
    foreach ($file in $files) {
        $req = $null
        try { $req = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { }
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        if ($null -eq $req) { continue }
        if (((Get-Date) - $file.CreationTime).TotalMinutes -gt 10) { continue }

        $target = [string]$req.target
        if ($req.action -eq 'install') {
            if ($target -and (Test-Path -LiteralPath $target)) { Install-Apk $target }
            else { Set-Footer 'Ярлык: APK-файл не найден.' }
            continue
        }

        $app = $script:apps | Where-Object { $_.Package -eq $target -or $_.Name -eq $target } | Select-Object -First 1
        if (-not $app) {
            Refresh-Apps
            $app = $script:apps | Where-Object { $_.Package -eq $target -or $_.Name -eq $target } | Select-Object -First 1
        }
        if ($app) { Start-AppLaunch $app }
        elseif ($target) { Set-Footer "Ярлык: приложение $target не найдено в Android." }
    }
}

$requestTimer = [System.Windows.Threading.DispatcherTimer]::new()
$requestTimer.Interval = [TimeSpan]::FromSeconds(1)
$requestTimer.Add_Tick({ Process-Requests })

$driveTimer = [System.Windows.Threading.DispatcherTimer]::new()
$driveTimer.Interval = [TimeSpan]::FromSeconds(2)
$driveTimer.Add_Tick({
    $driveTimer.Stop()
    Mount-AndroidDrive | Out-Null
})

$sessionTimer = [System.Windows.Threading.DispatcherTimer]::new()
$sessionTimer.Interval = [TimeSpan]::FromSeconds(2)
$sessionTimer.Add_Tick({
    $script:sessionTicks += 2
    $loaderElapsed.Text = "$($script:sessionTicks) сек"

    if (-not $script:sessionWaiting) {
        $state = $script:sessionJob.State
        if ($state -in @('Completed', 'Failed', 'Stopped')) {
            Receive-Job -Job $script:sessionJob -ErrorAction SilentlyContinue | Out-Null
            Remove-Job -Job $script:sessionJob -Force -ErrorAction SilentlyContinue
            $script:sessionJob = $null
            $script:sessionWaiting = $true
            $loaderSub.Text = 'Android загружается…'
        }
        return
    }

    if ((Get-WaydroidStatus) -eq 'RUNNING') {
        $sessionTimer.Stop()
        $loader.Hide()
        Test-Session | Out-Null
        Refresh-Apps
        Initialize-Adb
        Set-Footer 'Android запущен.'
        if ($script:pendingAndroidWindow) {
            $pending = $script:pendingAndroidWindow
            $script:pendingAndroidWindow = $null
            Start-AndroidWindow $pending.Package $pending.Title
        }
    } elseif ($script:sessionTicks -ge 90) {
        $sessionTimer.Stop()
        $loader.Hide()
        Test-Session | Out-Null
        Set-Footer 'Android не запустился за 90 секунд. Проверьте журнал Waydroid.'
    }
})

# Opens a standalone Android window (launcher or Settings). In Waydroid
# multi-window mode `show-full-ui` is a no-op, so the launcher is the
# closest thing to "Android as a whole" that still works.
function Start-AndroidWindow([string]$package, [string]$title) {
    if (-not (Test-Backend)) {
        $backendBtn.Visibility = 'Visible'
        Set-Footer 'Waydroid не найден в WSL. Нажмите «Настроить Android» или откройте README.'
        return
    }
    if (-not $script:sessionRunning) {
        $script:pendingAndroidWindow = [pscustomobject]@{ Package = $package; Title = $title }
        Start-Session
        return
    }
    $app = $script:apps | Where-Object { $_.Package -eq $package } | Select-Object -First 1
    if ($app) {
        Start-AppLaunch $app
        return
    }
    $cmd = "export DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/`$(id -u); waydroid app launch $package"
    Start-WslDetached ((Get-WslBase) + @('--', 'bash', '-lc', $cmd))
    Set-Footer "Открываю $title…"
}

function Start-Session {
    param([switch]$Restart)
    if (-not (Test-Backend)) {
        $backendBtn.Visibility = 'Visible'
        Set-Footer 'Waydroid не найден в WSL. Нажмите «Настроить Android» или откройте README.'
        return
    }
    $script:sessionTicks = 0
    $script:sessionWaiting = $false
    $loaderTitle.Text = $(if ($Restart) { 'Перезапуск Android' } else { 'Запуск Android' })
    $loaderSub.Text = $(if ($Restart) { 'Перезапускаю сессию Waydroid, чтобы окна снова подключились к графике WSL.' } else { 'Поднимаю контейнер и сессию Waydroid. Это займёт до минуты.' })
    $loaderElapsed.Text = '0 сек'
    $loader.Show()
    $loaderBar.IsIndeterminate = $true
    Set-Footer $(if ($Restart) { 'Перезапуск Android…' } else { 'Запуск Android…' })
    $jobWsl = $script:wsl
    $jobDistro = $script:wslDistro
    $action = $(if ($Restart) { 'restart' } else { 'start' })
    $script:sessionJob = Start-Job -ScriptBlock {
        param($wslExe, $distro, $verb)
        $wslArgs = @()
        if (-not [string]::IsNullOrWhiteSpace($distro)) { $wslArgs += @('-d', $distro) }
        & $wslExe @wslArgs -- bash -lc "systemctl --user $verb waydroid-session.service" 2>&1
    } -ArgumentList $jobWsl, $jobDistro, $action
    $sessionTimer.Start()
}

# --- events ---

$searchBox.Add_TextChanged({ Update-AppFilter })
$refreshBtn.Add_Click({
    Test-Session | Out-Null
    Refresh-Apps
})
$appsList.Add_SelectionChanged({
    $launchBtn.IsEnabled = ($null -ne $appsList.SelectedItem)
    $shortcutBtn.IsEnabled = ($null -ne $appsList.SelectedItem)
})
$appsList.Add_MouseDoubleClick({
    if ($null -ne $appsList.SelectedItem) { Start-AppLaunch $appsList.SelectedItem }
})
$launchBtn.Add_Click({ Start-AppLaunch $appsList.SelectedItem })
$shortcutBtn.Add_Click({ New-AppShortcut $appsList.SelectedItem })
$driveBtn.Add_Click({ Mount-AndroidDrive -Open | Out-Null })
$installBtn.Add_Click({
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Title = 'Выберите APK'
    $dlg.Filter = 'Android package (*.apk)|*.apk|Все файлы (*.*)|*.*'
    if ($dlg.ShowDialog($window) -eq $true) { Install-Apk $dlg.FileName }
})
$backendBtn.Add_Click({
    $setup = Join-Path $script:baseDir 'Setup-Backend.ps1'
    if (-not (Test-Path -LiteralPath $setup)) { $setup = Join-Path $script:baseDir 'installer\Setup-Backend.ps1' }
    if (Test-Path -LiteralPath $setup) {
        Start-Process -FilePath 'pwsh.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$setup`"" -WorkingDirectory $script:baseDir
        Set-Footer 'Открыл настройку Android в отдельном окне.'
    } else {
        Start-Process 'https://github.com/Sergey35853/winoid/blob/main/README.md#как-поднять-бэкенд'
        Set-Footer 'Открыл инструкцию по настройке бэкенда в браузере.'
    }
})
$fullUiBtn.Add_Click({
    Start-Session -Restart
})
$settingsBtn.Add_Click({
    Start-AndroidWindow 'com.android.settings' 'Настройки Android'
})
$showWindowBtn.Add_Click({
    if ($script:launchState) {
        $w = Find-WrapperByPackage $script:launchState.App.Package
        if ($null -ne $w) { Focus-Wrapper $w }
    }
    $loader.Hide()
})
$hideLoaderBtn.Add_Click({
    $loader.Hide()
    $launchTimer.Stop()
    Set-Footer 'Индикатор скрыт. Приложение продолжает запускаться.'
})
$window.Add_Drop({
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $files = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
        foreach ($f in $files) {
            if ($f -like '*.apk') { Install-Apk $f; break }
        }
    }
})
$window.Add_Closing({
    $launchTimer.Stop()
    $installTimer.Stop()
    $sessionTimer.Stop()
    $requestTimer.Stop()
    $driveTimer.Stop()
    try { Disconnect-AndroidDrive } catch { }
    $script:frameTimer.Stop()
    $script:bounceTimer.Stop()
    foreach ($w in @($script:wrappers)) {
        Restore-Source $w
        $w.Closed = $true
        try { $w.Grab.Dispose() } catch { }
        try { $w.Window.Close() } catch { }
    }
    if ($script:adb) { try { $script:adb.Dispose() } catch { }; $script:adb = $null }
    if ($script:installJob) { Remove-Job -Job $script:installJob -Force -ErrorAction SilentlyContinue }
    if ($script:sessionJob) { Remove-Job -Job $script:sessionJob -Force -ErrorAction SilentlyContinue }
    if ($script:wslKeepAlive) {
        try { if (-not $script:wslKeepAlive.HasExited) { $script:wslKeepAlive.Kill() } } catch { }
        try { $script:wslKeepAlive.Dispose() } catch { }
        $script:wslKeepAlive = $null
    }
})
$window.Add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
$window.Add_Loaded({
    Start-WslKeepAlive
    if (-not (Test-Session)) { Start-Session }
    Refresh-Apps
    Initialize-Adb
    $driveTimer.Start()
    if ($Install) { Install-Apk $Install }
    if ($Launch) {
        $app = $script:apps | Where-Object { $_.Package -eq $Launch -or $_.Name -eq $Launch } | Select-Object -First 1
        if ($app) { Start-AppLaunch $app }
    }
})
$loader.Add_Closing({ $_.Cancel = $true; $loader.Hide() })

$script:frameTimer.Start()
$requestTimer.Start()
$window.Show()
[System.Windows.Threading.Dispatcher]::Run()
