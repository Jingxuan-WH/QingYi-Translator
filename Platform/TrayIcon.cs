using Drawing = System.Drawing;
using WinForms = System.Windows.Forms;

namespace Translator.Platform;

internal sealed class TrayIcon : IDisposable
{
    private readonly WinForms.NotifyIcon _icon;

    public event Action? OpenRequested;
    public event Action? SettingsRequested;
    public event Action? ExitRequested;

    public TrayIcon()
    {
        var menu = new WinForms.ContextMenuStrip
        {
            ShowImageMargin = false,
            Font = new Drawing.Font("Microsoft YaHei UI", 9f),
            Padding = new WinForms.Padding(4),
            Renderer = new WinForms.ToolStripProfessionalRenderer(new FlatMenuColors()) { RoundedEdges = false },
        };
        menu.Items.Add(CreateItem("显示主窗口", () => OpenRequested?.Invoke(), bold: true));
        menu.Items.Add(CreateItem("设置…", () => SettingsRequested?.Invoke()));
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add(CreateItem("退出", () => ExitRequested?.Invoke()));

        _icon = new WinForms.NotifyIcon
        {
            Icon = LoadIcon(),
            Text = "轻译",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == WinForms.MouseButtons.Left)
                OpenRequested?.Invoke();
        };
    }

    public void ShowTip(string title, string text) => _icon.ShowBalloonTip(4000, title, text, WinForms.ToolTipIcon.None);

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.ContextMenuStrip?.Dispose();
        _icon.Dispose();
    }

    private static WinForms.ToolStripMenuItem CreateItem(string text, Action onClick, bool bold = false)
    {
        var item = new WinForms.ToolStripMenuItem(text) { Padding = new WinForms.Padding(8, 5, 24, 5) };
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

    private sealed class FlatMenuColors : WinForms.ProfessionalColorTable
    {
        private static readonly Drawing.Color Hover = Drawing.Color.FromArgb(238, 241, 246);
        private static readonly Drawing.Color Border = Drawing.Color.FromArgb(214, 219, 227);

        public override Drawing.Color MenuItemSelected => Hover;
        public override Drawing.Color MenuItemBorder => Hover;
        public override Drawing.Color MenuBorder => Border;
        public override Drawing.Color ToolStripDropDownBackground => Drawing.Color.White;
        public override Drawing.Color ImageMarginGradientBegin => Drawing.Color.White;
        public override Drawing.Color ImageMarginGradientMiddle => Drawing.Color.White;
        public override Drawing.Color ImageMarginGradientEnd => Drawing.Color.White;
        public override Drawing.Color SeparatorDark => Drawing.Color.FromArgb(228, 231, 236);
        public override Drawing.Color SeparatorLight => Drawing.Color.White;
    }
}
