// ios/Runner/NowPlayingChannel.swift
// Add this file to the Runner target, then register it in AppDelegate (see notes).

import Flutter
import MediaPlayer

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
