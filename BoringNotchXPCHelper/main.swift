//
//  main.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import Security

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    
    /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // The helper can resume authenticated sessions; only accept our own signed app.
        guard newConnection.effectiveUserIdentifier == getuid() else { return false }
        var guest: SecCode?
        var own: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: newConnection.processIdentifier] as CFDictionary, [], &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, [], nil) == errSecSuccess,
              SecCodeCopySelf([], &own) == errSecSuccess, let own else { return false }
        var guestInfo: CFDictionary?
        var ownInfo: CFDictionary?
        var guestStatic: SecStaticCode?
        var ownStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &guestStatic) == errSecSuccess, let guestStatic,
              SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
              SecCodeCopySigningInformation(guestStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &guestInfo) == errSecSuccess,
              SecCodeCopySigningInformation(ownStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &ownInfo) == errSecSuccess,
              let peer = guestInfo as? [String: Any], let selfInfo = ownInfo as? [String: Any],
              peer[kSecCodeInfoIdentifier as String] as? String == "com.notchharbor.app",
              let team = selfInfo[kSecCodeInfoTeamIdentifier as String] as? String,
              peer[kSecCodeInfoTeamIdentifier as String] as? String == team else { return false }
        
        // Configure the connection.
        // First, set the interface that the exported object implements.
        newConnection.exportedInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)
        
        // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
        let exportedObject = BoringNotchXPCHelper()
        newConnection.exportedObject = exportedObject
        
        // Resuming the connection allows the system to deliver more incoming messages.
        newConnection.resume()
        
        // Returning true from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call invalidate() on the connection and return false.
        return true
    }
}

// Create the delegate for the service.
let delegate = ServiceDelegate()

// Set up the one NSXPCListener for this service. It will handle all incoming connections.
let listener = NSXPCListener.service()
listener.delegate = delegate

// Resuming the serviceListener starts this service. This method does not return.
listener.resume()
