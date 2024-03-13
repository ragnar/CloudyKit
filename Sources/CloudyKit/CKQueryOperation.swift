//
//  CKQueryOperation.swift
//
//
//  Created by Ragnar Henriksen on 25/02/2024.
//

import Foundation

public class CKQueryOperation {
    public class Cursor {
        internal let continuationMarker: String

        public init(continuationMarker: String) {
            self.continuationMarker = continuationMarker
        }
    }

    public static let maximumResults: Int = 200

    public var query: CKQuery?
    public var cursor: CKQueryOperation.Cursor?
    public var desiredKeys: [CKRecord.FieldKey]?

    public convenience init(query: CKQuery) {
        self.init()
        self.query = query
    }

    public convenience init(cursor: CKQueryOperation.Cursor) {
        self.init()
        self.cursor = cursor
    }
}
