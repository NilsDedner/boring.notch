//
//  BoringNotchXPCHelperProtocol.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol BoringNotchXPCHelperProtocol {
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    // Keyboard backlight / CoreBrightness access (performed by the helper)
    func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Screen brightness access (performed by the helper)
    func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Process monitoring (performed by the unsandboxed helper)
    /// Input: JSON array of app PIDs. Reply: JSON {"<pid>": {"mem": bytes, "cpu": ns}} summed over
    /// each app and all of its descendant processes ("cpu" = total CPU time used so far).
    func appStatistics(_ pidsJSON: Data, with reply: @escaping (Data?) -> Void)
    /// Reply: JSON {"fans": [{"rpm", "min", "max"}], "power": watts} read from the SMC.
    func readSensors(with reply: @escaping (Data?) -> Void)
    /// Gracefully quits (or force-quits) a regular GUI app. Returns false for non-app or protected PIDs.
    func terminateApp(_ pid: Int32, force: Bool, with reply: @escaping (Bool) -> Void)
    // Screen recording via screencapture -v (fails inside the app sandbox)
    /// Input: JSON array of extra screencapture arguments. Replies true once recording runs.
    func startScreenRecording(_ argumentsJSON: Data, outputPath: String, with reply: @escaping (Bool) -> Void)
    /// Stops the recording and replies true if the movie file was written.
    func stopScreenRecording(with reply: @escaping (Bool) -> Void)
    func isScreenRecording(with reply: @escaping (Bool) -> Void)
}

/*
 To use the service from an application or other process, use NSXPCConnection to establish a connection to the service by doing something like this:

     connectionToService = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringNotchXPCHelper")
     connectionToService.remoteObjectInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)
     connectionToService.resume()

 Once you have a connection to the service, you can use it like this:

     if let proxy = connectionToService.remoteObjectProxy as? BoringNotchXPCHelperProtocol {
         proxy.performCalculation(firstNumber: 23, secondNumber: 19) { result in
             NSLog("Result of calculation is: \(result)")
         }
     }

 And, when you are finished with the service, clean up the connection like this:

     connectionToService.invalidate()
*/
