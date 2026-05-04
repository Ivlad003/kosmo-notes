using System.Buffers.Binary;

namespace KosmoNotes.Core.Embeddings;

/// <summary>
/// Vector helpers for embedding-based semantic search. Mirrors the Swift
/// <c>EmbeddingMath</c> enum in <c>Sources/AIKit/EmbeddingProvider.swift</c>.
/// </summary>
public static class EmbeddingMath
{
    /// <summary>
    /// Cosine similarity in <c>[-1, 1]</c>. Higher means more similar.
    /// Returns 0 on empty or length-mismatched input vectors.
    /// </summary>
    public static float CosineSimilarity(float[] a, float[] b)
    {
        ArgumentNullException.ThrowIfNull(a);
        ArgumentNullException.ThrowIfNull(b);
        if (a.Length == 0 || a.Length != b.Length)
        {
            return 0;
        }

        float dot = 0;
        float na = 0;
        float nb = 0;
        for (int i = 0; i < a.Length; i++)
        {
            dot += a[i] * b[i];
            na += a[i] * a[i];
            nb += b[i] * b[i];
        }
        double denom = Math.Sqrt(na) * Math.Sqrt(nb);
        return denom > 0 ? (float)(dot / denom) : 0;
    }

    /// <summary>
    /// Pack a <see cref="float"/> vector into a little-endian Float32 byte blob
    /// suitable for SQLite BLOB storage. Mirrors Swift's
    /// <c>Data(buffer:)</c> over a <c>[Float]</c> on a little-endian host.
    /// </summary>
    public static byte[] Pack(float[] vector)
    {
        ArgumentNullException.ThrowIfNull(vector);
        byte[] result = new byte[vector.Length * sizeof(float)];
        for (int i = 0; i < vector.Length; i++)
        {
            BinaryPrimitives.WriteSingleLittleEndian(
                result.AsSpan(i * sizeof(float), sizeof(float)),
                vector[i]);
        }
        return result;
    }

    /// <summary>Unpack a little-endian Float32 byte blob back into a <see cref="float"/> array.</summary>
    public static float[] Unpack(byte[] data)
    {
        ArgumentNullException.ThrowIfNull(data);
        int count = data.Length / sizeof(float);
        float[] result = new float[count];
        for (int i = 0; i < count; i++)
        {
            result[i] = BinaryPrimitives.ReadSingleLittleEndian(
                data.AsSpan(i * sizeof(float), sizeof(float)));
        }
        return result;
    }
}
