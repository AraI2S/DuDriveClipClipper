# Baidu Pan Clipboard Cleaner v1.0.1
# Windows PowerShell 5.1, .NET Framework 4.x, Windows 10/11
# Start using Start.vbs for a windowless background tray application.
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'

# Reuse the v1.0.0 mutex so old and new versions cannot run together.
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
using System.Diagnostics;
using System.Threading.Tasks;
using System.Text;
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

    // Native clipboard transaction: check the sequence while holding the clipboard lock.
    // Preallocate both strings before clearing the clipboard; restore original on write failure.
    internal static class NativeClipboard
    {
        private const uint UnicodeText = 13;
        private const uint Moveable = 2;
        [DllImport("user32.dll", SetLastError = true)] private static extern bool OpenClipboard(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool CloseClipboard();
        [DllImport("user32.dll", SetLastError = true)] private static extern bool EmptyClipboard();
        [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetClipboardData(uint format, IntPtr data);
        [DllImport("user32.dll")] private static extern IntPtr GetClipboardData(uint format);
        [DllImport("user32.dll")] private static extern bool IsClipboardFormatAvailable(uint format);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterClipboardFormat(string name);
        [DllImport("user32.dll")] private static extern IntPtr GetClipboardOwner();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalLock(IntPtr mem);
        [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(IntPtr mem);
        [DllImport("kernel32.dll")] private static extern IntPtr GlobalFree(IntPtr mem);
        [DllImport("kernel32.dll")] private static extern UIntPtr GlobalSize(IntPtr mem);
        private static readonly uint History = RegisterClipboardFormat("CanIncludeInClipboardHistory");
        private static readonly uint Cloud = RegisterClipboardFormat("CanUploadToCloudClipboard");
        private static readonly uint Exclude = RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
        private static readonly uint Ignore = RegisterClipboardFormat("Clipboard Viewer Ignore");

        private static bool Denies(uint format)
        {
            if (format == 0 || !IsClipboardFormatAvailable(format)) return false;
            IntPtr h = GetClipboardData(format);
            if (h == IntPtr.Zero || GlobalSize(h).ToUInt64() < 4) return true;
            IntPtr ptr = GlobalLock(h);
            if (ptr == IntPtr.Zero) return true;
            try { return Marshal.ReadInt32(ptr) != 1; }
            finally { GlobalUnlock(h); }
        }
        private static bool Excluded()
        {
            return (Exclude != 0 && IsClipboardFormatAvailable(Exclude)) ||
                   (Ignore != 0 && IsClipboardFormatAvailable(Ignore)) || Denies(History);
        }
        internal static bool HistoryOwner()
        {
            IntPtr owner = GetClipboardOwner();
            if (owner == IntPtr.Zero) return false;
            uint pid;
            GetWindowThreadProcessId(owner, out pid);
            if (pid == 0) return false;
            try
            {
                using (Process p = Process.GetProcessById((int)pid))
                {
                    string name = p.ProcessName.ToLowerInvariant();
                    return name == "textinputhost" || name == "shellexperiencehost" ||
                           name == "clipboard" || name == "clipboardsvc" ||
                           name == "windowsinternal.composableshell.experiences.textinput.inputapp" ||
                           name == "svchost" || name == "explorer" || name == "inputapp";
                }
            }
            catch { return false; }
        }
        internal static bool Eligible(IntPtr hwnd, uint sequence)
        {
            if (!OpenClipboard(hwnd)) throw new ExternalException("Clipboard busy");
            try { return Win32.GetClipboardSequenceNumber() == sequence && !Excluded(); }
            finally { CloseClipboard(); }
        }
        private static IntPtr Allocate(byte[] bytes)
        {
            IntPtr mem = GlobalAlloc(Moveable, new UIntPtr((uint)bytes.Length));
            if (mem == IntPtr.Zero) throw new ExternalException("Clipboard allocation failed");
            IntPtr ptr = GlobalLock(mem);
            if (ptr == IntPtr.Zero) { GlobalFree(mem); throw new ExternalException("Clipboard lock failed"); }
            try { Marshal.Copy(bytes, 0, ptr, bytes.Length); }
            finally { GlobalUnlock(mem); }
            return mem;
        }
        private static bool Transfer(uint format, ref IntPtr h)
        {
            if (format == 0 || h == IntPtr.Zero || SetClipboardData(format, h) == IntPtr.Zero) return false;
            h = IntPtr.Zero; // ownership transferred to Windows
            return true;
        }
        private static void Free(IntPtr h) { if (h != IntPtr.Zero) GlobalFree(h); }
        internal static bool Replace(IntPtr hwnd, uint expected, string original, string text, bool restore, out uint writtenSequence)
        {
            writtenSequence = 0;
            IntPtr data = IntPtr.Zero, backup = IntPtr.Zero, history = IntPtr.Zero, cloud = IntPtr.Zero;
            try
            {
                data = Allocate(Encoding.Unicode.GetBytes(text + "\0"));
                backup = Allocate(Encoding.Unicode.GetBytes(original + "\0"));
                history = Allocate(BitConverter.GetBytes(restore ? 0 : 1));
                cloud = Allocate(BitConverter.GetBytes(0));
                if (!OpenClipboard(hwnd)) throw new ExternalException("Clipboard busy");
                try
                {
                    if (Win32.GetClipboardSequenceNumber() != expected || (!restore && Excluded())) return false;
                    bool noCloud = restore || Denies(Cloud);
                    // Reading delayed formats can change the sequence: check again under lock.
                    if (Win32.GetClipboardSequenceNumber() != expected) return false;
                    if (!EmptyClipboard()) throw new ExternalException("Clipboard clear failed");
                    if (!Transfer(UnicodeText, ref data))
                    {
                        Transfer(UnicodeText, ref backup);
                        if (noCloud) Transfer(Cloud, ref cloud);
                        throw new ExternalException("Clipboard write failed");
                    }
                    Transfer(History, ref history);
                    if (noCloud) Transfer(Cloud, ref cloud);
                    writtenSequence = Win32.GetClipboardSequenceNumber();
                    return true;
                }
                finally { CloseClipboard(); }
            }
            finally { Free(data); Free(backup); Free(history); Free(cloud); }
        }
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
            string result = "https://pan.baidu.com/s/" + id;
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
        private bool manual;
        private int retries;
        private readonly Func<bool> historyEnabled;
        private readonly Func<Task> beginHistory;
        private readonly Func<Task, Task> beginTopText;
        private Task historyTask;
        private int phase;
        private uint sequence, handledSequence;
        private string pendingInput, pendingOutput, lastOriginal;
        private long deadline;
        private bool warned;
        private readonly ToolStripMenuItem restoreItem;
        private readonly ToolStripMenuItem statusItem;

        public TrayApp(Func<bool> enabled, Func<Task> history, Func<Task, Task> topText)
        {
            historyEnabled = enabled; beginHistory = history; beginTopText = topText;
            timer = new Timer();
            timer.Interval = 35;
            timer.Tick += OnTimerTick;
            listener = new ClipboardWindow();
            listener.Changed += OnClipboardChanged;

            menu = new ContextMenuStrip();
            statusItem = new ToolStripMenuItem("等待复制百度网盘分享文本");
            statusItem.Enabled = false;
            menu.Items.Add(statusItem);
            menu.Items.Add(new ToolStripSeparator());
            pauseItem = new ToolStripMenuItem("暂停自动清理");
            pauseItem.Click += OnTogglePause;
            menu.Items.Add(pauseItem);
            ToolStripMenuItem cleanNowItem = new ToolStripMenuItem("立即清理当前剪贴板");
            cleanNowItem.Click += OnCleanNow;
            menu.Items.Add(cleanNowItem);
            restoreItem = new ToolStripMenuItem("恢复上次清理前的原文");
            restoreItem.Enabled = false;
            restoreItem.Click += OnRestore;
            menu.Items.Add(restoreItem);
            menu.Items.Add(new ToolStripSeparator());
            ToolStripMenuItem exitItem = new ToolStripMenuItem("退出");
            exitItem.Click += OnExit;
            menu.Items.Add(exitItem);
            icon = new NotifyIcon();
            icon.Icon = SystemIcons.Information;
            icon.ContextMenuStrip = menu;
            icon.Text = "百度网盘剪贴板清理（运行中）";
            icon.Visible = true;
            // Only react to new copies; do not destroy a restored history item at startup.
        }

        private void OnClipboardChanged(object sender, EventArgs e)
        {
            uint now = Win32.GetClipboardSequenceNumber();
            if (paused || now == handledSequence || (phase != 0 && now == sequence)) return;
            Schedule(false);
        }

        private void Schedule(bool force)
        {
            timer.Stop();
            historyTask = null;
            pendingInput = pendingOutput = null;
            sequence = Win32.GetClipboardSequenceNumber();
            phase = 1;
            manual = force;
            retries = 0;
            deadline = Stopwatch.GetTimestamp() + Stopwatch.Frequency * 3;
            Later(35);
        }
        private void Later(int ms) { timer.Stop(); timer.Interval = ms; timer.Start(); }
        private void Finish(string status)
        {
            timer.Stop();
            handledSequence = sequence;
            phase = 0;
            historyTask = null;
            pendingInput = pendingOutput = null;
            if (status != null) statusItem.Text = status;
        }
        private void Preserve(string status)
        {
            Finish(status);
            if (!warned)
            {
                warned = true;
                icon.ShowBalloonTip(3000, "原文已保留", status + "。请确认 Win+V 剪贴板历史已开启。", ToolTipIcon.Info);
            }
        }
        private bool Expired() { return Stopwatch.GetTimestamp() >= deadline; }
        private void StartHistoryQuery()
        {
            historyTask = beginHistory();
            phase = 2;
            Later(25);
        }
        private void OnTimerTick(object sender, EventArgs e)
        {
            timer.Stop();
            if (phase == 0 || (paused && !manual)) return;
            if (Win32.GetClipboardSequenceNumber() != sequence) { Schedule(manual && paused); return; }
            if (Expired()) { Preserve("未确认原文已进入历史，未清理"); return; }
            try
            {
                if (phase == 1)
                {
                    // Win+V selections commonly come from these Windows shell processes.
                    // Preserve them so selecting the original can actually paste the original.
                    if (!manual && NativeClipboard.HistoryOwner()) { Finish(null); return; }
                    string input = Clipboard.GetText();
                    if (Win32.GetClipboardSequenceNumber() != sequence) { Schedule(manual && paused); return; }
                    string output = Cleaner.Normalize(input);
                    if (output == null) { Finish(null); return; }
                    if (!NativeClipboard.Eligible(listener.Handle, sequence)) { Finish(null); return; }
                    pendingInput = input; pendingOutput = output;
                    if (!historyEnabled()) { Preserve("剪贴板历史未开启或不可用，未清理"); return; }
                    StartHistoryQuery();
                    return;
                }
                if (phase == 2 || phase == 3)
                {
                    if (historyTask == null) { Preserve("无法访问剪贴板历史，未清理"); return; }
                    if (!historyTask.IsCompleted) { Later(25); return; }
                    if (historyTask.IsFaulted || historyTask.IsCanceled)
                    {
                        // Observe the exception; never replace unconfirmed original data.
                        var ignored = historyTask.Exception;
                        Preserve("读取剪贴板历史失败，未清理"); return;
                    }
                    if (phase == 2)
                    {
                        historyTask = beginTopText(historyTask);
                        if (historyTask == null) { phase = 4; Later(75); return; }
                        phase = 3; Later(25); return;
                    }
                    string top = ((Task<string>)historyTask).Result;
                    if (!String.Equals(top, pendingInput, StringComparison.Ordinal))
                    { phase = 4; historyTask = null; Later(75); return; }
                    phase = 5;
                }
                if (phase == 4) { StartHistoryQuery(); return; }
                if (phase == 5)
                {
                    uint written;
                    if (NativeClipboard.Replace(listener.Handle, sequence, pendingInput, pendingOutput, false, out written))
                    {
                        lastOriginal = pendingInput;
                        restoreItem.Enabled = true;
                        warned = false;
                        sequence = written;
                        Finish("已清理；原文已确认进入历史");
                    }
                    else { Finish(null); }
                }
            }
            catch (ExternalException)
            {
                if (++retries < 12) Later(75);
                else Preserve("剪贴板暂时不可访问，未清理");
            }
            catch (Exception)
            {
                Preserve("历史访问或剪贴板处理失败，未清理");
            }
        }

        private void OnTogglePause(object sender, EventArgs e)
        {
            paused = !paused;
            pauseItem.Checked = paused;
            icon.Text = paused ? "百度网盘剪贴板清理（已暂停）" : "百度网盘剪贴板清理（运行中）";
            timer.Stop(); phase = 0; historyTask = null; pendingInput = pendingOutput = null;
        }
        private void OnCleanNow(object sender, EventArgs e) { Schedule(true); }
        private void OnRestore(object sender, EventArgs e)
        {
            if (lastOriginal == null) return;
            timer.Stop(); phase = 0; historyTask = null; pendingInput = pendingOutput = null;
            try
            {
                uint before = Win32.GetClipboardSequenceNumber();
                string current = Clipboard.GetText();
                uint written;
                if (NativeClipboard.Replace(listener.Handle, before, current, lastOriginal, true, out written))
                { handledSequence = written; statusItem.Text = "已恢复上次原文（不会自动重新清理）"; }
            }
            catch { statusItem.Text = "恢复失败，请从 Win+V 选择原文"; }
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
        public static void Start(Func<bool> enabled, Func<Task> history, Func<Task, Task> topText)
        {
            // Per-monitor V2; older Windows versions may not support this API.
            try { Win32.SetProcessDpiAwarenessContext(new IntPtr(-4)); }
            catch (EntryPointNotFoundException) { }
            catch (DllNotFoundException) { }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayApp(enabled, history, topText));
        }
    }
}
'@

    Add-Type -TypeDefinition $source -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll') -ErrorAction Stop

    if ($SelfTest) {
        $tests = @(
            @{ Name='样例1：链接自带提取码'; Input="通过网盘分享的文件：【海报文件】`n链接: https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD 提取码: ABCD `n--来自百度网盘超级会员v10的分享"; Expected='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD' },
            @{ Name='样例2：文字中的提取码'; Input="通过网盘分享的文件：【海报文件】`n链接: https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA 提取码: ABCD `n--来自百度网盘超级会员v10的分享"; Expected='https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA?pwd=ABCD' },
            @{ Name='完整 HTTPS 链接保持不变'; Input='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD'; Expected='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD' },
            @{ Name='去除额外查询参数'; Input='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?from=share&pwd=ABCD&foo=bar'; Expected='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD' },
            @{ Name='全角冒号'; Input='链接：https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA 提取码：a1B2'; Expected='https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA?pwd=a1B2' },
            @{ Name='缺少提取码仍保留链接'; Input='链接: https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA'; Expected='https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA' },
            @{ Name='已规范化的链接不再改写'; Input='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD'; Expected='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD' },
            @{ Name='普通文字完全保留'; Input='今天收到了海报设计稿'; Expected='今天收到了海报设计稿' },
            @{ Name='其它网站完全保留'; Input='https://example.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD'; Expected='https://example.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD' },
            @{ Name='伪造的相似域名不处理'; Input='https://pan.baidu.com.evil.org/s/19xSckhDr5Fn4mZXUjHMqww'; Expected='https://pan.baidu.com.evil.org/s/19xSckhDr5Fn4mZXUjHMqww' },
            @{ Name='多个分享链接：避免丢数据'; Input='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww 和 https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA'; Expected='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww 和 https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA' },
            @{ Name='提取码冲突：避免猜测'; Input='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD 提取码: WXYZ'; Expected='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD 提取码: WXYZ' },
            @{ Name='提取码不规范：不丢弃原密码'; Input='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=%2B%2B'; Expected='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=%2B%2B' },
            @{ Name='完整中文标点'; Input='（https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA，提取码：ABCD。）'; Expected='https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA?pwd=ABCD' }
        )
        $tests += @{ Name='无协议链接补 HTTPS'; Input='pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD'; Expected='https://pan.baidu.com/s/19xSckhDr5Fn4mZXUjHMqww?pwd=ABCD' }
        $tests += @{ Name='HTTP 链接升级 HTTPS'; Input='http://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA'; Expected='https://pan.baidu.com/s/1SILi2vdp1fWqd1vQAMjZBA' }
        $passed = 0
        foreach ($case in $tests) {
            $normalized = [BaiduPanClipboardCleaner.Cleaner]::Normalize($case.Input)
            $actual = if ($null -eq $normalized) { $case.Input } else { $normalized }
            if ($actual -ceq $case.Expected -and ($case.Input -cne $case.Expected -or $null -eq $normalized)) {
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

    # WinRT projections are supplied by Windows PowerShell 5.1 / .NET Framework.
    # The delegates run on the same STA message-loop thread; asynchronous Tasks are
    # polled by the WinForms timer, never synchronously waited on in that thread.
    $script:historyApiAvailable = $false
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.ApplicationModel.DataTransfer.Clipboard, Windows.ApplicationModel.DataTransfer, ContentType=WindowsRuntime]
        $null = [Windows.ApplicationModel.DataTransfer.ClipboardHistoryItemsResult, Windows.ApplicationModel.DataTransfer, ContentType=WindowsRuntime]
        $script:asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and
            $_.GetGenericArguments().Length -eq 1 -and $_.GetParameters().Length -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        } | Select-Object -First 1
        if ($null -ne $script:asTask) { $script:historyApiAvailable = $true }
    } catch { }
    $enabled = [Func[bool]] {
        if (-not $script:historyApiAvailable) { return $false }
        return [Windows.ApplicationModel.DataTransfer.Clipboard]::IsHistoryEnabled()
    }
    $history = [Func[System.Threading.Tasks.Task]] {
        $op = [Windows.ApplicationModel.DataTransfer.Clipboard]::GetHistoryItemsAsync()
        $method = $script:asTask.MakeGenericMethod([Windows.ApplicationModel.DataTransfer.ClipboardHistoryItemsResult])
        return $method.Invoke($null, @($op))
    }
    $topText = [Func[System.Threading.Tasks.Task,System.Threading.Tasks.Task]] {
        param($task)
        $result = $task.Result
        if ($result.Status.ToString() -ne 'Success') { throw "History unavailable: $($result.Status)" }
        # Use newest timestamp rather than relying on undocumented collection order.
        $top = $result.Items | Sort-Object -Property Timestamp -Descending | Select-Object -First 1
        if ($null -eq $top -or -not $top.Content.Contains('Text')) { return $null }
        $op = $top.Content.GetTextAsync()
        $method = $script:asTask.MakeGenericMethod([string])
        return $method.Invoke($null, @($op))
    }
    [BaiduPanClipboardCleaner.Program]::Start($enabled, $history, $topText)
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
