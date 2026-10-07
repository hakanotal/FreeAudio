import Foundation
import Testing
@testable import FreeAudioCore

struct AppSettingTests {
    private func decode(_ json: String) throws -> AppSetting {
        try JSONDecoder().decode(AppSetting.self, from: Data(json.utf8))
    }

    @Test func defaultsAreUntouched() {
        #expect(AppSetting().isDefault)
        #expect(!AppSetting(level: 50).isDefault)
        #expect(!AppSetting(muted: true).isDefault)
        #expect(!AppSetting(level: 150).isDefault)
    }

    @Test func chosenOutputDeviceIsNotDefault() {
        #expect(!AppSetting(outputDeviceUID: "airpods").isDefault)
    }

    @Test func emptyOutputDeviceDecodesAsSystemDefault() throws {
        #expect(try decode(#"{"outputDeviceUID": ""}"#).outputDeviceUID == nil)
        #expect(try decode(#"{"outputDeviceUID": "dell", "outputDeviceName": "DELL"}"#).outputDeviceUID == "dell")
    }

    @Test func gainFollowsTheAppCurve() {
        #expect(AppSetting(level: 50).gain == 0.25)
        #expect(AppSetting(level: 100).gain == 1)
        #expect(AppSetting(level: 200).gain == 2)
    }

    @Test func v1SettingsConvertToTheSameGain() throws {
        #expect(try decode(#"{"volume": 0.5}"#).level == 50)
        #expect(try decode(#"{"volume": 1, "boost": 1.5}"#).level == 150)
        // 0.5 slider with 2x boost was gain 0.5 → about 70.7%.
        #expect(abs(try decode(#"{"volume": 0.5, "boost": 2}"#).level - 70.7) < 0.05)
        // A new level wins over old keys.
        #expect(try decode(#"{"level": 120, "volume": 0.1}"#).level == 120)
    }

    @Test func encodingWritesOnlyCurrentKeys() throws {
        let json = String(decoding: try JSONEncoder().encode(AppSetting(level: 40, name: "Zen")), as: UTF8.self)
        #expect(json.contains("\"level\""))
        #expect(!json.contains("volume"))
        #expect(!json.contains("boost"))
    }

    @Test func missingKeysTakeDefaults() throws {
        let setting = try decode("{}")
        #expect(setting == AppSetting())
    }

    @Test func badValuesAreClamped() throws {
        let setting = try decode(#"{"level": 700, "muted": true}"#)
        #expect(setting.level == 200)
        #expect(setting.muted)
    }

    @Test func wrongTypesDontThrow() throws {
        let setting = try decode(#"{"level": "loud", "muted": 1}"#)
        #expect(setting.level == 100)
    }

    @Test func fileRoundTrips() throws {
        let file = AppSettingsFile(apps: ["com.spotify.client": AppSetting(level: 30, name: "Spotify")])
        let back = try JSONDecoder().decode(AppSettingsFile.self, from: JSONEncoder().encode(file))
        #expect(back == file)
    }

    @Test func fileWithUnknownKeysStillLoads() throws {
        let file = try JSONDecoder().decode(AppSettingsFile.self, from: Data(#"{"future": true, "apps": {"a": {"volume": 0.5}}}"#.utf8))
        #expect(file.apps["a"]?.level == 50)
    }
}
