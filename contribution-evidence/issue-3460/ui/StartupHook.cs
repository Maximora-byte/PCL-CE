using System.Net;
using System.Net.Http;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using PCL.Core.App;
using PCL.Core.IO.Net;

// Diagnostic startup hook only. Never included in a production commit or build.
public static partial class StartupHook
{
    [LibraryImport("shell32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int SetCurrentProcessExplicitAppUserModelID(string appId);
    private static readonly string Root = Environment.GetEnvironmentVariable("PCL_UI_TEST_ROOT")!;
    private static readonly object LogLock = new();

    public static void Initialize()
    {
        // Disambiguate this diagnostic child from its packaged desktop parent.
        SetCurrentProcessExplicitAppUserModelID("PCLCE.Issue3460." + Path.GetFileName(Root));
        Paths.SharedData = Path.Combine(Root, "shared");
        Paths.SharedLocalData = Path.Combine(Root, "local");
        Paths.OldSharedData = Path.Combine(Root, "old");
        Paths.Temp = Path.Combine(Root, "temp");
        foreach (var p in new[] { Paths.SharedData, Paths.SharedLocalData, Paths.OldSharedData, Paths.Temp })
            Directory.CreateDirectory(p);
        Log(new { kind = "isolation", data = Paths.Data, shared = Paths.SharedData, local = Paths.SharedLocalData, temp = Paths.Temp });
        new Thread(Install) { IsBackground = true, Name = "Issue3460-HTTP-fixture" }.Start();
    }

    private static void Install()
    {
        try
        {
            var field = typeof(NetworkService).GetField("_factory", BindingFlags.NonPublic | BindingFlags.Static)!;
            while (field.GetValue(null) is not IHttpClientFactory) Thread.Sleep(5);
            var original = (IHttpClientFactory)field.GetValue(null)!;
            field.SetValue(null, new FixtureFactory(original));
            Log(new { kind = "http-fixture-installed" });
        }
        catch (Exception ex) { Log(new { kind = "hook-error", error = ex.ToString() }); }
    }

    internal static void Log(object data)
    {
        lock (LogLock)
            File.AppendAllText(Path.Combine(Root, "requests.jsonl"), System.Text.Json.JsonSerializer.Serialize(new { utc = DateTime.UtcNow, data }) + "\n");
    }

    private sealed class FixtureFactory(IHttpClientFactory original) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name)
        {
            using var template = original.CreateClient(name);
            var client = new HttpClient(new FixtureHandler()) { BaseAddress = template.BaseAddress, Timeout = template.Timeout };
            foreach (var h in template.DefaultRequestHeaders)
                client.DefaultRequestHeaders.TryAddWithoutValidation(h.Key, h.Value);
            return client;
        }
    }

    private sealed class FixtureHandler : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            var uri = request.RequestUri!;
            var path = uri.AbsolutePath;
            var fixture = path.Contains("CleanroomMC/Cleanroom/releases", StringComparison.OrdinalIgnoreCase) ? "cleanroom.json"
                : uri.Host == "meta.legacyfabric.net" ? "legacyfabric.json"
                : path.Contains("project/legacy-fabric-api/version") ? "legacyapi.json"
                : path.EndsWith("/project/legacy-fabric-api") ? "legacyapi-project.json"
                : path.EndsWith("/projects") && Uri.UnescapeDataString(uri.Query).Contains("EHGtwpJv") ? "legacyapi-deps.json"
                : path.EndsWith("version_manifest.json") || path.EndsWith("version_manifest_v2.json") ? "manifest.json"
                : null;
            var modeFile = Path.Combine(Root, "mode.txt");
            var mode = File.Exists(modeFile) ? File.ReadAllText(modeFile).Trim() : "fail";
            var fail = ((fixture is "cleanroom.json" or "legacyfabric.json" or "legacyapi.json") && mode == "fail")
                || (fixture == "legacyapi.json" && mode == "api-fail");
            Log(new { kind = "request", host = uri.Host, path, fixture, mode, fail });
            if (fail)
            {
                await Task.Delay(500, token);
                throw new TimeoutException("连接超时（issue #3460 本地 HTTP 故障注入）");
            }
            if (fixture is not null)
            {
                await Task.Delay(500, token);
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    RequestMessage = request,
                    Content = new StringContent(File.ReadAllText(Path.Combine(Root, "fixtures", fixture)), System.Text.Encoding.UTF8, "application/json")
                };
            }
            // Keep the diagnostic session offline except for captured fixture inputs.
            // Unrelated lists may show unavailable; this does not alter the tested refresh path.
            return new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)
            {
                RequestMessage = request,
                Content = new StringContent("Unrelated request blocked by isolated UI fixture")
            };
        }
    }
}
