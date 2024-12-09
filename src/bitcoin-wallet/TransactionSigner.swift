import BitcoinBase
import BitcoinCrypto
import Foundation

/// An affordance to sign multiple inputs of a bitcoin transaction.
public class TransactionSigner {
    
    /// Creates a new signer with default signature hash type of _all_.
    /// - Parameters:
    ///   - transaction: A transaction to sign.
    ///   - prevouts: All previous outputs corresponding to each of the transaction's inputs.
    public init(transaction: BitcoinTransaction, prevouts: [TransactionOutput]) {
        self.transaction = transaction
        hasher = .init(transaction: transaction, prevouts: prevouts, sighashType: .all)
    }

    /// Creates a new signer.
    /// - Parameters:
    ///   - transaction: A transaction to sign.
    ///   - prevouts: All previous outputs corresponding to each of the transaction's inputs.
    ///   - sighashType: An initial, optional signature hash type.
    public init(transaction: BitcoinTransaction, prevouts: [TransactionOutput], sighashType: SighashType? = Optional.none) {
        self.transaction = transaction
        hasher = .init(transaction: transaction, prevouts: prevouts, sighashType: sighashType)
    }
    
    /// The last version of the transaction containing all signatures generated by this signer.
    public private(set) var transaction: BitcoinTransaction

    /// A hasher instance for generating the required signature hashes.
    private let hasher: SignatureHash

    /// The current signature hash type.
    public var sighashType: SighashType? {
        get { hasher.sighashType }
        set { hasher.sighashType = newValue }
    }
    
    /// Signs a multi-signature input.
    /// - Parameters:
    ///   - inputIndex: A valid input index.
    ///   - redeemScript: An optional redeem script (pay-to-script-hash only).
    ///   - witnessScript: An optional witness script (pay-to-witness-script-hash only, also when wrapped).
    ///   - secretKeys: Secret keys for each signature.
    /// - Returns: A transaction with the signed input.
    @discardableResult
    public func sign(input inputIndex: Int, redeemScript: BitcoinScript? = .none, witnessScript: BitcoinScript? = .none, with secretKeys: [SecretKey]) -> BitcoinTransaction {

        let lockScript = hasher.prevouts[inputIndex].script

        precondition(
            lockScript.isPayToMultisig && redeemScript == .none && witnessScript == .none ||
            (lockScript.isPayToWitnessScriptHash && witnessScript != .none && witnessScript!.isPayToMultisig) ||
            (lockScript.isPayToScriptHash && redeemScript != .none && redeemScript!.isPayToMultisig) ||
            (redeemScript == .none && witnessScript != .none && witnessScript!.isPayToMultisig && lockScript == .payToScriptHash(.payToWitnessScriptHash(witnessScript!)))
        )

        let sigVersion: SigVersion = if witnessScript != .none { .witnessV0 }
            else { .base }

        hasher.set(input: inputIndex, sigVersion: sigVersion, scriptCode: witnessScript?.data ?? redeemScript?.data)
        let sighash = hasher.value

        var signatures = [Data]()
        for secretKey in secretKeys {
            let signature = secretKey.sign(hash: sighash)
            let extended = ExtendedSignature(signature, sighashType)
            signatures.append(extended.data)
        }
        if let redeemScript { signatures.append(redeemScript.data) }
        if let witnessScript { signatures.append(witnessScript.data)}

        if let witnessScript {
            let witness = [Data()] + signatures
            transaction.inputs[inputIndex].witness = .init(witness)
            if lockScript.isPayToScriptHash {
                let redeemScriptP2WSH = BitcoinScript.payToWitnessScriptHash(witnessScript)
                transaction.inputs[inputIndex].script = [.encodeMinimally(redeemScriptP2WSH.data)]
            }
        } else {
            let unlockScript = BitcoinScript([.zero] + signatures.map { ScriptOperation.encodeMinimally($0) })
            transaction.inputs[inputIndex].script = unlockScript
        }
        return transaction
    }

    /// Signs a single key input.
    /// - Parameters:
    ///   - inputIndex: A valid input index.
    ///   - secretKey: A secret key for signing.
    /// - Returns: A transaction with the signed input.
    @discardableResult
    public func sign(input inputIndex: Int, with secretKey: SecretKey) -> BitcoinTransaction {
        let lockScript = hasher.prevouts[inputIndex].script

        let publicKeyHash = Data(Hash160.hash(data: secretKey.publicKey.data))
        let redeemScript = BitcoinScript.payToWitnessPublicKeyHash(publicKeyHash)

        precondition(
            lockScript.isPayToPublicKey || lockScript.isPayToPublicKeyHash || lockScript.isPayToWitnessKeyHash || lockScript.isPayToTaproot || (
                lockScript == .payToScriptHash(redeemScript)
        ))

        let sigVersion: SigVersion = if lockScript.isPayToWitnessKeyHash || lockScript.isPayToScriptHash { .witnessV0 }
                         else if lockScript.isPayToTaproot { .witnessV1 }
                         else { .base }

        let scriptCode: Data? = if lockScript.isPayToScriptHash {
            BitcoinScript.segwitPKHScriptCode(publicKeyHash).data
        } else { .none }

        hasher.set(input: inputIndex, sigVersion: sigVersion, scriptCode: scriptCode)
        let sighash = hasher.value

        let signature = if lockScript.isPayToTaproot {
            secretKey.taprootSecretKey().sign(hash: sighash, signatureType: .schnorr)
        } else {
            secretKey.sign(hash: sighash)
        }

        let signatureExt = ExtendedSignature(signature, hasher.sighashType)
        // For pay-to-public key we just need to sign the hash and add the signature to the input's unlock script.
        var witnessData = [signatureExt.data]
        if lockScript.isPayToPublicKeyHash || lockScript.isPayToWitnessKeyHash || lockScript.isPayToScriptHash {
            // For pay-to-public-key-hash we need to also add the public key to the unlock script.
            witnessData.append(secretKey.publicKey.data)
        }
        if lockScript.isPayToWitnessKeyHash || lockScript.isPayToScriptHash || lockScript.isPayToTaproot {
            // For pay-to-witness-public-key-hash we sign a different hash and we add the signature and public key to the input's _witness_.
            transaction.inputs[inputIndex].witness = .init(witnessData)
        }
        if lockScript.isPayToPublicKey || lockScript.isPayToPublicKeyHash {
            let ops = witnessData.map { ScriptOperation.pushBytes($0) }
            transaction.inputs[inputIndex].script = .init(ops)
        }
        if lockScript.isPayToScriptHash {
            transaction.inputs[inputIndex].script = [.encodeMinimally(redeemScript.data)]
        }
        return transaction
    }
}
