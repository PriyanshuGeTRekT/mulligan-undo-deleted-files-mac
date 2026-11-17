import Foundation

/// Keeps `mulligan watch` running in the background from login on (for people who prefer the CLI to the menu-bar app).
public enum LaunchAgent {
    public static let label = "app.mulligan.watch"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func plist(executable: String, logPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>\(esc(executable))</string><string>watch</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Background</string>
            <key>LowPriorityIO</key><true/>
            <key>StandardErrorPath</key><string>\(esc(logPath))</string>
        </dict>
        </plist>
        """
    }
}
