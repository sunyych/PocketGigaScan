import Flutter
import Darwin
import UIKit
import XCTest

class RunnerTests: XCTestCase {

  func testLinkedPanoramaCoreExportsItsSupportedAbi() {
    guard
      let abiSymbol = dlsym(nil, "lumia_gigascan_abi_version"),
      let availabilitySymbol = dlsym(nil, "lumia_gigascan_is_available")
    else {
      XCTFail("The linked Runner executable is missing one or more NativeJobApi ABI exports.")
      return
    }
    guard
      dlsym(nil, "lumia_gigascan_job_json") != nil,
      dlsym(nil, "lumia_gigascan_free") != nil
    else {
      XCTFail("The linked Runner executable is missing NativeJobApi job/free exports.")
      return
    }

    let abiVersion = unsafeBitCast(abiSymbol, to: (@convention(c) () -> UInt32).self)
    let isAvailable = unsafeBitCast(availabilitySymbol, to: (@convention(c) () -> UInt32).self)
    XCTAssertEqual(abiVersion(), 1)
    XCTAssertEqual(isAvailable(), 1)
  }

}
