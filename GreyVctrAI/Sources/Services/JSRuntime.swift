import Foundation
import JavaScriptCore

/// Executes JavaScript functions for JS_Backed_Skills using JavaScriptCore.
protocol JSRuntimeProtocol: Sendable {
    /// Execute a skill's JavaScript with the given JSON data string.
    /// - Parameters:
    ///   - script: The JavaScript content (may include HTML wrapper tags from scripts/index.html).
    ///   - inputJSON: A JSON string to pass to `window.ai_edge_gallery_get_result`.
    /// - Returns: The JSON result string from the JS function.
    func execute(script: String, inputJSON: String) async throws -> String
}

final class JSRuntime: JSRuntimeProtocol, @unchecked Sendable {
    private let executionQueue = DispatchQueue(label: "com.greyvctr.ai.jsruntime")
    private let timeoutInterval: TimeInterval = 10.0

    func execute(script: String, inputJSON: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var didResume = false

            // Schedule timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + self.timeoutInterval) {
                lock.lock()
                guard !didResume else { lock.unlock(); return }
                didResume = true
                lock.unlock()
                continuation.resume(throwing: JSRuntimeError.timeout)
            }

            // Execute on dedicated queue
            self.executionQueue.async {
                do {
                    let result = try self.executeOnCurrentThread(script: script, inputJSON: inputJSON)
                    lock.lock()
                    guard !didResume else { lock.unlock(); return }
                    didResume = true
                    lock.unlock()
                    continuation.resume(returning: result)
                } catch {
                    lock.lock()
                    guard !didResume else { lock.unlock(); return }
                    didResume = true
                    lock.unlock()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func executeOnCurrentThread(script: String, inputJSON: String) throws -> String {
        // 1. Create a new isolated JSContext per execution for safety
        let context = JSContext()!

        // Capture JS exceptions
        var jsException: JSValue?
        context.exceptionHandler = { _, exception in
            jsException = exception
        }

        // 2. Set up a `window` object (JSContext doesn't have one by default).
        //    The skill scripts assign functions onto `window`, so we alias it
        //    to the global object.
        context.evaluateScript("var window = this;")

        // 3. Strip HTML tags to extract just the JavaScript content
        let jsContent = Self.extractJavaScript(from: script)

        // 4. Evaluate the skill's JavaScript content
        context.evaluateScript(jsContent)

        if let exception = jsException {
            throw JSRuntimeError.scriptEvaluationFailed(
                reason: exception.toString() ?? "Unknown script evaluation error"
            )
        }

        // 5. Get the `window.ai_edge_gallery_get_result` function
        guard let windowObj = context.objectForKeyedSubscript("window"),
              let getResultFn = windowObj.objectForKeyedSubscript("ai_edge_gallery_get_result"),
              !getResultFn.isUndefined else {
            throw JSRuntimeError.functionNotFound(name: "window.ai_edge_gallery_get_result")
        }

        // 6. Call the function with the inputJSON string.
        //    The JS functions are declared `async` but their bodies are synchronous
        //    (no actual await calls). We call the function and handle both sync return
        //    and Promise return cases.
        let callScript = """
            var __jsrt_result = undefined;
            var __jsrt_error = undefined;
            try {
                var __ret = window.ai_edge_gallery_get_result(\(Self.escapeForJS(inputJSON)));
                if (__ret && typeof __ret.then === 'function') {
                    __ret.then(function(v) { __jsrt_result = v; })
                         .catch(function(e) { __jsrt_error = String(e); });
                } else {
                    __jsrt_result = __ret;
                }
            } catch(e) {
                __jsrt_error = String(e);
            }
            """
        context.evaluateScript(callScript)

        if let exception = jsException {
            throw JSRuntimeError.executionError(
                reason: exception.toString() ?? "Unknown execution error"
            )
        }

        // For truly async functions, the .then() callback fires during the same
        // evaluateScript microtask checkpoint. Check result immediately.
        // If not resolved, do one more evaluateScript to drain microtasks.
        if let rv = context.objectForKeyedSubscript("__jsrt_result"),
           !rv.isUndefined, !rv.isNull,
           let str = rv.toString(), !str.isEmpty {
            return str
        }

        if let ev = context.objectForKeyedSubscript("__jsrt_error"),
           !ev.isUndefined, !ev.isNull {
            throw JSRuntimeError.executionError(reason: ev.toString() ?? "Unknown error")
        }

        // One more drain attempt
        context.evaluateScript("0;")

        if let rv = context.objectForKeyedSubscript("__jsrt_result"),
           !rv.isUndefined, !rv.isNull,
           let str = rv.toString(), !str.isEmpty {
            return str
        }

        if let ev = context.objectForKeyedSubscript("__jsrt_error"),
           !ev.isUndefined, !ev.isNull {
            throw JSRuntimeError.executionError(reason: ev.toString() ?? "Unknown error")
        }

        throw JSRuntimeError.executionError(
            reason: "Function returned undefined or null"
        )
    }

    // MARK: - Helpers

    /// Strips HTML tags from the script content, extracting just the JavaScript.
    /// The skill scripts are wrapped in `<script>...</script>` inside an HTML file.
    static func extractJavaScript(from html: String) -> String {
        // Try to extract content between <script> and </script> tags
        let pattern = "<script[^>]*>(.*?)</script>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else {
            // If regex fails, return the original string (might already be pure JS)
            return html
        }

        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, options: [], range: range)

        if matches.isEmpty {
            // No script tags found — assume it's already pure JavaScript
            return html
        }

        // Concatenate all script block contents
        var jsBlocks: [String] = []
        for match in matches {
            if let captureRange = Range(match.range(at: 1), in: html) {
                jsBlocks.append(String(html[captureRange]))
            }
        }

        return jsBlocks.joined(separator: "\n")
    }

    /// Escapes a string for safe embedding in a JavaScript function call.
    /// Wraps the value in a JS string literal using JSON encoding.
    static func escapeForJS(_ string: String) -> String {
        // Use JSONSerialization to produce a properly escaped JS string literal
        if let data = try? JSONSerialization.data(
            withJSONObject: string,
            options: .fragmentsAllowed
        ),
           let escaped = String(data: data, encoding: .utf8) {
            return escaped
        }
        // Fallback: manual escaping
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
