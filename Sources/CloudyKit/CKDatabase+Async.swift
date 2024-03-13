//
//  CKDatabase+Async.swift
//
//
//  Created by Diego Trevisan on 12.12.23.
//

extension CKDatabase {
    public func save(_ record: CKRecord, operationType: CKWSRecordOperation.OperationType? = nil) async throws -> CKRecord? {
        try await withCheckedThrowingContinuation { continuation in
            save(record, operationType: operationType) { record, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: record)
                }
            }
        }
    }

    public func fetch(withRecordID recordID: CKRecord.ID) async throws -> CKRecord? {
        try await withCheckedThrowingContinuation { continuation in
            fetch(withRecordID: recordID) { record, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: record)
                }
            }
        }
    }

    public func delete(withRecordID recordID: CKRecord.ID, operationType: CKWSRecordOperation.OperationType? = nil) async throws -> CKRecord.ID? {
        try await withCheckedThrowingContinuation { continuation in
            delete(withRecordID: recordID, operationType: operationType) { recordID, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: recordID)
                }
            }
        }
    }

    public func perform(_ query: CKQuery, inZoneWith zoneID: CKRecordZone.ID?) async throws -> [CKRecord]? {
        try await withCheckedThrowingContinuation { continuation in
            perform(query, inZoneWith: zoneID) { records, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: records)
                }
            }
        }
    }

    public func records(matching query: CKQuery, inZoneWith zoneID: CKRecordZone.ID? = nil, desiredKeys: [CKRecord.FieldKey]? = nil, resultsLimit: Int = CKQueryOperation.maximumResults) async throws -> (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { contiunation in
            perform(query, inZoneWith: zoneID, desiredKeys: desiredKeys, resultsLimit: resultsLimit) { result in
                switch result {
                case .success(let result):
                    contiunation.resume(returning: result)
                case .failure(let error):
                    contiunation.resume(throwing: error)
                }
            }
        }
    }

    public func records(matching query: CKQuery, continuingMatchFrom queryCursor: CKQueryOperation.Cursor, desiredKeys: [CKRecord.FieldKey]? = nil, resultsLimit: Int = CKQueryOperation.maximumResults) async throws -> (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { contiunation in
            fetch(query, withCursor: queryCursor, desiredKeys: desiredKeys, resultsLimit: resultsLimit) { result in
                switch result {
                case .success(let result):
                    contiunation.resume(returning: result)
                case .failure(let error):
                    contiunation.resume(throwing: error)
                }
            }
        }
    }

    public func modifyRecords(saving recordsToSave: [CKRecord]) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        try await withCheckedThrowingContinuation { contiunation in
            save(records: recordsToSave, operationType: .forceUpdate) { result in
                switch result {
                case .success(let values):
                    contiunation.resume(returning: Dictionary(values) { $1 })
                case .failure(let failure):
                    contiunation.resume(throwing: failure)
                }
            }
        }
    }

    public func modifyRecords(deleting recordsToDelete: [CKRecord.ID]) async throws -> [CKRecord.ID : Result<Void, Error>] {
        try await withCheckedThrowingContinuation { contiunation in
            delete(withRecordIDs: recordsToDelete, operationType: .forceDelete) { result in
                switch result {
                case .success(let values):
                    contiunation.resume(returning: Dictionary(values) { $1 })
                case .failure(let failure):
                    contiunation.resume(throwing: failure)
                }
            }
        }
    }
}
