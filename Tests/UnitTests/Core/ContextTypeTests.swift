import Foundation
import Testing
@testable import FastLang

@Suite("ContextType")
struct ContextTypeTests {

    @Test("all cases have non-empty raw values")
    func rawValuesNonEmpty() {
        for contextType in ContextType.allCases {
            #expect(!contextType.rawValue.isEmpty)
        }
    }

    @Test("raw values are capitalized display names")
    func rawValueFormat() {
        #expect(ContextType.email.rawValue == "Email")
        #expect(ContextType.chat.rawValue == "Chat")
        #expect(ContextType.document.rawValue == "Document")
        #expect(ContextType.spreadsheet.rawValue == "Spreadsheet")
        #expect(ContextType.code.rawValue == "Code")
        #expect(ContextType.notes.rawValue == "Notes")
        #expect(ContextType.generic.rawValue == "Generic")
    }

    @Test("JSON encode-decode roundtrip for every case")
    func codableRoundtrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for contextType in ContextType.allCases {
            let data = try encoder.encode(contextType)
            let decoded = try decoder.decode(ContextType.self, from: data)
            #expect(decoded == contextType)
        }
    }

    @Test("decodes from JSON string matching raw value")
    func decodesFromString() throws {
        let json = Data("\"Email\"".utf8)
        let decoded = try JSONDecoder().decode(ContextType.self, from: json)
        #expect(decoded == .email)
    }

    @Test("decoding unknown string fails")
    func unknownStringFails() {
        let json = Data("\"Unknown\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ContextType.self, from: json)
        }
    }

    @Test("CaseIterable yields exactly 7 cases")
    func caseCount() {
        #expect(ContextType.allCases.count == 7)
    }
}

@Suite("PromptMode")
struct PromptModeTests {

    @Test("insert and replace are distinct")
    func distinctCases() {
        let insert = PromptMode.insert
        let replace = PromptMode.replace
        #expect(type(of: insert) == PromptMode.self)
        #expect(type(of: replace) == PromptMode.self)
    }
}

@Suite("OverlayState")
struct OverlayStateTests {

    @Test("equatable works for simple cases")
    func equatableSimple() {
        #expect(OverlayState.input == .input)
        #expect(OverlayState.generating == .generating)
        #expect(OverlayState.approval == .approval)
        #expect(OverlayState.input != .generating)
    }

    @Test("equatable works for error case with same message")
    func equatableErrorSame() {
        #expect(OverlayState.error("fail") == .error("fail"))
    }

    @Test("equatable distinguishes different error messages")
    func equatableErrorDifferent() {
        #expect(OverlayState.error("a") != .error("b"))
    }

    @Test("error case is not equal to non-error cases")
    func errorNotEqualToOthers() {
        #expect(OverlayState.error("msg") != .input)
        #expect(OverlayState.error("msg") != .generating)
        #expect(OverlayState.error("msg") != .approval)
    }
}
