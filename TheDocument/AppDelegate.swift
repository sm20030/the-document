//
//  AppDelegate.swift
//  TheDocument
//


import UIKit
import UserNotifications
import Firebase
import FirebaseAuth
import Branch
import FacebookCore
import Ipify

import SwiftyBeaver
let log = SwiftyBeaver.self

var appDelegate = UIApplication.shared.delegate as! AppDelegate
var currentUser = TDUser()
var homeVC:HomeViewController? {
    return appDelegate.window?.rootViewController as? HomeViewController
}

let gcmMessageIDKey = "gcm.message_id"

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    var window: UIWindow?
    var justLogged = false
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        
        let console = ConsoleDestination()  // log to Xcode Console
        let file = FileDestination()  // log to default swiftybeaver.log file
        let cloud = SBPlatformDestination(appID: "89AgW5", appSecret: "rYsvf1jskVseeDujrutys76wi40u9ezy", encryptionKey: "FD14torking0v88mp2pnjtTbqeentcdk")
        
        console.format = "$DHH:mm:ss$d $L $M"
        
        log.addDestination(console)
        log.addDestination(file)
        log.addDestination(cloud)
        
        let barBtnAppearance = UIBarButtonItem.appearance()
        barBtnAppearance.tintColor = UIColor.white
        UIApplication.shared.statusBarStyle = .lightContent
        
        FirebaseApp.configure()
        Database.database().isPersistenceEnabled = true
        Auth.auth().addStateDidChangeListener() { self.authChanged(auth: $0, authUser: $1) }
        if !currentUser.isLogged { try? Auth.auth().signOut() }
        
        // [START set_messaging_delegate]
        Messaging.messaging().delegate = self
        // [END set_messaging_delegate]
        
        // Register for remote notifications. This shows a permission dialog on first run, to
        // show the dialog at a more appropriate time move this registration accordingly.
        // [START register_for_notifications]
        if #available(iOS 10.0, *) {
            // For iOS 10 display notification (sent via APNS)
            UNUserNotificationCenter.current().delegate = self
            
            let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
            UNUserNotificationCenter.current().requestAuthorization(
                options: authOptions,
                completionHandler: {_, _ in })
        } else {
            let settings: UIUserNotificationSettings =
                UIUserNotificationSettings(types: [.alert, .badge, .sound], categories: nil)
            application.registerUserNotificationSettings(settings)
        }
        
        application.registerForRemoteNotifications()
        // [END register_for_notifications]
        
        let branch: Branch = Branch.getInstance()
        branch.initSession(launchOptions: launchOptions, andRegisterDeepLinkHandler: { params, error in
            if error == nil && params?["+clicked_branch_link"] != nil && params?["userId"] != nil {
                // TDUser opened an invite link; if not yet friends, create the friend request
                let userId = params?["userId"] as! String
                let userName = params?["userName"] as? String ?? ""
                
                API().getInvitation(from: userId, name: userName)
            }
        })
        
        return true
    }
    
    // Respond to URI scheme links
    func application(_ application: UIApplication, open url: URL, sourceApplication: String?, annotation: Any) -> Bool {
        // pass the url to the handle deep link call
        Branch.getInstance().handleDeepLink(url);
        // do other deep link routing for the Facebook SDK, Pinterest SDK, etc
        return true
    }
    
    // Respond to Universal Links
    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([Any]?) -> Void) -> Bool {
        // pass the url to the handle deep link call
        Branch.getInstance().continue(userActivity)
        return true
    }
    
    func authChanged(auth: Auth, authUser: User?) -> Void {
        guard !justLogged else { return }

        if let authenticatedUser = authUser {
            (self.window?.rootViewController as? LoginViewController)?.hideLogin()
            Branch.getInstance().setIdentity(authenticatedUser.uid)
            currentUser = TDUser(uid: authenticatedUser.uid, email: authenticatedUser.email!)
            currentUser.startup { self.login(success: $0) }
        } else {
            (self.window?.rootViewController as? LoginViewController)?.showLogin()
        }
    }
   
    func login(success: Bool) {
        if success {
            self.showHome()
        } else {
            (self.window?.rootViewController as? LoginViewController)?.showLogin()
        }
    }
    
    private func showHome() {
        currentUser.isLogged = true
    
        if let _ = UserDefaults.standard.string(forKey: "user_last_ip") {
            initSynapse()
        } else {
            Ipify.getPublicIPAddress { result in
                switch result {
                case .success(let ip):
                    UserDefaults.standard.set(ip, forKey: "user_last_ip")
                    UserDefaults.standard.synchronize()
                    self.initSynapse()
                case .failure(let error):
                    log.error(error)
                    self.initSynapse()
                }
            }
        }
        
        DispatchQueue.main.async {
            self.window?.rootViewController = self.window?.rootViewController?.storyboard?.instantiateViewController(withIdentifier: Constants.homeVCStoryboardIdentifier)
        }
    }
    
    func presentMFAViewController() {
        DispatchQueue.main.async {
            let mfaVC = self.window?.rootViewController?.storyboard?.instantiateViewController(withIdentifier: "mfaVC") as! MFAViewController
            if let base = homeVC {
                log.debug("Presenting MFA VC")
                base.present(mfaVC, animated: true, completion: nil)
            } else {
                log.debug("homeVC was not defined")
            }
        }
    }
    
    func initSynapse() {
        log.debug("Init Synapse")
        if let synapseID = currentUser.synapseUID, !synapseID.isBlank {
            API().loadUser(uid: synapseID, { success in
                if (success) {
                    API().authorizeSynapseUser()
                }
            })
        }
    }
    
    func isSynapseUserVerified() -> Bool {

        guard let _ = currentUser.synapseUID else {
            log.debug("no uid")
            self.loadKYCModal()
            return false
        }
        
        guard let userRef = currentUser.synapseData else {
            homeVC?.showAlert(message: "You are currently experiencing network problems. Please try again in a few minutes. If you are connected to a public network such as an office or coffee shop, access to these features may be disabled for your privacy.")
            return false
        }
        
        guard let documents = userRef["documents"] as? [[String: Any]], let permission = userRef["permission"] as? String else {
            log.debug("No docs or no permissions")
            self.loadKYCModal()
            return false
        }
        
        var hasInitiated2FA = false
        var hasCompleted2FA = false
        if let userRef = currentUser.synapseData, let documents = userRef["documents"] as? [[String: Any]] {
            documents.forEach { document in
                if let socialDocs = document["social_docs"] as? [[String: Any]] {
                    socialDocs.forEach { doc in
                        if let type = doc["document_type"] as? String, let status = doc["status"] as? String, type == "PHONE_NUMBER_2FA" {
                            hasInitiated2FA = true
                            if (status == "SUBMITTED|VALID") {
                                hasCompleted2FA = true
                            }
                        }
                    }
                }
            }
        }
        
        if (permission == "SEND-AND-RECEIVE") {
            return true
        } else {
            API().loadUser(uid: currentUser.synapseUID!, { success in
                if (success) {
                    API().authorizeSynapseUser({ result in
                        if (result) {
                            if (hasCompleted2FA) {
                                log.debug("Loading under review modal")
                                self.loadUnderReviewModal()
                            } else if (hasInitiated2FA) {
                                log.debug("Loading 2FA modal")
                                self.load2FAModal()
                            } else {
                                homeVC?.showAlert(message: "You are currently experiencing network problems. Please try again in a few minutes. If you are connected to a public network such as an office or coffee shop, access to these features may be disabled for your privacy.")
                            }
                        } else {
                            homeVC?.showAlert(message: "You are currently experiencing network problems. Please try again in a few minutes. If you are connected to a public network such as an office or coffee shop, access to these features may be disabled for your privacy.")
                        }
                    })
                }
            })
            
            return false
        }
    }
    
    func loadUnderReviewModal() {
        DispatchQueue.main.async {
            let vc = self.window?.rootViewController?.storyboard?.instantiateViewController(withIdentifier: "sp_user_review") as! UserReviewViewController
            if let base = homeVC {
                base.present(vc, animated: true, completion: nil)
            }
        }
    }
    
    func loadKYCModal() {
        DispatchQueue.main.async {
            let vc = self.window?.rootViewController?.storyboard?.instantiateViewController(withIdentifier: "sp_user_kyc") as! UINavigationController
            if let base = homeVC {
                base.present(vc, animated: true, completion: nil)
            }
        }
    }
    
    func load2FAModal() {
        
        guard let userRef = currentUser.synapseData, let phone = currentUser.phone, let documents = userRef["documents"] as? [[String: Any]] else {
            log.debug("No docs or no permissions or no phone")
            return
        }
        
        var phoneDoc: [String: Any] = [:]
        var mainDoc: [String: Any] = [:]
        documents.forEach { document in
            if let socialDocs = document["social_docs"] as? [[String: Any]] {
                socialDocs.forEach { doc in
                    if let type = doc["document_type"] as? String, type == "PHONE_NUMBER_2FA" {
                        phoneDoc = doc
                        mainDoc = document
                    }
                }
            }
        }
        
        guard let documentId = mainDoc["id"] as? String else { log.debug("Could not find the main document"); return }
        guard let phoneDocumentId = phoneDoc["id"] as? String else { log.debug("Could not find the PHONE_NUMBER_2FA document"); return }
        
        API().resendPhoneKYC(documentId: documentId, phoneNumber: phone, phoneDocumentId: phoneDocumentId) { success in
            if (success) {
                self.loadKYCModal()
            } else {
                log.debug("Unable to resend phone KYC")
            }
        }
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        UserDefaults.standard.set(nil, forKey: "wokenNotification")
        UserDefaults.standard.set(nil, forKey: "wokenNotificationType")
        UserDefaults.standard.synchronize()
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
    }
    
    // [START receive_message]
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) {
        // If you are receiving a notification message while your app is in the background,
        // this callback will not be fired till the user taps on the notification launching the application.
        // TODO: Handle data of notification
        // With swizzling disabled you must let Messaging know about the message, for Analytics
        Messaging.messaging().appDidReceiveMessage(userInfo)
        // Print message ID.
        
        if let messageID = userInfo[gcmMessageIDKey] {
            print("Message ID: \(messageID)")
        }
        
        // Print full message.
        print(userInfo)
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // If you are receiving a notification message while your app is in the background,
        // this callback will not be fired till the user taps on the notification launching the application.
        // TODO: Handle data of notification
        // With swizzling disabled you must let Messaging know about the message, for Analytics
        Messaging.messaging().appDidReceiveMessage(userInfo)
        // Print message ID.
        if let messageID = userInfo[gcmMessageIDKey] {
            print("Message ID: \(messageID)")
        }
        
        // Print full message.
        print(userInfo)
        
        completionHandler(UIBackgroundFetchResult.newData)
    }
    // [END receive_message]
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Unable to register for remote notifications: \(error.localizedDescription)")
    }
    
    // This function is added here only for debugging purposes, and can be removed if swizzling is enabled.
    // If swizzling is disabled then this function must be implemented so that the APNs token can be paired to
    // the FCM registration token.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        log.debug("APNs token retrieved: \(deviceToken)")
        // With swizzling disabled you must set the APNs token here.
        Messaging.messaging().apnsToken = deviceToken
    }
}

// [START ios_10_message_handling]
@available(iOS 10, *)
extension AppDelegate : UNUserNotificationCenterDelegate {
    
    // Receive displayed notifications for iOS 10 devices.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        
        // With swizzling disabled you must let Messaging know about the message, for Analytics
        Messaging.messaging().appDidReceiveMessage(userInfo)
        
        // Print full message.
        log.info(userInfo)
        completionHandler([.alert, .badge, .sound])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        // Print message ID.
        if let messageID = userInfo[gcmMessageIDKey] {
            print("Message ID: \(messageID)")
        }
        
        log.info(userInfo)
        completionHandler()
    }
}
// [END ios_10_message_handling]

extension AppDelegate : MessagingDelegate {
    // [START refresh_token]
    func messaging(_ messaging: Messaging, didRefreshRegistrationToken fcmToken: String) {
        print("Firebase registration token: \(fcmToken)")
    }
    // [END refresh_token]
    // [START ios_10_data_message]
    // Receive data messages on iOS 10+ directly from FCM (bypassing APNs) when the app is in the foreground.
    // To enable direct data messages, you can set Messaging.messaging().shouldEstablishDirectChannel to true.
    func messaging(_ messaging: Messaging, didReceive remoteMessage: MessagingRemoteMessage) {
        print("Received data message: \(remoteMessage.appData)")
    }
    // [END ios_10_data_message]
}

//MARK: Remote resources

var downloadedImages = [String:Data]()

extension AppDelegate {
    func downloadImageFor(id:String, section:String, closure: ((Bool)->Void)? = nil) {
        guard downloadedImages["\(id)"] == nil else { closure?(true); return }
        guard let imageURL = URL(string: "\(Constants.FIRStoragePublicURL)\(section)%2F\(id)?alt=media") else { closure?(false); return }
        
        URLSession.shared.dataTask(with: imageURL, completionHandler: { (data, response, error) -> Void in
            
            guard let imgData = data, error == nil else {
                log.error(error)
                closure?(false)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                let statusCode = httpResponse.statusCode
                if statusCode != 200 {
                    closure?(false)
                    return
                }
            }

            downloadedImages["\(id)"] = imgData
            closure?(true)
        }).resume()
    }
}

