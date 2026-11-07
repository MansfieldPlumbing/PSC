# Marks the static methods that declare this source's keywords.
class Keyword : Attribute { }

class KeywordProbe {
    static [int] $Bits
    static [int] $Calls

    # Declares 'register Name { Bits = ...; Signed = ... }'.
    [Keyword()] static [void] register([string] $name, [int] $Bits, [bool] $Signed) {
        [KeywordProbe]::Bits += $Bits
        [KeywordProbe]::Calls++
    }

    # Declares 'lower Name { ... }'.
    [Keyword()] static [void] lower([string] $name) {
        [KeywordProbe]::Calls++
    }

    # Expected: Bits 8 + 16 + 100 = 124, Calls 3, so 124003.
    static [int] Run() {
        register A { Bits = 8; Signed = $false }
        register X { Bits = 16; Signed = $true }
        lower Body { [KeywordProbe]::Bits += 100 }
        return [KeywordProbe]::Bits * 1000 + [KeywordProbe]::Calls
    }
}
