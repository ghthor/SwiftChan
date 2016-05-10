//
//  util.swift
//  SwiftChan
//
//  Created by Willa Drengwitz on 5/10/16.
//  Copyright © 2016 Eksdyne Research. All rights reserved.
//

import Foundation

protocol Unique {}

extension Unique {
	static var newUUID: String { return NSUUID().UUIDString }
	static var newURI: String  { return "org.eksdyne.\(self.dynamicType)/\(newUUID)" }
}
