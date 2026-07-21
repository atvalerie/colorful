using System.Runtime.InteropServices;
using System.Text.Json;

namespace Colorful.Windows.Core;

internal sealed class CoreBridge : IDisposable
{
    private const string LibraryName = "colorful_core";
    private ulong _handle;

    public uint AbiVersion => Native.colorful_core_abi_version();
    public bool IsOpen => _handle != 0;
    public string DatabasePath { get; }

    public CoreBridge()
    {
        var dataDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "colorful");
        Directory.CreateDirectory(dataDirectory);
        DatabasePath = Path.Combine(dataDirectory, "colorful.sqlite");

        using var response = ParseResponse(CallString(() => Native.colorful_engine_open(DatabasePath)));
        EnsureSuccess(response.RootElement);
        _handle = response.RootElement.GetProperty("value").GetProperty("handle").GetUInt64();
    }

    public JsonDocument Snapshot()
    {
        EnsureOpen();
        var response = ParseResponse(CallString(() => Native.colorful_engine_snapshot(_handle)));
        EnsureSuccess(response.RootElement);
        return response;
    }

    public JsonDocument Dispatch(string commandJson)
    {
        EnsureOpen();
        var response = ParseResponse(CallString(
            () => Native.colorful_engine_dispatch(_handle, commandJson)));
        EnsureSuccess(response.RootElement);
        return response;
    }

    public void Dispose()
    {
        if (_handle == 0)
        {
            return;
        }

        Native.colorful_engine_close(_handle);
        _handle = 0;
    }

    private void EnsureOpen()
    {
        ObjectDisposedException.ThrowIf(_handle == 0, this);
    }

    private static JsonDocument ParseResponse(string json)
    {
        return JsonDocument.Parse(json);
    }

    private static void EnsureSuccess(JsonElement response)
    {
        if (response.TryGetProperty("ok", out var ok) && ok.GetBoolean())
        {
            return;
        }

        var message = response.TryGetProperty("error", out var error)
            ? error.GetString()
            : "The colorful core returned an invalid response.";
        throw new InvalidOperationException(message);
    }

    private static string CallString(Func<nint> call)
    {
        var pointer = call();
        if (pointer == 0)
        {
            throw new InvalidOperationException("The colorful core returned a null string.");
        }

        try
        {
            return Marshal.PtrToStringUTF8(pointer)
                ?? throw new InvalidOperationException("The colorful core returned invalid UTF-8.");
        }
        finally
        {
            Native.colorful_string_free(pointer);
        }
    }

    private static partial class Native
    {
        [LibraryImport(LibraryName)]
        [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        internal static partial uint colorful_core_abi_version();

        [LibraryImport(LibraryName, StringMarshalling = StringMarshalling.Utf8)]
        [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        internal static partial nint colorful_engine_open(string databasePath);

        [LibraryImport(LibraryName, StringMarshalling = StringMarshalling.Utf8)]
        [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        internal static partial nint colorful_engine_dispatch(ulong handle, string commandJson);

        [LibraryImport(LibraryName)]
        [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        internal static partial nint colorful_engine_snapshot(ulong handle);

        [LibraryImport(LibraryName)]
        [return: MarshalAs(UnmanagedType.I1)]
        [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        internal static partial bool colorful_engine_close(ulong handle);

        [LibraryImport(LibraryName)]
        [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
        internal static partial void colorful_string_free(nint value);
    }
}
