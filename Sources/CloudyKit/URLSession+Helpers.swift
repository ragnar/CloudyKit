//
//  URLSession+Helpers.swift
//  
//
//  Created by Camden on 12/21/20.
//

import Foundation
#if os(Linux)
import FoundationNetworking
import OpenCombine
import OpenCombineFoundation
#else
import Combine
#endif

enum NetworkSessionError: Error {
    case unableToHandle(value: String, type: String)
}

internal protocol NetworkSession {
    func internalDataTask(with request: URLRequest, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> NetworkSessionDataTask
    func internalDataTaskPublisher(for request: URLRequest) -> AnyPublisher<(data: Data, response: URLResponse), Error>
}

internal protocol NetworkSessionDataTask {
    func resume()
}

extension URLSession: NetworkSession {
    func internalDataTask(with request: URLRequest, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> NetworkSessionDataTask {
        return self.dataTask(with: request, completionHandler: completionHandler)
    }
    
    func internalDataTaskPublisher(for request: URLRequest) -> AnyPublisher<(data: Data, response: URLResponse), Error> {
        return self.dataTaskPublisher(for: request)
            .mapError { $0 as Error }
            .eraseToAnyPublisher()
    }
}

extension URLSessionDataTask: NetworkSessionDataTask { }

extension NetworkSession {
    internal func successfulDataTaskPublisher(for request: URLRequest) -> AnyPublisher<Data, Error> {
        return self.internalDataTaskPublisher(for: request)
            .tryMap { output in
                guard let response = output.response as? HTTPURLResponse else {
                    throw CKError(code: .internalError, userInfo: [:])
                }
                if CloudyKitConfig.debug {
                    print("=== CloudKit Web Services Request ===")
                    print("URL: \(request.url?.absoluteString ?? "no url")")
                    print("Method: \(request.httpMethod ?? "no method")")
                    print("Data:")
                    print("\(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "no data")")
                    print("======================================")
                    print("=== CloudKit Web Services Response ===")
                    print("Status Code: \(response.statusCode)")
                    print("Data:")
                    print("\(String(data: output.data, encoding: .utf8) ?? "invalid data")")
                    print("======================================")
                }
                if let ckwsError = try? CloudyKitConfig.decoder.decode(CKWSErrorResponse.self, from: output.data) {
                    if CloudyKitConfig.debug {
                        print("error: \(ckwsError)")
                    }
                    throw ckwsError.ckError
                }
                guard response.statusCode == 200 else {
                    throw CKError(code: .internalError, userInfo: [:])
                }
                return output.data
            }.eraseToAnyPublisher()
    }
    
    internal func recordTaskPublisher(for request: URLRequest) -> AnyPublisher<[(CKRecord.ID, Result<CKRecord, Error>)], Error> {
        return self.successfulDataTaskPublisher(for: request)
            .decode(type: CKWSRecordResponse.self, decoder: CloudyKitConfig.decoder)
            .tryMap { response in
                var result = [(CKRecord.ID, Result<CKRecord, Error>)]()

                for responseRecord in response.records {
                    guard let record = CKRecord(ckwsRecordResponse: responseRecord) else {
                        continue
                    }

                    if let errorCode = responseRecord.serverErrorCode {
                        if errorCode == "NOT_FOUND" {
                            result.append((record.recordID, .failure(CKError(code: .unknownItem, userInfo: [:]))))
                        } else {
                            result.append((record.recordID, .failure(CKError(code: .internalError, userInfo: [:]))))
                        }
                    } else {
                        result.append((record.recordID, .success(record)))
                    }
                }
                return result
            }.eraseToAnyPublisher()
    }
    
    internal func queryTaskPublisher(for request: URLRequest) -> AnyPublisher<(matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?), Error> {
        return self.successfulDataTaskPublisher(for: request)
            .decode(type: CKWSRecordResponse.self, decoder: CloudyKitConfig.decoder)
            .tryMap { response in
                var records = [(CKRecord.ID, Result<CKRecord, Error>)]()

                for responseRecord in response.records {
                    guard let record = CKRecord(ckwsRecordResponse: responseRecord) else {
                        continue
                    }

                    if let errorCode = responseRecord.serverErrorCode {
                        if errorCode == "NOT_FOUND" {
                            records.append((record.recordID, .failure(CKError(code: .unknownItem, userInfo: [:]))))
                        } else {
                            records.append((record.recordID, .failure(CKError(code: .internalError, userInfo: [:]))))
                        }
                    } else {
                        records.append((record.recordID, .success(record)))
                    }
                }

                let cursor: CKQueryOperation.Cursor? = response.continuationMarker.flatMap { CKQueryOperation.Cursor(continuationMarker: $0) }
                let result: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?) = (records, cursor)

                return result
            }
            .eraseToAnyPublisher()
    }

    internal func saveTaskPublisher(database: CKDatabase, environment: CloudyKitConfig.Environment, operationType: CKWSRecordOperation.OperationType? = nil, record: CKRecord, assetUploadResponses: [(String, CKWSAssetUploadResponse)] = []) -> AnyPublisher<CKRecord, Error> {
        let now = Date()
        let path = "/database/1/\(database.containerIdentifier)/\(environment.rawValue)/\(database.databaseScope.description)/records/modify"
        var request = URLRequest(url: URL(string: "\(CloudyKitConfig.host)\(path)")!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(CloudyKitConfig.serverKeyID, forHTTPHeaderField: "X-Apple-CloudKit-Request-KeyID")
        request.addValue(CloudyKitConfig.dateFormatter.string(from: now), forHTTPHeaderField: "X-Apple-CloudKit-Request-ISO8601Date")
        
        var fields: [String:CKWSRecordFieldValue] = [:]
        for (fieldName, value) in record.fields {
            switch value {
            case let value as Int:
                fields[fieldName] = CKWSRecordFieldValue(value: .number(value), type: nil)
            case let value as String:
                fields[fieldName] = CKWSRecordFieldValue(value: .string(value), type: nil)
            case let value as Array<String>:
                fields[fieldName] = CKWSRecordFieldValue(value: .stringList(value), type: nil)
            case _ as CKAsset:
                guard let dictionary = assetUploadResponses.first(where: { $0.0 == fieldName })?.1.singleFile else {
                    if CloudyKitConfig.debug {
                        print("unable to locate asset upload response for \"\(fieldName)\"")
                    }
                    continue
                }
                fields[fieldName] = CKWSRecordFieldValue(value: .asset(dictionary), type: nil)
            case _ as Array<CKAsset>:
                let dictionaries = assetUploadResponses.filter({ $0.0 == fieldName })
                    .map { $0.1.singleFile }
                fields[fieldName] = CKWSRecordFieldValue(value: .assetList(dictionaries), type: nil)
            case let value as Data:
                fields[fieldName] = CKWSRecordFieldValue(value: .bytes(value), type: nil)
            case let value as Array<Data>:
                fields[fieldName] = CKWSRecordFieldValue(value: .bytesList(value), type: nil)
            case let value as Date:
                fields[fieldName] = CKWSRecordFieldValue(value: .dateTime(Int(value.timeIntervalSince1970 * 1000)), type: nil)
            case let value as Double:
                fields[fieldName] = CKWSRecordFieldValue(value: .double(value), type: nil)
            case let value as CKRecord.Reference:
                let dict = CKWSReferenceDictionary(recordName: value.recordID.recordName, action: value.action.stringValue)
                fields[fieldName] = CKWSRecordFieldValue(value: .reference(dict), type: nil)
            case let value as Array<CKRecord.Reference>:
                let dictionaries = value.map { CKWSReferenceDictionary(recordName: $0.recordID.recordName, action: $0.action.stringValue) }
                fields[fieldName] = CKWSRecordFieldValue(value: .referenceList(dictionaries), type: nil)
            default:
                return Fail(error: NetworkSessionError.unableToHandle(
                    value: "\(value)",
                    type: "\(type(of: value))")
                ).eraseToAnyPublisher()
            }
        }
        let recordDictionary = CKWSRecordDictionary(recordName: record.recordID.recordName,
                                                    recordType: record.recordType,
                                                    recordChangeTag: record.recordChangeTag,
                                                    fields: fields,
                                                    created: nil,
                                                    serverErrorCode: nil,
                                                    reason: nil)
        let operationType: CKWSRecordOperation.OperationType = operationType ?? (record.creationDate == nil ? .create : .update)
        let operation = CKWSRecordOperation(operationType: operationType,
                                            desiredKeys: nil,
                                            record: recordDictionary)
        let modifyRequest = CKWSModifyRecordRequest(operations: [operation])
        if let data = try? CloudyKitConfig.encoder.encode(modifyRequest), let privateKey = CloudyKitConfig.serverPrivateKey {
            let signature = CKRequestSignature(data: data, date: now, path: path, privateKey: privateKey)
            if let signatureValue = try? signature.sign() {
                request.addValue(signatureValue, forHTTPHeaderField: "X-Apple-CloudKit-Request-SignatureV1")
            }
            request.httpBody = data
        }

        let cancellable = self.recordTaskPublisher(for: request)
            .tryMap { result -> CKRecord in
                guard 
                    let first = result.first?.1,
                    let value = try? first.get()
                else {
                    throw CKError(code: CKError.Code.internalError, userInfo: [:])
                }

                return value
            }
            .eraseToAnyPublisher()

        return cancellable
    }

    func saveTaskPublisher(database: CKDatabase, environment: CloudyKitConfig.Environment, operationType: CKWSRecordOperation.OperationType? = nil, records: [CKRecord], assetUploadResponses: [(String, CKWSAssetUploadResponse)] = []) -> AnyPublisher<[(CKRecord.ID, Result<CKRecord, Error>)], Error> {
        let now = Date()
        let path = "/database/1/\(database.containerIdentifier)/\(environment.rawValue)/\(database.databaseScope.description)/records/modify"
        var request = URLRequest(url: URL(string: "\(CloudyKitConfig.host)\(path)")!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(CloudyKitConfig.serverKeyID, forHTTPHeaderField: "X-Apple-CloudKit-Request-KeyID")
        request.addValue(CloudyKitConfig.dateFormatter.string(from: now), forHTTPHeaderField: "X-Apple-CloudKit-Request-ISO8601Date")

        var operations = [CKWSRecordOperation]()

        for record in records {
            var fields: [String: CKWSRecordFieldValue] = [:]

            for (fieldName, value) in record.fields {
                switch value {
                case let value as Int:
                    fields[fieldName] = CKWSRecordFieldValue(value: .number(value), type: nil)
                case let value as String:
                    fields[fieldName] = CKWSRecordFieldValue(value: .string(value), type: nil)
                case let value as [String]:
                    fields[fieldName] = CKWSRecordFieldValue(value: .stringList(value), type: nil)
                case _ as CKAsset:
                    guard let dictionary = assetUploadResponses.first(where: { $0.0 == fieldName })?.1.singleFile else {
                        if CloudyKitConfig.debug {
                            print("unable to locate asset upload response for \"\(fieldName)\"")
                        }
                        continue
                    }
                    fields[fieldName] = CKWSRecordFieldValue(value: .asset(dictionary), type: nil)
                case _ as [CKAsset]:
                    let dictionaries = assetUploadResponses.filter { $0.0 == fieldName }
                        .map { $0.1.singleFile }
                    fields[fieldName] = CKWSRecordFieldValue(value: .assetList(dictionaries), type: nil)
                case let value as Data:
                    fields[fieldName] = CKWSRecordFieldValue(value: .bytes(value), type: nil)
                case let value as [Data]:
                    fields[fieldName] = CKWSRecordFieldValue(value: .bytesList(value), type: nil)
                case let value as Date:
                    fields[fieldName] = CKWSRecordFieldValue(value: .dateTime(Int(value.timeIntervalSince1970 * 1000)), type: nil)
                case let value as Double:
                    fields[fieldName] = CKWSRecordFieldValue(value: .double(value), type: nil)
                case let value as CKRecord.Reference:
                    let dict = CKWSReferenceDictionary(recordName: value.recordID.recordName, action: value.action.stringValue)
                    fields[fieldName] = CKWSRecordFieldValue(value: .reference(dict), type: nil)
                case let value as [CKRecord.Reference]:
                    let dictionaries = value.map { CKWSReferenceDictionary(recordName: $0.recordID.recordName, action: $0.action.stringValue) }
                    fields[fieldName] = CKWSRecordFieldValue(value: .referenceList(dictionaries), type: nil)
                default:
                    return Fail(error: NetworkSessionError.unableToHandle(
                        value: "\(value)",
                        type: "\(type(of: value))"
                    )
                    ).eraseToAnyPublisher()
                }
            }
            let recordDictionary = CKWSRecordDictionary(recordName: record.recordID.recordName,
                                                        recordType: record.recordType,
                                                        recordChangeTag: record.recordChangeTag,
                                                        fields: fields,
                                                        created: nil,
                                                        serverErrorCode: nil,
                                                        reason: nil)
            let operationType: CKWSRecordOperation.OperationType = operationType ?? (record.creationDate == nil ? .create : .update)
            let operation = CKWSRecordOperation(operationType: operationType,
                                                desiredKeys: nil,
                                                record: recordDictionary)

            operations.append(operation)
        }

        let modifyRequest = CKWSModifyRecordRequest(operations: operations)

        if let data = try? CloudyKitConfig.encoder.encode(modifyRequest), let privateKey = CloudyKitConfig.serverPrivateKey {
            let signature = CKRequestSignature(data: data, date: now, path: path, privateKey: privateKey)
            if let signatureValue = try? signature.sign() {
                request.addValue(signatureValue, forHTTPHeaderField: "X-Apple-CloudKit-Request-SignatureV1")
            }
            request.httpBody = data
        }
        return recordTaskPublisher(for: request)
    }

    func fetchTaskPublisher(database: CKDatabase, environment: CloudyKitConfig.Environment, recordID: CKRecord.ID) -> AnyPublisher<CKRecord, Error> {
        let now = Date()
        let path = "/database/1/\(database.containerIdentifier)/\(environment.rawValue)/\(database.databaseScope.description)/records/lookup"
        var request = URLRequest(url: URL(string: "\(CloudyKitConfig.host)\(path)")!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(CloudyKitConfig.serverKeyID, forHTTPHeaderField: "X-Apple-CloudKit-Request-KeyID")
        request.addValue(CloudyKitConfig.dateFormatter.string(from: now), forHTTPHeaderField: "X-Apple-CloudKit-Request-ISO8601Date")
        let records = [
            CKWSLookupRecordDictionary(recordName: recordID.recordName)
        ]
        let fetchRequest = CKWSFetchRecordRequest(records: records)
        if let data = try? CloudyKitConfig.encoder.encode(fetchRequest), let privateKey = CloudyKitConfig.serverPrivateKey {
            let signature = CKRequestSignature(data: data, date: now, path: path, privateKey: privateKey)
            if let signatureValue = try? signature.sign() {
                request.addValue(signatureValue, forHTTPHeaderField: "X-Apple-CloudKit-Request-SignatureV1")
            }
            request.httpBody = data
        }

        let cancellable = self.recordTaskPublisher(for: request)
            .tryMap { result -> CKRecord in
                guard
                    let first = result.first?.1,
                    let value = try? first.get()
                else {
                    throw CKError(code: CKError.Code.internalError, userInfo: [:])
                }

                return value
            }
            .eraseToAnyPublisher()

        return cancellable
    }

    internal func queryTaskPublisher(
        database: CKDatabase,
        environment: CloudyKitConfig.Environment,
        query: CKQuery,
        cursor: CKQueryOperation.Cursor? = nil,
        zoneID: CKRecordZone.ID?,
        desiredKeys: [CKRecord.FieldKey]? = nil,
        resultsLimit: Int = CKQueryOperation.maximumResults
    ) -> AnyPublisher<(matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?), Error> {
        do {
            let now = Date()
            let path = "/database/1/\(database.containerIdentifier)/\(environment.rawValue)/\(database.databaseScope.description)/records/query"
            var request = URLRequest(url: URL(string: "\(CloudyKitConfig.host)\(path)")!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue(CloudyKitConfig.serverKeyID, forHTTPHeaderField: "X-Apple-CloudKit-Request-KeyID")
            request.addValue(CloudyKitConfig.dateFormatter.string(from: now), forHTTPHeaderField: "X-Apple-CloudKit-Request-ISO8601Date")
            
            var zoneIDDict: CKWSZoneIDDictionary? = nil
            
            if let zoneID = zoneID {
                zoneIDDict = CKWSZoneIDDictionary(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
            }
            
            let filterBy = query.predicate.filterBy
            let sortBy = query.sortDescriptors?.compactMap { CKWSSortDescriptorDictionary(fieldName: $0.key, ascending: $0.ascending) }
            let queryDict = try CKWSQueryDictionary(recordType: query.recordType, filterBy: filterBy(), sortBy: sortBy)
            let queryRequest = CKWSQueryRequest(zoneID: zoneIDDict, resultsLimit: resultsLimit, query: queryDict, continuationMarker: cursor?.continuationMarker, desiredKeys: desiredKeys)

            if let data = try? CloudyKitConfig.encoder.encode(queryRequest), let privateKey = CloudyKitConfig.serverPrivateKey {
                let signature = CKRequestSignature(data: data, date: now, path: path, privateKey: privateKey)
            
                if let signatureValue = try? signature.sign() {
                    request.addValue(signatureValue, forHTTPHeaderField: "X-Apple-CloudKit-Request-SignatureV1")
                }
                
                request.httpBody = data
            }

            return self.queryTaskPublisher(for: request)
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }
    }

    internal func deleteTaskPublisher(database: CKDatabase, environment: CloudyKitConfig.Environment, recordIDs: [CKRecord.ID], operationType: CKWSRecordOperation.OperationType? = nil) -> AnyPublisher<[(CKRecord.ID, Result<Void, Error>)], Error> {// AnyPublisher<CKWSRecordResponse, Error> {
        let now = Date()
        let path = "/database/1/\(database.containerIdentifier)/\(environment.rawValue)/\(database.databaseScope.description)/records/modify"
        var request = URLRequest(url: URL(string: "\(CloudyKitConfig.host)\(path)")!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(CloudyKitConfig.serverKeyID, forHTTPHeaderField: "X-Apple-CloudKit-Request-KeyID")
        request.addValue(CloudyKitConfig.dateFormatter.string(from: now), forHTTPHeaderField: "X-Apple-CloudKit-Request-ISO8601Date")

        let operations = recordIDs.map { recordID in
            let recordDictionary = CKWSRecordDictionary(recordName: recordID.recordName,
                                                        recordType: nil,
                                                        recordChangeTag: nil,
                                                        fields: nil,
                                                        created: nil,
                                                        serverErrorCode: nil,
                                                        reason: nil)
            let operationType: CKWSRecordOperation.OperationType = operationType ?? .forceDelete
            let operation = CKWSRecordOperation(operationType: operationType,
                                                desiredKeys: nil,
                                                record: recordDictionary)

            return operation
        }

        let modifyRequest = CKWSModifyRecordRequest(operations: operations)

        if let data = try? CloudyKitConfig.encoder.encode(modifyRequest), let privateKey = CloudyKitConfig.serverPrivateKey {
            let signature = CKRequestSignature(data: data, date: now, path: path, privateKey: privateKey)
            if let signatureValue = try? signature.sign() {
                request.addValue(signatureValue, forHTTPHeaderField: "X-Apple-CloudKit-Request-SignatureV1")
            }
            request.httpBody = data
        }
        return self.successfulDataTaskPublisher(for: request)
            .decode(type: CKWSRecordResponse.self, decoder: CloudyKitConfig.decoder)
            .tryMap { response in
                var result = [(CKRecord.ID, Result<Void, Error>)]()

                for record in response.records {
                    let recordID = CKRecord.ID(recordName: record.recordName)

                    if let errorCode = record.serverErrorCode {
                        if errorCode == "NOT_FOUND" {
                            result.append((recordID, .failure(CKError(code: .unknownItem, userInfo: [:]))))
                        } else {
                            result.append((recordID, .failure(CKError(code: .internalError, userInfo: [:]))))
                        }
                    } else {
                        result.append((recordID, .success(Void())))
                    }
                }

                return result
            }
            .eraseToAnyPublisher()
    }

    internal func requestAssetTokenTaskPublisher(database: CKDatabase, environment: CloudyKitConfig.Environment, tokenRequest: CKWSAssetTokenRequest) -> AnyPublisher<Data, Error> {
        let now = Date()
        let path = "/database/1/\(database.containerIdentifier)/\(environment.rawValue)/\(database.databaseScope.description)/assets/upload"
        var request = URLRequest(url: URL(string: "\(CloudyKitConfig.host)\(path)")!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(CloudyKitConfig.serverKeyID, forHTTPHeaderField: "X-Apple-CloudKit-Request-KeyID")
        request.addValue(CloudyKitConfig.dateFormatter.string(from: now), forHTTPHeaderField: "X-Apple-CloudKit-Request-ISO8601Date")
        if let data = try? CloudyKitConfig.encoder.encode(tokenRequest), let privateKey = CloudyKitConfig.serverPrivateKey {
            let signature = CKRequestSignature(data: data, date: now, path: path, privateKey: privateKey)
            if let signatureValue = try? signature.sign() {
                request.addValue(signatureValue, forHTTPHeaderField: "X-Apple-CloudKit-Request-SignatureV1")
            }
            request.httpBody = data
        }
        return self.successfulDataTaskPublisher(for: request)
    }
}

extension CKRecord {
    
    convenience init?(ckwsRecordResponse: CKWSRecordDictionary) {
        guard let recordType = ckwsRecordResponse.recordType,
              let createdTimestamp = ckwsRecordResponse.created?.timestamp else {
            return nil
        }
        let id = CKRecord.ID(recordName: ckwsRecordResponse.recordName)
        self.init(recordType: recordType, recordID: id)
        self.creationDate = Date(timeIntervalSince1970: TimeInterval(createdTimestamp) / 1000)
        self.recordChangeTag = ckwsRecordResponse.recordChangeTag
        self.fields = [:]
        for (fieldName, fieldValue) in ckwsRecordResponse.fields ?? [:] {
            switch fieldValue.value {
            case .string(let value): self.fields[fieldName] = value
            case .number(let value): self.fields[fieldName] = value
            case .asset(let value):
                guard let downloadURL = value.downloadURL, let fileURL = URL(string: downloadURL.replacingOccurrences(of: "${f}", with: value.fileChecksum)) else {
                    return nil
                }
                self.fields[fieldName] = CKAsset(fileURL: fileURL)
            case .assetList(let value):
                var assets: [CKAsset] = []
                for dict in value {
                    guard let downloadURL = dict.downloadURL, let fileURL = URL(string: downloadURL.replacingOccurrences(of: "${f}", with: dict.fileChecksum)) else {
                        return nil
                    }
                    assets.append(CKAsset(fileURL: fileURL))
                }
                self.fields[fieldName] = assets
            case .bytes(let value):
                self.fields[fieldName] = value
            case .bytesList(let value):
                self.fields[fieldName] = value
            case .double(let value):
                self.fields[fieldName] = value
            case .reference(let value):
                let recordID = CKRecord.ID(recordName: value.recordName)
                let action = CKRecord.Reference.Action(string: value.action)
                let reference = CKRecord.Reference(recordID: recordID, action: action)
                self.fields[fieldName] = reference
            case .dateTime(let value):
                self.fields[fieldName] = Date(timeIntervalSince1970: TimeInterval(value) / 1000)
            case .stringList(let value):
                self.fields[fieldName] = value
            case .referenceList(let value):
                let references = value.map { dict -> CKRecord.Reference in
                    let recordID = CKRecord.ID(recordName: dict.recordName)
                    let action = CKRecord.Reference.Action(string: dict.action)
                    let reference = CKRecord.Reference(recordID: recordID, action: action)
                    return reference
                }
                self.fields[fieldName] = references
            }
        }
    }
    
}
