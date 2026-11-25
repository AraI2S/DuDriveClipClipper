# Baidu Pan Clipboard Cleaner v1.0.0
# Windows PowerShell 5.1, .NET Framework 4.x, Windows 10/11
# Start using Start.vbs for a windowless background tray application.
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'

# A named mutex prevents two instances from fighting over the clipboard.
$mutex = $null
$ownsMutex = $false
try {
    if (-not $SelfTest) {
        $mutex = [System.Threading.Mutex]::new($true, 'Local\BaiduPanClipboardCleaner_v1_0', [ref]$ownsMutex)
        if (-not $ownsMutex) { return }
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace BaiduPanClipboardCleaner
{
    internal static class Win32
    {
        internal const int WM_CLIPBOARDUPDATE = 0x031D;

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool AddClipboardFormatListener(IntPtr hwnd);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

        [DllImport("user32.dll")]
        internal static extern uint GetClipboardSequenceNumber();

        [DllImport("user32.dll", EntryPoint = "SetProcessDpiAwarenessContext", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);
    }

    public static class Cleaner
    {
        // Deliberately match only the Baidu Pan /s/ share URL form, never similar-looking domains.
        // A share ID begins with '1' and is at least eight URL-safe characters long.
        private static readonly Regex LinkPattern = new Regex(
            @"(?<![A-Za-z0-9_.@/-])(?:https?://)?(?:www\.)?pan\.baidu\.com/s/(?<id>1[A-Za-z0-9_-]{7,79})(?![A-Za-z0-9_-])(?:\?(?<query>[A-Za-z0-9._~%=&+\-]*))?",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

        private static readonly Regex QueryCodePattern = new Regex(
            @"(?:^|&)pwd=(?<code>[A-Za-z0-9]{1,16})(?=$|[&.,;])",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

        private static readonly Regex QueryCodeKeyPattern = new Regex(
            @"(?:^|&)pwd=", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

        private static readonly Regex DescriptionCodePattern = new Regex(
            @"(?:提取码|提取密码|访问码|访问密码)\s*[:：]\s*(?<code>[A-Za-z0-9]{4,8})(?![A-Za-z0-9])",
            RegexOptions.CultureInvariant | RegexOptions.Compiled);

        // Return null to mean "leave the clipboard untouched".
        public static string Normalize(string input)
        {
            if (String.IsNullOrEmpty(input) || input.Length > 65536) return null;

            MatchCollection links = LinkPattern.Matches(input);
            // Choosing one link out of several would silently lose data.
            if (links.Count != 1) return null;

            Match link = links[0];
            string id = link.Groups["id"].Value;
            string query = link.Groups["query"].Success ? link.Groups["query"].Value : String.Empty;

            MatchCollection queryCodes = QueryCodePattern.Matches(query);
            MatchCollection queryCodeKeys = QueryCodeKeyPattern.Matches(query);
            if (queryCodeKeys.Count > 1) return null;
            // Avoid removing an unrecognized or malformed existing password.
            if (queryCodeKeys.Count == 1 && queryCodes.Count != 1) return null;

            string urlCode = queryCodes.Count == 1 ? queryCodes[0].Groups["code"].Value : null;

            MatchCollection descriptionCodes = DescriptionCodePattern.Matches(input);
            string descriptionCode = null;
            foreach (Match item in descriptionCodes)
            {
                string code = item.Groups["code"].Value;
                if (descriptionCode != null && !String.Equals(descriptionCode, code, StringComparison.Ordinal))
                    return null;
                descriptionCode = code;
            }

            // If link and description disagree, do not guess which one is right.
            if (urlCode != null && descriptionCode != null &&
                !String.Equals(urlCode, descriptionCode, StringComparison.Ordinal)) return null;

            string password = urlCode ?? descriptionCode;
            string result = "pan.baidu.com/s/" + id;
            if (!String.IsNullOrEmpty(password)) result += "?pwd=" + password;

            return String.Equals(result, input, StringComparison.Ordinal) ? null : result;
        }
    }

    internal sealed class ClipboardWindow : NativeWindow, IDisposable
    {
        public event EventHandler Changed;
        private bool registered;

        public ClipboardWindow()
        {
            CreateParams cp = new CreateParams();
            cp.Caption = "BaiduPanClipboardCleaner Message Window";
            CreateHandle(cp);

            if (!Win32.AddClipboardFormatListener(Handle))
            {
                int code = Marshal.GetLastWin32Error();
                DestroyHandle();
                throw new Win32Exception(code, "Cannot register clipboard listener");
            }
            registered = true;
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Win32.WM_CLIPBOARDUPDATE)
            {
                EventHandler handler = Changed;
                if (handler != null) handler(this, EventArgs.Empty);
                m.Result = IntPtr.Zero;
                return;
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (registered)
            {
                Win32.RemoveClipboardFormatListener(Handle);
                registered = false;
            }
            if (Handle != IntPtr.Zero) DestroyHandle();
        }
    }

    public sealed class TrayApp : ApplicationContext
    {
        private readonly ClipboardWindow listener;
        private readonly Timer timer;
        private readonly NotifyIcon icon;
        private readonly ContextMenuStrip menu;
        private readonly ToolStripMenuItem pauseItem;
        private bool paused;
        private int retries;

        public TrayApp()
        {
            listener = new ClipboardWindow();
            listener.Changed += OnClipboardChanged;

            timer = new Timer();
            timer.Interval = 60;
            timer.Tick += OnTimerTick;

            menu = new ContextMenuStrip();
            pauseItem = new ToolStripMenuItem("暂停自动清理");
            pauseItem.Click += OnTogglePause;
            menu.Items.Add(pauseItem);

            ToolStripMenuItem cleanNowItem = new ToolStripMenuItem("立即清理当前剪贴板");
            cleanNowItem.Click += OnCleanNow;
            menu.Items.Add(cleanNowItem);
            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem exitItem = new ToolStripMenuItem("退出");
            exitItem.Click += OnExit;
            menu.Items.Add(exitItem);

            icon = new NotifyIcon();
            icon.Icon = SystemIcons.Information;
            icon.ContextMenuStrip = menu;
            icon.Text = "百度网盘剪贴板清理（运行中）";
            icon.Visible = true;

            // Also normalize a matching item already on the clipboard when launched.
            Schedule();
        }

        private void OnClipboardChanged(object sender, EventArgs e)
        {
            if (!paused) Schedule();
        }

        private void Schedule()
        {
            retries = 0;
            timer.Stop();
            timer.Interval = 60;
            timer.Start();
        }

        private void Retry()
        {
            retries++;
            if (retries < 8)
            {
                timer.Interval = 110;
                timer.Start();
            }
        }

        private void OnTimerTick(object sender, EventArgs e)
        {
            timer.Stop();
            if (!paused) TryClean();
        }

        private void TryClean()
        {
            try
            {
                uint before = Win32.GetClipboardSequenceNumber();
                string input = Clipboard.GetText();
                uint after = Win32.GetClipboardSequenceNumber();

                if (before != 0 && after != 0 && before != after)
                {
                    Retry();
                    return;
                }

                string output = Cleaner.Normalize(input);
                if (output == null) return;

                // Avoid overwriting a newer clipboard item during this operation.
                uint current = Win32.GetClipboardSequenceNumber();
                if (after != 0 && current != 0 && current != after)
                {
                    Retry();
                    return;
                }

                Clipboard.SetText(output, TextDataFormat.UnicodeText);
                // The ensuing clipboard notification is harmless: normalized text is unchanged.
            }
            catch (ExternalException)
            {
                // Clipboard temporarily owned/locked by another application.
                Retry();
            }
        }

        private void OnTogglePause(object sender, EventArgs e)
        {
            paused = !paused;
            pauseItem.Checked = paused;
            icon.Text = paused ? "百度网盘剪贴板清理（已暂停）" : "百度网盘剪贴板清理（运行中）";
            timer.Stop();
            if (!paused) Schedule();
        }

        private void OnCleanNow(object sender, EventArgs e)
        {
            retries = 0;
            timer.Stop();
            TryClean();
        }

        private void OnExit(object sender, EventArgs e)
        {
            ExitThread();
        }

        protected override void ExitThreadCore()
        {
            timer.Stop();
            timer.Dispose();
            listener.Dispose();
            icon.Visible = false;
            icon.Dispose();
            menu.Dispose();
            base.ExitThreadCore();
        }
    }

    public static class Program
    {
        public static void Start()
        {
            // Per-monitor V2; older Windows versions may not support this API.
            try { Win32.SetProcessDpiAwarenessContext(new IntPtr(-4)); }
            catch (EntryPointNotFoundException) { }
            catch (DllNotFoundException) { }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayApp());
        }
    }
}
'@

    Add-Type -TypeDefinition $source -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -ErrorAction Stop

    if ($SelfTest) {
        $tests = @(
            @{ Name='样例1：链接自带提取码'; Input="通过网盘分享的文件：【海报文件】`n链接: https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD 提取码: ABCD `n--来自百度网盘超级会员v10的分享"; Expected='pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD' },
            @{ Name='样例2：文字中的提取码'; Input="通过网盘分享的文件：【海报文件】`n链接: https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA 提取码: ABCD `n--来自百度网盘超级会员v10的分享"; Expected='pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA?pwd=ABCD' },
            @{ Name='纯链接也能清理'; Input='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD'; Expected='pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD' },
            @{ Name='去除额外查询参数'; Input='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?from=share&pwd=ABCD&foo=bar'; Expected='pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD' },
            @{ Name='全角冒号'; Input='链接：https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA 提取码：a1B2'; Expected='pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA?pwd=a1B2' },
            @{ Name='缺少提取码仍保留链接'; Input='链接: https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA'; Expected='pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA' },
            @{ Name='已规范化的链接不再改写'; Input='pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD'; Expected='pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD' },
            @{ Name='普通文字完全保留'; Input='今天收到了海报设计稿'; Expected='今天收到了海报设计稿' },
            @{ Name='其它网站完全保留'; Input='https://example.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD'; Expected='https://example.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD' },
            @{ Name='伪造的相似域名不处理'; Input='https://pan.baidu.com.evil.org/s/19xSckhDr5Fn4mZXUjHMqww'; Expected='https://pan.baidu.com.evil.org/s/19xSckhDr5Fn4mZXUjHMqww' },
            @{ Name='多个分享链接：避免丢数据'; Input='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww 和 https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA'; Expected='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww 和 https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA' },
            @{ Name='提取码冲突：避免猜测'; Input='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD 提取码: WXYZ'; Expected='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD 提取码: WXYZ' },
            @{ Name='提取码不规范：不丢弃原密码'; Input='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=%2B%2B'; Expected='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=%2B%2B' },
            @{ Name='完整中文标点'; Input='（https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA，提取码：ABCD。）'; Expected='pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA?pwd=ABCD' }
        )
        $passed = 0
        foreach ($case in $tests) {
            $normalized = [BaiduPanClipboardCleaner.Cleaner]::Normalize($case.Input)
            $actual = if ($null -eq $normalized) { $case.Input } else { $normalized }
            if ($actual -ceq $case.Expected) {
                Write-Host ("[PASS] " + $case.Name)
                $passed++
            } else {
                Write-Host ("[FAIL] " + $case.Name) -ForegroundColor Red
                Write-Host ("  Actual: " + $actual)
                Write-Host ("  Expect: " + $case.Expected)
            }
        }
        Write-Host "`nTests: $passed / $($tests.Count) passed"
        if ($passed -ne $tests.Count) { exit 1 }
        exit 0
    }

    [BaiduPanClipboardCleaner.Program]::Start()
}
catch {
    $details = $_.Exception.ToString()
    if ($SelfTest) {
        Write-Host $details -ForegroundColor Red
        exit 1
    }
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "百度网盘剪贴板清理启动失败：`r`n`r`n$details",
            '百度网盘剪贴板清理',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch { }
}
finally {
    if ($ownsMutex -and $null -ne $mutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
