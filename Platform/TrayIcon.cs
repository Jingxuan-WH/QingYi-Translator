using Translator.Core;
using Drawing = System.Drawing;
using WinForms = System.Windows.Forms;

namespace Translator.Platform;

internal sealed class TrayIcon : IDisposable
{
    private readonly WinForms.NotifyIcon _icon;
    private readonly WinForms.ContextMenuStrip _menu;
    private readonly WinForms.ToolStripMenuItem _openItem;
    private readonly WinForms.ToolStripMenuItem _settingsItem;
    private readonly WinForms.ToolStripMenuItem _exitItem;
    private Action? _tipClicked;

    public event Action? OpenRequested;
    public event Action? SettingsRequested;
    public event Action? ExitRequested;

    public TrayIcon()
    {
        _menu = new WinForms.ContextMenuStrip
        {
            ShowImageMargin = false,
            Font = new Drawing.Font("Microsoft YaHei UI", 9f),
            Padding = new WinForms.Padding(4),
        };
        _openItem = CreateItem(() => OpenRequested?.Invoke(), bold: true);
        _settingsItem = CreateItem(() => SettingsRequested?.Invoke());
        _exitItem = CreateItem(() => ExitRequested?.Invoke());
        _menu.Items.Add(_openItem);
        _menu.Items.Add(_settingsItem);
        _menu.Items.Add(new WinForms.ToolStripSeparator());
        _menu.Items.Add(_exitItem);

        _icon = new WinForms.NotifyIcon
        {
            Icon = LoadIcon(),
            ContextMenuStrip = _menu,
            Visible = true,
        };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == WinForms.MouseButtons.Left)
                OpenRequested?.Invoke();
        };
        _icon.BalloonTipClicked += (_, _) =>
        {
            var action = _tipClicked;
            _tipClicked = null;
            action?.Invoke();
        };
        _icon.BalloonTipClosed += (_, _) => _tipClicked = null;

        UpdateTexts();
        ApplyTheme(dark: false);
    }

    /// <summary>Shows a notification; <paramref name="onClick"/> runs if the user clicks it.</summary>
    public void ShowTip(string title, string text, Action? onClick = null)
    {
        _tipClicked = onClick;
        _icon.ShowBalloonTip(5000, title, text, WinForms.ToolTipIcon.None);
    }

    public void UpdateTexts()
    {
        _openItem.Text = Loc.T("显示主窗口", "Show window");
        _settingsItem.Text = Loc.T("设置…", "Settings…");
        _exitItem.Text = Loc.T("退出", "Exit");
        _icon.Text = Loc.T("轻译", "QingYi Translator");
    }

    public void ApplyTheme(bool dark)
    {
        _menu.Renderer = new WinForms.ToolStripProfessionalRenderer(dark ? new DarkMenuColors() : new LightMenuColors()) { RoundedEdges = false };
        var text = dark ? Drawing.Color.FromArgb(230, 232, 238) : Drawing.Color.FromArgb(30, 36, 48);
        foreach (WinForms.ToolStripItem item in _menu.Items)
            item.ForeColor = text;
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _menu.Dispose();
        _icon.Dispose();
    }

    private static WinForms.ToolStripMenuItem CreateItem(Action onClick, bool bold = false)
    {
        var item = new WinForms.ToolStripMenuItem { Padding = new WinForms.Padding(8, 5, 24, 5) };
        if (bold)
            item.Font = new Drawing.Font(item.Font, Drawing.FontStyle.Bold);
        item.Click += (_, _) => onClick();
        return item;
    }

    private static Drawing.Icon LoadIcon()
    {
        var resource = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Assets/app.ico"));
        using var stream = resource!.Stream;
        return new Drawing.Icon(stream, WinForms.SystemInformation.SmallIconSize);
    }

    private class LightMenuColors : WinForms.ProfessionalColorTable
    {
        protected virtual Drawing.Color Background => Drawing.Color.White;
        protected virtual Drawing.Color Hover => Drawing.Color.FromArgb(238, 241, 246);
        protected virtual Drawing.Color Border => Drawing.Color.FromArgb(214, 219, 227);
        protected virtual Drawing.Color Separator => Drawing.Color.FromArgb(228, 231, 236);

        public override Drawing.Color MenuItemSelected => Hover;
        public override Drawing.Color MenuItemBorder => Hover;
        public override Drawing.Color MenuBorder => Border;
        public override Drawing.Color ToolStripDropDownBackground => Background;
        public override Drawing.Color ImageMarginGradientBegin => Background;
        public override Drawing.Color ImageMarginGradientMiddle => Background;
        public override Drawing.Color ImageMarginGradientEnd => Background;
        public override Drawing.Color SeparatorDark => Separator;
        public override Drawing.Color SeparatorLight => Background;
    }

    private sealed class DarkMenuColors : LightMenuColors
    {
        protected override Drawing.Color Background => Drawing.Color.FromArgb(32, 35, 43);
        protected override Drawing.Color Hover => Drawing.Color.FromArgb(46, 50, 61);
        protected override Drawing.Color Border => Drawing.Color.FromArgb(58, 63, 75);
        protected override Drawing.Color Separator => Drawing.Color.FromArgb(58, 63, 75);
    }
}
