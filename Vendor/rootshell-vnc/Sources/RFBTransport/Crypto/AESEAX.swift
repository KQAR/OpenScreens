import CommonCrypto
import Foundation

/// AES in EAX mode: encryption that also proves a message, and a header sent
/// beside it in the clear, arrived as they were sent.
///
/// This is the cipher of the RSA-AES security types, which RealVNC servers
/// and wayvnc protect a session with. EAX is built from two things AES
/// already gives: counter mode for the secrecy and CMAC for the proof.
struct AESEAX: Sendable {
    static let blockSize = kCCBlockSizeAES128
    static let tagSize = 16

    private let key: [UInt8]
    /// CMAC's two subkeys, for a last block that is whole and one that is not.
    private let wholeBlockKey: [UInt8]
    private let partBlockKey: [UInt8]

    /// - Parameter key: 16 bytes for AES-128 or 32 for AES-256.
    init?(key: Data) {
        guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256 else { return nil }
        self.key = Array(key)
        guard let zero = Self.cbcLastBlock(
            key: self.key, message: [UInt8](repeating: 0, count: Self.blockSize)) else { return nil }
        wholeBlockKey = Self.doubled(zero)
        partBlockKey = Self.doubled(wholeBlockKey)
    }

    /// Encrypts `plaintext`, returning the ciphertext followed by its tag.
    func seal(_ plaintext: Data, nonce: [UInt8], header: [UInt8]) -> Data? {
        guard let nonceMAC = omac(0, nonce),
              let headerMAC = omac(1, header),
              let ciphertext = counterMode(Array(plaintext), startingAt: nonceMAC),
              let ciphertextMAC = omac(2, ciphertext) else { return nil }
        var sealed = Data(ciphertext)
        sealed.append(contentsOf: Self.xor(Self.xor(nonceMAC, headerMAC), ciphertextMAC))
        return sealed
    }

    /// Decrypts what ``seal(_:nonce:header:)`` made. `nil` when the tag does
    /// not match: the message, the header or the nonce is not what was sent.
    func open(_ sealed: Data, nonce: [UInt8], header: [UInt8]) -> Data? {
        guard sealed.count >= Self.tagSize else { return nil }
        let ciphertext = Array(sealed.prefix(sealed.count - Self.tagSize))
        let tag = Array(sealed.suffix(Self.tagSize))
        guard let nonceMAC = omac(0, nonce),
              let headerMAC = omac(1, header),
              let ciphertextMAC = omac(2, ciphertext) else { return nil }
        let expected = Self.xor(Self.xor(nonceMAC, headerMAC), ciphertextMAC)
        // Every byte is compared whatever the ones before it were.
        var difference: UInt8 = 0
        for (a, b) in zip(expected, tag) {
            difference |= a ^ b
        }
        guard difference == 0,
              let plaintext = counterMode(ciphertext, startingAt: nonceMAC) else { return nil }
        return Data(plaintext)
    }

    // MARK: - The parts

    /// CMAC of `message` behind a block that says which of EAX's three
    /// inputs it is.
    private func omac(_ which: UInt8, _ message: [UInt8]) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: Self.blockSize)
        input[Self.blockSize - 1] = which
        input.append(contentsOf: message)

        let remainder = input.count % Self.blockSize
        let lastBlock = input.count - (remainder == 0 ? Self.blockSize : remainder)
        if remainder == 0 {
            for index in 0..<Self.blockSize {
                input[lastBlock + index] ^= wholeBlockKey[index]
            }
        } else {
            input.append(0x80)
            input.append(contentsOf: [UInt8](repeating: 0, count: Self.blockSize - remainder - 1))
            for index in 0..<Self.blockSize {
                input[lastBlock + index] ^= partBlockKey[index]
            }
        }
        return Self.cbcLastBlock(key: key, message: input)
    }

    /// The last block of `message` encrypted in CBC mode from a zero block,
    /// which is what a CBC-MAC is.
    private static func cbcLastBlock(key: [UInt8], message: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: message.count)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0,
            key, key.count, nil,
            message, message.count,
            &output, output.count, &moved)
        guard status == kCCSuccess, moved == message.count, moved >= blockSize else { return nil }
        return Array(output.suffix(blockSize))
    }

    private func counterMode(_ input: [UInt8], startingAt counter: [UInt8]) -> [UInt8]? {
        guard !input.isEmpty else { return [] }
        var cryptor: CCCryptorRef?
        let created = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding), counter, key, key.count, nil, 0, 0,
            CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        guard created == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = CCCryptorUpdate(cryptor, input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess, moved == input.count else { return nil }
        return output
    }

    /// A block multiplied by two in the field CMAC works in.
    private static func doubled(_ block: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: block.count)
        var carry: UInt8 = 0
        for index in stride(from: block.count - 1, through: 0, by: -1) {
            result[index] = (block[index] << 1) | carry
            carry = block[index] >> 7
        }
        if carry == 1 {
            result[block.count - 1] ^= 0x87
        }
        return result
    }

    private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        zip(a, b).map { $0 ^ $1 }
    }
}
