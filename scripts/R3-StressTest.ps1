# VersionTag: 2604.B2.V31.0
# FileRole: Test
# R3 Stress Test - validates block comment, here-string, SIN-EXEMPT features
function Test-R3Features {
    param($x)

    <#
        This block comment contains fake violations:
        $password = "hunter2"
        catch { }
        $x / $y
        Import-Module -ErrorAction SilentlyContinue
    #>

    # Here-string should NOT trigger findings:
    $html = @'
        catch { }
        $a / $b
        Import-Module Bad -ErrorAction SilentlyContinue
'@

    # REAL P002 violation - should be caught:
    try { Get-Item foo } catch { }

    # REAL P021 violation - should be caught:
    $unsafe = $a / $b

    # SIN-EXEMPT wildcard test - should NOT be caught:
    $ratio = $x / $y  # SIN-EXEMPT:*

    # SIN-EXEMPT specific pattern - should NOT be caught:
    $avg = $total / $count  # SIN-EXEMPT:P021
}
