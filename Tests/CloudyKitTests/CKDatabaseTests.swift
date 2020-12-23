//
//  CKDatabaseTests.swift
//  
//
//  Created by Camden on 12/21/20.
//

import XCTest
#if os(Linux)
import FoundationNetworking
#endif
@testable import CloudyKit
import Cryptor
import CryptorECC

final class CKDatabaseTests: XCTestCase {
    
    var mockedSession: MockedNetworkSession? = nil
    
    override func setUp() {
        let session = MockedNetworkSession()
        CloudyKitConfig.urlSession = session
        CloudyKitConfig.serverKeyID = "1234567890"
        if let data = try? Data.loadAsset(name: "eckey.pem"), let key = String(data: data, encoding: .utf8) {
            CloudyKitConfig.serverPrivateKey = try? ECPrivateKey(key: key)
        }
        self.mockedSession = session
    }
    
    func testSaveNewRecord() {
        let response = """
{
        "records": [
            {
                "recordName": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
                "recordType": "Users",
                "recordChangeTag": "\(UUID().uuidString)",
                "created": {
                    "timestamp": \(Int(Date().timeIntervalSince1970 * 1000))
                },
                "fields": {
                    "firstName" : {"value" : "Mei"},
                    "lastName" : {"value" : "Chen"},
                    "width": {"value": 18},
                    "height": {"value": 24}
                }
            }
        ]
}
"""
        self.mockedSession?.mockedResponse = HTTPURLResponse(url: URL(string: "https://apple.com")!, statusCode: 200, httpVersion: nil, headerFields: [:])
        self.mockedSession?.mockedData = response.data(using: .utf8)
        
        let container = CKContainer(identifier: "iCloud.com.example.myexampleapp")
        let database = container.publicDatabase
        let record = CloudyKit.CKRecord(recordType: "Users")
        record["firstName"] = "Mei"
        record["lastName"] = "Chen"
        record["width"] = 18
        record["height"] = 24
        XCTAssertNil(record.creationDate)
        let expectation = self.expectation(description: "completion handler called")
        database.save(record) { (record, error) in
            XCTAssertEqual("POST", self.mockedSession?.request?.httpMethod)
            XCTAssertNotNil(self.mockedSession?.request?.httpBody)
            XCTAssertEqual("1234567890", self.mockedSession?.request?.value(forHTTPHeaderField: "X-Apple-CloudKit-Request-KeyID"))
            XCTAssertNotNil(self.mockedSession?.request?.value(forHTTPHeaderField: "X-Apple-CloudKit-Request-SignatureV1"))
            XCTAssertNotNil(self.mockedSession?.request?.value(forHTTPHeaderField: "X-Apple-CloudKit-Request-ISO8601Date"))
            XCTAssertNil(error)
            XCTAssertNotNil(record)
            XCTAssertEqual("Users", record?.recordType)
            XCTAssertEqual("E621E1F8-C36C-495A-93FC-0C247A3E6E5F", record?.recordID.recordName)
            XCTAssertEqual("Mei", record?["firstName"] as? String)
            XCTAssertEqual("Chen", record?["lastName"] as? String)
            XCTAssertEqual(18, record?["width"] as? Int)
            XCTAssertEqual(24, record?["height"] as? Int)
            XCTAssertNotNil(record?.creationDate)
            expectation.fulfill()
        }
        self.wait(for: [expectation], timeout: 1)
    }

    static var allTests = [
        ("testSave", testSaveNewRecord),
    ]
}

