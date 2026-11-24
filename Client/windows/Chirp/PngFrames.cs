using System.Buffers.Binary;

namespace Chirp;

internal static class PngFrames
{
    // Some WIC versions expose only the default frame of an animated PNG.
    internal static bool Single(ReadOnlySpan<byte> data)
    {
        if (!data.StartsWith(new byte[] {137, 80, 78, 71, 13, 10, 26, 10})) return false;
        var frames = 0;
        for (var offset = 8; offset <= data.Length - 12;)
        {
            var length = BinaryPrimitives.ReadUInt32BigEndian(data[offset..]);
            if (length > data.Length - offset - 12) return false;
            var type = data.Slice(offset + 4, 4);
            if (type.SequenceEqual("acTL"u8) && (length != 8 || BinaryPrimitives.ReadUInt32BigEndian(data[(offset + 8)..]) != 1)) return false;
            if (type.SequenceEqual("fcTL"u8) && ++frames > 1) return false;
            if (type.SequenceEqual("IEND"u8)) return length == 0;
            offset += 12 + (int)length;
        }
        return false;
    }
}
