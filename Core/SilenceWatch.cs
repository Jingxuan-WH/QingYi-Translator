namespace Translator.Core;

/// <summary>
/// Notices a microphone that has delivered nothing but silence since listening started: muted, blocked by the privacy
/// settings (Windows then hands desktop apps silence instead of an error) or not shared with a virtual machine.
/// A real microphone always picks up some noise, so once anything was heard it stays quiet for the session.
/// </summary>
public sealed class SilenceWatch(double seconds = 8)
{
    /// <summary>Meter levels (0–1, as shown in the window) at or below this are digital silence.</summary>
    public const float Threshold = 0.0004f;

    private double? _since;
    private bool _heard;
    private bool _reported;

    /// <returns>True once, when the level has stayed at or below <see cref="Threshold"/> for the whole time.</returns>
    public bool Update(float level, double nowSeconds)
    {
        if (_heard || _reported)
            return false;
        if (level > Threshold)
        {
            _heard = true;
            return false;
        }
        _since ??= nowSeconds;
        if (nowSeconds - _since < seconds)
            return false;
        _reported = true;
        return true;
    }

    /// <summary>Starts over, e.g. when the devices are opened again.</summary>
    public void Reset()
    {
        _since = null;
        _heard = false;
        _reported = false;
    }
}
