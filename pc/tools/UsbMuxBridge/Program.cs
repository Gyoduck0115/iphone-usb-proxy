using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;

// UsbMuxBridge: Zero-dependency Windows companion tool for iphone-usb-proxy.
// Subcommands:
//   devices [--json]                  : Query Apple Mobile Device Service (127.0.0.1:27015) for USB iPhones.
//   forward <localPort> <devicePort> [--udid <serial>]
//                                     : Native usbmux TCP forwarder (drop-in fallback for iproxy).
//   mock-server [--port 1080]         : Local SOCKS5 + SagerNet UoT v1/v2 server for Stage 0/3 PC verification.
//   selftest                          : End-to-end protocol test suite (SOCKS5 TCP + UoT v1 + UoT v2 + usbmuxd check).

if (args.Length == 0 || args[0] is "-h" or "--help")
{
    PrintUsage();
    return 0;
}

using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    cts.Cancel();
};

try
{
    switch (args[0].ToLowerInvariant())
    {
        case "devices":
            return await RunDevicesAsync(args.Contains("--json"), cts.Token);
        case "forward":
            return await RunForwardAsync(args.Skip(1).ToArray(), cts.Token);
        case "mock-server":
            return await RunMockServerAsync(args.Skip(1).ToArray(), cts.Token);
        case "selftest":
            return await RunSelfTestAsync(cts.Token);
        default:
            Console.Error.WriteLine($"Unknown command: {args[0]}");
            PrintUsage();
            return 2;
    }
}
catch (OperationCanceledException)
{
    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine($"[UsbMuxBridge] Error: {ex.Message}");
    return 1;
}

static void PrintUsage()
{
    Console.WriteLine("""
    UsbMuxBridge - Apple usbmuxd forwarder & local SOCKS5/UoT verification tool

    Usage:
      UsbMuxBridge devices [--json]
      UsbMuxBridge forward <localPort> <devicePort> [--udid <serial>]
      UsbMuxBridge mock-server [--port 1080]
      UsbMuxBridge selftest
    """);
}

static async Task<int> RunDevicesAsync(bool jsonOutput, CancellationToken ct)
{
    var devices = await UsbMuxClient.ListDevicesAsync(ct);
    if (jsonOutput)
    {
        Console.WriteLine(JsonSerializer.Serialize(devices, new JsonSerializerOptions { WriteIndented = true }));
        return 0;
    }
    if (devices.Count == 0)
    {
        Console.WriteLine("No USB-connected iOS devices found via usbmuxd (127.0.0.1:27015).");
        return 0;
    }
    foreach (var d in devices)
    {
        Console.WriteLine($"DeviceID={d.DeviceId}  Connection={d.ConnectionType}  Serial={d.SerialNumber}");
    }
    return 0;
}

static async Task<int> RunForwardAsync(string[] subArgs, CancellationToken ct)
{
    if (subArgs.Length < 2 ||
        !int.TryParse(subArgs[0], out int localPort) ||
        !int.TryParse(subArgs[1], out int devicePort) ||
        localPort is < 1 or > 65535 ||
        devicePort is < 1 or > 65535)
    {
        Console.Error.WriteLine("Usage: UsbMuxBridge forward <localPort> <devicePort> [--udid <serial>]");
        return 2;
    }

    string? udid = null;
    for (int i = 2; i < subArgs.Length - 1; i++)
    {
        if (subArgs[i] == "--udid") udid = subArgs[i + 1];
    }

    var listener = new TcpListener(IPAddress.Loopback, localPort);
    listener.Start();
    Console.WriteLine($"[usbmux] Listening on 127.0.0.1:{localPort} -> iPhone:{devicePort} (Ctrl+C to stop)");

    try
    {
        while (!ct.IsCancellationRequested)
        {
            var client = await listener.AcceptTcpClientAsync(ct);
            _ = HandleForwardedClientAsync(client, devicePort, udid, ct);
        }
    }
    finally
    {
        listener.Stop();
    }
    return 0;
}

static async Task HandleForwardedClientAsync(TcpClient localClient, int devicePort, string? udid, CancellationToken ct)
{
    using (localClient)
    {
        localClient.NoDelay = true;
        try
        {
            var devices = await UsbMuxClient.ListDevicesAsync(ct);
            var usbDevices = devices.Where(d => string.Equals(d.ConnectionType, "USB", StringComparison.OrdinalIgnoreCase)).ToList();
            var target = udid is not null
                ? usbDevices.FirstOrDefault(d => string.Equals(d.SerialNumber, udid, StringComparison.OrdinalIgnoreCase))
                : usbDevices.FirstOrDefault();

            if (target is null)
            {
                Console.Error.WriteLine("[usbmux] No USB iPhone detected (is it unlocked and trusted?)");
                return;
            }

            using var deviceClient = await UsbMuxClient.ConnectDevicePortAsync(target.DeviceId, (ushort)devicePort, ct);
            deviceClient.NoDelay = true;

            var localStream = localClient.GetStream();
            var deviceStream = deviceClient.GetStream();

            var t1 = PumpHalfCloseAsync(localStream, deviceClient, deviceStream, ct);
            var t2 = PumpHalfCloseAsync(deviceStream, localClient, localStream, ct);
            await Task.WhenAll(t1, t2);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            Console.Error.WriteLine($"[usbmux] Forward session error: {ex.Message}");
        }
    }
}

static async Task PumpHalfCloseAsync(NetworkStream src, TcpClient dstClient, NetworkStream dst, CancellationToken ct)
{
    byte[] buffer = new byte[32 * 1024];
    try
    {
        while (true)
        {
            int n = await src.ReadAsync(buffer, ct);
            if (n == 0) break;
            await dst.WriteAsync(buffer.AsMemory(0, n), ct);
        }
        try { dstClient.Client.Shutdown(SocketShutdown.Send); } catch { }
    }
    catch { }
}

static async Task<int> RunMockServerAsync(string[] subArgs, CancellationToken ct)
{
    int port = 1080;
    for (int i = 0; i < subArgs.Length - 1; i++)
    {
        if (subArgs[i] == "--port" && int.TryParse(subArgs[i + 1], out int parsed))
            port = parsed;
    }

    await using var server = new LocalSocksUoTServer(port);
    int bound = server.Start();
    Console.WriteLine($"[mock-server] SOCKS5 + UoT v1/v2 server listening on 127.0.0.1:{bound} (Ctrl+C to stop)");
    try
    {
        await Task.Delay(Timeout.Infinite, ct);
    }
    catch (OperationCanceledException) { }
    return 0;
}

static async Task<int> RunSelfTestAsync(CancellationToken parentCt)
{
    using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(parentCt);
    timeoutCts.CancelAfter(TimeSpan.FromSeconds(15));
    var ct = timeoutCts.Token;

    Console.WriteLine("1) Checking Apple Mobile Device Service (usbmuxd 127.0.0.1:27015)...");
    try
    {
        var devices = await UsbMuxClient.ListDevicesAsync(ct);
        Console.WriteLine($"   OK: usbmuxd reachable ({devices.Count} device(s) attached).");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"   WARN: usbmuxd check failed ({ex.Message}).");
    }

    Console.WriteLine("2) Testing SOCKS5 TCP CONNECT + half-close relay...");
    using var tcpEcho = new TcpListener(IPAddress.Loopback, 0);
    tcpEcho.Start();
    int tcpEchoPort = ((IPEndPoint)tcpEcho.LocalEndpoint).Port;
    var echoTask = Task.Run(async () =>
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var c = await tcpEcho.AcceptTcpClientAsync(ct);
                _ = Task.Run(async () =>
                {
                    using (c)
                    {
                        var s = c.GetStream();
                        byte[] buf = new byte[4096];
                        int n;
                        while ((n = await s.ReadAsync(buf, ct)) > 0)
                            await s.WriteAsync(buf.AsMemory(0, n), ct);
                    }
                }, ct);
            }
            catch { break; }
        }
    }, ct);

    await using var proxy = new LocalSocksUoTServer(0);
    int proxyPort = proxy.Start();

    // Test SOCKS5 TCP CONNECT IPv4
    using (var client = new TcpClient())
    {
        await client.ConnectAsync(IPAddress.Loopback, proxyPort, ct);
        var s = client.GetStream();
        await s.WriteAsync(new byte[] { 0x05, 0x01, 0x00 }, ct);
        byte[] g = await StreamIo.ReadExactAsync(s, 2, ct);
        if (g[0] != 0x05 || g[1] != 0x00) throw new Exception("SOCKS5 greeting failed");

        byte[] req = { 0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, (byte)(tcpEchoPort >> 8), (byte)(tcpEchoPort & 0xff) };
        await s.WriteAsync(req, ct);
        byte[] rep = await StreamIo.ReadExactAsync(s, 10, ct);
        if (rep[1] != 0x00) throw new Exception($"SOCKS5 CONNECT failed: REP={rep[1]}");

        byte[] msg = Encoding.UTF8.GetBytes("hello-socks5-tcp");
        await s.WriteAsync(msg, ct);
        byte[] back = await StreamIo.ReadExactAsync(s, msg.Length, ct);
        if (!back.SequenceEqual(msg)) throw new Exception("TCP echo mismatch");
    }
    Console.WriteLine("   OK: SOCKS5 TCP CONNECT echo passed.");

    Console.WriteLine("3) Testing SagerNet UoT v2 (isConnect=false & isConnect=true) and UoT v1 UDP echo...");
    using var udpEcho = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
    int udpEchoPort = ((IPEndPoint)udpEcho.Client.LocalEndPoint!).Port;
    var udpEchoTask = Task.Run(async () =>
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var r = await udpEcho.ReceiveAsync(ct);
                await udpEcho.SendAsync(r.Buffer, r.RemoteEndPoint, ct);
            }
            catch { break; }
        }
    }, ct);

    // UoT v2 non-connect test
    await TestUoTV2Async(proxyPort, udpEchoPort, isConnect: false, ct);
    // UoT v2 connect test
    await TestUoTV2Async(proxyPort, udpEchoPort, isConnect: true, ct);
    // UoT v1 test
    await TestUoTV1Async(proxyPort, udpEchoPort, ct);
    Console.WriteLine("   OK: UoT v1 and UoT v2 (connect & non-connect) passed.");

    tcpEcho.Stop();
    udpEcho.Close();
    return 0;
}

static async Task TestUoTV2Async(int proxyPort, int udpEchoPort, bool isConnect, CancellationToken ct)
{
    using var client = new TcpClient();
    await client.ConnectAsync(IPAddress.Loopback, proxyPort, ct);
    var s = client.GetStream();

    await s.WriteAsync(new byte[] { 0x05, 0x01, 0x00 }, ct);
    _ = await StreamIo.ReadExactAsync(s, 2, ct);

    byte[] magic = Encoding.UTF8.GetBytes("sp.v2.udp-over-tcp.arpa");
    var connectReq = new MemoryStream();
    connectReq.Write(new byte[] { 0x05, 0x01, 0x00, 0x03, (byte)magic.Length });
    connectReq.Write(magic);
    connectReq.Write(new byte[] { 0x00, 0x00 });
    await s.WriteAsync(connectReq.ToArray(), ct);
    byte[] rep = await StreamIo.ReadExactAsync(s, 10, ct);
    if (rep[1] != 0x00) throw new Exception("UoT v2 CONNECT failed");

    // V2 request header: [isConnect][Socksaddr: 0x01 IPv4 127.0.0.1 port]
    byte[] v2Header = { (byte)(isConnect ? 1 : 0), 0x01, 127, 0, 0, 1, (byte)(udpEchoPort >> 8), (byte)(udpEchoPort & 0xff) };
    byte[] payload = Encoding.UTF8.GetBytes(isConnect ? "uot-v2-connect" : "uot-v2-packet");

    var frame = new MemoryStream();
    frame.Write(v2Header);
    if (!isConnect)
    {
        // UoT AddrParser ATYP: 0x00=IPv4
        frame.Write(new byte[] { 0x00, 127, 0, 0, 1, (byte)(udpEchoPort >> 8), (byte)(udpEchoPort & 0xff) });
    }
    frame.Write(new byte[] { (byte)(payload.Length >> 8), (byte)(payload.Length & 0xff) });
    frame.Write(payload);
    await s.WriteAsync(frame.ToArray(), ct);

    if (!isConnect)
    {
        byte[] addrHdr = await StreamIo.ReadExactAsync(s, 7, ct); // 0x00 + 4B IPv4 + 2B port
        if (addrHdr[0] != 0x00) throw new Exception($"Expected UoT IPv4 ATYP 0x00, got {addrHdr[0]}");
    }
    byte[] lenBytes = await StreamIo.ReadExactAsync(s, 2, ct);
    int len = BinaryPrimitives.ReadUInt16BigEndian(lenBytes);
    byte[] reply = await StreamIo.ReadExactAsync(s, len, ct);
    if (!reply.SequenceEqual(payload)) throw new Exception("UoT v2 echo mismatch");
}

static async Task TestUoTV1Async(int proxyPort, int udpEchoPort, CancellationToken ct)
{
    using var client = new TcpClient();
    await client.ConnectAsync(IPAddress.Loopback, proxyPort, ct);
    var s = client.GetStream();

    await s.WriteAsync(new byte[] { 0x05, 0x01, 0x00 }, ct);
    _ = await StreamIo.ReadExactAsync(s, 2, ct);

    byte[] magic = Encoding.UTF8.GetBytes("sp.udp-over-tcp.arpa");
    var connectReq = new MemoryStream();
    connectReq.Write(new byte[] { 0x05, 0x01, 0x00, 0x03, (byte)magic.Length });
    connectReq.Write(magic);
    connectReq.Write(new byte[] { 0x00, 0x00 });
    await s.WriteAsync(connectReq.ToArray(), ct);
    byte[] rep = await StreamIo.ReadExactAsync(s, 10, ct);
    if (rep[1] != 0x00) throw new Exception("UoT v1 CONNECT failed");

    byte[] payload = Encoding.UTF8.GetBytes("uot-v1-packet");
    var frame = new MemoryStream();
    frame.Write(new byte[] { 0x00, 127, 0, 0, 1, (byte)(udpEchoPort >> 8), (byte)(udpEchoPort & 0xff) });
    frame.Write(new byte[] { (byte)(payload.Length >> 8), (byte)(payload.Length & 0xff) });
    frame.Write(payload);
    await s.WriteAsync(frame.ToArray(), ct);

    byte[] addrHdr = await StreamIo.ReadExactAsync(s, 7, ct);
    if (addrHdr[0] != 0x00) throw new Exception("Expected UoT v1 IPv4 ATYP 0x00");
    byte[] lenBytes = await StreamIo.ReadExactAsync(s, 2, ct);
    int len = BinaryPrimitives.ReadUInt16BigEndian(lenBytes);
    byte[] reply = await StreamIo.ReadExactAsync(s, len, ct);
    if (!reply.SequenceEqual(payload)) throw new Exception("UoT v1 echo mismatch");
}

// MARK: - Apple usbmuxd Plist Protocol Client (Windows 127.0.0.1:27015)

record UsbMuxDevice(int DeviceId, string SerialNumber, string ConnectionType);

static class UsbMuxClient
{
    private const int UsbMuxPort = 27015;
    private const uint ProtocolPlist = 1;
    private const uint MessagePlist = 8;
    private static uint _tag = 1;

    public static async Task<List<UsbMuxDevice>> ListDevicesAsync(CancellationToken ct)
    {
        using var tcp = new TcpClient();
        await tcp.ConnectAsync(IPAddress.Loopback, UsbMuxPort, ct);
        var stream = tcp.GetStream();

        string plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>BundleID</key><string>com.local.usbproxy</string>
                <key>ClientVersionString</key><string>1.0</string>
                <key>MessageType</key><string>ListDevices</string>
                <key>ProgName</key><string>UsbMuxBridge</string>
            </dict>
            </plist>
            """;

        await SendPlistAsync(stream, plist, ct);
        string replyXml = await ReadPlistAsync(stream, ct);
        return ParseDeviceList(replyXml);
    }

    public static async Task<TcpClient> ConnectDevicePortAsync(int deviceId, ushort devicePort, CancellationToken ct)
    {
        var tcp = new TcpClient();
        try
        {
            await tcp.ConnectAsync(IPAddress.Loopback, UsbMuxPort, ct);
            var stream = tcp.GetStream();

            // Apple usbmuxd expects PortNumber in network byte order (big-endian swapped inside the integer!).
            ushort swappedPort = BinaryPrimitives.ReverseEndianness(devicePort);
            string plist = $"""
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>BundleID</key><string>com.local.usbproxy</string>
                    <key>ClientVersionString</key><string>1.0</string>
                    <key>DeviceID</key><integer>{deviceId}</integer>
                    <key>MessageType</key><string>Connect</string>
                    <key>PortNumber</key><integer>{swappedPort}</integer>
                    <key>ProgName</key><string>UsbMuxBridge</string>
                </dict>
                </plist>
                """;

            await SendPlistAsync(stream, plist, ct);
            string replyXml = await ReadPlistAsync(stream, ct);
            int code = ParseResultCode(replyXml);
            if (code != 0)
            {
                throw new InvalidOperationException($"usbmuxd Connect to DeviceID={deviceId} port {devicePort} failed (Result={code}). Is USBProxy running on the iPhone?");
            }
            return tcp;
        }
        catch
        {
            tcp.Dispose();
            throw;
        }
    }

    private static async Task SendPlistAsync(NetworkStream stream, string xml, CancellationToken ct)
    {
        byte[] payload = Encoding.UTF8.GetBytes(xml);
        byte[] header = new byte[16];
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(0, 4), (uint)(16 + payload.Length));
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(4, 4), ProtocolPlist);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(8, 4), MessagePlist);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(12, 4), Interlocked.Increment(ref _tag));

        await stream.WriteAsync(header, ct);
        await stream.WriteAsync(payload, ct);
    }

    private static async Task<string> ReadPlistAsync(NetworkStream stream, CancellationToken ct)
    {
        byte[] header = await StreamIo.ReadExactAsync(stream, 16, ct);
        uint totalLen = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(0, 4));
        if (totalLen < 16 || totalLen > 4 * 1024 * 1024)
            throw new InvalidDataException($"Invalid usbmuxd packet length: {totalLen}");
        byte[] body = await StreamIo.ReadExactAsync(stream, (int)(totalLen - 16), ct);
        return Encoding.UTF8.GetString(body);
    }

    private static List<UsbMuxDevice> ParseDeviceList(string xml)
    {
        var result = new List<UsbMuxDevice>();
        var doc = XDocument.Parse(xml, LoadOptions.None);
        var rootDict = doc.Root?.Element("dict");
        if (rootDict is null) return result;

        var deviceArray = GetPlistValue(rootDict, "DeviceList");
        if (deviceArray is null) return result;

        foreach (var itemDict in deviceArray.Elements("dict"))
        {
            var props = GetPlistValue(itemDict, "Properties");
            if (props is null) continue;
            int id = int.TryParse(GetPlistValue(props, "DeviceID")?.Value, out int parsedId) ? parsedId : 0;
            string serial = GetPlistValue(props, "SerialNumber")?.Value ?? "";
            string connType = GetPlistValue(props, "ConnectionType")?.Value ?? "Unknown";
            if (id > 0) result.Add(new UsbMuxDevice(id, serial, connType));
        }
        return result;
    }

    private static int ParseResultCode(string xml)
    {
        var doc = XDocument.Parse(xml, LoadOptions.None);
        var rootDict = doc.Root?.Element("dict");
        if (rootDict is null) return -1;
        return int.TryParse(GetPlistValue(rootDict, "Number")?.Value, out int code) ? code : -1;
    }

    private static XElement? GetPlistValue(XElement dict, string key)
    {
        var elements = dict.Elements().ToList();
        for (int i = 0; i < elements.Count - 1; i++)
        {
            if (elements[i].Name == "key" && elements[i].Value == key)
                return elements[i + 1];
        }
        return null;
    }
}

// MARK: - Local SOCKS5 + SagerNet UoT v1/v2 Reference Server (for Stage 0/3 PC verification)

sealed class LocalSocksUoTServer : IAsyncDisposable
{
    private readonly TcpListener _listener;
    private readonly CancellationTokenSource _cts = new();
    private Task? _acceptLoop;

    public LocalSocksUoTServer(int port)
    {
        _listener = new TcpListener(IPAddress.Loopback, port);
    }

    public int Start()
    {
        _listener.Start();
        int port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _acceptLoop = Task.Run(AcceptLoopAsync);
        return port;
    }

    private async Task AcceptLoopAsync()
    {
        while (!_cts.IsCancellationRequested)
        {
            try
            {
                var client = await _listener.AcceptTcpClientAsync(_cts.Token);
                _ = HandleClientAsync(client, _cts.Token);
            }
            catch { break; }
        }
    }

    private static async Task HandleClientAsync(TcpClient client, CancellationToken ct)
    {
        using (client)
        {
            client.NoDelay = true;
            var stream = client.GetStream();
            try
            {
                // 1. Greeting
                byte[] hdr = await StreamIo.ReadExactAsync(stream, 2, ct);
                if (hdr[0] != 0x05) return;
                byte[] methods = await StreamIo.ReadExactAsync(stream, hdr[1], ct);
                if (!methods.Contains((byte)0x00))
                {
                    await stream.WriteAsync(new byte[] { 0x05, 0xFF }, ct);
                    return;
                }
                await stream.WriteAsync(new byte[] { 0x05, 0x00 }, ct);

                // 2. Request
                byte[] reqHdr = await StreamIo.ReadExactAsync(stream, 3, ct);
                if (reqHdr[0] != 0x05 || reqHdr[1] != 0x01)
                {
                    await stream.WriteAsync(new byte[] { 0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }, ct);
                    return;
                }

                var (host, port) = await ReadSocksaddrAsync(stream, ct);
                if (string.Equals(host, "sp.v2.udp-over-tcp.arpa", StringComparison.OrdinalIgnoreCase))
                {
                    await stream.WriteAsync(new byte[] { 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }, ct);
                    await HandleUoTAsync(stream, isV2: true, ct);
                    return;
                }
                if (string.Equals(host, "sp.udp-over-tcp.arpa", StringComparison.OrdinalIgnoreCase))
                {
                    await stream.WriteAsync(new byte[] { 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }, ct);
                    await HandleUoTAsync(stream, isV2: false, ct);
                    return;
                }

                using var remote = new TcpClient();
                remote.NoDelay = true;
                try
                {
                    await remote.ConnectAsync(host, port, ct);
                }
                catch
                {
                    await stream.WriteAsync(new byte[] { 0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }, ct);
                    return;
                }

                await stream.WriteAsync(new byte[] { 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }, ct);
                var remoteStream = remote.GetStream();
                await Task.WhenAll(
                    RelayHalfCloseAsync(stream, remote, remoteStream, ct),
                    RelayHalfCloseAsync(remoteStream, client, stream, ct));
            }
            catch { }
        }
    }

    private static async Task HandleUoTAsync(NetworkStream tcp, bool isV2, CancellationToken ct)
    {
        bool isConnect = false;
        IPEndPoint? fixedTarget = null;
        if (isV2)
        {
            byte[] flag = await StreamIo.ReadExactAsync(tcp, 1, ct);
            isConnect = flag[0] != 0;
            var (h, p) = await ReadSocksaddrAsync(tcp, ct);
            if (isConnect) fixedTarget = await ResolveUdpEndpointAsync(h, p, ct);
        }

        using var udp = new UdpClient(new IPEndPoint(IPAddress.Any, 0));
        using var writeLock = new SemaphoreSlim(1, 1);
        using var uotCts = CancellationTokenSource.CreateLinkedTokenSource(ct);

        var recvTask = Task.Run(async () =>
        {
            try
            {
                while (!uotCts.IsCancellationRequested)
                {
                    var res = await udp.ReceiveAsync(uotCts.Token);
                    var ms = new MemoryStream();
                    if (!isConnect)
                    {
                        WriteUoTAddr(ms, res.RemoteEndPoint);
                    }
                    byte[] len = new byte[2];
                    BinaryPrimitives.WriteUInt16BigEndian(len, (ushort)res.Buffer.Length);
                    ms.Write(len);
                    ms.Write(res.Buffer);

                    await writeLock.WaitAsync(uotCts.Token);
                    try { await tcp.WriteAsync(ms.ToArray(), uotCts.Token); }
                    finally { writeLock.Release(); }
                }
            }
            catch { }
        }, uotCts.Token);

        try
        {
            while (!uotCts.IsCancellationRequested)
            {
                IPEndPoint target;
                if (isConnect)
                {
                    target = fixedTarget!;
                }
                else
                {
                    var (h, p) = await ReadUoTAddrAsync(tcp, uotCts.Token);
                    target = await ResolveUdpEndpointAsync(h, p, uotCts.Token);
                }

                byte[] lenBuf = await StreamIo.ReadExactAsync(tcp, 2, uotCts.Token);
                int len = BinaryPrimitives.ReadUInt16BigEndian(lenBuf);
                byte[] payload = await StreamIo.ReadExactAsync(tcp, len, uotCts.Token);
                await udp.SendAsync(payload, target, uotCts.Token);
            }
        }
        catch { }
        finally
        {
            uotCts.Cancel();
            udp.Close();
            await recvTask;
        }
    }

    private static async Task<(string Host, int Port)> ReadSocksaddrAsync(Stream s, CancellationToken ct)
    {
        byte atyp = (await StreamIo.ReadExactAsync(s, 1, ct))[0];
        string host = atyp switch
        {
            0x01 => new IPAddress(await StreamIo.ReadExactAsync(s, 4, ct)).ToString(),
            0x03 => Encoding.UTF8.GetString(await StreamIo.ReadExactAsync(s, (await StreamIo.ReadExactAsync(s, 1, ct))[0], ct)),
            0x04 => new IPAddress(await StreamIo.ReadExactAsync(s, 16, ct)).ToString(),
            _ => throw new InvalidDataException($"Unsupported SOCKS5 ATYP: {atyp}")
        };
        int port = BinaryPrimitives.ReadUInt16BigEndian(await StreamIo.ReadExactAsync(s, 2, ct));
        return (host, port);
    }

    private static async Task<(string Host, int Port)> ReadUoTAddrAsync(Stream s, CancellationToken ct)
    {
        byte atyp = (await StreamIo.ReadExactAsync(s, 1, ct))[0];
        string host = atyp switch
        {
            0x00 => new IPAddress(await StreamIo.ReadExactAsync(s, 4, ct)).ToString(),
            0x01 => new IPAddress(await StreamIo.ReadExactAsync(s, 16, ct)).ToString(),
            0x02 => Encoding.UTF8.GetString(await StreamIo.ReadExactAsync(s, (await StreamIo.ReadExactAsync(s, 1, ct))[0], ct)),
            _ => throw new InvalidDataException($"Unsupported UoT ATYP: {atyp}")
        };
        int port = BinaryPrimitives.ReadUInt16BigEndian(await StreamIo.ReadExactAsync(s, 2, ct));
        return (host, port);
    }

    private static void WriteUoTAddr(Stream s, IPEndPoint ep)
    {
        byte[] bytes = ep.Address.GetAddressBytes();
        s.WriteByte(ep.AddressFamily == AddressFamily.InterNetwork ? (byte)0x00 : (byte)0x01);
        s.Write(bytes);
        byte[] port = new byte[2];
        BinaryPrimitives.WriteUInt16BigEndian(port, (ushort)ep.Port);
        s.Write(port);
    }

    private static async Task<IPEndPoint> ResolveUdpEndpointAsync(string host, int port, CancellationToken ct)
    {
        if (IPAddress.TryParse(host, out var ip))
            return new IPEndPoint(ip, port);
        var addrs = await Dns.GetHostAddressesAsync(host, AddressFamily.InterNetwork, ct);
        return new IPEndPoint(addrs[0], port);
    }

    private static async Task RelayHalfCloseAsync(NetworkStream src, TcpClient dstClient, NetworkStream dst, CancellationToken ct)
    {
        byte[] buf = new byte[32 * 1024];
        try
        {
            while (true)
            {
                int n = await src.ReadAsync(buf, ct);
                if (n == 0) break;
                await dst.WriteAsync(buf.AsMemory(0, n), ct);
            }
            try { dstClient.Client.Shutdown(SocketShutdown.Send); } catch { }
        }
        catch { }
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        _listener.Stop();
        if (_acceptLoop is not null)
        {
            try { await _acceptLoop; } catch { }
        }
        _cts.Dispose();
    }
}

static class StreamIo
{
    public static async Task<byte[]> ReadExactAsync(Stream stream, int count, CancellationToken ct)
    {
        byte[] buf = new byte[count];
        int offset = 0;
        while (offset < count)
        {
            int n = await stream.ReadAsync(buf.AsMemory(offset, count - offset), ct);
            if (n == 0) throw new EndOfStreamException();
            offset += n;
        }
        return buf;
    }
}
