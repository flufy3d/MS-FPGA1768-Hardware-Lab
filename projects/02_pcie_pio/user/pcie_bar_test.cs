using System;
using System.Runtime.InteropServices;

//
// pcie_bar_test.cs — user-mode client for the pcie_bar KMDF driver.
//
// The driver maps BAR0 of PCI\VEN_1172&DEV_E003 and exposes three IOCTLs.
// This program is read-only by default. Pass --write to run the A+B test.
//

internal static class Program
{
    private const uint IoctlGetInfo  = 0x00222000; // CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)
    private const uint IoctlRead32   = 0x00222004; // ... 0x801
    private const uint IoctlWrite32  = 0x00222008; // ... 0x802

    private const uint GenericRead  = 0x80000000;
    private const uint GenericWrite = 0x40000000;
    private const uint FileShareRead  = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint OpenExisting = 3;

    private const uint DigcfPresent         = 0x02;
    private const uint DigcfDeviceInterface = 0x10;

    private const uint ExpectedId = 0x50434945; // "PCIE" numeric ID

    private static readonly Guid DeviceInterfaceGuid =
        new Guid("7A5E3C2B-9D4F-4E8A-9B1C-2D3E4F5A6B7C");

    [StructLayout(LayoutKind.Sequential)]
    private struct PcieBarInfo
    {
        public uint VendorId;
        public uint DeviceId;
        public ulong BarPhysicalAddress;
        public uint BarLength;
        public uint Mapped;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PcieBarAccess
    {
        public uint Offset;
        public uint Value;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SpDeviceInterfaceData
    {
        public uint cbSize;
        public Guid InterfaceClassGuid;
        public uint Flags;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(
        ref Guid classGuid,
        IntPtr enumerator,
        IntPtr hwndParent,
        uint flags);

    [DllImport("setupapi.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInterfaces(
        IntPtr deviceInfoSet,
        IntPtr deviceInfoData,
        ref Guid interfaceClassGuid,
        uint memberIndex,
        ref SpDeviceInterfaceData deviceInterfaceData);

    [DllImport("setupapi.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(
        IntPtr deviceInfoSet,
        ref SpDeviceInterfaceData deviceInterfaceData,
        IntPtr deviceInterfaceDetailData,
        uint deviceInterfaceDetailDataSize,
        out uint requiredSize,
        IntPtr deviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        IntPtr device,
        uint ioControlCode,
        IntPtr inBuffer,
        uint inBufferSize,
        IntPtr outBuffer,
        uint outBufferSize,
        out uint bytesReturned,
        IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private static IntPtr OpenDevice(out string path)
    {
        path = null;
        Guid guid = DeviceInterfaceGuid;

        IntPtr infoSet = SetupDiGetClassDevs(
            ref guid,
            IntPtr.Zero,
            IntPtr.Zero,
            DigcfPresent | DigcfDeviceInterface);

        if (infoSet == new IntPtr(-1))
        {
            throw new InvalidOperationException(
                "SetupDiGetClassDevs failed: " + Marshal.GetLastWin32Error());
        }

        try
        {
            var interfaceData = new SpDeviceInterfaceData();
            interfaceData.cbSize = (uint)Marshal.SizeOf(typeof(SpDeviceInterfaceData));

            for (uint index = 0; ; index++)
            {
                if (!SetupDiEnumDeviceInterfaces(
                        infoSet,
                        IntPtr.Zero,
                        ref guid,
                        index,
                        ref interfaceData))
                {
                    break;
                }

                uint requiredSize;
                SetupDiGetDeviceInterfaceDetail(
                    infoSet,
                    ref interfaceData,
                    IntPtr.Zero,
                    0,
                    out requiredSize,
                    IntPtr.Zero);

                if (requiredSize == 0)
                {
                    continue;
                }

                IntPtr detail = Marshal.AllocHGlobal((int)requiredSize);
                try
                {
                    // SP_DEVICE_INTERFACE_DETAIL_DATA.cbSize is 8 on x64.
                    Marshal.WriteInt32(detail, 0, 8);

                    if (!SetupDiGetDeviceInterfaceDetail(
                            infoSet,
                            ref interfaceData,
                            detail,
                            requiredSize,
                            out requiredSize,
                            IntPtr.Zero))
                    {
                        continue;
                    }

                    string devicePath = Marshal.PtrToStringAuto(
                        IntPtr.Add(detail, 4));

                    IntPtr handle = CreateFile(
                        devicePath,
                        GenericRead | GenericWrite,
                        FileShareRead | FileShareWrite,
                        IntPtr.Zero,
                        OpenExisting,
                        0,
                        IntPtr.Zero);

                    if (handle != new IntPtr(-1))
                    {
                        path = devicePath;
                        return handle;
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(detail);
                }
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(infoSet);
        }

        return new IntPtr(-1);
    }

    private static PcieBarInfo GetInfo(IntPtr device)
    {
        int size = Marshal.SizeOf(typeof(PcieBarInfo));
        IntPtr output = Marshal.AllocHGlobal(size);
        try
        {
            uint bytes;
            if (!DeviceIoControl(
                    device,
                    IoctlGetInfo,
                    IntPtr.Zero,
                    0,
                    output,
                    (uint)size,
                    out bytes,
                    IntPtr.Zero))
            {
                throw new InvalidOperationException(
                    "IOCTL_PCIE_BAR_GET_INFO failed: " + Marshal.GetLastWin32Error());
            }

            return (PcieBarInfo)Marshal.PtrToStructure(output, typeof(PcieBarInfo));
        }
        finally
        {
            Marshal.FreeHGlobal(output);
        }
    }

    private static uint Read32(IntPtr device, uint offset)
    {
        int size = Marshal.SizeOf(typeof(PcieBarAccess));
        IntPtr input = Marshal.AllocHGlobal(size);
        IntPtr output = Marshal.AllocHGlobal(size);
        try
        {
            var request = new PcieBarAccess { Offset = offset, Value = 0 };
            Marshal.StructureToPtr(request, input, false);

            uint bytes;
            if (!DeviceIoControl(
                    device,
                    IoctlRead32,
                    input,
                    (uint)size,
                    output,
                    (uint)size,
                    out bytes,
                    IntPtr.Zero))
            {
                throw new InvalidOperationException(
                    "IOCTL_PCIE_BAR_READ32(0x" + offset.ToString("X") +
                    ") failed: " + Marshal.GetLastWin32Error());
            }

            var response = (PcieBarAccess)Marshal.PtrToStructure(
                output, typeof(PcieBarAccess));
            return response.Value;
        }
        finally
        {
            Marshal.FreeHGlobal(input);
            Marshal.FreeHGlobal(output);
        }
    }

    private static void Write32(IntPtr device, uint offset, uint value)
    {
        int size = Marshal.SizeOf(typeof(PcieBarAccess));
        IntPtr input = Marshal.AllocHGlobal(size);
        try
        {
            var request = new PcieBarAccess { Offset = offset, Value = value };
            Marshal.StructureToPtr(request, input, false);

            uint bytes;
            if (!DeviceIoControl(
                    device,
                    IoctlWrite32,
                    input,
                    (uint)size,
                    IntPtr.Zero,
                    0,
                    out bytes,
                    IntPtr.Zero))
            {
                throw new InvalidOperationException(
                    "IOCTL_PCIE_BAR_WRITE32(0x" + offset.ToString("X") +
                    ") failed: " + Marshal.GetLastWin32Error());
            }
        }
        finally
        {
            Marshal.FreeHGlobal(input);
        }
    }

    private static void PrintHelp()
    {
        Console.WriteLine("pcie_bar_test.exe [--write]");
        Console.WriteLine();
        Console.WriteLine("  default   read-only: print BAR0 info, ID, A, B, SUM, COUNTER");
        Console.WriteLine("  --write   write A=0x12345678 and B=0x11111111, then verify SUM");
        Console.WriteLine();
        Console.WriteLine("Register map (16-byte PIO spacing):");
        Console.WriteLine("  0x00 A, 0x10 B, 0x20 SUM, 0x30 COUNTER, 0x40 ID");
    }

    private static int Main(string[] args)
    {
        bool write = false;
        foreach (string arg in args)
        {
            if (arg == "--help" || arg == "-h" || arg == "/?")
            {
                PrintHelp();
                return 0;
            }
            if (arg == "--write")
            {
                write = true;
                continue;
            }
            Console.Error.WriteLine("Unknown argument: " + arg);
            PrintHelp();
            return 2;
        }

        string path;
        IntPtr device = OpenDevice(out path);
        if (device == new IntPtr(-1))
        {
            Console.Error.WriteLine(
                "No pcie_bar device interface found.");
            Console.Error.WriteLine(
                "Install the driver, load pcie_pio.sof, and check that " +
                "PCI\\VEN_1172&DEV_E003 is present.");
            return 1;
        }

        try
        {
            Console.WriteLine("Device: " + path);

            PcieBarInfo info = GetInfo(device);
            Console.WriteLine(
                "IDs:    {0:X4}:{1:X4}",
                info.VendorId,
                info.DeviceId);
            Console.WriteLine(
                "BAR0:   0x{0:X} length 0x{1:X} mapped={2}",
                info.BarPhysicalAddress,
                info.BarLength,
                info.Mapped);

            if (info.Mapped == 0)
            {
                Console.Error.WriteLine(
                    "The driver mapped BAR0 but the ID register did not match.");
                Console.Error.WriteLine(
                    "Refusing to write. Check that pcie_pio.sof is loaded.");
                return 3;
            }

            uint id = Read32(device, 0x40);
            Console.WriteLine("ID:     0x{0:X8}", id);
            if (id != ExpectedId)
            {
                Console.Error.WriteLine(
                    "Unexpected ID 0x" + id.ToString("X8") +
                    " (expected 0x" + ExpectedId.ToString("X8") + ").");
                return 3;
            }

            uint a = Read32(device, 0x00);
            uint b = Read32(device, 0x10);
            uint sum = Read32(device, 0x20);
            uint counter1 = Read32(device, 0x30);
            uint counter2 = Read32(device, 0x30);

            Console.WriteLine("A:      0x{0:X8}", a);
            Console.WriteLine("B:      0x{0:X8}", b);
            Console.WriteLine("SUM:    0x{0:X8}", sum);
            Console.WriteLine(
                "COUNTER:0x{0:X8} then 0x{1:X8} ({2})",
                counter1,
                counter2,
                counter1 != counter2 ? "changing" : "STUCK");

            if (!write)
            {
                Console.WriteLine();
                Console.WriteLine("Read-only pass. Use --write for the A+B test.");
                return 0;
            }

            Console.WriteLine();
            Console.WriteLine("Writing A=0x12345678, B=0x11111111 ...");
            Write32(device, 0x00, 0x12345678);
            Write32(device, 0x10, 0x11111111);

            uint newSum = Read32(device, 0x20);
            uint newCounter1 = Read32(device, 0x30);
            uint newCounter2 = Read32(device, 0x30);

            Console.WriteLine("SUM:    0x{0:X8} (expected 0x23456789)", newSum);
            Console.WriteLine(
                "COUNTER:0x{0:X8} then 0x{1:X8} ({2})",
                newCounter1,
                newCounter2,
                newCounter1 != newCounter2 ? "changing" : "STUCK");

            if (newSum != 0x23456789)
            {
                Console.Error.WriteLine("A+B test FAILED.");
                return 4;
            }

            if (newCounter1 == newCounter2)
            {
                Console.Error.WriteLine("Counter did not change; FAILED.");
                return 4;
            }

            Console.WriteLine();
            Console.WriteLine("A+B test PASSED.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("ERROR: " + ex.Message);
            return 5;
        }
        finally
        {
            CloseHandle(device);
        }
    }
}
