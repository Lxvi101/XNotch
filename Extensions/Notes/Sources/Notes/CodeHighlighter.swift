import AppKit

/// Syntax colours for fenced code: one pass over the block with a small
/// scanner, so strings and comments that span lines come out right and a
/// keystroke costs a read of the block, not a regex per rule.
enum CodeHighlighter {
    enum Kind {
        case keyword, string, number, comment, type, function, property, constant, attribute, tag
    }

    struct Token {
        let range: NSRange
        let kind: Kind
    }

    /// A warm night palette, at home on the dark card beside Mote's orange.
    static func color(for kind: Kind) -> NSColor {
        switch kind {
        case .keyword: NSColor(red: 1, green: 0.56, blue: 0.64, alpha: 1)
        case .string: NSColor(red: 0.96, green: 0.79, blue: 0.48, alpha: 1)
        case .number, .constant: NSColor(red: 0.77, green: 0.66, blue: 1, alpha: 1)
        case .comment: NSColor(white: 1, alpha: 0.36)
        case .type: NSColor(red: 0.5, green: 0.85, blue: 0.91, alpha: 1)
        case .function: NSColor(red: 0.56, green: 0.73, blue: 1, alpha: 1)
        case .property: NSColor(red: 0.74, green: 0.83, blue: 0.98, alpha: 1)
        case .attribute: NSColor(red: 1, green: 0.69, blue: 0.48, alpha: 1)
        case .tag: NSColor(red: 1, green: 0.56, blue: 0.64, alpha: 1)
        }
    }

    /// Code that isn't coloured: a soft white, so the colours read as meaning.
    static let plain = NSColor(white: 1, alpha: 0.86)

    // MARK: Languages

    struct Language {
        var keywords: Set<String> = []
        var constants: Set<String> = []
        var lineComments: [String] = ["//"]
        var blockComment: (open: String, close: String)? = ("/*", "*/")
        var quotes: Set<UInt16> = [0x22, 0x27]
        /// Quotes whose strings may run over lines, like JavaScript's backticks.
        var multilineQuotes: Set<UInt16> = []
        var tripleQuotes = false
        var caseInsensitive = false
        /// `$name` and `@name` as variables, for shells and PHP; else `@` is an attribute.
        var sigilVariables = false
        var markup = false
    }

    private static func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }

    private static let cFamilyConstants = words("true false null nullptr NULL nil")

    private static let javascript = Language(
        keywords: words("""
            const let var function return if else for while do switch case break continue new class extends import from \
            export default async await try catch finally throw typeof instanceof in of yield delete void interface type \
            enum implements public private protected readonly static get set as declare namespace abstract keyof satisfies
            """),
        constants: words("true false null undefined this super NaN Infinity"),
        multilineQuotes: [0x60])

    private static let swift = Language(
        keywords: words("""
            let var func return if else guard for in while repeat switch case default break continue fallthrough struct \
            class enum protocol extension import init deinit subscript static private fileprivate public internal open \
            final override mutating nonmutating throws rethrows throw try catch do defer where as is async await actor some \
            any inout typealias associatedtype weak unowned lazy get set willSet didSet operator convenience required \
            indirect nonisolated isolated consume borrowing consuming macro
            """),
        constants: words("true false nil self Self super"),
        tripleQuotes: true)

    private static let python = Language(
        keywords: words("""
            def class return if elif else for while in not and or is import from as try except finally raise with lambda \
            yield pass break continue global nonlocal async await assert del match case print
            """),
        constants: words("True False None self cls"),
        lineComments: ["#"], blockComment: nil, tripleQuotes: true)

    private static let rust = Language(
        keywords: words("""
            fn let mut const static if else match for while loop in return break continue struct enum impl trait type \
            where pub crate mod use as ref move async await dyn unsafe extern super
            """),
        constants: words("true false self Self None Some Ok Err"))

    private static let go = Language(
        keywords: words("""
            func var const type struct interface map chan package import return if else for range switch case default \
            break continue go defer select fallthrough goto
            """),
        constants: words("true false nil iota"), multilineQuotes: [0x60])

    private static let cFamily = Language(
        keywords: words("""
            int long short char float double bool boolean void unsigned signed const static extern struct union enum \
            typedef sizeof return if else for while do switch case default break continue goto class public private \
            protected virtual override new delete this namespace using template typename auto volatile inline friend \
            operator try catch throw final abstract interface implements extends import package instanceof synchronized \
            throws var val fun object when is in out suspend data sealed companion lateinit string var async await \
            readonly ref base internal sealed record struct get set init yield
            """),
        constants: cFamilyConstants.union(words("this super")))

    private static let ruby = Language(
        keywords: words("""
            def class module end if elsif else unless case when while until for in do return yield begin rescue ensure \
            raise require require_relative include extend attr_accessor attr_reader attr_writer then and or not alias
            """),
        constants: words("true false nil self"), lineComments: ["#"], blockComment: nil)

    private static let php = Language(
        keywords: words("""
            function return if else elseif foreach for while do switch case break continue class public private \
            protected static new echo use namespace extends implements interface trait try catch finally throw fn match
            """),
        constants: words("true false null"), lineComments: ["//", "#"], sigilVariables: true)

    private static let shell = Language(
        keywords: words("""
            if then else elif fi for in do done while until case esac function return export local readonly echo cd \
            source exit set unset alias sudo
            """),
        constants: words("true false"), lineComments: ["#"], blockComment: nil, sigilVariables: true)

    private static let sql = Language(
        keywords: words("""
            select from where and or not insert into values update set delete create table alter drop index join left \
            right inner outer on group by order having limit offset as distinct union all primary key foreign references \
            default constraint unique view case when then else end in is like between exists returning with asc desc
            """),
        constants: words("null true false"), lineComments: ["--"], caseInsensitive: true)

    private static let json = Language(constants: words("true false null"), lineComments: [], blockComment: nil, quotes: [0x22])

    private static let css = Language(
        keywords: words("important media import from to keyframes supports"), lineComments: [], quotes: [0x22, 0x27])

    private static let yaml = Language(constants: words("true false null yes no on off"), lineComments: ["#"], blockComment: nil)

    private static let markup = Language(lineComments: [], blockComment: ("<!--", "-->"), markup: true)

    private static let generic = Language(lineComments: ["//", "#"], multilineQuotes: [0x60])

    static func language(named name: String) -> Language {
        switch name.lowercased() {
        case "js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs", "node": javascript
        case "swift": swift
        case "py", "python", "python3": python
        case "rs", "rust": rust
        case "go", "golang": go
        case "c", "h", "cpp", "c++", "cc", "hpp", "objc", "objective-c", "java", "kotlin", "kt", "cs", "csharp", "c#",
             "dart", "scala", "groovy": cFamily
        case "rb", "ruby": ruby
        case "php": php
        case "sh", "bash", "zsh", "shell", "fish", "console", "terminal": shell
        case "sql", "postgres", "postgresql", "mysql", "sqlite": sql
        case "json", "jsonc", "json5": json
        case "css", "scss", "sass", "less": css
        case "yaml", "yml", "toml", "ini": yaml
        case "html", "xml", "svg", "plist", "vue", "svelte": markup
        default: generic
        }
    }

    // MARK: Scanning

    /// Tokens in `range` of `text`.
    static func tokens(in text: NSString, range: NSRange, language: Language) -> [Token] {
        var tokens: [Token] = []
        let end = NSMaxRange(range)
        var i = range.location
        var previousSignificant: UInt16 = 0
        func char(_ index: Int) -> UInt16 { index < end ? text.character(at: index) : 0 }
        func starts(_ marker: String, at index: Int) -> Bool {
            let length = (marker as NSString).length
            guard index + length <= end else { return false }
            return text.substring(with: NSRange(location: index, length: length)) == marker
        }
        func isIdentifierStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127 }
        func isIdentifier(_ c: UInt16) -> Bool { isIdentifierStart(c) || (c >= 48 && c <= 57) }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func add(_ start: Int, _ stop: Int, _ kind: Kind) {
            if stop > start { tokens.append(Token(range: NSRange(location: start, length: stop - start), kind: kind)) }
        }

        while i < end {
            let c = char(i)
            // Comments.
            if let block = language.blockComment, starts(block.open, at: i) {
                let close = text.range(of: block.close, range: NSRange(location: i + (block.open as NSString).length,
                                                                        length: max(0, end - i - (block.open as NSString).length)))
                let stop = close.location == NSNotFound ? end : NSMaxRange(close)
                add(i, stop, .comment)
                i = stop
                continue
            }
            if let marker = language.lineComments.first(where: { starts($0, at: i) }),
               // "#" in a URL or a colour isn't a comment.
               marker != "#" || previousSignificant == 0 || [0x20, 0x09, 0x0A].contains(char(i - 1)) || i == range.location {
                var stop = i
                while stop < end, char(stop) != 0x0A { stop += 1 }
                add(i, stop, .comment)
                i = stop
                continue
            }
            // Strings.
            if language.quotes.contains(c) || language.multilineQuotes.contains(c) {
                let triple = language.tripleQuotes && char(i + 1) == c && char(i + 2) == c
                let multiline = triple || language.multilineQuotes.contains(c)
                var stop = i + (triple ? 3 : 1)
                while stop < end {
                    let d = char(stop)
                    if d == 0x5C { stop += 2; continue } // escape
                    if d == 0x0A, !multiline { break }
                    if d == c {
                        if !triple { stop += 1; break }
                        if char(stop + 1) == c && char(stop + 2) == c { stop += 3; break }
                    }
                    stop += 1
                }
                stop = min(stop, end)
                // A quoted key: "name": in JSON and YAML.
                var next = stop
                while next < end, char(next) == 0x20 || char(next) == 0x09 { next += 1 }
                add(i, stop, language.keywords.isEmpty && !language.markup && char(next) == 0x3A ? .property : .string)
                i = stop
                previousSignificant = c
                continue
            }
            // Markup tags: <name and </name.
            if language.markup, c == 0x3C, isIdentifierStart(char(i + 1)) || (char(i + 1) == 0x2F && isIdentifierStart(char(i + 2))) {
                var stop = i + 1
                if char(stop) == 0x2F { stop += 1 }
                let nameStart = stop
                while stop < end, isIdentifier(char(stop)) || char(stop) == 0x2D || char(stop) == 0x3A { stop += 1 }
                add(nameStart, stop, .tag)
                i = stop
                continue
            }
            // Numbers, not the digits inside a name.
            if isDigit(c) || (c == 0x2E && isDigit(char(i + 1)) && !isIdentifier(previousSignificant)) {
                if i > range.location, isIdentifier(char(i - 1)) { i += 1; continue }
                var stop = i + 1
                while stop < end, isIdentifier(char(stop)) || (char(stop) == 0x2E && isDigit(char(stop + 1))) { stop += 1 }
                add(i, stop, .number)
                i = stop
                previousSignificant = 0x30
                continue
            }
            // Variables and attributes with a sigil.
            if (c == 0x24 || c == 0x40) && isIdentifierStart(char(i + 1)) {
                var stop = i + 1
                while stop < end, isIdentifier(char(stop)) { stop += 1 }
                add(i, stop, language.sigilVariables || c == 0x24 ? .property : .attribute)
                i = stop
                previousSignificant = 0x61
                continue
            }
            // Words.
            if isIdentifierStart(c) {
                var stop = i + 1
                while stop < end, isIdentifier(char(stop)) || (language.markup && char(stop) == 0x2D) { stop += 1 }
                let word = text.substring(with: NSRange(location: i, length: stop - i))
                let key = language.caseInsensitive ? word.lowercased() : word
                var next = stop
                while next < end, char(next) == 0x20 || char(next) == 0x09 { next += 1 }
                if language.keywords.contains(key) {
                    add(i, stop, .keyword)
                } else if language.constants.contains(key) {
                    add(i, stop, .constant)
                } else if language.markup {
                    if char(next) == 0x3D { add(i, stop, .attribute) }
                } else if char(next) == 0x28 {
                    add(i, stop, .function)
                } else if previousSignificant == 0x2E {
                    add(i, stop, .property)
                } else if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first), word.count > 1 {
                    add(i, stop, .type)
                } else if char(next) == 0x3A, language.keywords.isEmpty, !language.markup {
                    // A key in JSON or YAML.
                    add(i, stop, .property)
                }
                i = stop
                previousSignificant = 0x61
                continue
            }
            if c != 0x20 && c != 0x09 && c != 0x0A { previousSignificant = c }
            i += 1
        }
        return tokens
    }
}
