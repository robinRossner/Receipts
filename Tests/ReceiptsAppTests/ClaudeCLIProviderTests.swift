import XCTest
@testable import ReceiptsApp

/// Output shapes captured from real `claude -p --output-format stream-json --verbose` runs of
/// Claude Code 2.1.314 (sanitised, same as backend/tests/test_receipts_llm.py).
final class ClaudeCLIProviderTests: XCTestCase {
    static let receipt = #"{"store":"Musterladen Testmarkt","date":"2026-10-15","items":[],"total":12.87}"#

    static let successEvents = [
        #"{"type":"system","subtype":"init","cwd":"/tmp/x","model":"claude-haiku-5-5","tools":[]}"#,
        #"{"type":"system","subtype":"thinking_tokens"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking"}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"StructuredOutput","input":\#(receipt)}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]},"tool_use_result":"Structured output provided successfully"}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#,
        #"{"type":"result","subtype":"success","is_error":false,"api_error_status":null,"stop_reason":"tool_use","terminal_reason":"completed","num_turns":2,"result":"{\"store\":\"Musterladen Testmarkt\",\"date\":\"2026-10-15\",\"items\":[],\"total\":12.87}","structured_output":\#(receipt)}"#,
    ]
    /// A bad --model: exit 1, an error result whose subtype is (oddly) still "success".
    static let errorEvents = [
        #"{"type":"system","subtype":"init","model":"no-such-model"}"#,
        #"{"type":"assistant","error":"model_not_found","api_error_status":404}"#,
        #"{"type":"result","subtype":"success","is_error":true,"api_error_status":404,"stop_reason":"stop_sequence","terminal_reason":"api_error","num_turns":1,"result":"There's an issue with the selected model (no-such-model). It may not exist."}"#,
    ]

    func ndjson(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testImageCallsUseStreamJSONOutputWithVerbose() {
        let args = ClaudeCLIProvider.arguments(model: "m", schema: .init(name: "x", root: ["type": "object"]), imageInput: true)
        XCTAssertEqual(args[args.firstIndex(of: "--output-format")! + 1], "stream-json")
        XCTAssertEqual(args[args.firstIndex(of: "--input-format")! + 1], "stream-json")
        XCTAssertTrue(args.contains("--verbose"))
    }

    func testTextCallsKeepJSONOutput() {
        let args = ClaudeCLIProvider.arguments(model: "m", schema: .init(name: "x", root: ["type": "object"]), imageInput: false)
        XCTAssertEqual(args[args.firstIndex(of: "--output-format")! + 1], "json")
        XCTAssertFalse(args.contains("--input-format"))
        XCTAssertFalse(args.contains("--verbose"))
    }

    func testNDJSONStreamYieldsStructuredOutputOfLastResult() throws {
        let text = try ClaudeCLIProvider.parseResult(stdout: ndjson(Self.successEvents), stderr: Data(), exitCode: 0)
        XCTAssertEqual(try object(text)["store"] as? String, "Musterladen Testmarkt")
        XCTAssertEqual(try object(text)["total"] as? Double, 12.87)
    }

    func testNDJSONToleratesBlankLinesNoiseAndTakesLastResult() throws {
        let early = #"{"type":"result","subtype":"success","result":"early"}"#
        let stdout = Data(("warming up\n\n" + early + "\n\n" + Self.successEvents.joined(separator: "\n") + "\n").utf8)
        let text = try ClaudeCLIProvider.parseResult(stdout: stdout, stderr: Data(), exitCode: 0)
        XCTAssertEqual(try object(text)["store"] as? String, "Musterladen Testmarkt")
    }

    func testFallsBackToResultTextWithoutStructuredOutput() throws {
        var lines = Self.successEvents
        lines[lines.count - 1] = #"{"type":"result","subtype":"success","is_error":false,"result":"{\"store\":\"Edeka\"}"}"#
        let text = try ClaudeCLIProvider.parseResult(stdout: ndjson(lines), stderr: Data(), exitCode: 0)
        XCTAssertEqual(try object(text)["store"] as? String, "Edeka")
    }

    func testSingleJSONObjectStillWorksForTextCalls() throws {
        let one = Data(Self.successEvents.last!.utf8)
        let text = try ClaudeCLIProvider.parseResult(stdout: one, stderr: Data(), exitCode: 0)
        XCTAssertEqual(try object(text)["store"] as? String, "Musterladen Testmarkt")
    }

    func testIsErrorIsAFailureEvenWithSuccessSubtype() {
        XCTAssertThrowsError(try ClaudeCLIProvider.parseResult(stdout: ndjson(Self.errorEvents), stderr: Data("[claude-code:unrecognized_model]".utf8), exitCode: 1)) { error in
            guard case ClaudeCLIError.failed(let code, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 1)
            XCTAssertTrue(detail.contains("selected model"), detail)
            XCTAssertFalse(detail.contains("init"), detail)
        }
    }

    func testIsErrorWithExitCodeZeroIsStillAFailure() {
        XCTAssertThrowsError(try ClaudeCLIProvider.parseResult(stdout: ndjson(Self.errorEvents), stderr: Data(), exitCode: 0)) { error in
            guard case ClaudeCLIError.failed = error else { return XCTFail("\(error)") }
        }
    }

    func testStreamWithoutResultIsBadOutput() {
        XCTAssertThrowsError(try ClaudeCLIProvider.parseResult(stdout: ndjson(Array(Self.successEvents.dropLast())), stderr: Data(), exitCode: 0)) { error in
            guard case ClaudeCLIError.badOutput = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ClaudeCLIProvider.parseResult(stdout: Data(), stderr: Data(), exitCode: 0))
    }

    func testNonZeroExitWithoutAResultReportsStderr() {
        XCTAssertThrowsError(try ClaudeCLIProvider.parseResult(stdout: Data(), stderr: Data("boom".utf8), exitCode: 2)) { error in
            guard case ClaudeCLIError.failed(_, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(detail, "boom")
        }
    }
}
