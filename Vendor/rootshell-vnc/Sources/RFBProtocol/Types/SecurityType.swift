import Foundation

/// RFB security types used during the handshake phase.
public enum SecurityType: Sendable, Equatable, Hashable {
    case none
    case vncAuthentication
    /// RSA-AES: keys exchanged with RSA, then the sign-in and the whole
    /// session in AES-EAX. What RealVNC servers speak by default.
    case ra2
    /// RSA-AES for the sign-in only; the session after it is not encrypted.
    case ra2ne
    case tight
    case vencrypt
    case apple30
    case macAuthentication
    case srp
    case appleSRP
    /// ``ra2`` with SHA-256 and 256-bit AES keys.
    case ra2_256
    /// ``ra2ne`` with SHA-256 and 256-bit AES keys.
    case ra2ne_256
    case unknown(UInt8)

    // MARK: - Raw value mapping

    /// The byte value transmitted on the wire for this security type.
    public var rawValue: UInt8 {
        switch self {
        case .none:                return 1
        case .vncAuthentication:   return 2
        case .ra2:                 return 5
        case .ra2ne:               return 6
        case .tight:               return 16
        case .vencrypt:            return 19
        case .apple30:             return 30
        case .macAuthentication:   return 33
        case .srp:                 return 35
        case .appleSRP:            return 36
        case .ra2_256:             return 129
        case .ra2ne_256:           return 130
        case .unknown(let v):      return v
        }
    }

    /// Create a `SecurityType` from its wire byte value.
    public init(rawValue: UInt8) {
        switch rawValue {
        case 1:  self = .none
        case 2:  self = .vncAuthentication
        case 5:  self = .ra2
        case 6:  self = .ra2ne
        case 16: self = .tight
        case 19: self = .vencrypt
        case 30: self = .apple30
        case 33: self = .macAuthentication
        case 35: self = .srp
        case 36: self = .appleSRP
        case 129: self = .ra2_256
        case 130: self = .ra2ne_256
        default: self = .unknown(rawValue)
        }
    }

    /// Generic preference order for supported types (higher = more preferred).
    /// Returns `nil` for types this client cannot negotiate. The built-in
    /// automatic policy also considers server context and interoperability, so
    /// it does not select solely by this value.
    public var negotiationPriority: Int? {
        switch self {
        case .none:                return 0
        case .vncAuthentication:   return 1
        case .apple30:             return 2
        case .appleSRP:            return 2
        case .macAuthentication:   return 3
        case .vencrypt:            return 4
        case .ra2ne, .ra2ne_256:   return 2
        case .ra2, .ra2_256:       return 4
        // Not yet implemented:
        case .srp:                 return nil
        case .tight:               return nil
        case .unknown:             return nil
        }
    }
}

/// User-facing policy for selecting the outer RFB security type.
///
/// `.automatic` is deliberately compatibility-first: Apple authentication is
/// considered only for Apple servers with a username, while conventional
/// servers use VNC Authentication when available and VeNCrypt when it is the
/// server's only supported authenticated option.
public enum VNCSecurityPolicy: String, Sendable, Equatable, Hashable, CaseIterable {
    case automatic
    case requireEncryption
    case none
    case vncAuthentication
    case apple30
    case macAuthentication
    case appleSRP
}

extension SecurityType {
    /// The RSA-AES types, in the order a client should want them: the ones
    /// that encrypt the whole session first, the stronger of each pair first.
    public static let rsaAES: [SecurityType] = [.ra2_256, .ra2, .ra2ne_256, .ra2ne]

    /// Whether everything after the sign-in is encrypted as well.
    public var encryptsSession: Bool {
        self == .ra2 || self == .ra2_256
    }

    /// An Apple-protocol server offering SRP without the 30/33 types every
    /// Mac offers: Screen Sharing servers on other systems, such as wayshare.
    public static func offersAppleSRPWithoutMacTypes(_ offered: [SecurityType]) -> Bool {
        offered.contains(.appleSRP)
            && !offered.contains(.apple30)
            && !offered.contains(.macAuthentication)
    }
}
