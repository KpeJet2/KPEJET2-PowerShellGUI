# VersionTag: 2605.B2.V31.7
# PowerShellGUI CI: SIN Pattern Scan
# Add this to your CI pipeline to block merges with new SINs or unaddressed advisories
# Usage: pwsh -NoProfile -ExecutionPolicy Bypass -File ./tools/Invoke-SINPatternScanner.ps1

# Example GitHub Actions step:
# - name: Run SIN Pattern Scanner
#   run: pwsh -NoProfile -ExecutionPolicy Bypass -File ./tools/Invoke-SINPatternScanner.ps1

