import Foundation

/// SCRIPT execution context.
struct ScriptContext {
    let transaction: Transaction
    let inputIndex: Int
    let previousOutputs: [Output]
    let configuration: ScriptConfigurarion
    let script: any Script
    var decodedOperations = [ScriptOperation]()
    var operationIndex: Int = 0
    var programCounter: Int = 0

    var previousOutput: Output {
        previousOutputs[inputIndex]
    }

    /// Support for `OP_CHECKSIG` and `OP_CHECKSIGVERIFY`.
    var lastCodeSeparatorOffset: Int? = .none

    /// Support for `OP_TOALTSTACK` and `OP_FROMALTSTACK`.
    var altStack: [Data] = []

    /// Support for `OP_IF`, `OP_NOTIF`, `OP_ELSE` and `OP_ENDIF`.
    var pendingIfOperations = [Bool?]()
    var pendingElseOperations = 0

    /// Support for `OP_IF`, `OP_NOTIF`, `OP_ELSE` and `OP_ENDIF`.
    var evaluateBranch: Bool {
        guard let lastEvaluatedIfResult = pendingIfOperations.last(where: { $0 != .none }), let lastEvaluatedIfResult else {
            return true
        }
        return lastEvaluatedIfResult
    }

    /// Support for `OP_CHECKSIG` and `OP_CHECKSIGVERIFY`. Legacy scripts only.
    func getScriptCode(signatures: [Data]) throws -> Data {
        precondition(script.version == .legacy)
        var scriptData = script.data
        if let codesepOffset = lastCodeSeparatorOffset {
            scriptData.removeFirst(codesepOffset + 1)
        }

        var scriptCode = Data()
        var programCounter2 = scriptData.startIndex
        while programCounter2 < scriptData.endIndex {
            guard let operation = ScriptOperation(scriptData[programCounter2...], version: script.version) else {
                preconditionFailure()
                // TODO: What happens to scriptCode if script cannot be fully decoded?
            }

            var operationContainsSignature = false
            for sig in signatures {
                if !sig.isEmpty, operation == .pushBytes(sig) {
                    operationContainsSignature = true
                    if configuration.constantScriptCode {
                        throw ScriptError.nonConstantScript
                    }
                    break
                }
            }

            if
                operation != .codeSeparator && !operationContainsSignature // Equivalent to FindAndDelete
            {
                scriptCode.append(operation.data)
            }
            programCounter2 += operation.size
        }
        return scriptCode
    }

    /// BIP143
    var segwitScriptCode: Data {
        var scriptData = script.data
        // if the witnessScript contains any OP_CODESEPARATOR, the scriptCode is the witnessScript but removing everything up to and including the last executed OP_CODESEPARATOR before the signature checking opcode being executed, serialized as scripts inside CTxOut.
        if let codesepOffset = lastCodeSeparatorOffset {
            scriptData.removeFirst(codesepOffset + 1)
        }
        return scriptData
    }
}
