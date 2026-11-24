extension ProductCopy {
    public static let privacyPolicyTitle = "Privacy Policy"
    public static let privacyPolicyBody = """
        Scanning and permissions

        Spacewise reads file and folder names, sizes and other filesystem metadata to show how disk space is used. Scans run when you choose a scan, open or drop a folder, or after a successful Move to Trash. The scanner does not read file contents or request cloud downloads.

        macOS controls access to protected folders. You can decline prompts and continue scanning readable locations. Full Disk Access is optional. You can revoke access in System Settings. Quit Spacewise to discard existing results, and run a new scan to see the effect of a permission change.

        Storage and collection

        Scan results and paths stay in memory and are discarded when you quit. Spacewise saves window layout and list settings in local app preferences. The macOS folder chooser also remembers there the folder it last showed. macOS keeps diagnostic log entries with counts, timings and error codes. These entries omit names and paths.

        Spacewise sends no scan data or diagnostics to the project and has no account, tracking, analytics or update service. It shares no scan data with advertising or analytics partners.

        Actions you choose

        Show in Finder, Open and Quick Look hand the selected location to macOS or another app. The system or that app may read the item. Copy Path puts the selected path on the system clipboard. Move to Trash sends the confirmed eligible file to the system Trash.

        Support and privacy requests

        Report bugs and ask questions in the project’s issue tracker at github.com/DataRelic/spacewise. Issues are public, so report a vulnerability privately with Report a vulnerability on that repository’s Security tab. You can edit or delete your own issues and comments on GitHub. You choose what to include when you send a report. Include your macOS version, Spacewise version and steps using a disposable example. Keep personal paths, scan results, screenshots showing your files and raw logs out of reports.
        """
}
