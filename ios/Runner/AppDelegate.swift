import Flutter
import UIKit
import MediaPlayer
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        return super.application(
            application,
            didFinishLaunchingWithOptions: launchOptions
        )
    }

    func didInitializeImplicitFlutterEngine(
        _ engineBridge: FlutterImplicitEngineBridge
    ) {
        GeneratedPluginRegistrant.register(
            with: engineBridge.pluginRegistry
        )

        NowPlayingChannel.register(
            messenger: engineBridge.applicationRegistrar.messenger()
        )
    }
}

// MARK: - Background keep-alive
//
// iOS suspends apps shortly after they leave the foreground. A silent audio
// loop (mixed with other audio, so Apple Music is NOT interrupted) tells iOS the
// app is "playing audio", which keeps the process, the Dart isolate and the BLE
// connection running while the screen is locked.
// Requires Info.plist UIBackgroundModes: audio (+ bluetooth-central).

final class KeepAlive {
    static let shared = KeepAlive()

    private var player: AVAudioPlayer?
    private var observing = false

    func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }

        if player == nil {
            player = try? AVAudioPlayer(data: KeepAlive.silentWav())
            player?.numberOfLoops = -1
            player?.prepareToPlay()
        }
        player?.play()

        if !observing {
            observing = true
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                self?.start()   // resume after a call / Siri / alarm
            }
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.player = nil
                self?.start()
            }
        }
    }

    // 1 second of silence, 8 kHz, 16-bit mono PCM, built in memory.
    private static func silentWav() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize = sampleRate * 2
        var d = Data()

        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }

        d.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}

// MARK: - Now playing channel (Apple Music app)

final class NowPlayingChannel: NSObject, FlutterStreamHandler {
    static let shared = NowPlayingChannel()
    private var sink: FlutterEventSink?

    static func register(messenger: FlutterBinaryMessenger) {
        let method = FlutterMethodChannel(name: "nowplaying/method", binaryMessenger: messenger)
        method.setMethodCallHandler { call, result in
            switch call.method {
            case "requestAuth":
                MPMediaLibrary.requestAuthorization { status in
                    DispatchQueue.main.async { result(status == .authorized) }
                }
            case "startKeepAlive":
                KeepAlive.shared.start()
                result(true)
            case "current":
                result(shared.current())
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        let events = FlutterEventChannel(name: "nowplaying/events", binaryMessenger: messenger)
        events.setStreamHandler(shared)
    }

    private func current() -> [String: String]? {
        guard let item = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem,
              let title = item.title, let artist = item.artist else { return nil }
        return ["title": title, "artist": artist]
    }

    @objc private func changed() {
        if let c = current() { sink?(c) }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        let player = MPMusicPlayerController.systemMusicPlayer
        player.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed),
            name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player)
        changed()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        NotificationCenter.default.removeObserver(self)
        MPMusicPlayerController.systemMusicPlayer.endGeneratingPlaybackNotifications()
        sink = nil
        return nil
    }
}
