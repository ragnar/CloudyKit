//
//  CKDatabase.swift
//  
//
//  Created by Camden on 12/21/20.
//

import Foundation
#if os(Linux)
import FoundationNetworking
import OpenCombine
#else
import Combine
#endif

public class CKDatabase {
    
    public enum Scope: Int {
        case `public` = 1
        case `private` = 2
        case shared = 3
    }
    
    public let databaseScope: Scope
    
    internal let containerIdentifier: String
    
    internal init(containerIdentifier: String, databaseScope: Scope) {
        self.containerIdentifier = containerIdentifier
        self.databaseScope = databaseScope
    }
    
    var cancelable: AnyCancellable? = nil
    
    public func save(_ record: CKRecord, completionHandler: @escaping (CKRecord?, Error?) -> Void) {        
//        let assetFieldDictionarys: [CKWSAssetFieldDictionary] = record.fields.compactMap { fieldName, value in
//            guard value is CKAsset else {
//                return nil
//            }
//            return CKWSAssetFieldDictionary(recordName: record.recordID.recordName,
//                                            recordType: record.recordType,
//                                            fieldName: fieldName)
//        }
//        if assetFieldDictionarys.count > 0 {
//            let tokenRequest = CKWSAssetTokenRequest(tokens: assetFieldDictionarys)
//            let task = CloudyKitConfig.urlSession.requestAssetTokenTask(database: self, environment: CloudyKitConfig.environment, tokenRequest: tokenRequest) { (tokenResponse, error) in
//                // TODO:
//            }
//            task.resume()
//        }
        let task = CloudyKitConfig.urlSession.saveTask(database: self,
                                                       environment: CloudyKitConfig.environment,
                                                       record: record,
                                                       completionHandler: completionHandler)
        task.resume()
    }
    
    public func fetch(withRecordID recordID: CKRecord.ID, completionHandler: @escaping (CKRecord?, Error?) -> Void) {
        let task = CloudyKitConfig.urlSession.fetchTask(database: self,
                                                        environment: CloudyKitConfig.environment,
                                                        recordID: recordID,
                                                        completionHandler: completionHandler)
        task.resume()
    }
    
    public func delete(withRecordID recordID: CKRecord.ID, completionHandler: @escaping (CKRecord.ID?, Error?) -> Void) {
        self.cancelable = CloudyKitConfig.urlSession.deleteTaskPublisher(database: self, environment: CloudyKitConfig.environment, recordID: recordID)
            .tryMap { output in
                // TODO: Handle error better
                guard let response = output.response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw CKError(code: .internalError)
                }
                return output.data
            }
            .decode(type: CKWSRecordResponse.self, decoder: CloudyKitConfig.decoder)
            .sink(receiveCompletion: { completion in
                switch completion {
                case .finished:
                    break
                case .failure(let error):
                    completionHandler(nil, error)
                }
            }, receiveValue: { response in
                guard let responseRecord = response.records.first else {
                    completionHandler(nil, CKError(code: .internalError))
                    return
                }
                let recordID = CKRecord.ID(recordName: responseRecord.recordName)
                completionHandler(recordID, nil)
            })
    }
}

extension CKDatabase.Scope: CustomStringConvertible {
    public var description: String {
        switch self {
        case .private: return "private"
        case .public: return "public"
        case .shared: return "shared"
        }
    }
}
