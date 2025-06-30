//
//  HashTests.swift
//  DownloadManager
//
//  Created by chen on 2025/6/20.
//

import CryptoKit
@testable import DownloadManager
import LoggerProxy
import XCTest

final class HashTests: XCTestCase {
    // MARK: - Test Properties

    private let text = "helloworld"
    private let data = "helloworld".data(using: .ascii)!
    private let tempFile = createUniqueDestinationURL()
    private let largeFile = createUniqueDestinationURL()
    private let crc32 = "f9eb20ad"
    private let md5 = "FC5E038D38A57032085441E7FE7010B0"
    private let sha1 = "6ADFB183A4A2C94A2F92DAB5ADE762A47889A5A1"
    private let sha224 = "B033D770602994EFA135C5248AF300D81567AD5B59CEC4BCCBF15BCC"
    private let sha256 = "936A185CAAA266BB9CBE981E9E05CB78CD732B0B3280EB944412BB6F8F8F07AF"
    private let sha384 = "97982a5b1414b9078103a1c008c4e3526c27b41cdbcf80790560a40f2a9bf2ed4427ab1428789915ed4b3dc07c454bd9"
    private let sha512 = "1594244D52F2D8C12B142BB61F47BC2EAF503D6D9CA8480CAE9FCF112F66E4967DC5E8FA98285E36DB8AF1B8FFA8B84CB15E0FBCF836C3DEB803C13F37659A60"

    private let large_crc32 = "f9eb20ad"
    private let large_md5 = "02A0EC03AFFAE6EB1387CC2B0AA43531"
    private let large_sha1 = "2229F59761CE98C38189B5888ECD649415DE473C"
    private let large_sha224 = "8F15FD9A6EB0AEBD5E4F31C1BE7239B81F9A5E3ED57D4C1C2D67C99E"
    private let large_sha256 = "1724C47F68A32B1617D8EB4530058CC7838BD4C6E664EE4BB7E954EC1A0EAC7A"
    private let large_sha384 = "BE0168547BF1D00733F9C5934BE9500362385420B816755542B50E6483A626088DB4251005D9A87B49FEF93AE83AC1D2"
    private let large_sha512 = "0746A4050D6EA07791563137C6502D65AC3A0262F59BA0893D57157D604F68968C079ECA561EE4F277EE460D7C08D13BE560A096BE5E791752B9A847BE1A21B5"

    override func setUpWithError() throws {
        try data.write(to: tempFile)
        FileManager.default.createFile(atPath: largeFile.path, contents: nil)
        let handler = try FileHandle(forWritingTo: largeFile)

        for _ in 0 ..< 1024 {
            try handler.write(contentsOf: data)
        }
        try handler.close()
    }

    private static func createUniqueDestinationURL() -> URL {
        let uniqueFileName = "test_\(UUID().uuidString).file"
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uniqueFileName)
    }

    func testCRC32() {
        XCTAssertEqual(crc32.lowercased(), CRC32.crc32(data: data).lowercased())
        XCTAssertEqual(crc32.lowercased(), text.dm_crc32().lowercased())
        XCTAssertEqual(crc32.lowercased(), data.dm_crc32().lowercased())
        let fileResult = try! IntegrityChecker.calculateHash(for: tempFile, type: .crc32)
        XCTAssertEqual(crc32.lowercased(), fileResult.lowercased())
    }

    func testMD5() {
        XCTAssertEqual(md5.lowercased(), text.dm_md5().lowercased())
        XCTAssertEqual(md5.lowercased(), data.dm_md5().lowercased())
        var fileResult = try! IntegrityChecker.calculateHash(for: tempFile, type: .md5)
        XCTAssertEqual(md5.lowercased(), fileResult.lowercased())
        fileResult = try! IntegrityChecker.calculateHash(for: largeFile, type: .md5)
        XCTAssertEqual(large_md5.lowercased(), fileResult.lowercased())

    }

    func testsha1() {
        XCTAssertEqual(sha1.lowercased(), text.dm_sha1().lowercased())
        XCTAssertEqual(sha1.lowercased(), data.dm_sha1().lowercased())

        var fileResult = try! IntegrityChecker.calculateHash(for: tempFile, type: .sha1)
        XCTAssertEqual(sha1.lowercased(), fileResult.lowercased())
        fileResult = try! IntegrityChecker.calculateHash(for: largeFile, type: .sha1)
        XCTAssertEqual(large_sha1.lowercased(), fileResult.lowercased())

    }

    func testsha256() {
        XCTAssertEqual(sha256.lowercased(), text.dm_sha256().lowercased())
        XCTAssertEqual(sha256.lowercased(), data.dm_sha256().lowercased())

        var fileResult = try! IntegrityChecker.calculateHash(for: tempFile, type: .sha256)
        XCTAssertEqual(sha256.lowercased(), fileResult.lowercased())
        fileResult = try! IntegrityChecker.calculateHash(for: largeFile, type: .sha256)
        XCTAssertEqual(large_sha256.lowercased(), fileResult.lowercased())

    }

    func testsha384() {
        XCTAssertEqual(sha384.lowercased(), text.dm_sha384().lowercased())
        XCTAssertEqual(sha384.lowercased(), data.dm_sha384().lowercased())

        var fileResult = try! IntegrityChecker.calculateHash(for: tempFile, type: .sha384)
        XCTAssertEqual(sha384.lowercased(), fileResult.lowercased())
        fileResult = try! IntegrityChecker.calculateHash(for: largeFile, type: .sha384)
        XCTAssertEqual(large_sha384.lowercased(), fileResult.lowercased())

    }

    func testsha512() {
        XCTAssertEqual(sha512.lowercased(), text.dm_sha512().lowercased())
        XCTAssertEqual(sha512.lowercased(), data.dm_sha512().lowercased())

        var fileResult = try! IntegrityChecker.calculateHash(for: tempFile, type: .sha512)
        XCTAssertEqual(sha512.lowercased(), fileResult.lowercased())
        fileResult = try! IntegrityChecker.calculateHash(for: largeFile, type: .sha512)
        XCTAssertEqual(large_sha512.lowercased(), fileResult.lowercased())

    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFile)
        try? FileManager.default.removeItem(at: largeFile)
    }
}
