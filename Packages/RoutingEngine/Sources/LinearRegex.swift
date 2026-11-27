// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-27). Not yet built or run on Apple platforms.
import Foundation

/// A small regular-expression engine with guaranteed linear-time matching
/// (Thompson NFA simulation, no backtracking, no captures).
///
/// Why not `NSRegularExpression` / `Regex`: both backtrack, so a hostile or
/// careless pattern in an imported profile could stall routing; and both
/// engines used behind this platform (sing-box and Xray-core) use Go's
/// `regexp` package, whose RE2 syntax has no backreferences or lookaround.
/// This type implements a documented subset of that syntax and rejects
/// everything else at compile time instead of silently mis-matching.
///
/// Supported: literals, `.`, `[...]` / `[^...]` with ranges, `\d \D \w \W \s \S`,
/// `\n \r \t \xHH`, escaped punctuation, `^`, `$`, `( )`, `(?: )`,
/// `(?P<name> )`, `(?<name> )`, `|`, `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}`
/// (lazy variants are accepted; laziness is irrelevant for a yes/no answer),
/// and a leading `(?i)` flag.
///
/// Not supported (compile error): backreferences, lookaround, `\b`/`\B`,
/// POSIX classes, Unicode classes, non-ASCII patterns, inline flags other than
/// a leading `(?i)`.
///
/// Matching is byte-oriented and unanchored (like Go's `MatchString`): the
/// pattern matches if it matches any substring. Internationalised domains
/// must be supplied in punycode.
public struct LinearRegex: Sendable {
    public enum CompileError: Error, Equatable, Sendable, CustomStringConvertible {
        case empty
        case tooLong(limit: Int)
        case nonASCII
        case tooComplex(limit: Int)
        case nestingTooDeep(limit: Int)
        case unsupported(String)
        case syntax(String)

        public var description: String {
            switch self {
            case .empty: return "pattern is empty"
            case let .tooLong(limit): return "pattern is longer than \(limit) bytes"
            case .nonASCII: return "pattern contains non-ASCII bytes"
            case let .tooComplex(limit): return "pattern compiles to more than \(limit) instructions"
            case let .nestingTooDeep(limit): return "groups are nested deeper than \(limit)"
            case let .unsupported(what): return "unsupported construct: \(what)"
            case let .syntax(what): return "syntax error: \(what)"
            }
        }
    }

    public static let maximumPatternLength = 512
    public static let maximumInstructions = 4096
    public static let maximumNesting = 32
    public static let maximumRepeat = 256
    /// Inputs longer than this never match (routing inputs are host names).
    public static let maximumInputLength = 4096

    public let pattern: String

    private let instructions: [Instruction]
    private let sets: [ByteSet]

    /// A byte string that every match contains, for inputs that are already
    /// lower case (host names are lowercased before routing): the longest
    /// one found by a conservative walk of the syntax tree, or empty. With
    /// `(?i)` a letter is reported in lower case. Used by the router to skip
    /// patterns whose literal does not occur in the name.
    let requiredLiteral: [UInt8]

    public init(_ pattern: String) throws {
        let bytes = Array(pattern.utf8)
        guard !bytes.isEmpty else { throw CompileError.empty }
        guard bytes.count <= LinearRegex.maximumPatternLength else {
            throw CompileError.tooLong(limit: LinearRegex.maximumPatternLength)
        }
        if bytes.contains(where: { $0 >= 0x80 }) {
            throw CompileError.nonASCII
        }
        var parser = Parser(bytes: bytes)
        let tree = try parser.parse()
        var compiler = Compiler()
        try compiler.emit(tree)
        compiler.instructions.append(.match)
        guard compiler.instructions.count <= LinearRegex.maximumInstructions else {
            throw CompileError.tooComplex(limit: LinearRegex.maximumInstructions)
        }
        self.pattern = pattern
        self.requiredLiteral = RequiredLiteral.of(tree).best
        self.instructions = compiler.instructions
        self.sets = compiler.sets
    }

    public func matches(_ text: String) -> Bool {
        matches(utf8: Array(text.utf8))
    }

    public func matches(utf8 input: [UInt8]) -> Bool {
        let length = input.count
        guard length <= LinearRegex.maximumInputLength else { return false }
        let size = instructions.count
        var current = ThreadList(size: size)
        var next = ThreadList(size: size)
        var stack: [Int] = []
        stack.reserveCapacity(16)

        var position = 0
        while true {
            // Unanchored search: a fresh thread starts at every position.
            if addThread(0, to: &current, position: position, length: length, stack: &stack) {
                return true
            }
            if position == length { return false }
            let byte = input[position]
            next.clear()
            var matched = false
            for pc in current.dense {
                if case let .byteSet(setIndex) = instructions[pc], sets[setIndex].contains(byte) {
                    if addThread(pc + 1, to: &next, position: position + 1, length: length, stack: &stack) {
                        matched = true
                        break
                    }
                }
            }
            if matched { return true }
            swap(&current, &next)
            position += 1
        }
    }

    /// Adds `start` and everything reachable through epsilon transitions.
    /// Returns `true` when a match instruction is reachable.
    private func addThread(
        _ start: Int,
        to list: inout ThreadList,
        position: Int,
        length: Int,
        stack: inout [Int]
    ) -> Bool {
        stack.removeAll(keepingCapacity: true)
        stack.append(start)
        while let pc = stack.popLast() {
            if list.mark[pc] == list.generation { continue }
            list.mark[pc] = list.generation
            switch instructions[pc] {
            case .match:
                return true
            case .byteSet:
                list.dense.append(pc)
            case let .jump(target):
                stack.append(target)
            case let .split(first, second):
                stack.append(second)
                stack.append(first)
            case .assertStart:
                if position == 0 { stack.append(pc + 1) }
            case .assertEnd:
                if position == length { stack.append(pc + 1) }
            }
        }
        return false
    }
}

extension LinearRegex: Equatable {
    public static func == (lhs: LinearRegex, rhs: LinearRegex) -> Bool {
        lhs.pattern == rhs.pattern
    }
}

// MARK: - Program

private enum Instruction: Sendable {
    case byteSet(Int)
    case split(Int, Int)
    case jump(Int)
    case assertStart
    case assertEnd
    case match
}

private struct ThreadList {
    var dense: [Int]
    var mark: [UInt32]
    var generation: UInt32

    init(size: Int) {
        dense = []
        dense.reserveCapacity(size)
        mark = [UInt32](repeating: 0, count: size)
        generation = 1
    }

    mutating func clear() {
        dense.removeAll(keepingCapacity: true)
        if generation == UInt32.max {
            for index in mark.indices { mark[index] = 0 }
            generation = 1
        } else {
            generation += 1
        }
    }
}

/// A set of byte values (256-bit bitmap).
private struct ByteSet: Sendable, Equatable {
    var w0: UInt64 = 0
    var w1: UInt64 = 0
    var w2: UInt64 = 0
    var w3: UInt64 = 0

    func contains(_ byte: UInt8) -> Bool {
        let bit = UInt64(1) << UInt64(byte & 63)
        switch byte >> 6 {
        case 0: return (w0 & bit) != 0
        case 1: return (w1 & bit) != 0
        case 2: return (w2 & bit) != 0
        default: return (w3 & bit) != 0
        }
    }

    mutating func insert(_ byte: UInt8) {
        let bit = UInt64(1) << UInt64(byte & 63)
        switch byte >> 6 {
        case 0: w0 |= bit
        case 1: w1 |= bit
        case 2: w2 |= bit
        default: w3 |= bit
        }
    }

    mutating func insert(from lower: UInt8, through upper: UInt8) {
        guard lower <= upper else { return }
        var value = Int(lower)
        while value <= Int(upper) {
            insert(UInt8(value))
            value += 1
        }
    }

    mutating func formUnion(_ other: ByteSet) {
        w0 |= other.w0
        w1 |= other.w1
        w2 |= other.w2
        w3 |= other.w3
    }

    func inverted() -> ByteSet {
        ByteSet(w0: ~w0, w1: ~w1, w2: ~w2, w3: ~w3)
    }

    /// Adds the other-case counterpart of every ASCII letter in the set.
    func caseFolded() -> ByteSet {
        var result = self
        var value = 0x41
        while value <= 0x5A {
            let upper = UInt8(value)
            let lower = UInt8(value + 0x20)
            if contains(upper) { result.insert(lower) }
            if contains(lower) { result.insert(upper) }
            value += 1
        }
        return result
    }

    static func single(_ byte: UInt8) -> ByteSet {
        var set = ByteSet()
        set.insert(byte)
        return set
    }

    static var digits: ByteSet {
        var set = ByteSet()
        set.insert(from: 0x30, through: 0x39)
        return set
    }

    static var word: ByteSet {
        var set = ByteSet.digits
        set.insert(from: 0x41, through: 0x5A)
        set.insert(from: 0x61, through: 0x7A)
        set.insert(0x5F)
        return set
    }

    static var space: ByteSet {
        var set = ByteSet()
        set.insert(0x20)
        set.insert(0x09)
        set.insert(0x0A)
        set.insert(0x0B)
        set.insert(0x0C)
        set.insert(0x0D)
        return set
    }

    /// Any byte except line feed.
    static var anyExceptNewline: ByteSet {
        ByteSet.single(0x0A).inverted()
    }
}

// MARK: - Syntax tree

private indirect enum Node {
    case empty
    case set(ByteSet)
    case concat([Node])
    case alternate([Node])
    case star(Node)
    case plus(Node)
    case optional(Node)
    case repetition(Node, minimum: Int, maximum: Int?)
    case assertStart
    case assertEnd
}

// MARK: - Required literal

/// Necessary substrings of a syntax tree. `exact` is set when the node
/// matches exactly one string; `best` is the longest string known to occur
/// in every match of the node.
private struct RequiredLiteral {
    static let maximumLength = 64

    var exact: [UInt8]?
    var best: [UInt8]

    /// The single lower-case byte a set stands for: a one-byte set, or the
    /// two cases of one ASCII letter (input is lower case).
    private static func literalByte(_ set: ByteSet) -> UInt8? {
        var members: [UInt8] = []
        var value = 0
        while value < 256 {
            if set.contains(UInt8(value)) {
                members.append(UInt8(value))
                if members.count > 2 { return nil }
            }
            value += 1
        }
        if members.count == 1 { return members[0] }
        if members.count == 2, members[0] >= 0x41, members[0] <= 0x5A, members[1] == members[0] + 0x20 {
            return members[1]
        }
        return nil
    }

    private static func longer(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        rhs.count > lhs.count ? rhs : lhs
    }

    static func of(_ node: Node) -> RequiredLiteral {
        switch node {
        case .empty, .assertStart, .assertEnd:
            // Zero-width: adjacent literals stay adjacent.
            return RequiredLiteral(exact: [], best: [])
        case let .set(set):
            if let byte = literalByte(set) { return RequiredLiteral(exact: [byte], best: [byte]) }
            return RequiredLiteral(exact: nil, best: [])
        case let .concat(items):
            var run: [UInt8]? = []
            var best: [UInt8] = []
            var whole: [UInt8]? = []
            for item in items {
                let part = of(item)
                if let exact = part.exact, var current = run, current.count + exact.count <= maximumLength {
                    current.append(contentsOf: exact)
                    run = current
                    whole?.append(contentsOf: exact)
                } else {
                    best = longer(best, run ?? [])
                    best = longer(best, part.best)
                    // A run restarts after a non-exact part, with this part's
                    // exact text if it has one.
                    run = part.exact.flatMap { $0.count <= maximumLength ? $0 : nil } ?? []
                    whole = nil
                }
            }
            best = longer(best, run ?? [])
            return RequiredLiteral(exact: whole, best: best)
        case let .alternate(branches):
            let parts = branches.map(of)
            if let first = parts.first?.exact, parts.allSatisfy({ $0.exact == first }) {
                return RequiredLiteral(exact: first, best: first)
            }
            return RequiredLiteral(exact: nil, best: [])
        case .star, .optional:
            return RequiredLiteral(exact: nil, best: [])
        case let .plus(child):
            let part = of(child)
            return RequiredLiteral(exact: nil, best: part.exact ?? part.best)
        case let .repetition(child, minimum, maximum):
            guard minimum >= 1 else { return RequiredLiteral(exact: nil, best: []) }
            let part = of(child)
            if let exact = part.exact, maximum == minimum, exact.count * minimum <= maximumLength {
                let repeated = Array([[UInt8]](repeating: exact, count: minimum).joined())
                return RequiredLiteral(exact: repeated, best: repeated)
            }
            return RequiredLiteral(exact: nil, best: part.exact ?? part.best)
        }
    }
}

// MARK: - Parser

private struct Parser {
    let bytes: [UInt8]
    var index = 0
    var depth = 0
    var caseInsensitive = false

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private var atEnd: Bool { index >= bytes.count }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func peek(offset: Int) -> UInt8? {
        let target = index + offset
        return target < bytes.count ? bytes[target] : nil
    }

    mutating func parse() throws -> Node {
        // Leading "(?i)".
        if bytes.count >= 4, bytes[0] == 0x28, bytes[1] == 0x3F, bytes[2] == 0x69, bytes[3] == 0x29 {
            caseInsensitive = true
            index = 4
        }
        let node = try parseAlternation()
        if !atEnd {
            // Only an unbalanced ')' can stop the top-level alternation early.
            throw LinearRegex.CompileError.syntax("unbalanced ')'")
        }
        return node
    }

    private mutating func parseAlternation() throws -> Node {
        var branches: [Node] = [try parseConcatenation()]
        while peek() == 0x7C { // '|'
            index += 1
            branches.append(try parseConcatenation())
        }
        return branches.count == 1 ? branches[0] : .alternate(branches)
    }

    private mutating func parseConcatenation() throws -> Node {
        var items: [Node] = []
        while let byte = peek(), byte != 0x7C, byte != 0x29 {
            items.append(try parseRepetition())
        }
        if items.isEmpty { return .empty }
        return items.count == 1 ? items[0] : .concat(items)
    }

    private mutating func parseRepetition() throws -> Node {
        var node = try parseAtom()
        while let byte = peek() {
            var applied = true
            switch byte {
            case 0x2A: // '*'
                index += 1
                node = .star(node)
            case 0x2B: // '+'
                index += 1
                node = .plus(node)
            case 0x3F: // '?'
                index += 1
                node = .optional(node)
            case 0x7B: // '{'
                if let bounds = try parseBounds() {
                    node = .repetition(node, minimum: bounds.minimum, maximum: bounds.maximum)
                } else {
                    applied = false
                }
            default:
                applied = false
            }
            if !applied { break }
            // Lazy marker: accepted and ignored.
            if peek() == 0x3F { index += 1 }
        }
        return node
    }

    /// Parses `{n}`, `{n,}`, `{n,m}`. Returns `nil` (consuming nothing) when
    /// the brace does not start a valid quantifier, in which case `{` is a
    /// literal, as in RE2.
    private mutating func parseBounds() throws -> (minimum: Int, maximum: Int?)? {
        var cursor = index + 1
        guard let minimum = Parser.readNumber(bytes, &cursor) else { return nil }
        var maximum: Int? = minimum
        if cursor < bytes.count, bytes[cursor] == 0x2C { // ','
            cursor += 1
            if cursor < bytes.count, bytes[cursor] == 0x7D {
                maximum = nil
            } else {
                guard let upper = Parser.readNumber(bytes, &cursor) else { return nil }
                maximum = upper
            }
        }
        guard cursor < bytes.count, bytes[cursor] == 0x7D else { return nil }
        cursor += 1
        if let upper = maximum, upper < minimum {
            throw LinearRegex.CompileError.syntax("repetition bounds are reversed")
        }
        let largest = maximum ?? minimum
        guard largest <= LinearRegex.maximumRepeat else {
            throw LinearRegex.CompileError.tooComplex(limit: LinearRegex.maximumInstructions)
        }
        index = cursor
        return (minimum, maximum)
    }

    private static func readNumber(_ bytes: [UInt8], _ cursor: inout Int) -> Int? {
        var value = 0
        var digits = 0
        while cursor < bytes.count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 {
            value = value * 10 + Int(bytes[cursor] - 0x30)
            digits += 1
            cursor += 1
            if digits > 4 { return nil }
        }
        return digits == 0 ? nil : value
    }

    private mutating func parseAtom() throws -> Node {
        guard let byte = peek() else {
            throw LinearRegex.CompileError.syntax("unexpected end of pattern")
        }
        switch byte {
        case 0x28: // '('
            return try parseGroup()
        case 0x5B: // '['
            return .set(fold(try parseClass()))
        case 0x2E: // '.'
            index += 1
            return .set(ByteSet.anyExceptNewline)
        case 0x5E: // '^'
            index += 1
            return .assertStart
        case 0x24: // '$'
            index += 1
            return .assertEnd
        case 0x5C: // '\'
            index += 1
            return .set(fold(try parseEscape(insideClass: false)))
        case 0x2A, 0x2B, 0x3F: // quantifier with nothing to repeat
            throw LinearRegex.CompileError.syntax("quantifier has nothing to repeat")
        default:
            index += 1
            return .set(fold(ByteSet.single(byte)))
        }
    }

    private func fold(_ set: ByteSet) -> ByteSet {
        caseInsensitive ? set.caseFolded() : set
    }

    private mutating func parseGroup() throws -> Node {
        // Current byte is '('.
        index += 1
        depth += 1
        guard depth <= LinearRegex.maximumNesting else {
            throw LinearRegex.CompileError.nestingTooDeep(limit: LinearRegex.maximumNesting)
        }
        if peek() == 0x3F { // '?'
            let second = peek(offset: 1)
            let third = peek(offset: 2)
            if second == 0x3A { // (?:
                index += 2
            } else if second == 0x50, third == 0x3C { // (?P<name>
                index += 3
                try skipGroupName()
            } else if second == 0x3C, third != 0x3D, third != 0x21 { // (?<name>
                index += 2
                try skipGroupName()
            } else {
                throw LinearRegex.CompileError.unsupported("group flags or lookaround '(?...'")
            }
        }
        let inner = try parseAlternation()
        guard peek() == 0x29 else {
            throw LinearRegex.CompileError.syntax("missing ')'")
        }
        index += 1
        depth -= 1
        return inner
    }

    private mutating func skipGroupName() throws {
        var length = 0
        while let byte = peek(), byte != 0x3E {
            let isWord = ByteSet.word.contains(byte)
            guard isWord else {
                throw LinearRegex.CompileError.syntax("invalid group name")
            }
            index += 1
            length += 1
        }
        guard length > 0, peek() == 0x3E else {
            throw LinearRegex.CompileError.syntax("invalid group name")
        }
        index += 1
    }

    /// Parses the escape after a consumed backslash and returns its byte set.
    private mutating func parseEscape(insideClass: Bool) throws -> ByteSet {
        guard let byte = peek() else {
            throw LinearRegex.CompileError.syntax("trailing backslash")
        }
        index += 1
        switch byte {
        case 0x64: return ByteSet.digits                 // \d
        case 0x44: return ByteSet.digits.inverted()      // \D
        case 0x77: return ByteSet.word                   // \w
        case 0x57: return ByteSet.word.inverted()        // \W
        case 0x73: return ByteSet.space                  // \s
        case 0x53: return ByteSet.space.inverted()       // \S
        case 0x6E: return ByteSet.single(0x0A)           // \n
        case 0x72: return ByteSet.single(0x0D)           // \r
        case 0x74: return ByteSet.single(0x09)           // \t
        case 0x78:                                       // \xHH
            guard let highByte = peek(), let lowByte = peek(offset: 1),
                  let high = Parser.hexDigit(highByte), let low = Parser.hexDigit(lowByte) else {
                throw LinearRegex.CompileError.syntax("\\x needs two hex digits")
            }
            index += 2
            let value = high * 16 + low
            guard value < 0x80 else { throw LinearRegex.CompileError.nonASCII }
            return ByteSet.single(UInt8(value))
        default:
            let isAlphanumeric = (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
            if isAlphanumeric {
                // Backreferences, \b, \B, \A, \z, \p{..} and friends.
                let scalar = String(decoding: [byte], as: UTF8.self)
                throw LinearRegex.CompileError.unsupported("escape '\\\(scalar)'")
            }
            return ByteSet.single(byte)
        }
    }

    private static func hexDigit(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)
        case 0x61...0x66: return Int(byte - 0x61 + 10)
        case 0x41...0x46: return Int(byte - 0x41 + 10)
        default: return nil
        }
    }

    private mutating func parseClass() throws -> ByteSet {
        // Current byte is '['.
        index += 1
        var negated = false
        if peek() == 0x5E {
            negated = true
            index += 1
        }
        var set = ByteSet()
        var first = true
        while true {
            guard let byte = peek() else {
                throw LinearRegex.CompileError.syntax("missing ']'")
            }
            if byte == 0x5D && !first { // ']'
                index += 1
                break
            }
            first = false
            if byte == 0x5B && peek(offset: 1) == 0x3A { // "[:"
                throw LinearRegex.CompileError.unsupported("POSIX character class")
            }

            // Lower bound of a possible range (or a multi-byte class escape).
            let lowerSet: ByteSet
            let lowerByte: UInt8?
            if byte == 0x5C {
                index += 1
                lowerSet = try parseEscape(insideClass: true)
                lowerByte = Parser.singleMember(of: lowerSet)
            } else {
                index += 1
                lowerSet = ByteSet.single(byte)
                lowerByte = byte
            }

            // Range "a-z"; a '-' right before ']' is a literal.
            if peek() == 0x2D, let after = peek(offset: 1), after != 0x5D {
                guard let lower = lowerByte else {
                    throw LinearRegex.CompileError.syntax("class escape cannot start a range")
                }
                index += 1 // '-'
                let upperByte: UInt8?
                if after == 0x5C {
                    index += 1
                    let upperSet = try parseEscape(insideClass: true)
                    upperByte = Parser.singleMember(of: upperSet)
                } else {
                    index += 1
                    upperByte = after
                }
                guard let upper = upperByte, lower <= upper else {
                    throw LinearRegex.CompileError.syntax("invalid character range")
                }
                set.insert(from: lower, through: upper)
            } else {
                set.formUnion(lowerSet)
            }
        }
        if negated {
            return fold(set).inverted()
        }
        return set
    }

    /// Returns the only member of a one-element set, or `nil`.
    private static func singleMember(of set: ByteSet) -> UInt8? {
        var found: UInt8?
        var value = 0
        while value < 256 {
            let byte = UInt8(value)
            if set.contains(byte) {
                if found != nil { return nil }
                found = byte
            }
            value += 1
        }
        return found
    }
}

// MARK: - Compiler

private struct Compiler {
    var instructions: [Instruction] = []
    var sets: [ByteSet] = []

    private func checkSize() throws {
        guard instructions.count <= LinearRegex.maximumInstructions else {
            throw LinearRegex.CompileError.tooComplex(limit: LinearRegex.maximumInstructions)
        }
    }

    mutating func emit(_ node: Node) throws {
        try checkSize()
        switch node {
        case .empty:
            break
        case let .set(set):
            sets.append(set)
            instructions.append(.byteSet(sets.count - 1))
        case let .concat(items):
            for item in items {
                try emit(item)
            }
        case let .alternate(branches):
            // split L1, next; L1: branch; jump end; next: ...
            var jumpsToEnd: [Int] = []
            for (position, branch) in branches.enumerated() {
                if position < branches.count - 1 {
                    let splitIndex = instructions.count
                    instructions.append(.split(splitIndex + 1, 0))
                    try emit(branch)
                    jumpsToEnd.append(instructions.count)
                    instructions.append(.jump(0))
                    instructions[splitIndex] = .split(splitIndex + 1, instructions.count)
                } else {
                    try emit(branch)
                }
            }
            let end = instructions.count
            for jumpIndex in jumpsToEnd {
                instructions[jumpIndex] = .jump(end)
            }
        case let .star(inner):
            let splitIndex = instructions.count
            instructions.append(.split(splitIndex + 1, 0))
            try emit(inner)
            instructions.append(.jump(splitIndex))
            instructions[splitIndex] = .split(splitIndex + 1, instructions.count)
        case let .plus(inner):
            let start = instructions.count
            try emit(inner)
            let splitIndex = instructions.count
            instructions.append(.split(start, splitIndex + 1))
        case let .optional(inner):
            let splitIndex = instructions.count
            instructions.append(.split(splitIndex + 1, 0))
            try emit(inner)
            instructions[splitIndex] = .split(splitIndex + 1, instructions.count)
        case let .repetition(inner, minimum, maximum):
            var copies = 0
            while copies < minimum {
                try emit(inner)
                copies += 1
            }
            if let maximum = maximum {
                var optionalCopies = maximum - minimum
                while optionalCopies > 0 {
                    try emit(.optional(inner))
                    optionalCopies -= 1
                }
            } else {
                try emit(.star(inner))
            }
        case .assertStart:
            instructions.append(.assertStart)
        case .assertEnd:
            instructions.append(.assertEnd)
        }
        try checkSize()
    }
}
