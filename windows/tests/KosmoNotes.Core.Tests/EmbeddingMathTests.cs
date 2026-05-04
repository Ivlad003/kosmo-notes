using KosmoNotes.Core.Embeddings;

namespace KosmoNotes.Core.Tests;

public class EmbeddingMathTests
{
    [Fact]
    public void CosineSimilarity_IdenticalVectors_IsOne()
    {
        float[] v = new float[] { 1, 2, 3, 4 };
        float sim = EmbeddingMath.CosineSimilarity(v, v);
        Assert.Equal(1f, sim, precision: 5);
    }

    [Fact]
    public void CosineSimilarity_OppositeVectors_IsMinusOne()
    {
        float[] a = new float[] { 1, 2, 3, 4 };
        float[] b = new float[] { -1, -2, -3, -4 };
        float sim = EmbeddingMath.CosineSimilarity(a, b);
        Assert.Equal(-1f, sim, precision: 5);
    }

    [Fact]
    public void CosineSimilarity_OrthogonalVectors_IsZero()
    {
        float[] a = new float[] { 1, 0, 0, 0 };
        float[] b = new float[] { 0, 1, 0, 0 };
        float sim = EmbeddingMath.CosineSimilarity(a, b);
        Assert.Equal(0f, sim, precision: 5);
    }

    [Fact]
    public void CosineSimilarity_LengthMismatch_IsZero()
    {
        float[] a = new float[] { 1, 2, 3 };
        float[] b = new float[] { 1, 2, 3, 4 };
        Assert.Equal(0f, EmbeddingMath.CosineSimilarity(a, b));
    }

    [Fact]
    public void CosineSimilarity_EmptyVectors_IsZero()
    {
        Assert.Equal(0f, EmbeddingMath.CosineSimilarity(Array.Empty<float>(), Array.Empty<float>()));
    }

    [Fact]
    public void CosineSimilarity_OneZeroVector_IsZero()
    {
        float[] a = new float[] { 1, 2, 3, 4 };
        float[] b = new float[] { 0, 0, 0, 0 };
        Assert.Equal(0f, EmbeddingMath.CosineSimilarity(a, b));
    }

    [Fact]
    public void Pack_FourElementVector_Produces16Bytes()
    {
        float[] v = new float[] { 1f, -2f, 3.5f, 0f };
        byte[] data = EmbeddingMath.Pack(v);
        Assert.Equal(16, data.Length);
    }

    [Fact]
    public void PackUnpack_RoundTripsExactly()
    {
        float[] original = new float[] { 1f, -2f, 3.5f, 0f };
        byte[] packed = EmbeddingMath.Pack(original);
        float[] unpacked = EmbeddingMath.Unpack(packed);
        Assert.Equal(original, unpacked);
    }

    [Fact]
    public void Pack_IsLittleEndianFloat32()
    {
        // 1.0f in IEEE-754 LE is 00 00 80 3F
        float[] v = new float[] { 1.0f };
        byte[] data = EmbeddingMath.Pack(v);
        Assert.Equal(new byte[] { 0x00, 0x00, 0x80, 0x3F }, data);
    }

    [Fact]
    public void Unpack_FromKnownLittleEndianBytes()
    {
        // 1.0f in IEEE-754 LE
        byte[] bytes = new byte[] { 0x00, 0x00, 0x80, 0x3F };
        float[] v = EmbeddingMath.Unpack(bytes);
        Assert.Single(v);
        Assert.Equal(1.0f, v[0]);
    }

    [Fact]
    public void Unpack_LargeBlob_RoundTrips()
    {
        var rng = new Random(42);
        float[] original = new float[1536];
        for (int i = 0; i < original.Length; i++)
        {
            original[i] = (float)((rng.NextDouble() * 2.0) - 1.0);
        }
        byte[] packed = EmbeddingMath.Pack(original);
        Assert.Equal(1536 * 4, packed.Length);
        float[] unpacked = EmbeddingMath.Unpack(packed);
        Assert.Equal(original, unpacked);
    }
}
