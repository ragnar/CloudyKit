//
//  File.swift
//  
//
//  Created by Camden on 12/21/20.
//

import Foundation

@MainActor
public final class CKContainer: Sendable {
    public let containerIdentifier: String
    public let publicDatabase: CKDatabase
    
    public init(identifier containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        self.publicDatabase = CKDatabase(containerIdentifier: containerIdentifier, databaseScope: .public)
    }
    
}
