//
//  MyWalletViewController.swift
//  TheDocument
//
//  Created by Scott Kacyn on 1/9/18.
//  Copyright © 2018 Refer To The Document. All rights reserved.
//

import UIKit

class MyWalletViewController: UIViewController {

    @IBOutlet weak var accountBalanceLabel: UILabel!
    @IBOutlet weak var depositButton: UIButton!
    @IBOutlet weak var withdrawButton: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        depositButton.layer.cornerRadius = 3.0
        withdrawButton.layer.cornerRadius = 3.0
        
        if let wallet = currentUser.wallet, let info = wallet["info"] as? [String: Any], let balance = info["balance"] as? [String: String] {
            let amount = balance["amount"] ?? "0.00"
            self.accountBalanceLabel.text = "$\(amount)"
        } else {
            self.accountBalanceLabel.text = "---"
        }

        getWallet()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    func getWallet() {
        print("Getting wallet...")
        API().getWallet { success in
            if success {
                print("Got wallet")
                DispatchQueue.main.async {
                    if let wallet = currentUser.wallet, let info = wallet["info"] as? [String: Any], let balance = info["balance"] as? [String: String] {
                        print("WALLET LOADED: \(wallet)")
                        let amount = balance["amount"] ?? "0.00"
                        self.accountBalanceLabel.text = "$\(amount)"
                    } else {
                        self.accountBalanceLabel.text = "$0.00"
                    }
                }
            } else {
                print("Error getting wallet")
            }
        }
    }
    
    @IBAction func depositFunds(_ sender: Any) {
    }
    
    @IBAction func withdrawFunds(_ sender: Any) {
        
    }
}