using System.Runtime.InteropServices;
using Concentus;
using Concentus.Enums;
using Concentus.Structs;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Chirp;

internal sealed class AudioService : IDisposable
{
    [DllImport("kernel32.dll")] private static extern ulong GetTickCount64();
    [DllImport("Chirp.RNNoise.dll", CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr rnnoise_create(IntPtr model);
    [DllImport("Chirp.RNNoise.dll", CallingConvention = CallingConvention.Cdecl)] private static extern void rnnoise_destroy(IntPtr state);
    [DllImport("Chirp.RNNoise.dll", CallingConvention = CallingConvention.Cdecl)] private static extern float rnnoise_process_frame(IntPtr state, [Out] float[] output, float[] input);
    [DllImport("chirp_windows_audio.dll", CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr chirp_aec_new();
    [DllImport("chirp_windows_audio.dll", CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    private static extern bool chirp_aec_frame(IntPtr state, short[] render, short[] microphone, [Out] short[] output, int delayMs);
    [DllImport("chirp_windows_audio.dll", CallingConvention = CallingConvention.Cdecl)] private static extern void chirp_aec_free(IntPtr state);
    internal static long Now => (long)GetTickCount64();
    private static readonly WaveFormat Format = new(48000, 16, 1);
    internal sealed record Endpoint(string Id, string Name);
    private readonly object sync = new();
    private readonly Mixer mixer = new();
    private readonly Dictionary<string, IOpusDecoder> decoders = new();
    private readonly short[] frame = new short[960];
    private readonly byte[] compressed = new byte[1275];
    private readonly float[] noiseIn = new float[480], noiseOut = new float[480];
    private readonly short[] speaker = new short[480], microphone = new short[480], processed = new short[480];
    private IOpusEncoder? encoder;
    private WasapiRecorder? input;
    private WasapiPlayer? output;
    private MMDevice? captureDevice, renderDevice;
    private IntPtr noise, echo;
    private readonly VoiceGate gate = new();
    private int filled;
    private long lease, leaseRevision, captureVersion, testUntil;
    private string entry = "", group = "", captureGroup = "";
    private MicrophoneClip? test;
    private bool testing;
    private Guid? testOwner;
    internal event Action<string, byte[], byte>? Encoded;
    internal event Action<long, string>? Failed;
    internal event Action<bool>? CaptureInitialized;
    internal string InputId { get; set; } = "";
    internal string OutputId { get; set; } = "";
    // These IDs are also used by saved preferences and the voice processing picker.
    internal const int SystemCommunicationsPreset = 1;
    internal int Preset
    {
        get;
        set => field = value is 0 or 2 ? value : SystemCommunicationsPreset;
    } = SystemCommunicationsPreset;
    internal bool Denoise => Preset != SystemCommunicationsPreset;
    internal bool Communications => Preset != 2;
    internal bool Activation { get; set; }
    internal int Threshold { get; set; } = -45;
    internal int InputGain { get; set; } = 100;
    internal int Master { get => mixer.Master; set => mixer.Master = value; }
    internal bool Listen { get => mixer.Listen; set => mixer.Listen = value; }
    internal double Level { get { lock (sync) return gate.Level; } }
    internal double PeerVolume(string peer) => mixer.GetVolume(peer);
    internal void SetPeerVolume(string peer, double volume) => mixer.Volume(peer, (int)volume);
    internal static List<Endpoint> Endpoints(bool capture)
    {
        using var all = new MMDeviceEnumerator();
        return all.EnumerateAudioEndPoints(capture ? DataFlow.Capture : DataFlow.Render, DeviceState.Active)
            .Select(d => { using (d) return new Endpoint(d.ID, d.FriendlyName); }).ToList();
    }
    private static MMDevice Device(bool capture, string id)
    {
        using var all = new MMDeviceEnumerator();
        return string.IsNullOrEmpty(id) ? all.GetDefaultAudioEndpoint(capture ? DataFlow.Capture : DataFlow.Render, Role.Communications) : all.GetDevice(id);
    }
    internal static string ActiveId(bool capture, string id)
    {
        try { using var device = Device(capture, id); return device.State == DeviceState.Active ? device.ID : ""; }
        catch (COMException) { return ""; }
    }
    internal static void ValidateProcessing(bool communications, bool denoise)
    {
        if (!communications)
        {
            var processor = chirp_aec_new();
            if (processor == IntPtr.Zero) throw new IOException("AEC_UNAVAILABLE");
            chirp_aec_free(processor);
        }
        if (denoise)
        {
            var processor = rnnoise_create(IntPtr.Zero);
            if (processor == IntPtr.Zero) throw new IOException("RNNOISE_UNAVAILABLE");
            rnnoise_destroy(processor);
        }
    }
    internal bool Capturing(string id) { lock (sync) return input is not null && !testing && captureGroup == id; }
    internal bool GateOpen { get { lock (sync) return gate.Open; } }
    internal bool HasInput { get { lock (sync) return input is not null; } }
    internal bool IsCurrentInput(long version) { lock (sync) return input is not null && captureVersion == version; }
    internal bool HasOutput { get { lock (sync) return output is not null; } }
    internal void OpenOutput() { lock (sync) EnsureOutput(); }
    internal static short[] ReadCue(bool joined)
    {
        var name = joined ? "JoinTheRoom.mp3" : "LeftTheRoom.mp3";
        using var source = new MediaFoundationReader(Path.Combine(AppContext.BaseDirectory, "Sounds", name));
        using var converter = new MediaFoundationResampler(source, Format);
        using var pcm = new MemoryStream();
        var buffer = new byte[8192];
        int count;
        while ((count = converter.Read(buffer)) > 0) pcm.Write(buffer, 0, count);
        return MemoryMarshal.Cast<byte, short>(pcm.GetBuffer().AsSpan(0, (int)pcm.Length)).ToArray();
    }
    internal TimeSpan PlayCue(short[] samples)
    {
        lock (sync)
        {
            if (entry.Length == 0 || !Listen || samples.Length == 0) return TimeSpan.Zero;
            EnsureOutput();
            mixer.AddCue(samples, Now + 3000);
            return TimeSpan.FromSeconds((double)samples.Length / Format.SampleRate);
        }
    }
    internal void StopCue() => mixer.ClearCues();
    internal bool TestBusy { get { lock (sync) return testOwner is not null; } }
    internal bool OwnsTest(Guid owner) { lock (sync) return testOwner == owner; }
    internal bool IsTesting(Guid owner) { lock (sync) return testOwner == owner && testing; }
    internal bool HasClip(Guid owner) { lock (sync) return testOwner == owner && testing && test?.Count > 0; }
    internal void UpdateTest(Guid owner)
    {
        if (OwnsTest(owner) && (IsTesting(owner) ? Now >= testUntil : !mixer.HasLocalPlayback)) CancelTest();
    }
    internal bool Renew(string identity, string id, long deadline, long revision)
    {
        lock (sync)
        {
            if (identity == "" || identity != entry || revision < leaseRevision) return false;
            InstallLease(deadline > Now ? id : "", deadline, revision);
            return true;
        }
    }
    internal bool Permitted(string identity, string id)
    {
        lock (sync) return identity != "" && identity == entry && id != "" && id == group && Now < lease;
    }
    internal void BeginEntry(string identity)
    {
        lock (sync)
        {
            if (entry != identity) mixer.ResetVolumes();
            entry = identity; InstallLease("", 0, 0);
        }
    }
    private void InstallLease(string value, long deadline, long revision)
    {
        leaseRevision = revision;
        mixer.SetDeadline(value == "" ? 0 : deadline);
        lease = deadline;
        if (group == value) return;
        group = value;
        foreach (var decoder in decoders.Values) decoder.Dispose();
        decoders.Clear(); mixer.Clear();
    }
    internal void StartCapture(string id) => StartInput(id, false);
    private void StartInput(string id, bool probe)
    {
        StopCapture();
        try
        {
            lock (sync)
            {
                if (!probe && (id.Length == 0 || group != id || Now >= lease)) throw new IOException("CONTENT_PAUSED");
                captureGroup = id; testing = probe;
                if (probe) { test = new MicrophoneClip(); testUntil = Now + 10_000; }
                if (!Communications)
                {
                    echo = chirp_aec_new();
                    if (echo == IntPtr.Zero) throw new IOException("AEC_UNAVAILABLE");
                    mixer.EnableReference(true);
                }
                if (Denoise) { noise = rnnoise_create(IntPtr.Zero); if (noise == IntPtr.Zero) throw new IOException("RNNOISE_UNAVAILABLE"); }
                if (!probe) encoder = OpusCodecFactory.CreateEncoder(48000, 1, OpusApplication.OPUS_APPLICATION_VOIP);
                captureDevice = Device(true, InputId);
                var builder = new WasapiRecorderBuilder().WithDevice(captureDevice).WithSharedMode().WithEventSync().WithBufferLength(20).WithFormat(Format);
                if (Communications) builder.WithCommunicationsMode(); else builder.WithRawMode();
                input = builder.Build();
                var owner = input;
                input.DataAvailable += (buffer, flags, position, timestamp) => Capture(owner, buffer);
                input.RecordingStopped += (_, args) => { if (args.Exception is not null) InputFailed(owner, args.Exception.Message); };
            }
            input.StartRecording();
            CaptureInitialized?.Invoke(Denoise);
        }
        catch { StopCapture(); throw; }
    }
    private void Capture(WasapiRecorder sender, ReadOnlySpan<byte> buffer)
    {
        try
        {
            lock (sync)
            {
                if (input != sender || (testing ? Now >= testUntil : captureGroup != group || Now >= lease)) { filled = 0; return; }
                foreach (var sample in MemoryMarshal.Cast<byte, short>(buffer))
                {
                    frame[filled++] = sample;
                    if (filled != frame.Length) continue;
                    filled = 0;
                    for (int offset = 0; offset < frame.Length; offset += 480)
                    {
                        if (echo != IntPtr.Zero)
                        {
                            mixer.TakeReference(speaker);
                            Array.Copy(frame, offset, microphone, 0, microphone.Length);
                            // The render queue is 40 ms and capture is configured for 20 ms.
                            if (!chirp_aec_frame(echo, speaker, microphone, processed, 60))
                                throw new IOException("AUDIO_PROCESSING_FAILED");
                            processed.CopyTo(frame, offset);
                        }
                        if (noise == IntPtr.Zero) continue;
                        for (int i = 0; i < 480; i++) noiseIn[i] = frame[offset + i];
                        rnnoise_process_frame(noise, noiseOut, noiseIn);
                        for (int i = 0; i < 480; i++) frame[offset + i] = (short)Math.Clamp(noiseOut[i], short.MinValue, short.MaxValue);
                    }
                    for (int i = 0; i < frame.Length; i++)
                        frame[i] = (short)Math.Clamp(frame[i] * InputGain / 100, short.MinValue, short.MaxValue);
                    var audioLevel = gate.Process(frame, Activation, Threshold);
                    if (testing && test is not null)
                    {
                        if (Now < testUntil) test.Append(frame);
                    }
                    else if (encoder is not null && captureGroup == group && Now < lease)
                    {
                        var length = encoder.Encode(frame, frame.Length, compressed, compressed.Length);
                        if (length > 0) Encoded?.Invoke(group, compressed[..length], audioLevel);
                    }
                }
            }
        }
        catch (Exception ex) { InputFailed(sender, ex.Message); }
    }
    private void InputFailed(WasapiRecorder owner, string message)
    {
        lock (sync) { if (ReferenceEquals(input, owner)) Failed?.Invoke(captureVersion, message); }
    }
    internal void StopCapture()
    {
        WasapiRecorder? rec; MMDevice? device;
        lock (sync)
        {
            rec = input; input = null; captureVersion++; device = captureDevice; captureDevice = null;
            testing = false; filled = 0; captureGroup = ""; gate.Reset(); Array.Clear(frame);
            mixer.EnableReference(false);
            if (echo != IntPtr.Zero) { chirp_aec_free(echo); echo = IntPtr.Zero; }
            encoder?.Dispose(); encoder = null;
            if (noise != IntPtr.Zero) { rnnoise_destroy(noise); noise = IntPtr.Zero; }
        }
        if (rec is not null) { try { rec.StopRecording(); } finally { rec.Dispose(); } }
        device?.Dispose();
    }
    internal void StartTest(Guid owner)
    {
        if (testOwner is not null || entry.Length != 0) throw new IOException("AUDIO_TEST_BUSY");
        testOwner = owner;
        try { StartInput("", true); }
        catch { CancelTest(); throw; }
    }
    internal void PlayTest(Guid owner)
    {
        if (!IsTesting(owner)) return;
        StopCapture();
        try
        {
            lock (sync)
            {
                var data = test?.Finish(true) ?? []; test = null;
                if (data.Length == 0) { testOwner = null; return; }
                EnsureOutput(); mixer.Add("local-test", data, Now + 4000);
            }
        }
        catch { CancelTest(); throw; }
    }
    internal void EndTest(Guid owner) { if (testOwner == owner) CancelTest(); }
    internal void CancelTest()
    {
        if (testOwner is null) return;
        StopCapture(); lock (sync) { testOwner = null; test?.Finish(false); test = null; }
        StopOutput();
    }
    private void EnsureOutput()
    {
        if (output is not null)
        {
            if (output.PlaybackState != PlaybackState.Playing) output.Play();
            return;
        }
        renderDevice = Device(false, OutputId);
        WasapiPlayer? player = null;
        try
        {
            player = new WasapiPlayerBuilder().WithDevice(renderDevice).WithCategory(AudioStreamCategory.Communications).WithSharedMode().WithLatency(40).Build();
            player.Init(mixer); player.Play(); output = player;
        }
        catch { player?.Dispose(); renderDevice.Dispose(); renderDevice = null; throw; }
    }
    internal void Play(string identity, string id, string peer, byte[] packet, long deadline)
    {
        lock (sync)
        {
            if (identity == "" || identity != entry || id == "" || id != group || Now >= Math.Min(lease, deadline) || packet.Length is < 1 or > 1275 || !Listen) return;
            EnsureOutput();
            if (!decoders.TryGetValue(peer, out var decoder)) decoders[peer] = decoder = OpusCodecFactory.CreateDecoder(48000, 1);
            var pcm = DecodePacket(decoder, packet);
            if (pcm.Length > 0) mixer.Add(peer, pcm, Math.Min(deadline, lease));
        }
    }
    internal static short[] DecodePacket(IOpusDecoder decoder, ReadOnlySpan<byte> packet)
    {
        int samples = OpusPacketInfo.GetNumSamples(packet, Format.SampleRate);
        if (samples <= 0) return [];
        var pcm = new short[samples];
        int decoded;
        try { decoded = decoder.Decode(packet, pcm, samples); }
        catch (OpusException ex) { decoded = ex.OpusErrorCode; }
        if (decoded == OpusError.OPUS_INVALID_PACKET) return [];
        if (decoded < 0) throw new IOException("AUDIO_DECODE_FAILED");
        return decoded == samples ? pcm : pcm[..decoded];
    }
    internal void StopOutput()
    {
        WasapiPlayer? player; MMDevice? device;
        lock (sync) { mixer.Clear(); player = output; output = null; device = renderDevice; renderDevice = null; }
        player?.Dispose(); device?.Dispose();
    }
    internal void Reset()
    {
        BeginEntry("");
        try { StopCapture(); }
        finally
        {
            lock (sync) { testOwner = null; test?.Finish(false); test = null; }
            StopOutput();
        }
    }
    public void Dispose() => Reset();

    // WASAPI pulls the mix. Expired frames are discarded even if the UI or the
    // protocol process was suspended while there was queued audio.
    internal sealed class Mixer : IWaveProvider
    {
        private sealed record Block(short[] Samples, long Deadline) { public int Position; }
        private readonly Dictionary<string, Queue<Block>> streams = new();
        private readonly Queue<Block> cues = new();
        private readonly Dictionary<string, int> volumes = new();
        private readonly object guard = new();
        private readonly Queue<short> reference = new(5760);
        private bool referenceEnabled;
        private long lease;
        public WaveFormat WaveFormat => Format;
        public volatile int Master = 100;
        public volatile bool Listen = true;
        internal void Volume(string peer, int volume) { lock (guard) volumes[peer] = volume; }
        internal int GetVolume(string peer) { lock (guard) return volumes.GetValueOrDefault(peer, 100); }
        internal bool HasLocalPlayback { get { lock (guard) return streams.TryGetValue("local-test", out var q) && q.Count > 0 && q.Peek().Deadline > Now; } }
        internal void ResetVolumes() { lock (guard) volumes.Clear(); }
        internal void AddCue(short[] samples, long until) { lock (guard) cues.Enqueue(new Block(samples, until)); }
        internal void ClearCues() { lock (guard) cues.Clear(); }
        internal void Clear() { lock (guard) { foreach (var q in streams.Values) foreach (var b in q) Array.Clear(b.Samples); streams.Clear(); cues.Clear(); reference.Clear(); } }
        internal void SetDeadline(long until) { lock (guard) lease = until; }
        internal void EnableReference(bool enabled)
        {
            lock (guard) { reference.Clear(); referenceEnabled = enabled; }
        }
        internal void TakeReference(short[] samples)
        {
            lock (guard)
                for (int i = 0; i < samples.Length; i++)
                    samples[i] = reference.TryDequeue(out var sample) ? sample : (short)0;
        }
        internal void Add(string peer, short[] samples, long until)
        {
            lock (guard)
            {
                if (!streams.TryGetValue(peer, out var q)) streams[peer] = q = new Queue<Block>();
                if (q.Count >= 8) q.Dequeue(); q.Enqueue(new Block(samples, until));
            }
        }
        private static void Mix(Queue<Block> queue, Span<short> samples, long now, double gain, bool audible)
        {
            int offset = 0;
            while (offset < samples.Length && queue.TryPeek(out var block))
            {
                if (!audible || now >= block.Deadline) { Array.Clear(block.Samples); queue.Dequeue(); continue; }
                int count = Math.Min(samples.Length - offset, block.Samples.Length - block.Position);
                for (int i = 0; i < count; i++)
                    samples[offset + i] = (short)Math.Clamp(samples[offset + i] + block.Samples[block.Position + i] * gain, short.MinValue, short.MaxValue);
                offset += count;
                block.Position += count;
                if (block.Position == block.Samples.Length) { Array.Clear(block.Samples); queue.Dequeue(); }
            }
        }
        public int Read(Span<byte> bytes)
        {
            bytes.Clear(); var samples = MemoryMarshal.Cast<byte, short>(bytes);
            lock (guard)
            {
                var now = Now;
                foreach (var (peer, q) in streams)
                {
                    var gain = Master * volumes.GetValueOrDefault(peer, 100) / 10000d;
                    Mix(q, samples, now, gain, peer == "local-test" || Listen && now < lease);
                }
                Mix(cues, samples, now, Math.Min(Master, 100) / 100d, Listen);
                if (referenceEnabled)
                    foreach (var sample in samples)
                    {
                        if (reference.Count == 5760) reference.Dequeue();
                        reference.Enqueue(sample);
                    }
            }
            return bytes.Length;
        }
    }
}
