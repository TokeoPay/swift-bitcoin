import Foundation
import JSONRPC
import BitcoinBase
import BitcoinBlockchain

/// Summary of current blockchain information such as total number of headers, blocks and a list of block IDs (hashes).
public struct GetBlockchainInfoCommand: Sendable {

    internal struct Output: JSONStringConvertible {
        let headers: Int
        let blocks: Int
        let hashes: [String]
    }

    public init(bitcoinService: BitcoinService) {
        self.bitcoinService = bitcoinService
    }

    let bitcoinService: BitcoinService

    public func run(_ request: JSONRequest) async -> JSONResponse {

        precondition(request.method == Self.method)

        let headers = await bitcoinService.headers
        let blocks = await bitcoinService.transactions.count
        let result = Output(
            headers: headers.count,
            blocks: blocks,
            hashes: headers.map { $0.idHex }
        )
        return .init(id: request.id, result: JSONObject.string(result.description))
    }

    public static let method = "get-blockchain-info"
}
