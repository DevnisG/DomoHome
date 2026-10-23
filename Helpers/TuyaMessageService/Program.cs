using System.Buffers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using DotPulsar;
using DotPulsar.Abstractions;
using DotPulsar.Extensions;

if (args.Contains("--self-test"))
{
    MessageTests.Run();
    return;
}

var exitCode = 0;
var environmentName = "TEST";
try
{
    var configurationLine = await Console.In.ReadLineAsync();
    if (configurationLine is null || configurationLine.Length > 16384) throw new InvalidDataException();
    var configuration = JsonSerializer.Deserialize<Configuration>(configurationLine, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new InvalidDataException();
    configuration.Validate();
    environmentName = configuration.Environment;
    using var cancellation = new CancellationTokenSource();
    if (args.Contains("--probe")) cancellation.CancelAfter(TimeSpan.FromSeconds(300));
    Console.CancelKeyPress += (_, e) => { e.Cancel = true; cancellation.Cancel(); };
    var parentProcessID = NativeProcess.GetParentProcessId();
    using var parentWatch = new Timer(_ => { if (NativeProcess.GetParentProcessId() != parentProcessID) Environment.Exit(0); }, null, 1000, 1000);
    await using var client = PulsarClient.Builder()
        .ServiceUrl(new Uri("pulsar+ssl://mqe.tuyaus.com:7285/"))
        .ConnectionSecurity(EncryptionPolicy.EnforceEncrypted)
        .VerifyCertificateAuthority(true)
        .VerifyCertificateName(true)
        .Authentication(new TuyaAuthentication(configuration.AccessId, configuration.AccessSecret))
        .ExceptionHandler(context => {
            if (context.Exception is DotPulsar.Exceptions.AuthenticationException or DotPulsar.Exceptions.AuthorizationException) {
                Output.Connection("AuthFailure", configuration.Environment);
                context.Result = FaultAction.ThrowException;
                context.ExceptionHandled = true;
                cancellation.Cancel();
            }
        })
        .Build();
    var topicSuffix = configuration.Environment == "TEST" ? "event-test" : "event";
    var wasActive = false;
    await using var consumer = client.NewConsumer()
        .Topic($"persistent://{configuration.AccessId}/out/{topicSuffix}")
        .SubscriptionName(configuration.AccessId + "-sub")
        .SubscriptionType(SubscriptionType.Exclusive)
        .StateChangedHandler(change => {
            var active = change.ConsumerState == ConsumerState.Active;
            Output.Connection(active ? "connected" : "disconnected", configuration.Environment);
            if (active) wasActive = true;
            else if (wasActive) cancellation.Cancel();
        })
        .Create();
    await foreach (var message in consumer.Messages(cancellation.Token))
    {
        try
        {
            if (message.Data.Length > 262144) throw new InvalidDataException();
            var payload = message.Data.ToArray();
            var encryption = message.Properties.TryGetValue("em", out var mode) ? mode : "";
            var data = MessageCodec.Decrypt(payload, configuration.AccessSecret, encryption);
            var id = message.MessageId;
            var messageID = $"{id.LedgerId}:{id.EntryId}:{id.Partition}:{id.BatchIndex}";
            foreach (var property in MessageCodec.Normalize(data, configuration.DeviceId, messageID,
                         message.PublishTimeAsDateTimeOffset.ToString("O")).ToArray())
                Output.Write(property);
        }
        catch (Exception error) when (error is MessageValidationException or CryptographicException or JsonException or InvalidDataException or FormatException or ArgumentException or KeyNotFoundException or InvalidOperationException or OverflowException)
        {
            Output.Write(new { schemaVersion = 1, type = "diagnostic", state = "DecodingFailure", reason = error is MessageValidationException validation ? validation.Code : error.GetType().Name });
            Console.Error.WriteLine("DecodingFailure");
        }
        await consumer.Acknowledge(message, cancellation.Token);
    }
}
catch (OperationCanceledException) { }
catch (Exception error)
{
    var state = error is InvalidDataException or JsonException ? "ConfigurationMissing"
        : error is DotPulsar.Exceptions.AuthenticationException or DotPulsar.Exceptions.AuthorizationException ? "AuthFailure" : "ConnectionLost";
    Output.Connection(state, environmentName);
    Console.Error.WriteLine(state);
    exitCode = 1;
}
Environment.ExitCode = exitCode;

internal sealed record Configuration(
    int SchemaVersion, string AccessId, string AccessSecret, string DeviceId, string Environment)
{
    public void Validate()
    {
        if (SchemaVersion != 1 || string.IsNullOrWhiteSpace(AccessId) || string.IsNullOrWhiteSpace(DeviceId)
            || string.IsNullOrEmpty(AccessSecret) || AccessSecret.Length != 32
            || !AccessId.All(char.IsAsciiLetterOrDigit) || !DeviceId.All(char.IsAsciiLetterOrDigit)
            || Environment is not ("TEST" or "PROD")) throw new InvalidDataException();
    }
}

internal static class Output
{
    private static readonly object Gate = new();
    internal static void Write(object value)
    {
        lock (Gate)
        {
            Console.Out.WriteLine(JsonSerializer.Serialize(value));
            Console.Out.Flush();
        }
    }
    internal static void Connection(string state, string environment) => Write(new { schemaVersion = 1, type = "connection", state, environment });
}

internal sealed class TuyaAuthentication : IAuthentication
{
    private readonly byte[] data;
    public string AuthenticationMethodName => "auth1";
    public TuyaAuthentication(string accessId, string secret)
    {
        var password = Hash(accessId + Hash(secret)).Substring(8, 16);
        data = JsonSerializer.SerializeToUtf8Bytes(new { username = accessId, password });
    }
    private static string Hash(string value) => Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
    public ValueTask<byte[]> GetAuthenticationData(CancellationToken cancellationToken) => ValueTask.FromResult(data);
}

internal static class MessageCodec
{
    internal static byte[] Decrypt(byte[] wire, string secret, string encryption)
    {
        if (encryption != "aes_gcm" || secret.Length != 32) throw new MessageValidationException("EncryptionMismatch");
        using var document = JsonDocument.Parse(wire);
        var envelope = document.RootElement;
        if (!envelope.TryGetProperty("protocol", out var protocol)) throw new MessageValidationException("MissingProtocol");
        if (protocol.GetInt32() != 1000) throw new MessageValidationException("ProtocolMismatch");
        if (envelope.TryGetProperty("encryptVersion", out var version) && version.GetString() != "v2") throw new MessageValidationException("VersionMismatch");
        if (!envelope.TryGetProperty("sign", out var signatureElement)) throw new MessageValidationException("MissingSignature");
        var signature = signatureElement.GetString() ?? throw new MessageValidationException("MissingSignature");
        var knownFields = new HashSet<string> { "data", "encryptVersion", "protocol", "pv", "sign", "t" };
        if (envelope.EnumerateObject().Any(property => !knownFields.Contains(property.Name))) throw new MessageValidationException("UnsupportedEnvelope");
        var signedFields = new[] { "data", "protocol", "pv", "t" };
        var parts = signedFields.Select(name => {
            var value = envelope.GetProperty(name);
            if (value.ValueKind is not (JsonValueKind.String or JsonValueKind.Number)) throw new InvalidDataException();
            var text = value.ValueKind == JsonValueKind.String ? value.GetString() : value.GetRawText();
            if (string.IsNullOrEmpty(text)) throw new InvalidDataException();
            return name + "=" + text;
        });
        var signedData = string.Join("||", parts) + "||" + secret;
        var expected = MD5.HashData(Encoding.UTF8.GetBytes(signedData));
        var supplied = Convert.FromHexString(signature);
        if (!CryptographicOperations.FixedTimeEquals(expected, supplied)) throw new MessageValidationException("SignatureMismatch");
        var encrypted = Convert.FromBase64String(envelope.GetProperty("data").GetString() ?? "");
        if (encrypted.Length < 28) throw new InvalidDataException();
        var plaintext = new byte[encrypted.Length - 28];
        using var aes = new AesGcm(Encoding.UTF8.GetBytes(secret.Substring(8, 16)), 16);
        aes.Decrypt(encrypted.AsSpan(0, 12), encrypted.AsSpan(12, plaintext.Length), encrypted.AsSpan(encrypted.Length - 16), plaintext);
        return plaintext;
    }

    internal static IEnumerable<object> Normalize(byte[] decrypted, string deviceID, string messageID, string publishedAt)
    {
        using var document = JsonDocument.Parse(decrypted);
        var root = document.RootElement;
        if (root.TryGetProperty("data", out var nested) && nested.ValueKind == JsonValueKind.Object) root = nested;
        if (!root.TryGetProperty("bizCode", out var bizCode) || bizCode.GetString() != "devicePropertyMessage") yield break;
        var data = root.GetProperty("bizData");
        if (data.GetProperty("devId").GetString() != deviceID) yield break;
        var dataID = data.GetProperty("dataId").GetString();
        if (string.IsNullOrEmpty(dataID) || dataID.Length > 256) throw new InvalidDataException();
        var properties = data.GetProperty("properties");
        if (properties.ValueKind != JsonValueKind.Array || properties.GetArrayLength() > 256) throw new InvalidDataException();
        foreach (var property in properties.EnumerateArray())
        {
            if (!property.TryGetProperty("dpId", out var dpElement) || !property.TryGetProperty("code", out var codeElement)) continue;
            var dpID = dpElement.GetInt32();
            var code = codeElement.GetString();
            if (!((dpID == 19 && code == "doorbell") || (dpID == 9 && code == "unlock_request") || (dpID == 15 && code == "unlock_app"))) continue;
            var value = property.GetProperty("value");
            if (value.ValueKind is not (JsonValueKind.True or JsonValueKind.False or JsonValueKind.Number or JsonValueKind.String)) continue;
            if (value.ValueKind == JsonValueKind.String && (value.GetString()?.Length ?? 0) > 64) continue;
            yield return new { schemaVersion = 1, type = "property", deviceId = deviceID, dataId = dataID,
                messageId = messageID, dpId = dpID, code, value = value.Clone(), eventTimeMs = property.GetProperty("time").GetInt64(), publishedAt };
        }
    }
}

internal static class NativeProcess
{
    [System.Runtime.InteropServices.DllImport("libc", EntryPoint = "getppid")]
    internal static extern int GetParentProcessId();
}

internal sealed class MessageValidationException(string code) : Exception
{
    internal string Code { get; } = code;
}
