using System;
using System.Runtime.InteropServices;

public static class PucTaskbarIdentity
{
    private const ushort VT_LPWSTR = 31;
    private static readonly Guid AppUserModelFormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropertyKey
    {
        public Guid FormatId;
        public uint PropertyId;

        public PropertyKey(Guid formatId, uint propertyId)
        {
            FormatId = formatId;
            PropertyId = propertyId;
        }
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct PropVariant
    {
        [FieldOffset(0)]
        public ushort VariantType;

        [FieldOffset(8)]
        public IntPtr PointerValue;

        public static PropVariant FromString(string value)
        {
            PropVariant result = new PropVariant();
            result.VariantType = VT_LPWSTR;
            result.PointerValue = Marshal.StringToCoTaskMemUni(value);
            return result;
        }

        public string GetString()
        {
            return VariantType == VT_LPWSTR && PointerValue != IntPtr.Zero
                ? Marshal.PtrToStringUni(PointerValue)
                : null;
        }
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig]
        int GetCount(out uint propertyCount);

        [PreserveSig]
        int GetAt(uint propertyIndex, out PropertyKey key);

        [PreserveSig]
        int GetValue(ref PropertyKey key, out PropVariant value);

        [PreserveSig]
        int SetValue(ref PropertyKey key, ref PropVariant value);

        [PreserveSig]
        int Commit();
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appUserModelId);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetCurrentProcessExplicitAppUserModelID(out IntPtr appUserModelId);

    [DllImport("shell32.dll")]
    private static extern int SHGetPropertyStoreForWindow(
        IntPtr windowHandle,
        ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IPropertyStore propertyStore);

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PropVariant propVariant);

    public static void SetProcessIdentity(string appUserModelId)
    {
        Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(appUserModelId));
    }

    public static string GetProcessIdentity()
    {
        IntPtr value = IntPtr.Zero;
        Marshal.ThrowExceptionForHR(GetCurrentProcessExplicitAppUserModelID(out value));
        try
        {
            return value == IntPtr.Zero ? null : Marshal.PtrToStringUni(value);
        }
        finally
        {
            if (value != IntPtr.Zero)
            {
                Marshal.FreeCoTaskMem(value);
            }
        }
    }

    public static void ConfigureWindow(IntPtr windowHandle, string appUserModelId, string iconResource)
    {
        IPropertyStore propertyStore = GetWindowPropertyStore(windowHandle);
        try
        {
            // Set relaunch metadata before the ID so the taskbar refresh sees the complete identity.
            SetString(propertyStore, 3, iconResource);
            SetString(propertyStore, 5, appUserModelId);
            Marshal.ThrowExceptionForHR(propertyStore.Commit());
        }
        finally
        {
            Marshal.FinalReleaseComObject(propertyStore);
        }
    }

    public static string GetWindowProperty(IntPtr windowHandle, uint propertyId)
    {
        IPropertyStore propertyStore = GetWindowPropertyStore(windowHandle);
        PropVariant value = new PropVariant();
        try
        {
            PropertyKey key = new PropertyKey(AppUserModelFormatId, propertyId);
            Marshal.ThrowExceptionForHR(propertyStore.GetValue(ref key, out value));
            return value.GetString();
        }
        finally
        {
            PropVariantClear(ref value);
            Marshal.FinalReleaseComObject(propertyStore);
        }
    }

    private static IPropertyStore GetWindowPropertyStore(IntPtr windowHandle)
    {
        Guid interfaceId = typeof(IPropertyStore).GUID;
        IPropertyStore propertyStore;
        Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(windowHandle, ref interfaceId, out propertyStore));
        return propertyStore;
    }

    private static void SetString(IPropertyStore propertyStore, uint propertyId, string value)
    {
        PropertyKey key = new PropertyKey(AppUserModelFormatId, propertyId);
        PropVariant propVariant = PropVariant.FromString(value);
        try
        {
            Marshal.ThrowExceptionForHR(propertyStore.SetValue(ref key, ref propVariant));
        }
        finally
        {
            PropVariantClear(ref propVariant);
        }
    }
}
