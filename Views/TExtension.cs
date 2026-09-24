using System.Globalization;
using System.Windows.Data;
using System.Windows.Markup;
using Translator.Core;

namespace Translator.Views;

/// <summary>
/// XAML text in both interface languages, e.g. <c>Text="{v:T 设置, En=Settings}"</c>.
/// It binds to <see cref="Loc.English"/>, so the text switches as soon as the interface language changes.
/// </summary>
[MarkupExtensionReturnType(typeof(string))]
public sealed class TExtension : MarkupExtension
{
    public TExtension()
    {
    }

    public TExtension(string zh) => Zh = zh;

    [ConstructorArgument("zh")]
    public string Zh { get; set; } = "";

    public string En { get; set; } = "";

    public override object ProvideValue(IServiceProvider serviceProvider) =>
        new Binding(nameof(Loc.English))
        {
            Source = Loc.Instance,
            Mode = BindingMode.OneWay,
            Converter = PickLanguage.Instance,
            ConverterParameter = new LocText(Zh, En.Length > 0 ? En : Zh),
        }.ProvideValue(serviceProvider);

    private sealed class PickLanguage : IValueConverter
    {
        public static readonly PickLanguage Instance = new();

        public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
            parameter is LocText text ? (value is true ? text.En : text.Zh) : "";

        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
            throw new NotSupportedException();
    }
}
