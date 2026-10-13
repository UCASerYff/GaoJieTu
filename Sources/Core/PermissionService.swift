import AppKit
import AVFoundation

enum PermissionService {
    static var screenGranted:Bool{CGPreflightScreenCaptureAccess()}
    static var microphoneStatus:AVAuthorizationStatus{AVCaptureDevice.authorizationStatus(for:.audio)}
    static var scrollingGranted:Bool{AXIsProcessTrusted()}
    @MainActor static func requestScreen()->Bool{CGRequestScreenCaptureAccess()}
    static func requestMicrophone() async -> Bool{await AVCaptureDevice.requestAccess(for:.audio)}
    @MainActor static func requestScrolling()->Bool{AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)}
}
