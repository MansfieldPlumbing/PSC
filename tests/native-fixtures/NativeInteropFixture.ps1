class NativeInteropFixture {
    static [System.Threading.SpinWait] $Spinner
    static [System.Runtime.InteropServices.ComTypes.FILETIME] $Time
    static [string] $DataText
    static [int[]] $DataNumbers
    static [IntPtr] $DataPointer
    static [byte[]] GuidBytes([string] $text) { return [Guid]::new($text).ToByteArray() }
    static [string] NumberText([int] $value) { return $value.ToString('X8') }
    static [long] DateTicks() { return [DateTime]::new([long]123456).Ticks }
    static [string] ValueTypeName([int] $value) { return $value.GetType().FullName }
    static [int] MutateStaticValue() { [NativeInteropFixture]::Spinner.SpinOnce(); return [NativeInteropFixture]::Spinner.Count }
    static [int] MutateLocalValue() { [System.Threading.SpinWait] $local = [NativeInteropFixture]::Spinner; $local.SpinOnce(); return $local.Count }
    static [int] WriteStructField() { [NativeInteropFixture]::Time.dwLowDateTime = 123; return [NativeInteropFixture]::Time.dwLowDateTime }
    static [NativeInteropFixture] MakeInstance() { return [NativeInteropFixture]::new() }
    static [string] ReadData() { return [NativeInteropFixture]::DataText }
    static [int] DataAt([int] $index) { return [NativeInteropFixture]::DataNumbers[$index] }
    static [char] Character([int] $value) { return [char]$value }
    static [int] ListWork() {
        [System.Collections.Generic.List[int]] $items = [System.Collections.Generic.List[int]]::new()
        $items.Add(3); $items.Add(5); $items[-1] += 2; $items[0] = 11
        return $items[-1] + $items[0]
    }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs = [System.Runtime.CompilerServices.CallConvStdcall])]
    static [uint] ProcessId([IntPtr] $functionPointer) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs = [System.Runtime.CompilerServices.CallConvCdecl])]
    static [int] Compare([IntPtr] $functionPointer, [IntPtr] $left, [IntPtr] $right) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.UnmanagedCallersOnly(CallConvs = [System.Runtime.CompilerServices.CallConvCdecl])]
    static [int] Comparator([IntPtr] $left, [IntPtr] $right) {
        return [NativeInteropFixture]::CompareValues($left, $right)
    }
    static [int] CompareValues([IntPtr] $left, [IntPtr] $right) {
        [int] $a = [Runtime.InteropServices.Marshal]::ReadInt32($left)
        [int] $b = [Runtime.InteropServices.Marshal]::ReadInt32($right)
        if ($a -lt $b) { return -1 }
        if ($a -gt $b) { return 1 }
        return 0
    }
    static [IntPtr] ComparatorAddress() {
        return [NativeInteropFixture].GetMethod('Comparator').MethodHandle.GetFunctionPointer()
    }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs = [System.Runtime.CompilerServices.CallConvCdecl])]
    static [void] Sort([IntPtr] $functionPointer, [IntPtr] $data, [UIntPtr] $count, [UIntPtr] $size, [IntPtr] $compare) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.UnmanagedCallersOnly(CallConvs=[System.Runtime.CompilerServices.CallConvCdecl])]
    static [double] Mixed([long] $a, [single] $b, [double] $c, [long] $d) {
        return [double]$a + [double]$b + $c + [double]$d
    }
    static [IntPtr] MixedAddress() { return [NativeInteropFixture].GetMethod('Mixed').MethodHandle.GetFunctionPointer() }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs=[System.Runtime.CompilerServices.CallConvCdecl])]
    static [double] CallMixed([IntPtr] $pointer, [long] $a, [single] $b, [double] $c, [long] $d) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.UnmanagedCallersOnly(CallConvs=[System.Runtime.CompilerServices.CallConvStdcall])]
    static [IntPtr] EchoPointer([IntPtr] $value) { return $value }
    static [IntPtr] EchoAddress() { return [NativeInteropFixture].GetMethod('EchoPointer').MethodHandle.GetFunctionPointer() }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs=[System.Runtime.CompilerServices.CallConvStdcall])]
    static [IntPtr] CallEcho([IntPtr] $pointer, [IntPtr] $value) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.UnmanagedCallersOnly(CallConvs=[System.Runtime.CompilerServices.CallConvCdecl])]
    static [void] WriteValue([IntPtr] $address, [long] $value) { [Runtime.InteropServices.Marshal]::WriteInt64($address, $value) }
    static [IntPtr] WriteAddress() { return [NativeInteropFixture].GetMethod('WriteValue').MethodHandle.GetFunctionPointer() }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs=[System.Runtime.CompilerServices.CallConvCdecl])]
    static [void] CallWrite([IntPtr] $pointer, [IntPtr] $address, [long] $value) { throw [NotSupportedException]::new() }
    static [int] Main() {
        foreach ($assembly in [AppDomain]::CurrentDomain.GetAssemblies()) {
            if ($assembly.GetName().Name -eq 'System.Management.Automation') { return 1 }
        }
        [IntPtr] $kernel = [Runtime.InteropServices.NativeLibrary]::Load('kernel32.dll')
        [IntPtr] $crt = [Runtime.InteropServices.NativeLibrary]::Load('ucrtbase.dll')
        [IntPtr] $data = [Runtime.InteropServices.Marshal]::AllocHGlobal(12)
        try {
            [IntPtr] $pidPointer = [Runtime.InteropServices.NativeLibrary]::GetExport($kernel, 'GetCurrentProcessId')
            if ([NativeInteropFixture]::ProcessId($pidPointer) -ne [uint][Environment]::ProcessId) { return 2 }
            [Runtime.InteropServices.Marshal]::WriteInt32($data, 0, 7)
            [Runtime.InteropServices.Marshal]::WriteInt32($data, 4, -3)
            [Runtime.InteropServices.Marshal]::WriteInt32($data, 8, 1)
            [IntPtr] $sort = [Runtime.InteropServices.NativeLibrary]::GetExport($crt, 'qsort')
            [NativeInteropFixture]::Sort($sort, $data, [UIntPtr]::new([uint]3), [UIntPtr]::new([uint]4), [NativeInteropFixture]::ComparatorAddress())
            if ([Runtime.InteropServices.Marshal]::ReadInt32($data, 0) -ne -3) { return 3 }
            if ([Runtime.InteropServices.Marshal]::ReadInt32($data, 4) -ne 1) { return 4 }
            if ([Runtime.InteropServices.Marshal]::ReadInt32($data, 8) -ne 7) { return 5 }
            return 0
        }
        finally {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($data)
            [Runtime.InteropServices.NativeLibrary]::Free($crt)
            [Runtime.InteropServices.NativeLibrary]::Free($kernel)
        }
    }}

class UnselectedNativeFixture {
    static [int] $Data
    static [int] Value() { return 29 }
}

class DefaultInitializerFixture {
    [int] $Value = 7
    static [int] Read() { return [DefaultInitializerFixture]::new().Value }
}

