// RadioAlarm — a macOS alarm clock that wakes you with FM radio (via the station's live stream).
// Always dark mode, black background, red seven-segment clock.

import SwiftUI
import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import IOKit.pwr_mgt
import Network
import ServiceManagement

// MARK: - Models

struct Station: Codable, Hashable, Identifiable {
    var id: String { url }
    var name: String
    var url: String
    var detail: String = ""
}

let presetStations: [Station] = [
    Station(name: "KEXP 90.3 FM", url: "https://kexp.streamguys1.com/kexp160.aac", detail: "Seattle"),
    Station(name: "WNYC 93.9 FM", url: "https://fm939.wnyc.org/wnycfm", detail: "New York"),
    Station(name: "KQED 88.5 FM", url: "https://streams.kqed.org/kqedradio", detail: "San Francisco"),
]

/// Old single-alarm format, kept only to move existing settings into the new alarm list.
struct AlarmSettings: Codable, Equatable {
    var hour = 7
    var minute = 0
    var enabled = false
    var days: Set<Int> = []          // 1 = Sunday … 7 = Saturday; empty = one-time
    var station: Station = presetStations[0]
    var snoozeMinutes = 9
}

struct Alarm: Codable, Identifiable, Equatable {
    var id = UUID()
    var hour = 7
    var minute = 0
    var enabled = true
    var days: Set<Int> = []          // 1 = Sunday … 7 = Saturday; empty = one-time
    var station: Station = presetStations[0]
    var lastFired: Date?             // blocks a second ring within 12 h (time-zone travel)
    var skipDay: String?             // "yyyy-MM-dd" (local) of the one ring being skipped
    var snooze: Int?                 // minutes; per alarm (nil in older saved data)
    var pinned: Bool?                // pinned alarms are listed first (nil in older saved data)

    var isRepeating: Bool { !days.isEmpty }
    var isPinned: Bool { pinned ?? false }
    var snoozeMinutes: Int {
        get { snooze ?? 9 }
        set { snooze = newValue }
    }
}

struct AlarmNotice: Equatable {
    let time: Date
    let alarmTime: String            // e.g. "7:00 AM"
}

/// Always read the Mac's current time zone (it changes when you travel).
func localCalendar() -> Calendar {
    var c = Calendar.current
    c.timeZone = TimeZone.current
    return c
}

func dayKey(_ d: Date) -> String {
    let c = localCalendar().dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}

func alarmTimeString(_ a: Alarm) -> String {
    let d = localCalendar().date(bySettingHour: a.hour, minute: a.minute, second: 0, of: Date())!
    return d.formatted(date: .omitted, time: .shortened)
}

/// A repeating timer that also runs while a menu or dialog is open (the menu bar menu,
/// the quit question), so alarms and fades never pause.
func commonTimer(_ interval: TimeInterval, _ block: @escaping @Sendable (Timer) -> Void) -> Timer {
    let t = Timer(timeInterval: interval, repeats: true, block: block)
    RunLoop.main.add(t, forMode: .common)
    return t
}

// MARK: - CoreAudio helpers

enum AudioOut {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let headphoneSource: UInt32 = 0x6864706E   // 'hdpn' — wired headphones in the jack

    private static func addr(_ sel: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func getUInt32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var a = addr(sel, scope)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static var defaultOutput: AudioDeviceID? {
        guard let id = getUInt32(system, kAudioHardwarePropertyDefaultOutputDevice), id != 0 else { return nil }
        return id
    }

    static var allDevices: [AudioDeviceID] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var a = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }

    static func uid(_ id: AudioDeviceID) -> String? {
        var a = addr(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &uid) == noErr,
              let u = uid?.takeRetainedValue() else { return nil }
        return u as String
    }

    static func device(withUID u: String) -> AudioDeviceID? { allDevices.first { uid($0) == u } }

    /// The Mac's own speakers (also carries the headphone jack).
    static var builtInOutput: AudioDeviceID? {
        allDevices.first { getUInt32($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn && hasOutput($0) }
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let t = getUInt32(id, kAudioDevicePropertyTransportType)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    static func wiredHeadphonesPlugged(_ id: AudioDeviceID) -> Bool {
        getUInt32(id, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput) == headphoneSource
    }

    static func volume(_ id: AudioDeviceID) -> Float? {
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioHardwareServiceGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func setVolume(_ id: AudioDeviceID, _ value: Float) {
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        var v = Float32(max(0, min(1, value)))
        AudioHardwareServiceSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func isMuted(_ id: AudioDeviceID) -> Bool {
        getUInt32(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput) == 1
    }

    static func setMuted(_ id: AudioDeviceID, _ muted: Bool) {
        var a = addr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(id, &a) else { return }
        var v: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }
}

// MARK: - Volume ramp (system volume, restored afterwards)

struct SavedVolume: Codable { var uid: String; var volume: Float; var muted: Bool }

@MainActor
final class VolumeRamp: ObservableObject {
    static let totalSteps = 16                 // same as the volume keys
    static let fastUntilStep = 8               // 50%
    static let fastInterval: TimeInterval = 5
    static let slowInterval: TimeInterval = 300
    private static let key = "RadioAlarm.restoreVolume"

    @Published var step = 0
    private var timer: Timer?
    private var device: AudioDeviceID?
    private var lastStep = Date()

    func start(device id: AudioDeviceID) {
        stop()
        device = id
        // Remember the pre-alarm state on disk so it can be restored even after a crash.
        if UserDefaults.standard.data(forKey: Self.key) == nil, let u = AudioOut.uid(id) {
            let saved = SavedVolume(uid: u, volume: AudioOut.volume(id) ?? 0.5, muted: AudioOut.isMuted(id))
            UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.key)
        }
        AudioOut.setMuted(id, false)
        step = 1
        AudioOut.setVolume(id, Float(step) / Float(Self.totalSteps))
        lastStep = Date()
        timer = commonTimer(1) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let id = device else { return }
        if AudioOut.isMuted(id) { AudioOut.setMuted(id, false) }   // e.g. AutoMute muted it
        // Also undo anything that turned the volume down (e.g. AutoMute setting it to 0) between steps.
        let target = Float(step) / Float(Self.totalSteps)
        if let v = AudioOut.volume(id), v < target - 0.01 { AudioOut.setVolume(id, target) }
        guard step < Self.totalSteps else { return }
        let interval = step < Self.fastUntilStep ? Self.fastInterval : Self.slowInterval
        if Date().timeIntervalSince(lastStep) >= interval {
            step += 1
            lastStep = Date()
            AudioOut.setVolume(id, Float(step) / Float(Self.totalSteps))
        }
    }

    func stopAndRestore() {
        stop()
        Self.restorePending()
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        device = nil
        step = 0
    }

    /// Put the volume back the way it was before the alarm (also run at launch / quit).
    static func restorePending() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(SavedVolume.self, from: data) else { return }
        if let id = AudioOut.device(withUID: saved.uid) {
            AudioOut.setVolume(id, saved.volume)
            AudioOut.setMuted(id, saved.muted)
        }
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Preview player (Test button / station picker)

@MainActor
final class RadioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var status = ""
    private var player: AVPlayer?
    private var statusObs: NSKeyValueObservation?

    func play(_ station: Station, volume: Double) {
        stop()
        guard let url = URL(string: station.url) else { status = "Bad URL"; return }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.volume = Float(volume)
        player = p
        status = "Connecting…"
        statusObs = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in
                switch item.status {
                case .readyToPlay: self?.status = "Live"
                case .failed: self?.status = "Stream failed: \(item.error?.localizedDescription ?? "unknown")"
                default: break
                }
            }
        }
        p.play()
        isPlaying = true
    }

    func stop() {
        statusObs = nil
        player?.pause(); player = nil
        isPlaying = false
        status = ""
    }
}

// MARK: - Alarm audio (radio with backup sound)

@MainActor
final class AlarmAudio: ObservableObject {
    enum Mode { case off, connecting, radio, backup }
    @Published var mode: Mode = .off

    private static let backupSound = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
    private static let failAfter: TimeInterval = 10
    private static let retryEvery: TimeInterval = 30

    private var station: Station?
    private var deviceUID: String?
    private var radio: AVPlayer?
    private var backup: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var watchdog: Timer?
    private var notPlayingSince: Date?
    private var lastRadioAttempt = Date()

    func start(_ station: Station, deviceUID: String?, online: Bool) {
        stop()
        self.station = station
        self.deviceUID = deviceUID
        mode = .connecting
        if !online { startBackup() }
        startRadio()
        watchdog = commonTimer(1) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    private func startRadio() {
        radio?.pause()
        lastRadioAttempt = Date()
        guard let s = station, let url = URL(string: s.url) else { return }
        let p = AVPlayer(url: url)
        if let u = deviceUID { p.audioOutputDeviceUniqueID = u }
        p.volume = backup == nil ? 1 : 0          // stay silent while the backup sound is on
        p.play()
        radio = p
    }

    private func startBackup() {
        guard backup == nil else { return }
        let q = AVQueuePlayer()
        if let u = deviceUID { q.audioOutputDeviceUniqueID = u }
        looper = AVPlayerLooper(player: q, templateItem: AVPlayerItem(url: Self.backupSound))
        q.play()
        backup = q
        radio?.volume = 0
        mode = .backup
    }

    private func stopBackup() {
        backup?.pause(); backup = nil
        looper = nil
    }

    private func check() {
        let now = Date()
        if let r = radio, r.timeControlStatus == .playing {
            notPlayingSince = nil
            if backup != nil { stopBackup(); r.volume = 1 }   // radio came back
            mode = .radio
            return
        }
        if notPlayingSince == nil { notPlayingSince = now }
        if backup == nil, now.timeIntervalSince(notPlayingSince!) > Self.failAfter { startBackup() }
        if backup != nil, now.timeIntervalSince(lastRadioAttempt) > Self.retryEvery { startRadio() }
    }

    private var fadeTimer: Timer?

    /// Fade the alarm sound to silence, then call `done` (used by the 15-minute auto-stop).
    func fadeOut(over seconds: TimeInterval, then done: @escaping () -> Void) {
        watchdog?.invalidate(); watchdog = nil      // don't switch radio/backup while fading
        let start = Date()
        let r0 = radio?.volume ?? 0, b0 = backup?.volume ?? 0
        fadeTimer = commonTimer(0.1) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                let k = Float(max(0, 1 - Date().timeIntervalSince(start) / seconds))
                self.radio?.volume = r0 * k
                self.backup?.volume = b0 * k
                if k == 0 { t.invalidate(); self.fadeTimer = nil; done() }
            }
        }
    }

    func stop() {
        fadeTimer?.invalidate(); fadeTimer = nil
        watchdog?.invalidate(); watchdog = nil
        radio?.pause(); radio = nil
        stopBackup()
        notPlayingSince = nil
        mode = .off
    }
}

// MARK: - Auto-open at login

@MainActor
enum AutoOpen {
    static let label = "local.radioalarm.opener"
    private static let loginKey = "RadioAlarm.loginItemRegistered"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Only the copy installed in /Applications manages this, so a test build elsewhere never registers itself.
    static var isInstalledCopy: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    private static let askedKey = "RadioAlarm.loginItemAsked"

    /// Open at login (after a restart). On first launch of an installed copy, ask the user once.
    /// Shown as a sheet (not a blocking modal) so alarm timers keep running while it's on screen.
    /// Whatever they choose, they can change it later in System Settings → General → Login Items.
    static func askForLoginItemIfNeeded() {
        let d = UserDefaults.standard
        // loginKey: set by the earlier version, which turned this on without asking.
        guard isInstalledCopy, !d.bool(forKey: askedKey), !d.bool(forKey: loginKey) else { return }
        if SMAppService.mainApp.status == .enabled { d.set(true, forKey: askedKey); return }
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }   // try again next launch
        d.set(true, forKey: askedKey)   // ask only once

        let alert = NSAlert()
        alert.messageText = "Open Radio Alarm when you log in?"
        alert.informativeText = """
        Alarms only ring while Radio Alarm is open. If it opens automatically when you log in, \
        your alarms keep working after you restart your Mac.

        You can change this later in System Settings → General → Login Items.
        """
        alert.addButton(withTitle: "Open at Login")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try SMAppService.mainApp.register()
            } catch {
                NSLog("RadioAlarm: couldn't add login item: \(error)")
            }
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()   // macOS wants the user to switch it on there
            }
        }
    }

    static var loginNeedsApproval: Bool {
        isInstalledCopy && SMAppService.mainApp.status == .requiresApproval
    }

    /// Minutes before each alarm that the opener job reopens the app.
    static let openerLeadMinutes = 5

    /// Safety net if the app was quit the night before (by accident, Force Quit or a crash): a launchd job
    /// (it runs even while the app is quit) reopens the app a few minutes before each alarm that's on.
    /// Does nothing if the app is already running. Rewritten whenever the alarms change.
    static func updateOpener(_ alarms: [Alarm]) {
        guard isInstalledCopy else { return }
        var times: [[String: Int]] = []
        for a in alarms where a.enabled {
            var m = a.hour * 60 + a.minute - openerLeadMinutes
            var dayShift = 0
            if m < 0 { m += 24 * 60; dayShift = -1 }          // e.g. a 00:02 alarm opens at 23:57 the day before
            let base = ["Hour": m / 60, "Minute": m % 60]
            if a.isRepeating {
                for d in a.days.sorted() {                     // app: 1 = Sunday … 7; launchd: 0 = Sunday … 6
                    var e = base; e["Weekday"] = (d - 1 + dayShift + 7) % 7
                    times.append(e)
                }
            } else {
                times.append(base)   // one-time: daily until it rings (it's then switched off and dropped from here)
            }
        }
        guard !times.isEmpty else { removeOldOpener(); return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c",
                                 "/usr/bin/pgrep -xq RadioAlarm || /usr/bin/open -g \"\(Bundle.main.bundlePath)\""],
            "StartCalendarInterval": times,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        if (try? Data(contentsOf: plistURL)) == data { return }   // unchanged: already scheduled
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: plistURL)) != nil else { return }
        launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    /// Removes the opener job (used when no alarm is on).
    /// (The earlier version's job used the same label, so this also cleans that up.)
    static func removeOldOpener() {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - Sleep radio (plays for a set time, then fades out)

@MainActor
final class SleepRadio: ObservableObject {
    static let durations = [15, 30, 45, 60, 0]     // 0 = no time limit
    static let extendMinutes = 15
    private static let fadeSeconds: TimeInterval = 60
    private static let giveUpAfter: TimeInterval = 15     // stream not playing this long = give up quietly
    private static let key = "RadioAlarm.sleep"
    private struct Saved: Codable { var station: Station?; var minutes: Int }

    @Published var station: Station? { didSet { save() } }
    @Published var minutes: Int { didSet { save() } }
    @Published var endsAt: Date?                   // nil while playing = no time limit
    @Published var remaining: TimeInterval = 0
    @Published var message: String?
    @Published var isPlaying = false

    private var player: AVPlayer?
    private var timer: Timer?
    private var notPlayingSince: Date?
    private var playingName = ""

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(Saved.self, from: data) {
            station = s.station
            minutes = s.minutes
        } else {
            station = nil
            minutes = 30
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Saved(station: station, minutes: minutes)) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Plays on whatever output is current (AirPods are fine) at the current volume — nothing is changed.
    func start(_ s: Station) {
        stop()
        message = nil
        guard let url = URL(string: s.url) else { message = "That station's link doesn't work."; return }
        let p = AVPlayer(url: url)
        p.play()
        player = p
        playingName = s.name
        isPlaying = true
        endsAt = minutes > 0 ? Date().addingTimeInterval(Double(minutes * 60)) : nil
        notPlayingSince = Date()
        timer = commonTimer(1) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func extend() {
        guard let e = endsAt else { return }
        endsAt = e.addingTimeInterval(Double(Self.extendMinutes * 60))
        tick()
    }

    private func tick() {
        guard let p = player else { return }
        if let e = endsAt {
            remaining = max(0, e.timeIntervalSinceNow)
            if remaining <= 0 { stop(); return }
            p.volume = Float(min(1, remaining / Self.fadeSeconds))     // fade out over the last minute
        }
        if p.timeControlStatus == .playing {
            notPlayingSince = nil
        } else {
            if notPlayingSince == nil { notPlayingSince = Date() }
            // Offline or station down: just stop (no backup beeping at bedtime).
            if Date().timeIntervalSince(notPlayingSince!) > Self.giveUpAfter {
                let name = playingName
                stop()
                message = "Couldn't play \(name). Check your internet connection."
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.pause(); player = nil
        isPlaying = false
        endsAt = nil
        remaining = 0
        notPlayingSince = nil
    }
}

// MARK: - Alarm controller

@MainActor
final class AlarmController: ObservableObject {
    @Published var alarms: [Alarm] {
        didSet {
            for i in alarms.indices {
                guard let old = oldValue.first(where: { $0.id == alarms[i].id }) else { continue }
                // A time/days change, or switching the alarm on, is a new alarm: clear the
                // "don't ring twice within 12 h" block and any skip, so it rings at its next occurrence.
                if alarms[i].hour != old.hour || alarms[i].minute != old.minute
                    || alarms[i].days != old.days || (alarms[i].enabled && !old.enabled) {
                    alarms[i].lastFired = nil
                    if alarms[i].skipDay == old.skipDay { alarms[i].skipDay = nil }
                }
            }
            save(); recompute()
            AutoOpen.updateOpener(alarms)   // keep the reopen-before-alarm job in step with the alarms
        }
    }
    @Published var ringing = false
    @Published var ringingAlarm: Alarm?
    @Published var snoozeUntil: Date?
    @Published var pendingFire: [UUID: Date] = [:]
    @Published var missed: AlarmNotice?
    @Published var autoStopped: AlarmNotice?
    @Published var now = Date()

    // Environment checks shown as banners
    @Published var online = true
    @Published var bluetoothOutput = false
    @Published var wiredHeadphones = false
    @Published var autoTimeZoneOff = false
    @Published var loginNeedsApproval = false

    let preview = RadioPlayer()
    let audio = AlarmAudio()
    let ramp = VolumeRamp()
    let sleep = SleepRadio()

    static weak var shared: AlarmController?
    /// Set by the menu bar icon (which is always on screen) so the window can be reopened after it's closed.
    var openMainWindow: (() -> Void)?

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)        // bring the Dock icon back while the window is open
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    var nextAlarmSummary: String {
        if let s = snoozeUntil { return "Snoozing until \(s.formatted(date: .omitted, time: .shortened))" }
        guard let n = nextFire else { return "No alarms on" }
        return "Next alarm: \(n.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    private var ticker: Timer?
    private var lastTZ = TimeZone.current.identifier
    private var awakeAssertion: IOPMAssertionID = 0
    private let pathMonitor = NWPathMonitor()
    private var snoozedAlarm: Alarm?
    private static let key = "RadioAlarm.state"
    private static let legacyKey = "RadioAlarm.settings"
    private static let legacyLastFiredKey = "RadioAlarm.lastFired"
    private static let missedGrace: TimeInterval = 90     // later than this = Mac was asleep
    private static let autoStopAfter: TimeInterval = 15 * 60   // stop by itself if nobody presses Stop/Snooze
    private static let autoStopNoticeFor: TimeInterval = 60 * 60   // hide the "stopped automatically" banner after this
    private var ringStarted: Date?
    private var autoStopping = false

    // snoozeMinutes: the old shared snooze length, only read to fill in alarms saved before it was per alarm.
    private struct SavedState: Codable { var alarms: [Alarm]; var snoozeMinutes: Int? }

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.key), let s = try? JSONDecoder().decode(SavedState.self, from: data) {
            var loaded = s.alarms
            for i in loaded.indices where loaded[i].snooze == nil { loaded[i].snooze = s.snoozeMinutes ?? 9 }
            alarms = loaded
        } else if let data = d.data(forKey: Self.legacyKey),
                  let old = try? JSONDecoder().decode(AlarmSettings.self, from: data) {
            // Move the old single alarm into the list, unchanged.
            alarms = [Alarm(hour: old.hour, minute: old.minute, enabled: old.enabled, days: old.days,
                            station: old.station, lastFired: d.object(forKey: Self.legacyLastFiredKey) as? Date,
                            snooze: old.snoozeMinutes)]
        } else {
            alarms = [Alarm(enabled: false, snooze: 9)]
        }
        save()
        VolumeRamp.restorePending()   // in case the app quit mid-alarm
        AutoOpen.updateOpener(alarms)   // schedule the reopen-before-alarm job (replaces the old removal)
        Self.shared = self
        recompute()

        // Keep the screen (and therefore the Mac) awake while the app is open.
        // Closing the lid still puts the Mac to sleep.
        IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Radio Alarm keeps the screen on" as CFString, &awakeAssertion)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.online = path.status == .satisfied }
        }
        pathMonitor.start(queue: .main)

        // Follow the Mac's clock and time zone as they change (travel, manual changes).
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.timeChanged() }
            }
        }

        ticker = commonTimer(1) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        checkEnvironment()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(SavedState(alarms: alarms, snoozeMinutes: nil)) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    // MARK: Editing

    func addAlarm() -> UUID {
        // Start from the most recent alarm's station and snooze length.
        let a = Alarm(station: alarms.last?.station ?? presetStations[0], snooze: alarms.last?.snoozeMinutes ?? 9)
        alarms.append(a)
        return a.id
    }

    func deleteAlarm(_ id: UUID) {
        alarms.removeAll { $0.id == id }
    }

    /// Pin/unpin an alarm (swipe right). Pinned alarms are listed first.
    func togglePin(_ id: UUID) {
        guard let i = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[i].pinned = !alarms[i].isPinned
    }

    /// The next ring of this alarm, ignoring any skip — the ring the Skip button acts on.
    func nextOccurrence(_ a: Alarm, honoringSkip: Bool = false) -> Date? {
        guard a.enabled else { return nil }
        let cal = localCalendar()
        let start = Date()
        for offset in 0..<16 {
            guard let day = cal.date(byAdding: .day, value: offset, to: start),
                  let t = cal.date(bySettingHour: a.hour, minute: a.minute, second: 0, of: day),
                  t > start else { continue }
            if a.isRepeating && !a.days.contains(cal.component(.weekday, from: t)) { continue }
            // Never ring twice in one morning (e.g. flying west after it already rang).
            if let lf = a.lastFired, abs(t.timeIntervalSince(lf)) < 12 * 3600 { continue }
            if honoringSkip, a.skipDay == dayKey(t) { continue }
            return t
        }
        return nil
    }

    func toggleSkip(_ id: UUID) {
        guard let i = alarms.firstIndex(where: { $0.id == id }) else { return }
        if alarms[i].skipDay != nil {
            alarms[i].skipDay = nil
        } else if alarms[i].isRepeating, let t = nextOccurrence(alarms[i]) {
            alarms[i].skipDay = dayKey(t)
        }
    }

    /// The ring currently being skipped, if any.
    func skippedRing(_ a: Alarm) -> Date? {
        guard let key = a.skipDay else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone.current
        guard let day = f.date(from: key) else { return nil }
        return localCalendar().date(bySettingHour: a.hour, minute: a.minute, second: 0, of: day)
    }

    var nextFire: Date? { ([snoozeUntil].compactMap { $0 } + Array(pendingFire.values)).min() }

    private func timeChanged() {
        NSTimeZone.resetSystemTimeZone()
        lastTZ = TimeZone.current.identifier
        recompute()
        now = Date()
    }

    /// Work out each alarm's next ring in the current local time zone.
    private func recompute() {
        var p: [UUID: Date] = [:]
        for a in alarms { if let t = nextOccurrence(a, honoringSkip: true) { p[a.id] = t } }
        pendingFire = p
    }

    private func tick() {
        now = Date()
        if TimeZone.current.identifier != lastTZ { timeChanged() }
        if Int(now.timeIntervalSince1970) % 3 == 0 { checkEnvironment() }
        // Nobody pressed Stop/Snooze for 15 minutes (e.g. you went out): fade out and stop.
        if ringing, !autoStopping, let rs = ringStarted, now.timeIntervalSince(rs) >= Self.autoStopAfter {
            autoStop()
        }
        // The "stopped automatically" banner clears itself after an hour so it doesn't linger as old news.
        if let n = autoStopped, now.timeIntervalSince(n.time) >= Self.autoStopNoticeFor {
            autoStopped = nil
        }

        // A skip clears itself once the skipped ring has passed.
        for i in alarms.indices {
            if let s = skippedRing(alarms[i]), now >= s { alarms[i].skipDay = nil }
        }

        if !ringing, let s = snoozeUntil, now >= s, let a = snoozedAlarm {
            snoozeUntil = nil
            snoozedAlarm = nil
            if now.timeIntervalSince(s) < Self.missedGrace { fire(a) }
            else { missed = AlarmNotice(time: s, alarmTime: alarmTimeString(a)) }
        }

        // Snapshot first: each change to `alarms` recomputes pendingFire, which would
        // push a second alarm due this same minute to tomorrow.
        let due = pendingFire
        var changed = false
        for i in alarms.indices {
            guard let f = due[alarms[i].id], now >= f else { continue }
            alarms[i].lastFired = f
            if now.timeIntervalSince(f) < Self.missedGrace {
                // Already ringing (another alarm, same minute or overlapping): don't start a second ring.
                if !ringing { fire(alarms[i]) }
            } else {
                missed = AlarmNotice(time: f, alarmTime: alarmTimeString(alarms[i]))   // Mac was asleep
            }
            if !alarms[i].isRepeating { alarms[i].enabled = false }   // one-time alarm
            changed = true
        }
        if changed { recompute() }
    }

    private func checkEnvironment() {
        let speakers = AudioOut.builtInOutput ?? AudioOut.defaultOutput
        if let s = speakers {
            wiredHeadphones = AudioOut.wiredHeadphonesPlugged(s)
        }
        bluetoothOutput = AudioOut.defaultOutput.map(AudioOut.isBluetooth) ?? false
        loginNeedsApproval = AutoOpen.loginNeedsApproval
        let tzPrefs = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.timezone.auto.plist")
        autoTimeZoneOff = (tzPrefs?["Active"] as? Bool) == false
    }

    var headphonesConnected: Bool { bluetoothOutput || wiredHeadphones }

    func fire(_ a: Alarm) {
        preview.stop()
        sleep.stop()          // the alarm takes over from sleep radio
        ringing = true
        ringingAlarm = a
        ringStarted = Date()
        autoStopping = false
        missed = nil
        autoStopped = nil
        // Always ring on the Mac's speakers, never in AirPods/Bluetooth headphones.
        let device = AudioOut.builtInOutput ?? AudioOut.defaultOutput
        if let d = device { ramp.start(device: d) }
        audio.start(a.station, deviceUID: device.flatMap(AudioOut.uid), online: online)
        showMainWindow()                       // reopens the window if it was closed to the menu bar
        NSApp.requestUserAttention(.criticalRequest)
    }

    private func autoStop() {
        autoStopping = true
        audio.fadeOut(over: 5) { [weak self] in
            guard let self, self.ringing else { return }
            let label = self.ringingAlarm.map(alarmTimeString) ?? ""
            self.stopAlarm()
            self.autoStopped = AlarmNotice(time: Date(), alarmTime: label)
        }
    }

    func stopAlarm() {
        ringing = false
        ringingAlarm = nil
        ringStarted = nil
        autoStopping = false
        snoozeUntil = nil
        snoozedAlarm = nil
        audio.stop()
        ramp.stopAndRestore()
    }

    func snooze() {
        let minutes = ringingAlarm?.snoozeMinutes ?? 9     // this alarm's own snooze length
        snoozedAlarm = ringingAlarm
        ringing = false
        ringingAlarm = nil
        ringStarted = nil
        autoStopping = false
        audio.stop()
        ramp.stopAndRestore()
        snoozeUntil = Date().addingTimeInterval(Double(minutes * 60))
    }
}

// MARK: - Station search (radio-browser.info, free & open)

struct RBStation: Decodable {
    let name: String
    let url_resolved: String
    let country: String?
    let state: String?
    let codec: String?
    let bitrate: Int?
}

func searchStations(_ query: String) async -> [Station] {
    var comps = URLComponents(string: "https://all.api.radio-browser.info/json/stations/search")!
    comps.queryItems = [
        .init(name: "name", value: query),
        .init(name: "limit", value: "40"),
        .init(name: "hidebroken", value: "true"),
        .init(name: "order", value: "clickcount"),
        .init(name: "reverse", value: "true"),
    ]
    var req = URLRequest(url: comps.url!)
    req.setValue("RadioAlarm/1.0", forHTTPHeaderField: "User-Agent")
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let results = try? JSONDecoder().decode([RBStation].self, from: data) else { return [] }
    return results.map {
        let place = [$0.state, $0.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        let fmt = [$0.codec, ($0.bitrate ?? 0) > 0 ? "\($0.bitrate!)k" : nil].compactMap { $0 }.joined(separator: " ")
        return Station(name: $0.name.trimmingCharacters(in: .whitespaces), url: $0.url_resolved,
                       detail: [place, fmt].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

// MARK: - Theme

extension Color {
    static let bg = Color.black
    static let card = Color(white: 0.08)
    static let accent = Color(red: 1.0, green: 0.12, blue: 0.10)
    static let dim = Color.white.opacity(0.5)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Seven-segment clock

struct SevenSegmentDigit: View {
    let digit: Int?          // nil = blank
    let lit: Color
    // Segments: a(top) b(top-right) c(bottom-right) d(bottom) e(bottom-left) f(top-left) g(middle)
    private static let map: [[Bool]] = [
        [true, true, true, true, true, true, false],     // 0
        [false, true, true, false, false, false, false], // 1
        [true, true, false, true, true, false, true],    // 2
        [true, true, true, true, false, false, true],    // 3
        [false, true, true, false, false, true, true],   // 4
        [true, false, true, true, false, true, true],    // 5
        [true, false, true, true, true, true, true],     // 6
        [true, true, true, false, false, false, false],  // 7
        [true, true, true, true, true, true, true],      // 8
        [true, true, true, true, false, true, true],     // 9
    ]

    var body: some View {
        Canvas { ctx, size in
            let paths = Self.segments(in: size)
            let on = digit.map { Self.map[$0] } ?? Array(repeating: false, count: 7)
            for (i, p) in paths.enumerated() where !on[i] {
                ctx.fill(p, with: .color(lit.opacity(0.07)))     // faint unlit segments
            }
            ctx.addFilter(.shadow(color: lit.opacity(0.8), radius: size.width * 0.06))
            for (i, p) in paths.enumerated() where on[i] {
                ctx.fill(p, with: .color(lit))
            }
        }
        .aspectRatio(0.56, contentMode: .fit)
    }

    static func segments(in s: CGSize) -> [Path] {
        let w = s.width, h = s.height
        let t = w * 0.17             // thickness
        let g = t * 0.12             // gap between segments
        func hseg(_ y: CGFloat) -> Path {
            let x1 = t / 2 + g, x2 = w - t / 2 - g
            var p = Path()
            p.addLines([CGPoint(x: x1, y: y), CGPoint(x: x1 + t / 2, y: y - t / 2), CGPoint(x: x2 - t / 2, y: y - t / 2),
                        CGPoint(x: x2, y: y), CGPoint(x: x2 - t / 2, y: y + t / 2), CGPoint(x: x1 + t / 2, y: y + t / 2)])
            p.closeSubpath()
            return p
        }
        func vseg(_ x: CGFloat, _ y1: CGFloat, _ y2: CGFloat) -> Path {
            let a = y1 + g, b = y2 - g
            var p = Path()
            p.addLines([CGPoint(x: x, y: a), CGPoint(x: x + t / 2, y: a + t / 2), CGPoint(x: x + t / 2, y: b - t / 2),
                        CGPoint(x: x, y: b), CGPoint(x: x - t / 2, y: b - t / 2), CGPoint(x: x - t / 2, y: a + t / 2)])
            p.closeSubpath()
            return p
        }
        let top = t / 2, mid = h / 2, bot = h - t / 2
        let left = t / 2, right = w - t / 2
        return [hseg(top), vseg(right, top, mid), vseg(right, mid, bot), hseg(bot),
                vseg(left, mid, bot), vseg(left, top, mid), hseg(mid)]
    }
}

struct DigitalClock: View {
    let date: Date
    var height: CGFloat = 90
    var showSeconds = true

    private var uses12h: Bool {
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false
    }

    var body: some View {
        let c = localCalendar().dateComponents([.hour, .minute, .second], from: date)
        var hour = c.hour ?? 0
        let isPM = hour >= 12
        if uses12h { hour = hour % 12 == 0 ? 12 : hour % 12 }
        let colonOn = (c.second ?? 0) % 2 == 0
        // Seconds are drawn at the same size as hours and minutes.
        return HStack(alignment: .top, spacing: height * 0.12) {
            HStack(spacing: height * 0.1) {
                SevenSegmentDigit(digit: (uses12h && hour < 10) ? nil : hour / 10, lit: .accent)
                SevenSegmentDigit(digit: hour % 10, lit: .accent)
                colon(on: colonOn)
                SevenSegmentDigit(digit: (c.minute ?? 0) / 10, lit: .accent)
                SevenSegmentDigit(digit: (c.minute ?? 0) % 10, lit: .accent)
                if showSeconds {
                    colon(on: colonOn)
                    SevenSegmentDigit(digit: (c.second ?? 0) / 10, lit: .accent)
                    SevenSegmentDigit(digit: (c.second ?? 0) % 10, lit: .accent)
                }
            }
            .frame(height: height)
            if uses12h {
                Text(isPM ? "PM" : "AM")
                    .font(.system(size: height * 0.18, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accent)
                    .shadow(color: .accent.opacity(0.7), radius: 4)
            }
        }
    }

    private func colon(on: Bool) -> some View {
        VStack(spacing: height * 0.22) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accent.opacity(on ? 1 : 0.07))
                    .frame(width: height * 0.09, height: height * 0.09)
                    .shadow(color: .accent.opacity(on ? 0.8 : 0), radius: 5)
            }
        }
    }
}

struct TimeZoneLabel: View {
    let date: Date
    var body: some View {
        let tz = TimeZone.current
        let city = tz.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? tz.identifier
        let day = date.formatted(Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day())
        Text("\(day)  ·  \(tz.abbreviation(for: date) ?? "") \(city)")
            .font(.system(.title2, design: .monospaced))
            .foregroundStyle(Color.accent.opacity(0.75))
    }
}

// MARK: - Views

struct Banner: View {
    let icon: String
    let text: String
    var dismiss: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accent)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Color.dim)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accent.opacity(0.35)))
    }
}

struct ContentView: View {
    @EnvironmentObject var alarm: AlarmController
    @ObservedObject var preview: RadioPlayer
    @State private var editing: EditTarget?
    @State private var rowHeights: [UUID: CGFloat] = [:]

    struct EditTarget: Identifiable { let id: UUID }

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            if alarm.ringing {
                RingingView(audio: alarm.audio, ramp: alarm.ramp)
            } else {
                // Center the panel vertically in the window (still scrolls if the window is small).
                GeometryReader { geo in
                    ScrollView {
                        mainPanel.padding(20)
                            .frame(minHeight: geo.size.height)
                    }
                }
            }
        }
        .sheet(item: $editing) { t in AlarmEditor(id: t.id, preview: preview).environmentObject(alarm) }
        .onAppear { NSApp.setActivationPolicy(.regular) }
        // Red close button: keep running in the menu bar only, without a Dock icon.
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private var mainPanel: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                DigitalClock(date: alarm.now)
                TimeZoneLabel(date: alarm.now)
                Text(nextLabel).font(.callout).foregroundStyle(Color.dim)
            }
            .padding(.vertical, 10)

            banners

            Card {
                // The rows are a List (not a plain ForEach) because swipe actions only work in a List.
                // Swipe right: Pin. Swipe left: Delete, and Skip next for repeating alarms.
                List {
                    // Pinned alarms first, then by time of day (stored order is unchanged).
                    ForEach(sortedAlarms) { a in
                        VStack(spacing: 12) {
                            AlarmRow(a: a, skipped: alarm.skippedRing(a), enabled: enabledBinding(a.id))
                                .contentShape(Rectangle())
                                .onTapGesture { editing = EditTarget(id: a.id) }
                            Divider().overlay(Color.white.opacity(0.06))
                        }
                        .padding(.bottom, 12)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: RowHeights.self, value: [a.id: g.size.height])
                        })
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.card)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { alarm.togglePin(a.id) } label: {
                                Label(a.isPinned ? "Unpin" : "Pin", systemImage: a.isPinned ? "pin.slash" : "pin")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { alarm.deleteAlarm(a.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            // Same skip as the editor's Skip button; only repeating alarms that are on have a next ring to skip.
                            if alarm.skippedRing(a) != nil {
                                Button { alarm.toggleSkip(a.id) } label: {
                                    Label("Undo skip", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.gray)
                            } else if a.isRepeating, alarm.nextOccurrence(a) != nil {
                                Button { alarm.toggleSkip(a.id) } label: {
                                    Label("Skip next", systemImage: "forward.end")
                                }
                                .tint(.gray)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                // A List inside the page's ScrollView has no height of its own: size it to its rows.
                .frame(height: sortedAlarms.reduce(0) { $0 + (rowHeights[$1.id] ?? 64) })
                .onPreferenceChange(RowHeights.self) { rowHeights = $0 }
                Button {
                    editing = EditTarget(id: alarm.addAlarm())
                } label: {
                    Label("Add alarm", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accent)
            }

            SleepRadioCard(sleep: alarm.sleep, preview: preview)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    private var sortedAlarms: [Alarm] {
        alarm.alarms.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return ($0.hour, $0.minute) < ($1.hour, $1.minute)
        }
    }

    /// Measured height of each alarm row, used to size the List.
    struct RowHeights: PreferenceKey {
        static var defaultValue: [UUID: CGFloat] = [:]
        static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
            value.merge(nextValue()) { $1 }
        }
    }

    private func enabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { alarm.alarms.first { $0.id == id }?.enabled ?? false },
                set: { v in if let i = alarm.alarms.firstIndex(where: { $0.id == id }) { alarm.alarms[i].enabled = v } })
    }

    @ViewBuilder private var banners: some View {
        if let a = alarm.autoStopped {
            Banner(icon: "alarm",
                   text: "The \(a.alarmTime) alarm stopped automatically at \(a.time.formatted(date: .omitted, time: .shortened)) — no one pressed Stop.",
                   dismiss: { alarm.autoStopped = nil })
        }
        if let m = alarm.missed {
            Banner(icon: "exclamationmark.triangle.fill",
                   text: "Missed the \(m.alarmTime) alarm at \(m.time.formatted(date: .omitted, time: .shortened)) — your Mac was asleep.",
                   dismiss: { alarm.missed = nil })
        }
        if !alarm.online {
            Banner(icon: "wifi.slash", text: "You're offline. The alarm will use the backup sound until the radio connects.")
        }
        if alarm.wiredHeadphones {
            Banner(icon: "headphones", text: "Wired headphones are plugged in. Unplug them or the alarm will play in them.")
        } else if alarm.bluetoothOutput {
            Banner(icon: "airpodspro", text: "Headphones connected. The alarm will play through the Mac's speakers, not your headphones.")
        }
        if alarm.loginNeedsApproval {
            Banner(icon: "power",
                   text: "To reopen after a restart, allow Radio Alarm in System Settings → General → Login Items.")
        }
        if alarm.autoTimeZoneOff {
            Banner(icon: "globe",
                   text: "Automatic time zone is off. Turn on “Set time zone automatically” in System Settings → General → Date & Time so the alarm follows you when you travel.")
        }
    }

    private var nextLabel: String {
        if let s = alarm.snoozeUntil { return "Snoozing until \(s.formatted(date: .omitted, time: .shortened))" }
        guard let n = alarm.nextFire else { return "No alarms on" }
        let mins = Int(n.timeIntervalSince(alarm.now) / 60) + 1
        let rel = mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
        return "Next alarm \(n.formatted(.dateTime.weekday(.abbreviated).hour().minute())) · in \(rel)"
    }
}

func daysSummary(_ days: Set<Int>) -> String {
    if days.isEmpty { return "Once" }
    if days.count == 7 { return "Every day" }
    if days == [2, 3, 4, 5, 6] { return "Weekdays" }
    if days == [1, 7] { return "Weekends" }
    let symbols = Calendar.current.shortWeekdaySymbols   // index 0 = Sunday
    return days.sorted().map { symbols[$0 - 1] }.joined(separator: " ")
}

struct AlarmRow: View {
    let a: Alarm
    let skipped: Date?
    @Binding var enabled: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(alarmTimeString(a))
                        .font(.system(size: 30, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(a.enabled ? Color.white : Color.dim)
                    // Shows the alarm is pinned to the top of the list.
                    if a.isPinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
                Text("\(daysSummary(a.days)) · \(a.station.name)")
                    .font(.caption).foregroundStyle(Color.dim).lineLimit(1)
                if let s = skipped {
                    Text("Skipping \(s.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                        .font(.caption).foregroundStyle(Color.accent)
                }
            }
            Spacer()
            Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch).tint(.accent)
        }
    }
}

struct AlarmEditor: View {
    let id: UUID
    @EnvironmentObject var alarm: AlarmController
    @ObservedObject var preview: RadioPlayer
    @Environment(\.dismiss) var dismiss
    @State private var showStations = false

    private var current: Alarm? { alarm.alarms.first { $0.id == id } }

    private var binding: Binding<Alarm> {
        Binding(get: { current ?? Alarm() },
                set: { v in if let i = alarm.alarms.firstIndex(where: { $0.id == id }) { alarm.alarms[i] = v } })
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            localCalendar().date(bySettingHour: binding.wrappedValue.hour, minute: binding.wrappedValue.minute,
                                 second: 0, of: Date())!
        }, set: { d in
            let c = localCalendar().dateComponents([.hour, .minute], from: d)
            var a = binding.wrappedValue
            a.hour = c.hour ?? 7
            a.minute = c.minute ?? 0
            binding.wrappedValue = a
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Alarm").font(.title3.bold())
                Spacer()
                Button("Done") { preview.stop(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let a = current {
                Card {
                    HStack {
                        DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.stepperField)
                            .font(.title2)
                        Spacer()
                        Toggle("On", isOn: binding.enabled).toggleStyle(.switch).tint(.accent)
                    }
                    DayPicker(days: binding.days)
                }

                Card {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Color.accent)
                        VStack(alignment: .leading) {
                            Text(a.station.name).font(.headline)
                            if !a.station.detail.isEmpty {
                                Text(a.station.detail).font(.caption).foregroundStyle(Color.dim)
                            }
                        }
                        Spacer()
                        Button("Change…") { showStations = true }
                    }
                    HStack {
                        Button {
                            if preview.isPlaying { preview.stop() }
                            else { preview.play(a.station, volume: alarm.headphonesConnected ? 0.2 : 1) }
                        } label: {
                            Label(preview.isPlaying ? "Stop" : "Test", systemImage: preview.isPlaying ? "stop.fill" : "play.fill")
                        }
                        Text(preview.status).font(.caption).foregroundStyle(Color.dim).lineLimit(1)
                    }
                }

                if a.isRepeating {
                    Card { skipRow(a) }
                }

                // Snooze length lives here (moved off the main screen); each alarm has its own.
                Card {
                    HStack {
                        Stepper("Snooze: \(a.snoozeMinutes) min", value: binding.snoozeMinutes, in: 1...30)
                        Spacer()
                        Text("This alarm").font(.caption).foregroundStyle(Color.dim)
                    }
                }

                Button(role: .destructive) {
                    preview.stop()
                    dismiss()
                    alarm.deleteAlarm(id)
                } label: {
                    Label("Delete alarm", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Color.bg)
        .sheet(isPresented: $showStations) {
            StationPicker(station: binding.station, preview: preview).environmentObject(alarm)
        }
    }

    @ViewBuilder private func skipRow(_ a: Alarm) -> some View {
        let day = Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day()
        HStack {
            if let s = alarm.skippedRing(a) {
                Text("Skipping \(s.formatted(day)). It rings again after that.")
                    .foregroundStyle(Color.accent)
                Spacer()
                Button("Undo skip") { alarm.toggleSkip(id) }
            } else if let n = alarm.nextOccurrence(a) {
                Text("Next ring \(n.formatted(day)) \(n.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(Color.dim)
                Spacer()
                Button("Skip \(n.formatted(day))") { alarm.toggleSkip(id) }
            } else {
                Text("Turn the alarm on to skip a day.").foregroundStyle(Color.dim)
            }
        }
    }
}

struct SleepRadioCard: View {
    @EnvironmentObject var alarm: AlarmController
    @ObservedObject var sleep: SleepRadio
    @ObservedObject var preview: RadioPlayer
    @State private var showStations = false

    /// Last station used for sleep radio, else the most recent alarm's station.
    private var station: Station { sleep.station ?? alarm.alarms.last?.station ?? presetStations[0] }

    var body: some View {
        Card {
            HStack {
                Image(systemName: "moon.fill").foregroundStyle(Color.accent)
                VStack(alignment: .leading) {
                    Text("Sleep radio").font(.headline)
                    Text(station.name).font(.caption).foregroundStyle(Color.dim)
                }
                Spacer()
                if !sleep.isPlaying { Button("Change…") { showStations = true } }
            }
            if sleep.isPlaying {
                HStack {
                    if sleep.endsAt != nil {
                        Text("Stops in \(countdown)").monospacedDigit().foregroundStyle(Color.accent)
                        if sleep.remaining <= 60 { Text("fading out").font(.caption).foregroundStyle(Color.dim) }
                    } else {
                        Text("Playing · no time limit").foregroundStyle(Color.accent)
                    }
                    Spacer()
                    if sleep.endsAt != nil {
                        Button("+\(SleepRadio.extendMinutes) min") { sleep.extend() }
                    }
                    Button("Stop") { sleep.stop() }
                }
            } else {
                HStack(spacing: 6) {
                    ForEach(SleepRadio.durations, id: \.self) { m in
                        Button { sleep.minutes = m } label: {
                            Text(m > 0 ? "\(m) min" : "No limit")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(sleep.minutes == m ? Color.accent : Color.white.opacity(0.08), in: Capsule())
                                .foregroundStyle(Color.white)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Button {
                        preview.stop()
                        sleep.start(station)
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                }
                if let m = sleep.message {
                    Text(m).font(.caption).foregroundStyle(Color.accent)
                }
            }
        }
        .sheet(isPresented: $showStations) {
            StationPicker(station: Binding(get: { station }, set: { sleep.station = $0 }), preview: preview)
                .environmentObject(alarm)
        }
    }

    private var countdown: String {
        let t = Int(sleep.remaining.rounded(.up))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct DayPicker: View {
    @Binding var days: Set<Int>
    private let symbols = Calendar.current.veryShortWeekdaySymbols   // index 0 = Sunday
    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { d in
                let on = days.contains(d)
                Button {
                    if on { days.remove(d) } else { days.insert(d) }
                } label: {
                    Text(symbols[d - 1])
                        .font(.caption.bold())
                        .frame(width: 30, height: 30)
                        .background(on ? Color.accent : Color.white.opacity(0.08), in: Circle())
                        .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(days.isEmpty ? "Once" : days.count == 7 ? "Every day" : "Repeats")
                .font(.caption).foregroundStyle(Color.dim)
        }
    }
}

struct RingingView: View {
    @EnvironmentObject var alarm: AlarmController
    @ObservedObject var audio: AlarmAudio
    @ObservedObject var ramp: VolumeRamp

    var body: some View {
        VStack(spacing: 22) {
            DigitalClock(date: alarm.now, height: 130, showSeconds: false)
            TimeZoneLabel(date: alarm.now)
            VStack(spacing: 4) {
                Text(audio.mode == .backup ? "Backup sound — radio unavailable" : (alarm.ringingAlarm?.station.name ?? ""))
                Text("Volume \(ramp.step)/\(VolumeRamp.totalSteps)").font(.caption)
            }
            .foregroundStyle(Color.dim)
            HStack(spacing: 16) {
                Button { alarm.snooze() } label: {
                    Text("Snooze \(alarm.ringingAlarm?.snoozeMinutes ?? 9)m").frame(width: 150, height: 48)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .keyboardShortcut(.space, modifiers: [])
                Button { alarm.stopAlarm() } label: {
                    Text("Stop").bold().frame(width: 150, height: 48).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .background(Color.accent, in: RoundedRectangle(cornerRadius: 12))
                .keyboardShortcut(.return, modifiers: [])
            }
            .font(.title3)
        }
    }
}

struct StationPicker: View {
    @Binding var station: Station
    @EnvironmentObject var alarm: AlarmController
    @ObservedObject var preview: RadioPlayer
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var results: [Station] = []
    @State private var searching = false
    @State private var customName = ""
    @State private var customURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose a station").font(.title3.bold())
                Spacer()
                Button("Done") { preview.stop(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("Search stations (e.g. KEXP, BBC, jazz, 101.1)", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runSearch)
                Button("Search", action: runSearch).disabled(query.isEmpty)
            }
            List {
                Section("Presets") { ForEach(presetStations) { row($0) } }
                if searching { Section { ProgressView().frame(maxWidth: .infinity) } }
                if !results.isEmpty { Section("Results") { ForEach(results) { row($0) } } }
            }
            .scrollContentBackground(.hidden)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 10))

            Text("Or paste a stream URL").font(.caption).foregroundStyle(Color.dim)
            HStack {
                TextField("Name", text: $customName).textFieldStyle(.roundedBorder).frame(width: 140)
                TextField("https://…", text: $customURL).textFieldStyle(.roundedBorder)
                Button("Use") {
                    station = Station(name: customName.isEmpty ? "Custom" : customName, url: customURL)
                    dismiss()
                }.disabled(URL(string: customURL)?.scheme == nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .background(Color.bg)
    }

    private func row(_ s: Station) -> some View {
        HStack {
            Button { preview.play(s, volume: alarm.headphonesConnected ? 0.2 : 1) } label: {
                Image(systemName: "play.circle")
            }.buttonStyle(.plain).foregroundStyle(Color.accent)
            VStack(alignment: .leading) {
                Text(s.name).lineLimit(1)
                if !s.detail.isEmpty { Text(s.detail).font(.caption).foregroundStyle(Color.dim).lineLimit(1) }
            }
            Spacer()
            if s.url == station.url {
                Image(systemName: "checkmark").foregroundStyle(Color.accent)
            } else {
                Button("Select") { station = s }
            }
        }
    }

    private func runSearch() {
        guard !query.isEmpty else { return }
        searching = true
        Task {
            results = await searchStations(query)
            searching = false
        }
    }
}

// MARK: - Menu bar

struct MenuBarIcon: View {
    @Environment(\.openWindow) private var openWindow
    let alarm: AlarmController
    var body: some View {
        Image(systemName: "alarm.fill")
            .onAppear { alarm.openMainWindow = { openWindow(id: "main") } }
    }
}

struct MenuBarMenu: View {
    @ObservedObject var alarm: AlarmController
    @ObservedObject var sleep: SleepRadio
    var body: some View {
        Text(alarm.nextAlarmSummary)
        Divider()
        Button("Open Radio Alarm") { alarm.showMainWindow() }
        if alarm.ringing {
            Button("Stop Alarm") { alarm.stopAlarm() }
        }
        if sleep.isPlaying {
            Button("Stop Sleep Radio") { sleep.stop() }
        }
        Divider()
        Button("Quit Radio Alarm…") { NSApp.terminate(nil) }   // asks first (see applicationShouldTerminate)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)   // force dark mode regardless of system setting
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.systemIsShuttingDown = true
        }
        // First launch after install: ask whether to open at login (once the window is up).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated { AutoOpen.askForLoginItemIfNeeded() }
        }
        // Return/Enter while typing the alarm time: finish editing (deselect the time field).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 36 || event.keyCode == 76,          // Return, keypad Enter
                  let window = event.window,
                  var view = window.firstResponder as? NSView else { return event }
            while !(view is NSDatePicker) {
                guard let parent = view.superview else { return event }
                view = parent
            }
            window.makeFirstResponder(nil)
            return nil
        }
    }
    private var systemIsShuttingDown = false

    /// Cmd-Q / Quit: always ask first — alarms don't ring while the app is quit.
    /// Not asked when the Mac restarts, shuts down or logs out (it would block that).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if systemIsShuttingDown { return .terminateNow }
        let summary = MainActor.assumeIsolated { AlarmController.shared?.nextAlarmSummary ?? "" }
        let alert = NSAlert()
        alert.messageText = "Quit Radio Alarm?"
        alert.informativeText = "Your alarms won't ring until you open it again.\n\(summary)"
        alert.addButton(withTitle: "Cancel")       // first button = default (Return) and Esc
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { VolumeRamp.restorePending() }   // never leave the volume cranked up
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (Finder/Spotlight) while it's in the menu bar: show the window.
        if !flag { MainActor.assumeIsolated { AlarmController.shared?.showMainWindow() } }
        return true
    }
}

@main
struct RadioAlarmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var alarm = AlarmController()

    init() {
        // Only one copy may run (two would both ring): if one is already open, show it and quit this one.
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != getpid() }) {
            other.activate()
            exit(0)
        }
    }

    var body: some Scene {
        Window("Radio Alarm", id: "main") {
            ContentView(preview: alarm.preview)
                .environmentObject(alarm)
                .preferredColorScheme(.dark)
                .frame(minWidth: 460, minHeight: 640)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarMenu(alarm: alarm, sleep: alarm.sleep)
        } label: {
            MenuBarIcon(alarm: alarm)
        }
    }
}
