# SpamSieveSDK

[SpamSieve](https://c-command.com/spamsieve/) is an app that adds powerful spam filtering to Mac e-mail clients. SpamSieve has built-in support for Apple Mail and Outlook, and [other mail apps](https://c-command.com/spamsieve/help/requirements) use SpamSieve by communicating with it through its Apple events interface. This SDK provides an easy-to-use Swift interface so that you can add SpamSieve support to your app without having to directly deal with Apple events.

# Usage

## Set Up Client Object

Your app uses a `SpamSieveClient` object to talk to the SpamSieve app (the “server”).

```swift
// We recommend writing to an app-specific log file to help with troubleshooting on a customer's Mac. 
class Logger: SpamSieveLogger {
    func debug(_ message: @autoclosure () -> String) {
        NSLog("Debug: %@", message())
    }
    
    func error(_ message: @autoclosure () -> String) {
        NSLog("Error: %@", message())
    }
}
let spamSieve = SpamSieveClient(
    logger: Logger(),
    mailClientInfo: .init(name: "MyMailClient", shortVersionString: "1.0"))

// Normally, you would use the RFC 822 message source received from the mail server.
let messageData = Data()
// The subject is used for logging and error reporting; presumably, you've already parsed this out of `messageData` to store/display the message.
let subject = "Test Subject"
```

## Score

The mail client downloads an incoming message and sends it to SpamSieve for classification. The origin information goes into SpamSieve's Log window.

```swift
let incomingOrigin = SpamSieveClient.MessageOrigin(
    contextIdentifier: "com.example.mymailclient.incoming",
    mailAccountType: "IMAP",
    mailAccountName: "MyIMAPAccount",
    mailboxName: "INBOX")
let score = try spamSieve.scoreMessage(subject: subject,
                                       data: messageData,
                                       origin: incomingOrigin,
                                       type: .automatic)
if score.isSpam {
    // Move message to Junk mailbox
}
```

If the user selects a message and asks the mail client to have SpamSieve rescore it, use something like `"com.example.mymailclient.menu"` for the context and `.manual` for the type.

## Train as Spam

Suppose SpamSieve thought the message was good, but it was actually spam. The user selects the message and chooses **Train as Spam** from the menu.

```swift
let trainInboxOrigin = SpamSieveClient.MessageOrigin(
    contextIdentifier: "com.example.mymailclient.menu",
    mailAccountType: "IMAP",
    mailAccountName: "MyIMAPAccount",
    mailboxName: "INBOX")
try spamSieve.trainMessage(subject: subject, 
                           data: messageData, 
                           origin: trainInboxOrigin, 
                           category: .spam)
// Now the mail client should move the message to Junk.
```

## Train as Good

Suppose SpamSieve thought the message was spam, but it was actually good. The message has been moved to Junk. The user selects it there and chooses **Train as Good** from the menu.

```swift
let trainJunkOrigin = SpamSieveClient.MessageOrigin(
    contextIdentifier: "com.example.mymailclient.menu",
    mailAccountType: "IMAP",
    mailAccountName: "MyIMAPAccount",
    mailboxName: "Junk")
try spamSieve.trainMessage(subject: subject, 
                           data: messageData, 
                           origin: trainJunkOrigin, 
                           category: .good)
// Now the mail client should move the message to Inbox and perhaps mark it as unread.
```
