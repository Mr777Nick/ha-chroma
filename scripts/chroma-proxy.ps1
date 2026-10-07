<#
.SYNOPSIS
    LAN proxy for the Razer Chroma SDK REST server.

.DESCRIPTION
    Razer Synapse registers the Chroma SDK in HTTP.sys as http://localhost:54235/.
    HTTP.sys only serves such a URL to local clients:
      - Host header other than "localhost"  -> 400 Bad Request (Invalid Hostname)
      - Host "localhost" from a remote IP   -> 403 Forbidden
    Port 54235 (and every session port) is held by HTTP.sys on all addresses,
    so nothing else can listen on it. Windows networking / firewall settings
    cannot change this.

    This proxy listens on a separate port (default 54236), outside HTTP.sys, and
    forwards every request to the SDK over loopback. The session returned by the
    SDK (a random port in the dynamic range) is rewritten to the proxy port, so
    the whole conversation goes through a single port. Sessions are tracked per
    client IP.

    In Home Assistant, set the integration port to the proxy port (54236).

.PARAMETER Port
    Port the proxy listens on (all IPv4 addresses).

.PARAMETER UpstreamPort
    Port of the Chroma SDK REST server.

.PARAMETER LogFile
    Optional log file. Without it, log goes to the console.

.PARAMETER Install
    Register a scheduled task that starts the proxy hidden at logon (and start it now).

.PARAMETER Uninstall
    Stop and remove the scheduled task.

.EXAMPLE
    .\chroma-proxy.ps1                 # run in the foreground
.EXAMPLE
    .\chroma-proxy.ps1 -Install        # run at every logon
#>
[CmdletBinding()]
param(
    [int]$Port = 54236,
    [int]$UpstreamPort = 54235,
    [string]$LogFile,
    [switch]$Install,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$taskName = "Chroma SDK LAN proxy"

if ($Uninstall) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task '$taskName'."
    return
}

if ($Install) {
    if (-not $LogFile) { $LogFile = Join-Path $env:LOCALAPPDATA "chroma-proxy.log" }
    $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port -UpstreamPort $UpstreamPort -LogFile `"$LogFile`""
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Write-Host "Installed and started scheduled task '$taskName'. Log: $LogFile"
    return
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public static class ChromaProxy
{
    const string EntryPath = "/razer/chromasdk";
    const string SessionPath = "/chromasdk";

    static int listenPort;
    static int upstreamPort;
    static string logFile;
    static readonly object logLock = new object();
    // client IP -> SDK session port
    static readonly Dictionary<string, int> sessions = new Dictionary<string, int>();

    class Request
    {
        public string Method;
        public string Path;
        public bool Close;
        public string ContentType;
        public byte[] Body;
    }

    public static void Start(int port, int upstream, string log)
    {
        listenPort = port;
        upstreamPort = upstream;
        logFile = string.IsNullOrEmpty(log) ? null : log;

        TcpListener listener = new TcpListener(IPAddress.Any, port);
        listener.Start();
        Thread t = new Thread(delegate() { AcceptLoop(listener); });
        t.IsBackground = true;
        t.Start();
        Log("Listening on 0.0.0.0:" + port + ", forwarding to localhost:" + upstream);
    }

    static void Log(string message)
    {
        string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message;
        lock (logLock)
        {
            if (logFile != null)
            {
                try { File.AppendAllText(logFile, line + Environment.NewLine); } catch { }
            }
            else
            {
                Console.WriteLine(line);
            }
        }
    }

    static void AcceptLoop(TcpListener listener)
    {
        while (true)
        {
            TcpClient client;
            try { client = listener.AcceptTcpClient(); }
            catch (Exception ex) { Log("Accept failed: " + ex.Message); continue; }
            ThreadPool.QueueUserWorkItem(delegate { Handle(client); });
        }
    }

    static void Handle(TcpClient client)
    {
        IPEndPoint remote = (IPEndPoint)client.Client.RemoteEndPoint;
        IPEndPoint local = (IPEndPoint)client.Client.LocalEndPoint;
        string clientIp = remote.Address.ToString();
        try
        {
            client.ReceiveTimeout = 120000;
            NetworkStream stream = client.GetStream();
            while (true)
            {
                Request req = ReadRequest(stream);
                if (req == null) break;
                DateTime started = DateTime.Now;
                byte[] response = Process(req, clientIp, local.Address.ToString());
                Log(clientIp + " " + req.Method + " " + req.Path + " -> "
                    + Encoding.ASCII.GetString(response, 9, 3) + " ("
                    + (int)(DateTime.Now - started).TotalMilliseconds + " ms)");
                stream.Write(response, 0, response.Length);
                stream.Flush();
                if (req.Close) break;
            }
        }
        catch (IOException) { }
        catch (Exception ex) { Log(clientIp + " error: " + ex.Message); }
        finally { client.Close(); }
    }

    static string ReadLine(Stream stream)
    {
        StringBuilder sb = new StringBuilder();
        while (true)
        {
            int b = stream.ReadByte();
            if (b < 0) return sb.Length == 0 ? null : sb.ToString();
            if (b == '\n') break;
            if (b != '\r') sb.Append((char)b);
            if (sb.Length > 16384) throw new IOException("Header line too long");
        }
        return sb.ToString();
    }

    static byte[] ReadExact(Stream stream, int count)
    {
        byte[] buffer = new byte[count];
        int read = 0;
        while (read < count)
        {
            int n = stream.Read(buffer, read, count - read);
            if (n <= 0) throw new IOException("Connection closed while reading body");
            read += n;
        }
        return buffer;
    }

    static Request ReadRequest(Stream stream)
    {
        string requestLine = ReadLine(stream);
        while (requestLine != null && requestLine.Length == 0) requestLine = ReadLine(stream);
        if (requestLine == null) return null;

        string[] parts = requestLine.Split(' ');
        if (parts.Length < 3) throw new IOException("Bad request line: " + requestLine);

        Request req = new Request();
        req.Method = parts[0].ToUpperInvariant();
        req.Path = parts[1];
        req.Close = parts[2] == "HTTP/1.0";

        Dictionary<string, string> headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string line;
        while (!string.IsNullOrEmpty(line = ReadLine(stream)))
        {
            int idx = line.IndexOf(':');
            if (idx > 0) headers[line.Substring(0, idx).Trim()] = line.Substring(idx + 1).Trim();
        }

        string value;
        if (headers.TryGetValue("Connection", out value))
        {
            if (value.Equals("close", StringComparison.OrdinalIgnoreCase)) req.Close = true;
            else if (value.Equals("keep-alive", StringComparison.OrdinalIgnoreCase)) req.Close = false;
        }
        headers.TryGetValue("Content-Type", out req.ContentType);

        if (headers.TryGetValue("Transfer-Encoding", out value) && value.IndexOf("chunked", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            MemoryStream body = new MemoryStream();
            while (true)
            {
                string sizeLine = ReadLine(stream) ?? "0";
                int semi = sizeLine.IndexOf(';');
                int size = Convert.ToInt32((semi >= 0 ? sizeLine.Substring(0, semi) : sizeLine).Trim(), 16);
                if (size == 0)
                {
                    while (!string.IsNullOrEmpty(ReadLine(stream))) { }
                    break;
                }
                byte[] chunk = ReadExact(stream, size);
                body.Write(chunk, 0, chunk.Length);
                ReadLine(stream);
            }
            req.Body = body.ToArray();
        }
        else if (headers.TryGetValue("Content-Length", out value) && int.Parse(value) > 0)
        {
            req.Body = ReadExact(stream, int.Parse(value));
        }
        else
        {
            req.Body = new byte[0];
        }
        return req;
    }

    static byte[] Process(Request req, string clientIp, string localIp)
    {
        string path = req.Path.Split('?')[0].TrimEnd('/');
        // After a lost session, aiochroma reconnects to the old session URL
        // (http://host:<sid>/chromasdk/razer/chromasdk). The session port is the
        // proxy port, so treat it as the entry point.
        if (path.Equals(SessionPath + EntryPath, StringComparison.OrdinalIgnoreCase))
        {
            path = EntryPath;
            req.Path = EntryPath;
        }
        bool isEntry = path.Equals(EntryPath, StringComparison.OrdinalIgnoreCase);
        bool isSession = path.Equals(SessionPath, StringComparison.OrdinalIgnoreCase)
            || path.StartsWith(SessionPath + "/", StringComparison.OrdinalIgnoreCase);

        int target;
        if (isEntry)
        {
            target = upstreamPort;
        }
        else if (isSession)
        {
            lock (sessions)
            {
                if (!sessions.TryGetValue(clientIp, out target))
                {
                    Log(clientIp + " " + req.Method + " " + req.Path + " -> 404 (no session)");
                    return Response(404, "application/json", "{\"result\":-1,\"error\":\"No Chroma SDK session for this client\"}");
                }
            }
        }
        else
        {
            return Response(404, "application/json", "{\"result\":-1,\"error\":\"Unknown path\"}");
        }

        int status;
        string contentType;
        byte[] body;
        if (!Forward(req, target, out status, out contentType, out body))
        {
            if (isSession) lock (sessions) { sessions.Remove(clientIp); }
            Log(clientIp + " " + req.Method + " " + req.Path + " -> 502 (SDK on port " + target + " unreachable)");
            return Response(502, "application/json", "{\"result\":-1,\"error\":\"Chroma SDK is unreachable\"}");
        }

        if (isEntry && req.Method == "POST" && status == 200)
        {
            string text = Encoding.UTF8.GetString(body);
            Match m = Regex.Match(text, "\"sessionid\"\\s*:\\s*(\\d+)");
            if (m.Success)
            {
                int sid = int.Parse(m.Groups[1].Value);
                lock (sessions) { sessions[clientIp] = sid; }
                text = Regex.Replace(text, "(\"sessionid\"\\s*:\\s*)\\d+", "${1}" + listenPort);
                text = Regex.Replace(text, "(\"uri\"\\s*:\\s*\")[^\"]*(\")", "${1}http://" + localIp + ":" + listenPort + SessionPath + "${2}");
                body = Encoding.UTF8.GetBytes(text);
                Log(clientIp + " new session: SDK port " + sid + " mapped to proxy port " + listenPort);
            }
        }
        else if (isSession && req.Method == "DELETE" && path.Equals(SessionPath, StringComparison.OrdinalIgnoreCase))
        {
            lock (sessions) { sessions.Remove(clientIp); }
            Log(clientIp + " session closed");
        }

        return Response(status, contentType, body);
    }

    static bool Forward(Request req, int port, out int status, out string contentType, out byte[] body)
    {
        status = 0;
        contentType = null;
        body = null;

        HttpWebRequest up = (HttpWebRequest)WebRequest.Create("http://localhost:" + port + req.Path);
        up.Method = req.Method;
        up.Proxy = null;
        up.Timeout = 15000;
        up.ReadWriteTimeout = 15000;
        up.KeepAlive = true;
        up.ContentType = string.IsNullOrEmpty(req.ContentType) ? "application/json" : req.ContentType;

        HttpWebResponse resp;
        try
        {
            if (req.Body.Length > 0 && req.Method != "GET" && req.Method != "HEAD")
            {
                up.ContentLength = req.Body.Length;
                using (Stream s = up.GetRequestStream()) { s.Write(req.Body, 0, req.Body.Length); }
            }
            else if (req.Method == "POST" || req.Method == "PUT" || req.Method == "DELETE")
            {
                up.ContentLength = 0;
            }
            resp = (HttpWebResponse)up.GetResponse();
        }
        catch (WebException ex)
        {
            resp = ex.Response as HttpWebResponse;
            if (resp == null) return false;
        }

        using (resp)
        using (Stream s = resp.GetResponseStream())
        using (MemoryStream ms = new MemoryStream())
        {
            s.CopyTo(ms);
            body = ms.ToArray();
            status = (int)resp.StatusCode;
            contentType = resp.ContentType;
        }
        return true;
    }

    static byte[] Response(int status, string contentType, string body)
    {
        return Response(status, contentType, Encoding.UTF8.GetBytes(body));
    }

    static byte[] Response(int status, string contentType, byte[] body)
    {
        string reason = status == 200 ? "OK" : status == 404 ? "Not Found" : status == 502 ? "Bad Gateway" : "Status";
        string head = "HTTP/1.1 " + status + " " + reason + "\r\n"
            + "Content-Type: " + (string.IsNullOrEmpty(contentType) ? "application/json" : contentType) + "\r\n"
            + "Content-Length: " + body.Length + "\r\n"
            + "Connection: keep-alive\r\n\r\n";
        byte[] headBytes = Encoding.ASCII.GetBytes(head);
        byte[] result = new byte[headBytes.Length + body.Length];
        Buffer.BlockCopy(headBytes, 0, result, 0, headBytes.Length);
        Buffer.BlockCopy(body, 0, result, headBytes.Length, body.Length);
        return result;
    }
}
'@

[ChromaProxy]::Start($Port, $UpstreamPort, $LogFile)
while ($true) { Start-Sleep -Seconds 1 }
