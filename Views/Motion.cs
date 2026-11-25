using System.Windows;
using System.Windows.Media.Animation;

namespace Translator.Views;

/// <summary>Short, interruptible opacity changes that never alter layout or the size of streamed text.</summary>
internal static class Motion
{
    public static bool Enabled => SystemParameters.ClientAreaAnimation && !SystemParameters.HighContrast;

    public static void Fade(UIElement element, double from, double to, Action? finished = null)
    {
        element.BeginAnimation(UIElement.OpacityProperty, null);
        element.Opacity = to;
        if (!Enabled || !element.IsVisible || from == to)
        {
            finished?.Invoke();
            return;
        }
        var animation = new DoubleAnimation(from, to, TimeSpan.FromMilliseconds(to > from ? 145 : 95))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            FillBehavior = FillBehavior.Stop
        };
        if (finished is not null)
            animation.Completed += (_, _) => finished();
        element.BeginAnimation(UIElement.OpacityProperty, animation);
    }

    public static void Show(FrameworkElement element, bool visible)
    {
        var visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (element.Visibility == visibility)
            return;
        element.Visibility = visibility;
        if (visible)
            Fade(element, 0, 1);
    }
}
