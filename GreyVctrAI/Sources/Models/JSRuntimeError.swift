import Foundation

/// Errors from JavaScript execution in the JSRuntime.
enum JSRuntimeError: Error, Equatable, LocalizedError {
    /// The JavaScript source could not be evaluated (syntax error, etc.).
    case scriptEvaluationFailed(reason: String)
    /// The expected function was not found in the JS context.
    case functionNotFound(name: String)
    /// A runtime error occurred during JS function execution.
    case executionError(reason: String)
    /// The input string is not valid JSON.
    case invalidInputJSON
    /// The output from the JS function is not valid JSON.
    case invalidOutputJSON
    /// JavaScript execution timed out.
    case timeout

    var errorDescription: String? {
        switch self {
        case .scriptEvaluationFailed(let reason):
            return "JavaScript evaluation failed: \(reason)"
        case .functionNotFound(let name):
            return "JavaScript function not found: \(name)"
        case .executionError(let reason):
            return "JavaScript execution failed: \(reason)"
        case .invalidInputJSON:
            return "The JavaScript skill input was not valid JSON."
        case .invalidOutputJSON:
            return "The JavaScript skill returned invalid JSON."
        case .timeout:
            return "JavaScript execution timed out after 10 seconds."
        }
    }
}
