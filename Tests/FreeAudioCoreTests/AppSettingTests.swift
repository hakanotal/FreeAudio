import Foundation
import Testing
@testable import FreeAudioCore

struct AppSettingTests {
    private func decode(_ json: String) throws -> AppSetting {
        try JSONDecoder().decode(AppSetting.self, from: Data(json.utf8))
    }

    @Test func defaultsAreUntouched() {
        #expect(AppSetting().isDefault)
        #expect(!AppSetting(volume: 0.5).isDefault)
        #expect(!AppSetting(muted: true).isDefault)
        #expect(!AppSetting(boost: 1.5).isDefault)
    }

    @Test func gainCombinesCurveAndBoost() {
        #expect(AppSetting(volume: 0.5).gain == 0.25)
        #expect(AppSetting(volume: 1, boost: 2).gain == 2)
    }

    @Test func missingKeysTakeDefaults() throws {
        let setting = try decode("{}")
        #expect(setting == AppSetting())
    }

    @Test func badValuesAreClamped() throws {
        let setting = try decode(#"{"volume": 7, "boost": 3.9, "muted": true}"#)
        #expect(setting.volume == 1)
        #expect(setting.boost == 2)
        #expect(setting.muted)
    }

    @Test func wrongTypesDontThrow() throws {
        let setting = try decode(#"{"volume": "loud", "muted": 1}"#)
        #expect(setting.volume == 1)
    }

    @Test func fileRoundTrips() throws {
        let file = AppSettingsFile(apps: ["com.spotify.client": AppSetting(volume: 0.3, name: "Spotify")])
        let back = try JSONDecoder().decode(AppSettingsFile.self, from: JSONEncoder().encode(file))
        #expect(back == file)
    }

    @Test func fileWithUnknownKeysStillLoads() throws {
        let file = try JSONDecoder().decode(AppSettingsFile.self, from: Data(#"{"future": true, "apps": {"a": {"volume": 0.5}}}"#.utf8))
        #expect(file.apps["a"]?.volume == 0.5)
    }
}
