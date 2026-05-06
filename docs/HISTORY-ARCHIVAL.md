# History File Archival Integration

- All history files are now packaged into zip archives by major version (V30, V31, V32, etc.).
- Code that loads history files now uses the Get-HistoryFileFromZip utility to extract and read from the correct archive.
- This approach is documented and scaffolded for logs, test results, config backups, documentation, and user exports.
- See tools/Package-HistoryFilesByMajorVersion.ps1 and modules/PwShGUI-HistoryZip.psm1 for implementation details.
