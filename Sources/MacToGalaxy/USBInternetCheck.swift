import Foundation
import GalaxyCore
import Network
import Security

final class USBInternetCheck {
    enum Outcome {
        case passed
        case noPath
        case failed
        case unexpectedResponse
    }

    private static let host = "www.google.com"
    private let queue = DispatchQueue(label: "MacToGalaxy.USBInternetCheck")
    private let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private let interfaceName: String
    private var completion: ((Outcome) -> Void)?
    private var connection: NWConnection?
    private var response = Data()

    init(interfaceName: String, completion: @escaping (Outcome) -> Void) {
        self.interfaceName = interfaceName
        self.completion = completion
    }

    func start() {
        queue.async { [self] in
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self, self.connection == nil,
                      let interface = path.availableInterfaces.first(where: { $0.name == self.interfaceName })
                else { return }
                self.connect(through: interface)
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self else { return }
                self.finish(self.connection == nil ? .noPath : .failed)
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            completion = nil
            stop()
        }
    }

    private func connect(through interface: NWInterface) {
        guard completion != nil else { return }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredInterface = interface
        let connection = NWConnection(host: NWEndpoint.Host(Self.host), port: 443, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.sendRequest()
            case .failed:
                self?.finish(.failed)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendRequest() {
        let request = "GET /generate_204 HTTP/1.1\r\nHost: \(Self.host)\r\nConnection: close\r\n\r\n"
        connection?.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            if error == nil {
                self?.receive()
            } else {
                self?.finish(.failed)
            }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, self.completion != nil else { return }
            if error != nil {
                self.finish(.failed)
                return
            }
            if let data { self.response.append(data) }
            switch InternetProbeResponse(buffer: self.response) {
            case .success:
                self.finish(.passed)
            case .unexpected:
                self.finish(.unexpectedResponse)
            case .incomplete:
                if isComplete {
                    self.finish(.unexpectedResponse)
                } else {
                    self.receive()
                }
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        stop()
        completion(outcome)
    }

    private func stop() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }
}
