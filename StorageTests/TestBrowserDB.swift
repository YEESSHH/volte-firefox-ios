// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0

import Foundation
import Shared
@testable import Storage
@testable import Client
import XCGLogger

import XCTest

private let log = XCGLogger.default

class TestBrowserDB: XCTestCase {
    let files = MockFiles()

    fileprivate func rm(_ path: String) {
        do {
            try files.remove(path)
        } catch {
        }
    }

    override func setUp() {
        super.setUp()
        rm("foo.db")
        rm("foo.db-shm")
        rm("foo.db-wal")
        rm("foo.db.bak.1")
        rm("foo.db.bak.1-shm")
        rm("foo.db.bak.1-wal")
    }

    class MockFailingSchema: Schema {
        var name: String { return "FAILURE" }
        var version: Int { return BrowserSchema.DefaultVersion + 1 }
        func drop(_ db: SQLiteDBConnection) -> Bool {
            return true
        }
        func create(_ db: SQLiteDBConnection) -> Bool {
            return false
        }
        func update(_ db: SQLiteDBConnection, from: Int) -> Bool {
            return false
        }
    }

    fileprivate class MockListener {
        var notification: Notification?
        @objc
        func onDatabaseWasRecreated(_ notification: Notification) {
            self.notification = notification
        }
    }

    func testUpgradeV33toV34RemovesLongURLs() {
        let db = BrowserDB(filename: "v33.db", schema: BrowserSchema(), files: SupportingFiles())
        let results = db.runQuery("SELECT bmkUri, title FROM bookmarksLocal WHERE type = 1", args: nil, factory: { row in
            (row[0] as! String, row[1] as! String)
        }).value.successValue!

        // The bookmark with the long URL has been deleted.
        XCTAssertTrue(results.count == 1)

        let remaining = results[0]!

        // This one's title has been truncated to 4096 chars.
        XCTAssertEqual(remaining.1.count, 4096)
        XCTAssertEqual(remaining.1.utf8.count, 4096)
        XCTAssertTrue(remaining.1.hasPrefix("abcdefghijkl"))
        XCTAssertEqual(remaining.0, "http://example.com/short")
    }

    func testMovesDB() {
        var db = BrowserDB(filename: "foo.db", schema: BrowserSchema(), files: self.files)
        db.run("CREATE TABLE foo (bar TEXT)").succeeded() // Just so we have writes in the WAL.

        XCTAssertTrue(files.exists("foo.db"))
        XCTAssertTrue(files.exists("foo.db-shm"))
        XCTAssertTrue(files.exists("foo.db-wal"))

        // Grab a pointer to the -shm so we can compare later.
        let shmAAttributes = try! files.attributesForFileAt(relativePath: "foo.db-shm")
        let creationA = shmAAttributes[FileAttributeKey.creationDate] as! Date
        let inodeA = (shmAAttributes[FileAttributeKey.systemFileNumber] as! NSNumber).uintValue

        XCTAssertFalse(files.exists("foo.db.bak.1"))
        XCTAssertFalse(files.exists("foo.db.bak.1-shm"))
        XCTAssertFalse(files.exists("foo.db.bak.1-wal"))

        let center = NotificationCenter.default
        let listener = MockListener()
        center.addObserver(listener, selector: #selector(MockListener.onDatabaseWasRecreated), name: .DatabaseWasRecreated, object: nil)
        defer { center.removeObserver(listener) }

        // It'll still fail, but it moved our old DB.
        // Our current observation is that closing the DB deletes the .shm file and also
        // checkpoints the WAL.
        db.forceClose()

        db = BrowserDB(filename: "foo.db", schema: MockFailingSchema(), files: self.files)
        db.run("CREATE TABLE foo (bar TEXT)").failed() // This won't actually write since we'll get a failed connection
        db = BrowserDB(filename: "foo.db", schema: BrowserSchema(), files: self.files)
        db.run("CREATE TABLE foo (bar TEXT)").succeeded() // Just so we have writes in the WAL.

        XCTAssertTrue(files.exists("foo.db"))
        XCTAssertTrue(files.exists("foo.db-shm"))
        XCTAssertTrue(files.exists("foo.db-wal"))

        // But now it's been reopened, it's not the same -shm!
        let shmBAttributes = try! files.attributesForFileAt(relativePath: "foo.db-shm")
        let creationB = shmBAttributes[FileAttributeKey.creationDate] as! Date
        let inodeB = (shmBAttributes[FileAttributeKey.systemFileNumber] as! NSNumber).uintValue
        XCTAssertTrue(creationA.compare(creationB) != ComparisonResult.orderedDescending)
        XCTAssertNotEqual(inodeA, inodeB)

        XCTAssertTrue(files.exists("foo.db.bak.1"))
        XCTAssertFalse(files.exists("foo.db.bak.1-shm"))
        XCTAssertFalse(files.exists("foo.db.bak.1-wal"))

        // The right notification was issued.
        XCTAssertEqual("foo.db", (listener.notification?.object as? String))
    }

    func testConcurrentQueries() {
        let expectation = self.expectation(description: "Got all DB results")

        var db = BrowserDB(filename: "foo.db", schema: BrowserSchema(), files: self.files)
        db.run("CREATE TABLE foo (id INTEGER PRIMARY KEY AUTOINCREMENT, bar TEXT)").succeeded() // Just so we have writes in the WAL.

        _ = db.withConnection { connection -> Void in
            for i in 0..<1000 {
                let args: Args = ["bar \(i)"]
                try connection.executeChange("INSERT INTO foo (bar) VALUES (?)", withArgs: args)
            }
        }

        func fooBarFactory(_ row: SDRow) -> [String : Any] {
            var result: [String : Any] = [:]
            result["id"] = row["id"]
            result["bar"] = row["bar"]
            return result
        }

        let longQuery = db.runQuery("SELECT * FROM (SELECT * FROM (SELECT * FROM foo WHERE bar LIKE ?) WHERE bar LIKE ?) WHERE bar LIKE ?", args: ["%b%", "%a%", "%r%"], factory: fooBarFactory)
        let shortConcurrentQuery = db.runQueryConcurrently("SELECT * FROM foo LIMIT 1", args: nil, factory: fooBarFactory)

        var isLongQueryDone = false
        var isShortConcurrentQueryDone = false

        var longQueryRuntimeDuration: Timestamp = 0
        var shortConcurrentQueryRuntimeDuration: Timestamp = 0

        let longQueryStartTimestamp = Date.now()
        let longQueryResult = longQuery.bind { result -> Deferred<Maybe<[[String : Any]]>> in
            if let results = result.successValue?.asArray() {
                isLongQueryDone = true
                longQueryRuntimeDuration = Date.now() - longQueryStartTimestamp
                XCTAssertTrue(isShortConcurrentQueryDone)
                return deferMaybe(results)
            }

            return deferMaybe(DatabaseError(description: "Unable to execute long-running query"))
        }

        let shortConcurrentQueryStartTimestamp = Date.now()
        let shortConcurrentQueryResult = shortConcurrentQuery.bind { result -> Deferred<Maybe<[[String : Any]]>> in
            if let results = result.successValue?.asArray() {
                isShortConcurrentQueryDone = true
                shortConcurrentQueryRuntimeDuration = Date.now() - shortConcurrentQueryStartTimestamp
                XCTAssertFalse(isLongQueryDone)
                return deferMaybe(results)
            }

            return deferMaybe(DatabaseError(description: "Unable to execute concurrent short-running query"))
        }

        _ = all([longQueryResult, shortConcurrentQueryResult]).bind { results -> Success in
            XCTAssert(longQueryRuntimeDuration > shortConcurrentQueryRuntimeDuration, "Long query runtime duration should be greater than short concurrent query runtime duration")
            expectation.fulfill()
            return succeed()
        }

        waitForExpectations(timeout: 10, handler: nil)
    }
}
