Set-StrictMode -Version Latest
if (-not ('CECTestPeer' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Concurrent;
using System.IO;
using System.Runtime.InteropServices;
public sealed class CECTestPeer : IDisposable {
    readonly CancellationTokenSource stop = new CancellationTokenSource();
    readonly TcpListener listener;
    readonly UdpClient udp;
    readonly Task loop;
    readonly ConcurrentBag<TcpClient> clients = new ConcurrentBag<TcpClient>();
    readonly ConcurrentBag<Task> handlers = new ConcurrentBag<Task>();
    readonly string mode;
    readonly int size;
    readonly EventWaitHandle receivedEvent;
    public readonly ConcurrentBag<byte[]> Payloads = new ConcurrentBag<byte[]>();
    int accepts, received;
    public int Port { get; private set; }
    public int Accepts { get { return Volatile.Read(ref accepts); } }
    public int Received { get { return Volatile.Read(ref received); } }
    public CECTestPeer(string protocol, string mode, int size, string eventName = null) {
        this.mode = mode; this.size = size;
        if (eventName != null) receivedEvent = EventWaitHandle.OpenExisting(eventName);
        if (protocol == "tcp") {
            listener = new TcpListener(IPAddress.Loopback,0); listener.Start();
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            loop = TcpLoop();
        } else {
            udp = new UdpClient(new IPEndPoint(IPAddress.Loopback,0));
            Port = ((IPEndPoint)udp.Client.LocalEndPoint).Port;
            loop = UdpLoop();
        }
    }
    async Task TcpLoop() {
        try { while (!stop.IsCancellationRequested) {
            var c = await listener.AcceptTcpClientAsync(stop.Token); c.NoDelay = true;
            clients.Add(c); int attempt = Interlocked.Increment(ref accepts);
            handlers.Add(Handle(c,attempt));
        }} catch (OperationCanceledException) {} catch (SocketException) { if (!stop.IsCancellationRequested) throw; }
    }
    async Task Handle(TcpClient c, int attempt) {
        try { using (c) { var stream = c.GetStream(); var buffer = new byte[Math.Max(1,size)];
            if (mode == "reconnect" || mode == "corruptHold" || mode == "short" || mode == "hold" || mode == "echoThenHold") {
                int count = 0;
                while (count < size) { int n = await stream.ReadAsync(buffer.AsMemory(count,size-count),stop.Token); if (n == 0) return; count += n; }
                Payloads.Add((byte[])buffer.Clone()); Interlocked.Increment(ref received); if (receivedEvent != null) receivedEvent.Set();
                if (mode == "reconnect" && attempt <= 2) return;
                if (mode == "short") { await stream.WriteAsync(buffer.AsMemory(0,size/2),stop.Token); return; }
                if (mode == "hold") { await Task.Delay(Timeout.Infinite,stop.Token); return; }
                if (mode == "corruptHold") { buffer[0] ^= 1; await stream.WriteAsync(buffer,stop.Token); await stream.ReadAsync(buffer,stop.Token); await Task.Delay(Timeout.Infinite,stop.Token); return; }
                await stream.WriteAsync(buffer,stop.Token);
                if (mode == "echoThenHold") { await stream.ReadAsync(buffer,stop.Token); await Task.Delay(Timeout.Infinite,stop.Token); return; }
            }
            while (true) {
                int n = await stream.ReadAsync(buffer,stop.Token); if (n == 0) return;
                var captured = new byte[n]; Array.Copy(buffer,captured,n); Payloads.Add(captured); Interlocked.Increment(ref received);
                if (receivedEvent != null) receivedEvent.Set();
                if (mode == "delay") await Task.Delay(30,stop.Token);
                if (mode == "fragment") { for (int i=0;i<n;i+=997) { await stream.WriteAsync(buffer.AsMemory(i,Math.Min(997,n-i)),stop.Token); await Task.Delay(1,stop.Token); } }
                else await stream.WriteAsync(buffer.AsMemory(0,n),stop.Token);
            }
        }} catch (OperationCanceledException) {}
        catch (IOException error) { if (!stop.IsCancellationRequested && !PeerClosed(error.InnerException as SocketException)) throw; }
        catch (SocketException error) { if (!stop.IsCancellationRequested && !PeerClosed(error)) throw; }
    }
    static bool PeerClosed(SocketException error) {
        return error != null && (error.SocketErrorCode == SocketError.ConnectionReset ||
            error.SocketErrorCode == SocketError.ConnectionAborted);
    }
    async Task UdpLoop() {
        try { while (true) { var packet = await udp.ReceiveAsync(stop.Token);
            Payloads.Add((byte[])packet.Buffer.Clone()); Interlocked.Increment(ref received); if (receivedEvent != null) receivedEvent.Set();
            if (mode == "hold") continue;
            var payload = packet.Buffer;
            if (mode == "short") Array.Resize(ref payload,payload.Length/2);
            if (mode == "corruptHold" && Received == 1) payload[0] ^= 1;
            else if (mode == "corruptHold") continue;
            await udp.SendAsync(payload,packet.RemoteEndPoint,stop.Token);
        }} catch (OperationCanceledException) {} catch (SocketException) { if (!stop.IsCancellationRequested) throw; }
    }
    public void Dispose() {
        stop.Cancel(); if (listener != null) listener.Stop(); if (udp != null) udp.Dispose();
        foreach (var c in clients) c.Dispose();
        if (!loop.Wait(2000)) throw new Exception("peer loop timeout");
        if (!Task.WaitAll(handlers.ToArray(),2000)) throw new Exception("peer handler timeout");
        if (receivedEvent != null) receivedEvent.Dispose(); stop.Dispose();
    }
}
public static class CECTestMemory {
    [StructLayout(LayoutKind.Sequential)] struct Counters {
        public uint Size, Faults;
        public UIntPtr PeakWorkingSet, WorkingSet, PeakPagedQuota, PagedQuota, PeakNonPagedQuota, NonPagedQuota, Pagefile, PeakPagefile;
    }
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool K32GetProcessMemoryInfo(IntPtr process, out Counters counters, uint size);
    public static ulong Peak(IntPtr process) {
        Counters counters;
        if (!K32GetProcessMemoryInfo(process,out counters,(uint)Marshal.SizeOf<Counters>())) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return counters.PeakWorkingSet.ToUInt64();
    }
}
'@
}
function Invoke-CECProcess {
    param([string]$Path, [string[]]$Arguments, [int]$TimeoutMilliseconds = 10000)
    $psi = [Diagnostics.ProcessStartInfo]::new($Path)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($arg in $Arguments) { $psi.ArgumentList.Add($arg) }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMilliseconds)) { $p.Kill($true); throw "process timeout: $Path $Arguments" }
        [pscustomobject]@{ Code = $p.ExitCode; Text = $stdout.Result; ErrorText = $stderr.Result; WallMilliseconds = $timer.Elapsed.TotalMilliseconds; CPUMilliseconds = $p.TotalProcessorTime.TotalMilliseconds; PeakWorkingSetBytes = [CECTestMemory]::Peak($p.Handle) }
    } finally { if (-not $p.HasExited) { $p.Kill($true) }; $p.Dispose() }
}
