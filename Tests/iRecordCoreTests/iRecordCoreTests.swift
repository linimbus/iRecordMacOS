import XCTest
@testable import iRecordCore

final class iRecordCoreTests: XCTestCase {
    func testVideoFormatParsing() {
        XCTAssertEqual(VideoFormat.parse("mp4"), .mp4H264)
        XCTAssertEqual(VideoFormat.parse("MP4-H264"), .mp4H264)
        XCTAssertEqual(VideoFormat.parse("gif"), .gif)
        XCTAssertEqual(VideoFormat.parse("prores"), .movProRes)
        XCTAssertEqual(VideoFormat.parse("hevc"), .mp4HEVC)
        XCTAssertNil(VideoFormat.parse("mkv"))
    }

    func testSettingsRoundTrip() throws {
        var settings = AppSettings.default
        settings.format = .gif
        settings.fps = 15
        settings.audioSource = .both
        settings.language = .simplifiedChinese
        settings.outputDirectory = "/tmp/irecord-tests"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.format, .gif)
        XCTAssertEqual(decoded.fps, 15)
        XCTAssertEqual(decoded.audioSource, .both)
        XCTAssertEqual(decoded.language, .simplifiedChinese)
        XCTAssertEqual(decoded.outputDirectory, "/tmp/irecord-tests")
    }

    func testSettingsToleratesMissingFields() throws {
        let data = Data("{\"format\":\"gif\",\"fps\":12}".utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.format, .gif)
        XCTAssertEqual(decoded.fps, 12)
        XCTAssertEqual(decoded.quality, .high)
    }

    func testAllLocalizationsCoverEveryKey() {
        for language in AppLanguage.allCases where language != .system {
            for key in L10n.english.keys {
                XCTAssertNotEqual(
                    L10n.t(key, language),
                    key,
                    "Missing \(language.rawValue) translation for \(key)"
                )
            }
        }
    }

    func testHotkeyDisplay() {
        let hotkey = Hotkey(keyCode: 15, modifiers: Hotkey.commandKey | Hotkey.optionKey)
        XCTAssertEqual(hotkey.displayString, "⌥⌘R")
    }

    func testGIFKeepsSilence() {
        XCTAssertFalse(VideoFormat.gif.supportsAudio)
        XCTAssertTrue(VideoFormat.mp4H264.supportsAudio)
        XCTAssertEqual(VideoFormat.gif.recordingExtension, "mp4")
    }
}
