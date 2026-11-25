using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Translator.Views;

/// <summary>Interruptible transitions that only affect rendering.</summary>
public static class Motion
{
    public static bool Enabled => SystemParameters.ClientAreaAnimation && !SystemParameters.HighContrast;

    public static readonly DependencyProperty SwitchOnProperty = DependencyProperty.RegisterAttached(
        "SwitchOn", typeof(bool), typeof(Motion), new PropertyMetadata(false, SwitchChanged));

    public static bool GetSwitchOn(DependencyObject element) => (bool)element.GetValue(SwitchOnProperty);
    public static void SetSwitchOn(DependencyObject element, bool value) => element.SetValue(SwitchOnProperty, value);

    private static void SwitchChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    {
        var knob = (FrameworkElement)sender;
        var slide = knob.RenderTransform as TranslateTransform;
        if (slide is null || slide.IsFrozen)
            knob.RenderTransform = slide = new TranslateTransform();
        double from = slide.X;
        double to = (bool)args.NewValue ? 20 : 0;
        slide.BeginAnimation(TranslateTransform.XProperty, null);
        slide.X = to;
        if (Enabled && knob.IsVisible && knob.IsLoaded && from != to)
            slide.BeginAnimation(TranslateTransform.XProperty, Transition(from, to, 120));
    }

    private static DoubleAnimation Transition(double from, double to, int milliseconds) =>
        new(from, to, TimeSpan.FromMilliseconds(milliseconds))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            FillBehavior = FillBehavior.Stop
        };

    public static void Fade(UIElement element, double from, double to, Action? finished = null)
    {
        element.BeginAnimation(UIElement.OpacityProperty, null);
        element.Opacity = to;
        if (!Enabled || !element.IsVisible || from == to)
        {
            finished?.Invoke();
            return;
        }
        var animation = Transition(from, to, to > from ? 145 : 95);
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
