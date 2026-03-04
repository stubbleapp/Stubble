import Foundation
import AppKit

/// Detects when the user is engaged in video calls, media playback, or calendar meetings.
/// Used to suppress idle detection when the user is watching/listening but not providing HID input.
class MediaActivityDetector {

    // MARK: - Dependencies

    private weak var activityMonitor: ActivityMonitor?
    private weak var calendarMonitor: CalendarMonitor?
    private weak var windowTitleMonitor: WindowTitleMonitor?

    init(activityMonitor: ActivityMonitor, calendarMonitor: CalendarMonitor, windowTitleMonitor: WindowTitleMonitor) {
        self.activityMonitor = activityMonitor
        self.calendarMonitor = calendarMonitor
        self.windowTitleMonitor = windowTitleMonitor
    }

    // MARK: - App Bundle ID Whitelist

    /// Bundle IDs of video conferencing apps where the user is likely engaged even without HID input.
    private static let conferencingApps: Set<String> = [
        "us.zoom.xos",                      // Zoom
        "com.microsoft.teams",              // Microsoft Teams
        "com.microsoft.teams2",             // Microsoft Teams (new)
        "com.apple.FaceTime",               // FaceTime
        "com.webex.meetingmanager",         // Webex
        "com.cisco.webexmeetings",          // Webex Meetings
        "com.gotomeeting.mac",              // GoToMeeting
        "com.slack.Slack",                  // Slack (huddles)
        "com.discord.Discord",              // Discord (voice/video)
        "com.skype.skype",                  // Skype
        "com.loom.desktop",                 // Loom
        "com.gather.Gather",                // Gather
        "com.around.app",                   // Around
        "com.tuple.app",                    // Tuple
        "com.pop.pop",                      // Pop
        "com.hopin.app",                    // Hopin
    ]

    /// Bundle IDs of media playback apps (video/music players, streaming apps).
    private static let mediaApps: Set<String> = [
        "com.netflix.Netflix",              // Netflix
        "com.apple.TV",                     // Apple TV
        "com.apple.Music",                  // Apple Music
        "com.spotify.client",               // Spotify
        "io.mpv",                           // mpv
        "org.videolan.vlc",                 // VLC
        "com.colliderli.iina",              // IINA
        "com.amazon.aiv.AIVApp",            // Prime Video
        "com.disney.disneyplus",            // Disney+
        "com.hulu.hululu",                  // Hulu
        "tv.plex.plex-media-player",        // Plex
        "com.plexapp.plexamp",              // Plexamp
        "com.infuse7.app",                  // Infuse
        "com.apple.podcasts",               // Apple Podcasts
        "com.apple.QuickTimePlayerX",       // QuickTime
        "com.real.RealPlayer",              // RealPlayer
        "com.twitch.TwitchApp",             // Twitch
        "com.movist.MovistPro",             // Movist Pro
        "com.elmedia-video-player.mac",     // Elmedia
    ]

    /// Combined set for quick lookup.
    private static let alwaysActiveApps: Set<String> = conferencingApps.union(mediaApps)

    // MARK: - Browser Patterns

    /// Browser bundle IDs that need window title inspection.
    private static let browserBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.brave.Browser",
        "company.thebrowser.Browser",       // Arc
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    /// Window title patterns that indicate video content in browsers.
    /// These are checked case-insensitively.
    private static let browserVideoPatterns: [String] = [
        // Video conferencing
        "google meet",
        "zoom meeting",
        "microsoft teams",
        "webex",

        // Streaming platforms
        "youtube",
        "netflix",
        "prime video",
        "disney+",
        "hulu",
        "twitch",
        "vimeo",
        "dailymotion",
        "pluto tv",
        "tubi",
        "peacock",
        "paramount+",
        "hbo max",
        "max -",  // HBO Max rebranded
        "crunchyroll",
        "funimation",

        // Video indicators in titles
        "watching",
        "now playing",
        "- watch",
    ]

    // MARK: - Detection Methods

    /// Returns true if the frontmost app is a known video/conferencing app.
    func isInMediaApp() -> Bool {
        guard let bundleId = activityMonitor?.currentApp()?.bundleIdentifier else {
            return false
        }
        return Self.alwaysActiveApps.contains(bundleId)
    }

    /// Returns true if the frontmost app is a browser showing video content.
    func isInBrowserVideo() -> Bool {
        guard let bundleId = activityMonitor?.currentApp()?.bundleIdentifier,
              Self.browserBundleIds.contains(bundleId) else {
            return false
        }

        // Check window title for video patterns
        guard let title = windowTitleMonitor?.title.lowercased(), !title.isEmpty else {
            return false
        }

        return Self.browserVideoPatterns.contains { pattern in
            title.contains(pattern)
        }
    }

    /// Returns true if the user is currently in a calendar meeting marked as a video call.
    func isInCalendarMeeting() -> Bool {
        guard let monitor = calendarMonitor else { return false }

        let now = Date()
        // Check for meetings that started up to 5 min ago and end in the future
        // (to account for meetings that start slightly late)
        guard let context = monitor.eventsContext(
            from: now.addingTimeInterval(-5 * 60),
            to: now.addingTimeInterval(60)
        ) else {
            return false
        }

        // Look for [video call] marker that CalendarMonitor already adds
        return context.contains("[video call]")
    }

    /// Returns true if any of the media activity signals indicate the user is engaged.
    /// This is the primary check used by IdleDetector.
    func isUserEngagedInMedia() -> Bool {
        return isInMediaApp() || isInBrowserVideo() || isInCalendarMeeting()
    }

    /// Returns a description of why media activity was detected (for logging).
    func engagementReason() -> String? {
        if isInMediaApp() {
            if let name = activityMonitor?.currentApp()?.localizedName {
                return "media app (\(name))"
            }
            return "media app"
        }
        if isInBrowserVideo() {
            return "browser video content"
        }
        if isInCalendarMeeting() {
            return "calendar video meeting"
        }
        return nil
    }
}
