class CustomObjectProbe {
    # Reads, typed: 3 * 1000 + 'smb'.Length = 3003.
    static [int] Values() {
        $o = [pscustomobject]@{ Rom = 'smb'; Frames = 3 }
        [string] $rom = $o.Rom
        [int] $frames = $o.Frames
        return $frames * 1000 + $rom.Length
    }
    # Mutation of an existing property.
    static [int] Mutation() {
        $o = [pscustomobject]@{ Frames = 3 }
        $o.Frames = 7
        [int] $frames = $o.Frames
        return $frames
    }
    # PowerShell's own formatting of a custom object.
    static [string] Formatting() {
        $o = [pscustomobject]@{ Rom = 'smb'; Frames = 3 }
        return $o.ToString()
    }
    # Type identity as PowerShell reports it.
    static [string] TypeIdentity() {
        $o = [pscustomobject]@{ A = 1 }
        return $o.GetType().FullName
    }
    # A property it does not have reads as $null.
    static [int] Missing() {
        $o = [pscustomobject]@{ A = 1 }
        if ($null -eq $o.Nope) { return 1 }
        return 0
    }
    # .PSObject is the object itself.
    static [int] PSObjectIsSelf() {
        $o = [pscustomobject]@{ A = 1 }
        if ([object]::ReferenceEquals($o.PSObject, $o)) { return 1 }
        return 0
    }
    # Through .PSObject: the wrapper's own members. TypeNames has 2 entries; property A holds 4; base is PSCustomObject.
    static [int] PSObjectView() {
        $o = [pscustomobject]@{ A = 4 }
        [int] $names = $o.PSObject.TypeNames.Count
        [int] $a = $o.PSObject.Properties['A'].Value
        [string] $base = $o.PSObject.BaseObject.GetType().Name
        return $names * 100 + $a * 10 + $base.Length
    }
    # The object escapes to the caller, which inspects it as PowerShell.
    static [object] Escapes() {
        return [pscustomobject]@{ Rom = 'smb'; Frames = 3; Mapper = 0 }
    }
}
