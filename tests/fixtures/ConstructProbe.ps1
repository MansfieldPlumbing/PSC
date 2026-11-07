enum Shade { Dark; Light = 5; Bright }

class Holder {
    [int] $Count
    [long] $Total
    [byte] $Small
}

class ConstructProbe {
    static [Holder] $Shared = [Holder]::new()

    static [int] EnumConstant() { return [int][Shade]::Bright }
    static [int] EnumCompare() { [Shade] $s = [Shade]::Light; if ($s -eq [Shade]::Light) { return 1 }; return 0 }
    static [int] SwitchInt() {
        [int] $result = 0
        switch (3) { 1 { $result = 10; break } 3 { $result = 30; break } default { $result = 99 } }
        return $result
    }
    static [int] SwitchEnum() {
        [int] $result = 0
        switch ([Shade]::Bright) { ([Shade]::Dark) { $result = 1; break } ([Shade]::Bright) { $result = 6; break } }
        return $result
    }
    static [int] SwitchDefault() {
        [int] $result = 0
        switch (7) { 1 { $result = 1 } default { $result = 77 } }
        return $result
    }
    static [int] Ternary() { [int] $x = 4; return ($x -gt 3) ? 1 : 2 }
    static [int] TernaryNarrow() { [byte] $b = 200; [int] $r = ($b -gt 100) ? $b : 0; return $r }
    static [int] IfValue() { [int] $x = 4; [int] $r = if ($x -gt 3) { 7 } else { 8 }; return $r }
    static [int] Chained() { [int] $a = 0; [int] $b = 0; $a = $b = 9; return $a + $b }
    static [int] ChainedMember() { $h = [Holder]::new(); $h.Count = $h.Total = 5; return $h.Count }
    static [int] ByteShift() { [byte] $v = 0xFF; return [int]($v -shl 8) }
    static [int] ByteIncrement() { [byte] $v = 7; $v++; return $v }
    static [int] MemberChainCompound() { [ConstructProbe]::Shared.Count = 1; [ConstructProbe]::Shared.Count += 4; return [ConstructProbe]::Shared.Count }
    static [int] MixedWidth() { [byte] $b = 3; [int] $i = 4; [long] $l = 5; return [int]($b + $i + $l) }
    static [int] NullCompare() { $h = [Holder]::new(); if ($null -ne $h) { return 1 }; return 0 }
    static [int] ByteBand() { [byte] $b = 0x0F; return $b -band 0xFF }
    static [int] WhileBreak() { [int] $i = 0; while ($true) { $i++; if ($i -ge 5) { break } }; return $i }
    static [int] SwitchInLoop() {
        [int] $sum = 0
        for ([int] $i = 0; $i -lt 3; $i++) { switch ($i) { 0 { $sum += 1; break } 1 { $sum += 10; break } default { $sum += 100 } } }
        return $sum
    }
    static [int] ReturnInSwitch() { switch (2) { 2 { return 22 } }; return 0 }
}
