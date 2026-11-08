import Foundation
import MediaPlayer
import UIKit

@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private var currentTrackID: String?
    private var currentArtwork: MPMediaItemArtwork?

    private init() {}

    func update(track: MusicInfo?, elapsed: Double, duration: Double, rate: Double, artwork: MPMediaItemArtwork? = nil) {
        guard let track else {
            clear()
            return
        }

        // The periodic time observer calls update() every 0.5 s without an
        // artwork argument. Keep the last downloaded artwork instead of
        // rebuilding nowPlayingInfo without MPMediaItemPropertyArtwork.
        if currentTrackID != track.id {
            currentTrackID = track.id
            currentArtwork = nil
        }
        if let artwork { currentArtwork = artwork }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.name,
            MPMediaItemPropertyArtist: track.singer,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let album = track.albumName, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let currentArtwork { info[MPMediaItemPropertyArtwork] = currentArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
    }

    func clear() {
        currentTrackID = nil
        currentArtwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
