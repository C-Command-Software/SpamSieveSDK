import Foundation
import AppKit

private let spamSieveSDKVersion = "1.0.7"

/// You could implement these to append to your app's own log file. They should be threadsafe.
public protocol SpamSieveLogger {
    func debug(_ message: @autoclosure () -> String)
    func error(_ message: @autoclosure () -> String)
}

public class SpamSieveClient {   
    let logger: SpamSieveLogger
    let mailClientInfo: MailClientInfo    
    
    public init(logger: SpamSieveLogger, mailClientInfo: MailClientInfo) {
        self.logger = logger
        self.mailClientInfo = mailClientInfo
    }
    
    /**
     - Parameter subject: This is just for debug logging
     - Parameter data: The full RFC 822 data received from the server. This should include any attachments. It should not change if the same message is later trained or rescored.
     - Parameter origin: Information about where the message is in the mail hierarchy and the context in which SpamSieve is being asked to filter it.
     - Parameter type: Manual scorings skip auto-training to avoid cascading errors. 
     */
    public func scoreMessage(subject: String, 
                             data: Data,
                             origin: MessageOrigin,
                             type: ScoringType) throws -> Score {
        logger.debug("Begin scoring message of length \(data.count): \(subject)")
        do {        
            let event = try appleEvent(id: "iSSc".mjtFourCharCode,
                                       messageData: data, 
                                       origin: origin)
            switch type {
                case .manual:
                    event.mjtSetParam(false, for: "bAut")
                case .automatic:
                    break
            }
            let startDate = Date()
            let score = try score(fromReply: sendEvent(event, subject: subject), 
                                   subject: subject)
            let duration = -startDate.timeIntervalSinceNow
            logger.debug("Score of \(score.rawValue) in \(duration.mjtSecondsString) for message: \(subject)")
            return score
        } catch {
            logger.error("Error scoring message: \(describe(error)) subject: \(subject)")
            throw error
        }
    }
    
    /**
     - Parameter subject: This is just for debug logging
     - Parameter data: The full RFC 822 data received from the server. This should include any attachments. It should not change if the same message is later trained or rescored.
     - Parameter origin: Information about where the message is in the mail hierarchy and the context in which SpamSieve is being asked to filter it.
     - Parameter category: What the user says the message is.
     */
    public func trainMessage(subject: String, 
                             data: Data,
                             origin: MessageOrigin,
                             category: Category) throws {
        logger.debug("Begin training message of length \(data.count) as \(category): \(subject)")
        do {        
            let event = try appleEvent(id: category.trainingEventID,
                                       messageData: data, 
                                       origin: origin)
            let startDate = Date()
            _ = try sendEvent(event, subject: subject)
            let duration = -startDate.timeIntervalSinceNow
            logger.debug("Trained message as \(category) in \(duration.mjtSecondsString): \(subject)")
        } catch {
            logger.error("Error scoring message as \(category): \(describe(error)) subject: \(subject)")
            throw error
        }
    }
}

// MARK: Types

public extension SpamSieveClient {
    struct MailClientInfo {
        let name: String
        let shortVersionString: String
    }
    
    struct MessageOrigin {
        /// For example, "com.your-domain.mail-client-name.incoming-mail" or "com.your-domain.mail-client-name.user-action". Contact <spamsieve@c-command.com> and explain which values you're using so that we can localize them.
        var contextIdentifier: String
        var ruleName: String? = nil
        var mailAccountType: String? = nil
        var mailAccountName: String? = nil
        var mailboxName: String? = nil
        var mailboxContainerName: String? = nil
    }

    enum ScoringType {
        /// The message is being auto-scored, e.g. because the mail client just downloaded it.
        case automatic
        /// The user has chosen to rescore a message or newly process a batch of old messages that might not have been scored before.
        case manual
    }

    struct Score: RawRepresentable {
        public var rawValue: Int
        
        public init?(rawValue: Int) {
            guard rawValue >= 0 && rawValue <= 100 else { return nil}
            self.rawValue = rawValue
        }
        
        public var isSpam: Bool { rawValue >= 50 }
    }
    
    enum Category: String, CaseIterable {
        case spam
        case good
        
        var trainingEventID: FourCharCode {
            switch self {
                case .spam: return "addS".mjtFourCharCode
                case .good: return "addG".mjtFourCharCode
            }
        }
    }
}

// MARK: Apple Events

private extension SpamSieveClient {
    func appleEvent(id: FourCharCode, messageData: Data, origin: MessageOrigin) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: "mtSS".mjtFourCharCode,
            eventID: id,
            targetDescriptor: try targetDescriptor(),
            returnID: AEReturnID(kAutoGenerateReturnID), 
            transactionID: AETransactionID(kAnyTransactionID))
        event.mjtSetParam(try descriptor(type: typeChar, data: messageData), 
                          for: "Mess")
        event.mjtSetParam(originDescriptor(origin: origin), for: "rOrg")
        return event
    }
    
    func descriptor(type: FourCharCode, data: Data) throws -> NSAppleEventDescriptor {
        if let result = NSAppleEventDescriptor(descriptorType: type, data: data) {
            return result
        }
        throw error(.nilDescriptor, type: type, data: data) 
    }
       
    func originDescriptor(origin: MessageOrigin) -> NSAppleEventDescriptor {
        let result = NSAppleEventDescriptor.record()
        result.mjtSetValue(mailClientInfo.name, for: "sApN")
        result.mjtSetValue(mailClientInfo.shortVersionString, for: "sApV")
        result.mjtSetValue(spamSieveSDKVersion, for: "sInV")
        
        result.mjtSetValue(origin.contextIdentifier, for: "sSou")
        result.mjtSetValue(origin.ruleName, for: "sRuN")
        result.mjtSetValue(origin.mailAccountType, for: "sMaT")
        result.mjtSetValue(origin.mailAccountName, for: "sMaN")
        result.mjtSetValue(origin.mailboxName, for: "sMxN")
        result.mjtSetValue(origin.mailboxContainerName, for: "sMcN")        
        return result
    }
    
    func targetDescriptor() throws -> NSAppleEventDescriptor {
        try descriptor(type: typeApplicationBundleID, 
                       data: spamSieveBundleIdentifier.data(using: .utf8)!)
    }
            
    func sendEvent(_ event: NSAppleEventDescriptor, subject: String, tries: Int = 1) throws -> NSAppleEventDescriptor {
        launchSpamSieveIfNecessary()
        let timeout = TimeInterval(10) // kAEDefaultTimeout is too long
        do {
            let reply = try event.sendEvent(options: .waitForReply, timeout: timeout)
            if let errorNumber = reply.paramDescriptor(forKeyword: keyErrorNumber) {
                throw error(.appleEventFailed, 
                            reply: reply,
                            subject: subject,
                            underlyingError: NSError(domain: NSOSStatusErrorDomain, 
                                                     code: Int(errorNumber.int32Value)))
            }
            return reply
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == errAETimeout {
            logger.error("Timeout sending event '\(event.eventID.mjtString)' (tries: \(tries)): \(subject)")
            if tries >= 5 {
                throw error
            }
            return try sendEvent(event, subject: subject, tries: tries + 1)
        }
    }
    
    func score(fromReply reply: NSAppleEventDescriptor, subject: String) throws -> Score {    
        guard let directObject = reply.paramDescriptor(forKeyword: keyDirectObject) else {
            throw error(.noDirectObject, reply: reply, subject: subject)
        }
        guard let score = Score(rawValue: Int(directObject.int32Value)) else {
            throw error(.invalidScore, reply: reply, subject: subject)
        }
        return score
    }
}

// MARK: Launching

private let spamSieveBundleIdentifier = "com.c-command.SpamSieve"

private extension SpamSieveClient {    
    func launchSpamSieveIfNecessary() {
        if isSpamSieveRunning() { return }
        launchSpamSieve()
    }

    func isSpamSieveRunning() -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: spamSieveBundleIdentifier)
        guard let app = apps.first else { return false }
        return app.isFinishedLaunching
    }
       
    func launchSpamSieve() {
        launchUsingWorkspace()
        waitUntilLaunched()
        if !isSpamSieveRunning() {
            launchUsingLaunchAgent()
            waitUntilLaunched()
        }
    }
    
    func launchUsingWorkspace() {
        let workspace = NSWorkspace.shared
        guard let url = workspace.urlForApplication(withBundleIdentifier: spamSieveBundleIdentifier) else {
            logger.error("Could not find SpamSieve application")
            return
        }
        logger.debug("Trying to launch SpamSieve using workspace: \(url.path)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.promptsUserIfNeeded = false
        let group = DispatchGroup()
        group.enter()
        workspace.openApplication(at: url, configuration: configuration) { app, error in
            group.leave()
            if let app {
                self.logger.debug("Launched SpamSieve: \(app)")
            }
            if let error {
                self.logger.error("Error launching SpamSieve: \(error)")
            }
        }
        switch group.wait(timeout: .now() + .seconds(15)) {
            case .timedOut:
                self.logger.error("Timed out waiting for NSWorkspace launch callback")
            case .success:
                break
        }
    }
   
    func launchUsingLaunchAgent() {
        logger.debug("Trying to launch SpamSieve via launch agent.")
        let center = DistributedNotificationCenter.default()
        let name = "com.c-command.SpamSieve.LaunchAgent.Launch"
        center.postNotificationName(.init(rawValue: name), 
                                    object: nil,
                                    deliverImmediately: true)
    }
    
    func waitUntilLaunched() {
        let giveUpDate = Date(timeIntervalSinceNow: 5)
        while !isSpamSieveRunning() && giveUpDate.timeIntervalSinceNow > 0 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        }
        if isSpamSieveRunning() {
            logger.debug("SpamSieve is now running")
        } else {
            logger.error("Client \(mailClientInfo) was unable to launch SpamSieve.")
        }        
    }
}

// MARK: Errors

public extension SpamSieveClient {
    static let errorDomain = "com.c-command.spamsieve.client"
    static let typeKey = "type"
    static let dataKey = "data"
    static let replyKey = "reply"
    static let subjectKey = "subject"
    
    enum ErrorCode: Int {
        case nilDescriptor = 1
        case appleEventFailed = 2
        case noDirectObject = 3
        case invalidScore = 4
    }
    
    func error(_ code: ErrorCode, 
               type: FourCharCode? = nil,
               data: Data? = nil,
               reply: NSAppleEventDescriptor? = nil,
               subject: String? = nil,
               underlyingError: NSError? = nil) -> NSError {
        var userInfo = [String: Any]()
        userInfo[Self.typeKey] = type
        userInfo[Self.dataKey] = data
        userInfo[Self.replyKey] = reply
        userInfo[Self.subjectKey] = subject
        userInfo[NSUnderlyingErrorKey] = underlyingError
        userInfo[NSLocalizedDescriptionKey] = String(describing: code)
        return NSError(domain: Self.errorDomain, code: code.rawValue, userInfo: userInfo)        
    }

    func describe(_ error: Error) -> String {
        // `Error.localizedDescription` does not include `userInfo`
        let nsError = error as NSError
        return nsError.debugDescription
    }
}

// MARK: Utility

private typealias MJTFourCharCode = String

public extension String {
    var mjtFourCharCode: FourCharCode {
        precondition(count == 4)
        let data = data(using: .macOSRoman)! 
        var code: FourCharCode = 0
        let bytesWritten = Swift.withUnsafeMutableBytes(of: &code) {
            data.copyBytes(to: $0)
        }
        precondition(bytesWritten == 4)
        return code.bigEndian
    }
}

public extension FourCharCode {
    var mjtString: String {
        String(mjtMacOSRomanData: Data(mjtFrom: self.bigEndian))
    }
}

public extension Data {
    init<T>(mjtFrom value: T) {
        self = Swift.withUnsafeBytes(of: value) {
            Data($0)
        }
    }
}

public extension String {
    init(mjtMacOSRomanData data: Data) {
        self = String(data: data, encoding: .macOSRoman)!
    }
}

fileprivate extension TimeInterval {
    var mjtSecondsString: String {
        String(format: "%.2fs", self)
    }
}

fileprivate extension NSAppleEventDescriptor {
    func mjtSetValue(_ string: String?, for keyword: MJTFourCharCode) {
        guard let string = string else { return }
        setDescriptor(NSAppleEventDescriptor(string: string),
                      forKeyword: keyword.mjtFourCharCode)
    }

    func mjtSetParam(_ descriptor: NSAppleEventDescriptor, for keyword: MJTFourCharCode) {
        setParam(descriptor, forKeyword: keyword.mjtFourCharCode)
    }
    
    func mjtSetParam(_ bool: Bool, for keyword: MJTFourCharCode) {
        mjtSetParam(NSAppleEventDescriptor(boolean: bool), for: keyword)
    }
}
