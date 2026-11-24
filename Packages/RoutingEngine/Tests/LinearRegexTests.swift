// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation
import XCTest
@testable import RoutingEngine

final class LinearRegexTests: XCTestCase {
    private func check(
        _ pattern: String,
        matches: [String] = [],
        rejects: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let regex: LinearRegex
        do {
            regex = try LinearRegex(pattern)
        } catch {
            XCTFail("pattern '\(pattern)' must compile, got \(error)", file: file, line: line)
            return
        }
        for text in matches {
            XCTAssertTrue(regex.matches(text), "'\(pattern)' must match '\(text)'", file: file, line: line)
        }
        for text in rejects {
            XCTAssertFalse(regex.matches(text), "'\(pattern)' must not match '\(text)'", file: file, line: line)
        }
    }

    private func checkFails(
        _ pattern: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ expectation: (LinearRegex.CompileError) -> Bool
    ) {
        do {
            _ = try LinearRegex(pattern)
            XCTFail("pattern '\(pattern)' must not compile", file: file, line: line)
        } catch let error as LinearRegex.CompileError {
            XCTAssertTrue(expectation(error), "unexpected error \(error) for '\(pattern)'", file: file, line: line)
        } catch {
            XCTFail("unexpected error type \(error)", file: file, line: line)
        }
    }

    func testLiteralsAreUnanchored() {
        check("abc", matches: ["abc", "xxabcxx", "abcabc"], rejects: ["ab", "acb", ""])
    }

    func testAnchors() {
        check("^abc$", matches: ["abc"], rejects: ["abcd", "xabc", ""])
        check("^abc", matches: ["abc", "abcd"], rejects: ["xabc"])
        check("abc$", matches: ["abc", "xabc"], rejects: ["abcd"])
        check("^$", matches: [""], rejects: ["a"])
    }

    func testDotAndEscapedDot() {
        check("a.c", matches: ["abc", "a-c", "xa.cx"], rejects: ["ac", "a\nc"])
        check("\\.example\\.com$", matches: ["www.example.com", "a.b.example.com"],
              rejects: ["wwwxexample.com", "www.example.com.evil", "example.com"])
    }

    func testQuantifiers() {
        check("^ads?\\.", matches: ["ad.example.com", "ads.example.com"],
              rejects: ["adsx.example.com", "bad.example.com", "adss.example.com"])
        check("^a*$", matches: ["", "a", "aaaa"], rejects: ["b", "aab"])
        check("^a+$", matches: ["a", "aaaa"], rejects: ["", "ab"])
        check("^a{3}$", matches: ["aaa"], rejects: ["aa", "aaaa"])
        check("^a{2,}$", matches: ["aa", "aaaaa"], rejects: ["a", ""])
        check("^a{1,3}$", matches: ["a", "aa", "aaa"], rejects: ["", "aaaa"])
        check("^a{0}$", matches: [""], rejects: ["a"])
        check("^a+?b*?$", matches: ["a", "aab"], rejects: ["b"])
    }

    func testBraceWithoutBoundsIsLiteral() {
        check("^a{$", matches: ["a{"], rejects: ["a"])
        check("^a{x}$", matches: ["a{x}"], rejects: ["a"])
    }

    func testAlternationAndGroups() {
        check("^(www|api)\\.example\\.(com|org)$",
              matches: ["www.example.com", "api.example.org"],
              rejects: ["cdn.example.com", "www.example.net", "wwwapi.example.com"])
        check("^(?:ab)+c$", matches: ["abc", "ababc"], rejects: ["c", "abac"])
        check("^(?P<name>ab)c$", matches: ["abc"], rejects: ["ab"])
        check("^(?<name>ab)c$", matches: ["abc"], rejects: ["ab"])
        check("^(a|b|)c$", matches: ["ac", "bc", "c"], rejects: ["abc"])
        check("a|", matches: ["zzz", "", "a"])
        check("^((a)(b))((c))$", matches: ["abc"], rejects: ["ab"])
    }

    func testCharacterClasses() {
        check("^[a-c]+\\d{2,3}$", matches: ["abc12", "a123"], rejects: ["abc1", "abc1234", "x99", "d12"])
        check("^[^.]+\\.cn$", matches: ["example.cn"], rejects: ["a.b.cn", ".cn"])
        check("^[\\w-]+$", matches: ["a-b_c9"], rejects: ["a.b", ""])
        check("^[a\\-z]$", matches: ["a", "-", "z"], rejects: ["b"])
        check("^[]a]$", matches: ["]", "a"], rejects: ["b"])
        check("^[a-]$", matches: ["a", "-"], rejects: ["b"])
        check("^[\\d.]+$", matches: ["10.0.0.1"], rejects: ["10.0.0.x"])
        check("^[^\\d]+$", matches: ["abc"], rejects: ["ab1"])
        check("^[.*+?]$", matches: [".", "*", "+", "?"], rejects: ["a"])
    }

    func testEscapes() {
        check("^\\d+$", matches: ["0123456789"], rejects: ["12a", ""])
        check("^\\D+$", matches: ["abc"], rejects: ["a1"])
        check("^\\w+$", matches: ["aZ_09"], rejects: ["a-b"])
        check("^\\W$", matches: ["-", "."], rejects: ["a", "_"])
        check("^a\\sb$", matches: ["a b", "a\tb"], rejects: ["ab"])
        check("^\\S+$", matches: ["abc"], rejects: ["a b"])
        check("^\\x41\\x2e$", matches: ["A."], rejects: ["a."])
        check("^a\\+b\\*\\(\\)\\[\\]\\{\\}\\|\\^\\$\\\\$", matches: ["a+b*()[]{}|^$\\"])
    }

    func testCaseSensitivity() {
        check("EXAMPLE", matches: ["EXAMPLE"], rejects: ["example"])
        check("(?i)^EXAMPLE\\.com$", matches: ["example.com", "ExAmPlE.COM", "EXAMPLE.COM"], rejects: ["example.org"])
        check("(?i)^[a-c]+$", matches: ["abc", "ABC", "aBc"], rejects: ["abd"])
        check("(?i)^[^a]$", matches: ["b", "B"], rejects: ["a", "A"])
    }

    func testPathologicalPatternsStayLinear() {
        // Classic catastrophic-backtracking shapes: must answer immediately.
        let longRun = String(repeating: "a", count: 2000) + "!"
        check("(a*)*b", rejects: [longRun])
        check("^(a+)+$", rejects: [longRun])
        check("(a|aa)+$", rejects: [longRun])
        check("^(a*)*$", matches: [String(repeating: "a", count: 2000)])
        check("(x+x+)+y", rejects: [String(repeating: "x", count: 1500)])
    }

    func testInputLengthBound() throws {
        let regex = try LinearRegex("a")
        let tooLong = String(repeating: "a", count: LinearRegex.maximumInputLength + 1)
        XCTAssertFalse(regex.matches(tooLong))
        XCTAssertTrue(regex.matches(String(repeating: "a", count: LinearRegex.maximumInputLength)))
    }

    func testSyntaxErrors() {
        let isSyntax: (LinearRegex.CompileError) -> Bool = { error in
            if case .syntax = error { return true }
            return false
        }
        checkFails("(", isSyntax)
        checkFails(")", isSyntax)
        checkFails("a)", isSyntax)
        checkFails("(a", isSyntax)
        checkFails("[a", isSyntax)
        checkFails("[", isSyntax)
        checkFails("*a", isSyntax)
        checkFails("+", isSyntax)
        checkFails("a|*", isSyntax)
        checkFails("\\", isSyntax)
        checkFails("a{3,2}", isSyntax)
        checkFails("[z-a]", isSyntax)
        checkFails("\\x4", isSyntax)
        checkFails("(?P<>a)", isSyntax)
    }

    func testUnsupportedConstructsAreRejectedNotMisread() {
        let isUnsupported: (LinearRegex.CompileError) -> Bool = { error in
            if case .unsupported = error { return true }
            return false
        }
        checkFails("(a)\\1", isUnsupported)
        checkFails("(?=a)b", isUnsupported)
        checkFails("(?!a)b", isUnsupported)
        checkFails("(?<=a)b", isUnsupported)
        checkFails("(?<!a)b", isUnsupported)
        checkFails("\\bword", isUnsupported)
        checkFails("\\pL", isUnsupported)
        checkFails("[[:alpha:]]", isUnsupported)
        checkFails("a(?i)b", isUnsupported)
        checkFails("(?s)a", isUnsupported)
    }

    func testLimits() {
        checkFails("") { $0 == .empty }
        checkFails("é") { $0 == .nonASCII }
        checkFails("\\xff") { $0 == .nonASCII }
        checkFails(String(repeating: "a", count: LinearRegex.maximumPatternLength + 1)) { error in
            error == .tooLong(limit: LinearRegex.maximumPatternLength)
        }
        let isTooComplex: (LinearRegex.CompileError) -> Bool = { error in
            if case .tooComplex = error { return true }
            return false
        }
        checkFails("(a{200}){200}", isTooComplex)
        checkFails("a{300}", isTooComplex)
        checkFails("((((a{10}){10}){10}){10}){10}", isTooComplex)
        checkFails(String(repeating: "(", count: 40) + "a" + String(repeating: ")", count: 40)) { error in
            error == .nestingTooDeep(limit: LinearRegex.maximumNesting)
        }
        XCTAssertNoThrow(try LinearRegex(String(repeating: "a", count: LinearRegex.maximumPatternLength)))
        XCTAssertNoThrow(try LinearRegex("a{256}"))
    }

    func testEquatableByPattern() throws {
        XCTAssertEqual(try LinearRegex("a+"), try LinearRegex("a+"))
        XCTAssertNotEqual(try LinearRegex("a+"), try LinearRegex("a*"))
    }
}
