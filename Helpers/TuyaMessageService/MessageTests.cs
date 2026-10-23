using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

internal static class MessageTests
{
    internal static void Run()
    {
        var secret = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        var plaintext = Encoding.UTF8.GetBytes("{\"bizCode\":\"devicePropertyMessage\",\"bizData\":{\"devId\":\"fixture\",\"dataId\":\"data\",\"properties\":[{\"dpId\":19,\"code\":\"doorbell\",\"time\":1792680784000,\"value\":true},{\"dpId\":9,\"code\":\"unlock_request\",\"time\":1792680784000,\"value\":\"60\"},{\"dpId\":50,\"code\":\"remote_no_dp_key\",\"value\":\"redacted\"}]}}");
        var nonce = RandomNumberGenerator.GetBytes(12);
        var encrypted = new byte[plaintext.Length];
        var tag = new byte[16];
        using var aes = new AesGcm(Encoding.UTF8.GetBytes(secret.Substring(8, 16)), 16);
        aes.Encrypt(nonce, plaintext, encrypted, tag);
        var payload = Convert.ToBase64String(nonce.Concat(encrypted).Concat(tag).ToArray());
        var unsigned = $"data={payload}||protocol=1000||pv=2.0||t=1||{secret}";
        var sign = Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(unsigned))).ToLowerInvariant();
        var wire = JsonSerializer.SerializeToUtf8Bytes(new { data = payload, encryptVersion = "v2", protocol = 1000, pv = "2.0", t = 1, sign });
        var decrypted = MessageCodec.Decrypt(wire, secret, "aes_gcm");
        Require(decrypted.SequenceEqual(plaintext));
        Require(MessageCodec.Normalize(decrypted, "fixture", "id", DateTimeOffset.UtcNow.ToString("O")).Count() == 2);
        Require(!MessageCodec.Normalize(decrypted, "other", "id", DateTimeOffset.UtcNow.ToString("O")).Any());
        var unknownType = Encoding.UTF8.GetString(decrypted).Replace("devicePropertyMessage", "unsupportedMessage");
        Require(!MessageCodec.Normalize(Encoding.UTF8.GetBytes(unknownType), "fixture", "id", DateTimeOffset.UtcNow.ToString("O")).Any());
        var mismatchedCode = Encoding.UTF8.GetString(decrypted).Replace("doorbell", "invalid_code");
        Require(MessageCodec.Normalize(Encoding.UTF8.GetBytes(mismatchedCode), "fixture", "id", DateTimeOffset.UtcNow.ToString("O")).Count() == 1);
        Require(!MessageCodec.Normalize(Encoding.UTF8.GetBytes("{}"), "fixture", "id", DateTimeOffset.UtcNow.ToString("O")).Any());
        Reject(() => MessageCodec.Decrypt(wire, secret, "aes_ecb"));
        Reject(() => MessageCodec.Decrypt(wire, new string('x', 32), "aes_gcm"));
        Reject(() => MessageCodec.Decrypt(Encoding.UTF8.GetBytes("{}"), secret, "aes_gcm"));
        var wrongVersion = Encoding.UTF8.GetString(wire).Replace("\"v2\"", "\"v1\"");
        Reject(() => MessageCodec.Decrypt(Encoding.UTF8.GetBytes(wrongVersion), secret, "aes_gcm"));
        var wrongProtocol = Encoding.UTF8.GetString(wire).Replace("1000", "4");
        Reject(() => MessageCodec.Decrypt(Encoding.UTF8.GetBytes(wrongProtocol), secret, "aes_gcm"));
        var badTag = tag.ToArray();
        badTag[0] ^= 1;
        Reject(() => aes.Decrypt(nonce, encrypted, badTag, new byte[plaintext.Length]));
        var invalidSignature = wire.ToArray();
        var text = Encoding.UTF8.GetString(invalidSignature).Replace(sign, new string('0', 32));
        Reject(() => MessageCodec.Decrypt(Encoding.UTF8.GetBytes(text), secret, "aes_gcm"));
        Console.WriteLine("PASS: AES-GCM, signature, tampering, ECB rejection, device filter, multiple properties, sensitive DP filtering");
    }
    private static void Require(bool condition) { if (!condition) throw new InvalidOperationException("Test failure"); }
    private static void Reject(Action action)
    {
        try { action(); } catch { return; }
        throw new InvalidOperationException("Expected rejection");
    }
}
