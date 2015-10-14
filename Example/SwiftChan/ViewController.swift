//
//  ViewController.swift
//  SwiftChan
//
//  Created by Wilhelmina Drengwitz on 09/01/2015.
//  Copyright (c) 2015 Wilhelmina Drengwitz. All rights reserved.
//

import UIKit
import SwiftChan

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
		let app = <-applicationCh

		ASyncRecv { (name) in
			print(name)
		} <- applicationNameCh
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

}

