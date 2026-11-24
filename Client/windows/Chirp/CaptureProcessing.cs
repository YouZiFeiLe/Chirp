namespace Chirp;

internal sealed class VoiceGate
{
    private float gain;
    private int quietSamples;
    internal bool Open { get; private set; }
    internal double Level { get; private set; } = -96;
    internal void Reset() { Open = false; gain = 0; quietSamples = 0; Level = -96; }

    private static double Decibels(double energy, int length) =>
        energy == 0 ? -127 : 10 * Math.Log10(energy / (length * 32768d * 32768d));

    internal byte Process(Span<short> samples, bool enabled, int threshold)
    {
        if (samples.IsEmpty) return 127;
        double energy = 0;
        foreach (var sample in samples) energy += (double)sample * sample;
        var db = Decibels(energy, samples.Length);
        Level = Math.Clamp(db, -96, 0);
        if (enabled)
        {
            var cutoff = Math.Clamp(threshold, -80, -10);
            if (Level >= (Open ? cutoff - 5 : cutoff)) { Open = true; quietSamples = 0; }
            else if (Open && (quietSamples += samples.Length) >= 12000) { Open = false; quietSamples = 0; }
            energy = 0;
            for (var i = 0; i < samples.Length; i++)
            {
                gain = Math.Clamp(gain + (Open ? 1f : -1f) / 240, 0, 1);
                samples[i] = (short)(samples[i] * gain);
                energy += (double)samples[i] * samples[i];
            }
            db = Decibels(energy, samples.Length);
        }
        else { Open = false; gain = 0; quietSamples = 0; }
        // RFC 6464 uses the level of the transmitted frame, with 127 for silence.
        return (byte)Math.Clamp(Math.Round(-db), 0, 127);
    }
}

internal sealed class MicrophoneClip
{
    private readonly short[] buffer = new short[48000 * 3];
    private int position;
    private bool closed;
    internal int Count { get; private set; }
    internal void Append(ReadOnlySpan<short> frame)
    {
        if (closed) return;
        foreach (var sample in frame)
        {
            buffer[position] = sample;
            position = (position + 1) % buffer.Length;
        }
        Count = Math.Min(buffer.Length, Count + frame.Length);
    }
    internal short[] Finish(bool play)
    {
        var samples = new short[play ? Count : 0];
        var first = Count == buffer.Length ? position : 0;
        for (var i = 0; i < samples.Length; i++) samples[i] = buffer[(first + i) % buffer.Length];
        Array.Clear(buffer); Count = 0; closed = true;
        return samples;
    }
}
