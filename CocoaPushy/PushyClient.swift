//  The MIT License (MIT)
//
//  Copyright 2017 Noel Gaur<noelgaur@qq.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy of this
//  software and associated documentation files (the "Software"), to deal in the Software
//  without restriction, including without limitation the rights to use, copy, modify,
//  merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
//  persons to whom the Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all copies or
//  substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
//  BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//  DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


/////////////////////////////////////////////////////////
//  PushyClient.swift
//  CocoaPushy
//
//  Created by Noel Gaur on 2/25/17.
//  Copyright © 2017 Noel Gaur. All rights reserved.
//
/////////////////////////////////////////////////////////

import Foundation
import CocoaMQTT
import SystemConfiguration
import CoreData


/*
 Network Availability Provider
 */

fileprivate class Logger{
    private static var _formatter:DateFormatter{
        let dfmt = DateFormatter()
        dfmt.dateFormat = "yyyy-MM-dd hh:mm:ss"
        dfmt.locale = Locale.current
        return dfmt
    }
    private static let formatter = _formatter
    
    fileprivate class func log(_ tag:String, _ stmt:String){
        let dateStr = formatter.string(from: Date(timeIntervalSinceNow: 0))
        print("[\(dateStr)]:([PushyClient]:[\(tag)]: \(stmt)")
        
    }
    fileprivate class func log(_ stmt:String){
         self.log("",stmt)
    }
}


public enum PushyError:Error{
    case mqttConnError(reason:String)
    case mqttConfigError(reason:String)
    case malformedUrl(reason:String)
    
}

public extension PushyError{
    var code:Int{
        switch(self){
        case .mqttConnError: return 1001;
        case .mqttConfigError: return 1002;
        case .malformedUrl: return 1003;
        }
    }
}

public extension PushyError{
    var blame:String{
        switch(self){
        case .mqttConnError: return "MQTT Connection failed."
        case .mqttConfigError: return "MQTT invalid configuration specified."
        case .malformedUrl: return "Host or provided url is malformed."
        }
    }
}

enum NetworkAvailabilityError: Error {
    case FailedToCreateWithAddress(sockaddr_in)
    case FailedToCreateWithHostname(String)
    case UnableToSetCallback
    case UnableToSetDispatchQueue
}

let NetworkAvailabilityChangedNotification = NSNotification.Name("com.earlydata.pushy.client.networkNotification")
public let PushyMessageNotification = NSNotification.Name("com.earlydata.pushy.client.pushynotifier")

func callback(reachability:SCNetworkReachability, flags: SCNetworkReachabilityFlags, info: UnsafeMutableRawPointer?) {
    
    guard let info = info else { return }
    
    let reachability = Unmanaged<NetworkAvailability>.fromOpaque(info).takeUnretainedValue()
    
    DispatchQueue.main.async {
        reachability.reachabilityChanged()
    }
}

class NetworkAvailability {
    
    public typealias NetworkReachable = (NetworkAvailability) -> ()
    public typealias NetworkUnreachable = (NetworkAvailability) -> ()
    
    public enum NetworkStatus: CustomStringConvertible {
        
        case notReachable, reachableViaWiFi, reachableViaWWAN
        
        public var description: String {
            switch self {
            case .reachableViaWWAN: return "Cellular"
            case .reachableViaWiFi: return "WiFi"
            case .notReachable: return "No Connection"
            }
        }
    }
    
    public var whenReachable: NetworkReachable?
    public var whenUnreachable: NetworkUnreachable?
    public var reachableOnWWAN: Bool
    
    // The notification center on which "reachability changed" events are being posted
    public var notificationCenter: NotificationCenter = NotificationCenter.default
    
    public var currentNetworkAvailabilityString: String {
        return "\(currentNetworkAvailabilityStatus)"
    }
    
    public var currentNetworkAvailabilityStatus: NetworkStatus {
        guard isReachable else { return .notReachable }
        
        if isReachableViaWiFi {
            return .reachableViaWiFi
        }
        if isRunningOnDevice {
            return .reachableViaWWAN
        }
        
        return .notReachable
    }
    
    fileprivate var previousFlags: SCNetworkReachabilityFlags?
    
    fileprivate var isRunningOnDevice: Bool = {
        #if (arch(i386) || arch(x86_64)) && os(iOS)
            return false
        #else
            return true
        #endif
    }()
    
    fileprivate var notifierRunning = false
    fileprivate var reachabilityRef: SCNetworkReachability?
    
    fileprivate let reachabilitySerialQueue = DispatchQueue(label: "uk.co.ashleymills.reachability")
    
    required public init(reachabilityRef: SCNetworkReachability) {
        reachableOnWWAN = true
        self.reachabilityRef = reachabilityRef
    }
    
    public convenience init?(hostname: String) {
        
        guard let ref = SCNetworkReachabilityCreateWithName(nil, hostname) else { return nil }
        
        self.init(reachabilityRef: ref)
    }
    
    public convenience init?() {
        
        var zeroAddress = sockaddr()
        zeroAddress.sa_len = UInt8(MemoryLayout<sockaddr>.size)
        zeroAddress.sa_family = sa_family_t(AF_INET)
        
        guard let ref: SCNetworkReachability = withUnsafePointer(to: &zeroAddress, {
            SCNetworkReachabilityCreateWithAddress(nil, UnsafePointer($0))
        }) else { return nil }
        
        self.init(reachabilityRef: ref)
    }
    
    deinit {
        stopNotifier()
        
        reachabilityRef = nil
        whenReachable = nil
        whenUnreachable = nil
    }
}

extension NetworkAvailability {
    
    // MARK: - *** Notifier methods ***
    func startNotifier() throws {
        
        guard let reachabilityRef = reachabilityRef, !notifierRunning else { return }
        
        var context = SCNetworkReachabilityContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = UnsafeMutableRawPointer(Unmanaged<NetworkAvailability>.passUnretained(self).toOpaque())
        if !SCNetworkReachabilitySetCallback(reachabilityRef, callback, &context) {
            stopNotifier()
            throw NetworkAvailabilityError.UnableToSetCallback
        }
        
        if !SCNetworkReachabilitySetDispatchQueue(reachabilityRef, reachabilitySerialQueue) {
            stopNotifier()
            throw NetworkAvailabilityError.UnableToSetDispatchQueue
        }
        
        // Perform an intial check
        reachabilitySerialQueue.async {
            self.reachabilityChanged()
        }
        
        notifierRunning = true
    }
    
    func stopNotifier() {
        defer { notifierRunning = false }
        guard let reachabilityRef = reachabilityRef else { return }
        
        SCNetworkReachabilitySetCallback(reachabilityRef, nil, nil)
        SCNetworkReachabilitySetDispatchQueue(reachabilityRef, nil)
    }
    
    // MARK: - *** Connection test methods ***
    var isReachable: Bool {
        
        guard isReachableFlagSet else { return false }
        
        if isConnectionRequiredAndTransientFlagSet {
            return false
        }
        
        if isRunningOnDevice {
            if isOnWWANFlagSet && !reachableOnWWAN {
                // We don't want to connect when on 3G.
                return false
            }
        }
        
        return true
    }
    
    var isReachableViaWWAN: Bool {
        // Check we're not on the simulator, we're REACHABLE and check we're on WWAN
        return isRunningOnDevice && isReachableFlagSet && isOnWWANFlagSet
    }
    
    var isReachableViaWiFi: Bool {
        
        // Check we're reachable
        guard isReachableFlagSet else { return false }
        
        // If reachable we're reachable, but not on an iOS device (i.e. simulator), we must be on WiFi
        guard isRunningOnDevice else { return true }
        
        // Check we're NOT on WWAN
        return !isOnWWANFlagSet
    }
    
    var description: String {
        
        let W = isRunningOnDevice ? (isOnWWANFlagSet ? "W" : "-") : "X"
        let R = isReachableFlagSet ? "R" : "-"
        let c = isConnectionRequiredFlagSet ? "c" : "-"
        let t = isTransientConnectionFlagSet ? "t" : "-"
        let i = isInterventionRequiredFlagSet ? "i" : "-"
        let C = isConnectionOnTrafficFlagSet ? "C" : "-"
        let D = isConnectionOnDemandFlagSet ? "D" : "-"
        let l = isLocalAddressFlagSet ? "l" : "-"
        let d = isDirectFlagSet ? "d" : "-"
        
        return "\(W)\(R) \(c)\(t)\(i)\(C)\(D)\(l)\(d)"
    }
}

fileprivate extension NetworkAvailability {
    
    func reachabilityChanged() {
        
        let flags = reachabilityFlags
        
        guard previousFlags != flags else { return }
        
        let block = isReachable ? whenReachable : whenUnreachable
        block?(self)
        
        self.notificationCenter.post(name: NetworkAvailabilityChangedNotification, object:self)
        
        previousFlags = flags
    }
    
    var isOnWWANFlagSet: Bool {
        #if os(iOS)
            return reachabilityFlags.contains(.isWWAN)
        #else
            return false
        #endif
    }
    var isReachableFlagSet: Bool {
        return reachabilityFlags.contains(.reachable)
    }
    var isConnectionRequiredFlagSet: Bool {
        return reachabilityFlags.contains(.connectionRequired)
    }
    var isInterventionRequiredFlagSet: Bool {
        return reachabilityFlags.contains(.interventionRequired)
    }
    var isConnectionOnTrafficFlagSet: Bool {
        return reachabilityFlags.contains(.connectionOnTraffic)
    }
    var isConnectionOnDemandFlagSet: Bool {
        return reachabilityFlags.contains(.connectionOnDemand)
    }
    var isConnectionOnTrafficOrDemandFlagSet: Bool {
        return !reachabilityFlags.intersection([.connectionOnTraffic, .connectionOnDemand]).isEmpty
    }
    var isTransientConnectionFlagSet: Bool {
        return reachabilityFlags.contains(.transientConnection)
    }
    var isLocalAddressFlagSet: Bool {
        return reachabilityFlags.contains(.isLocalAddress)
    }
    var isDirectFlagSet: Bool {
        return reachabilityFlags.contains(.isDirect)
    }
    var isConnectionRequiredAndTransientFlagSet: Bool {
        return reachabilityFlags.intersection([.connectionRequired, .transientConnection]) == [.connectionRequired, .transientConnection]
    }
    
    var reachabilityFlags: SCNetworkReachabilityFlags {
        
        guard let reachabilityRef = reachabilityRef else { return SCNetworkReachabilityFlags() }
        
        var flags = SCNetworkReachabilityFlags()
        let gotFlags = withUnsafeMutablePointer(to: &flags) {
            SCNetworkReachabilityGetFlags(reachabilityRef, UnsafeMutablePointer($0))
        }
        
        if gotFlags {
            return flags
        } else {
            return SCNetworkReachabilityFlags()
        }
    }
}





/**
 MQTT Provider, handles all communication
 with server on MQTT Channel
 
 */


public struct PushyConf{
    fileprivate let host:String
    fileprivate let port:UInt16
    fileprivate let deviceId:String
    fileprivate let clientId:String
    fileprivate let user:String?
    fileprivate let pass:String?
    fileprivate let isSSL:Bool
    fileprivate let certName:String?
    fileprivate let certPass:String?
    
    public init(host:String,port:UInt16,deviceId:String,clientId client:String,
         user:String? = nil,password pass:String? = nil,
         isSSL:Bool=false,certificateName certName:String? = nil,
         certificatePassword certPass:String? = nil){
        
        self.host       = host;
        self.port       = port;
        self.deviceId   = deviceId;
        self.clientId   = client;
        self.user       = user;
        self.pass       = pass;
        self.isSSL      = isSSL;
        self.certName   = certName;
        self.certPass   = certPass;
        
    }
}






/**
 @description Provides MQTT message dispatcher
 functionality to server.
 
 This receiver adapts automatically to internal
 connection. Beneath the MqttClient - it uses
 GCD to asynchronously maintain session with server.
 
 It can be safely called from main thread without
 performance panelties.
 
 @note Important methods:
 
 initialize :  init(_)
 connect    :  connect(_)
 publish    :  publish(_)
 subscribe  :  subscribe(_)
 disconnect :  disconnect(_)
 
 [Singleton]
 [MT-ThreadSafe]
 */
class MqttClient {
    
    ///Internal MQTT provider deligate - Its singleton
    private var mqtt: CocoaMQTT!
    
    let networkMonitor:NetworkAvailability
    
    var notificationCenter: NotificationCenter = NotificationCenter.default
    var messageCallback:((_ id:UInt16,_ topic:String,_ payload:[UInt8])->Void)?
    
    
    ///In memory permanent reference to configuration
    ///for recreating connection
    private let conf:PushyConf;
    
    private let accessQueue = DispatchQueue(label: "PushyNotificationQueue", attributes: .concurrent)
    
    
    /// Unsafe write
    private var _isConnected:Bool = false
    
    private var _subscriptionQueue:[String:String] = [:]
    
    
    
    var subscriptionQueue:[String:String]{
        var copyQueue:[String:String] = [:]
        accessQueue.sync{
            [unowned self] in
            copyQueue = self._subscriptionQueue
        }
        return copyQueue
    }
    
    /// ThreadSafe readonly to get connection state
    var isConnected:Bool{
        return self._isConnected
    }
    
    
    
    /// <#Description#>
    ///
    /// - Parameter conf: <#conf description#>
    init(config conf:PushyConf,networkMonitor:NetworkAvailability) {
        self.conf = conf
        self.networkMonitor = networkMonitor
        notificationCenter.addObserver(self, selector: #selector(self.reconnect),
                                       name: NetworkAvailabilityChangedNotification, object:nil)
        
        
    }
    
    convenience init(networkMonitor:NetworkAvailability,host:String,port:UInt16,deviceId:String,clientId client:String,
                     user:String?=nil,password pass:String?=nil,
                     isSSL:Bool=false)  {
        
        self.init(config: PushyConf(host:host,port:port,deviceId:deviceId,clientId:client,
                                    user:user, password:pass,isSSL: isSSL), networkMonitor: networkMonitor)
    }
    
    @discardableResult
    private func validateUrl(url:String) throws ->Bool?{
        if (url.hasPrefix("tcp://") || url.hasPrefix("ssl://") ||
            url.hasPrefix("ws://") || url.hasPrefix("wss://")){
            return true
        }else{
            throw PushyError.mqttConfigError(
                reason:"Invalid connection protocol <\(url.substring(to: (url.range(of: ":\\")?.lowerBound ?? url.endIndex)))>")
        }
        
    }
    
    private func getPort(url:String)->Int?{
        //colon before port number
        if let portSuffix = url.components(separatedBy:":").last{
            let portStr = portSuffix.components(separatedBy: "/").first ?? portSuffix
            return Int(portStr)
        }
        return nil
    }
    
    @objc private func reconnect(notification:Notification){
        if(networkMonitor.isReachable){
            self.connect()
        }
    }
    
    
    
    func connect()->Void{
        accessQueue.async(flags: .barrier){
            [unowned self] in
            if(!self.isConnected){
                self._isConnected = true
                self.mqtt = self.createInstance()
                self.mqtt.connect()
            }
        }
        
    }
    
    
    func subscribe(topic: String){
        accessQueue.async(flags: .barrier){
            [unowned self] in
            self._subscriptionQueue[topic] = topic
            if(self.isConnected){
                self.mqtt.subscribe(topic)
            }
        }
    }
    
    func unsubscribe(topic: String){
        accessQueue.async(flags: .barrier){
            [unowned self] in
            if(self.isConnected){
                self.mqtt.unsubscribe(topic)
            }
            
        }
    }
    
    func createInstance()->CocoaMQTT{
        let clientID = "PushyIOS-\(conf.deviceId)-" + String(ProcessInfo().processIdentifier)
        let mqtt = CocoaMQTT(clientID: clientID, host: conf.host, port: conf.port)
        if let confUser = conf.user,let confPass = conf.pass{
            mqtt.username = confUser
            mqtt.password = confPass
        }
        mqtt.keepAlive = 60
        mqtt.delegate = self
        mqtt.cleanSession = false
        if(conf.isSSL){
            mqtt.enableSSL = true
            if let certName = conf.certName, let certPass = conf.certPass{
                if let clientCertArray = getClientCertFromP12File(certName: certName,
                                                                  certPassword: certPass){
                    var sslSettings: [String: NSObject] = [:]
                    sslSettings[kCFStreamSSLCertificates as String] = clientCertArray
                    
                    mqtt.sslSettings = sslSettings
                }
            }
            
        }
        return mqtt
    }
    
    
    func getClientCertFromP12File(certName: String, certPassword: String) -> CFArray? {
        // get p12 file path
        let resourcePath = Bundle.main.path(forResource: certName, ofType: "p12")
        
        guard let filePath = resourcePath, let p12Data = NSData(contentsOfFile: filePath) else {
            _console("Failed to open the certificate file: \(certName).p12")
            return nil
        }
        
        // create key dictionary for reading p12 file
        let key = kSecImportExportPassphrase as String
        let options : NSDictionary = [key: certPassword]
        
        var items : CFArray?
        let securityError = SecPKCS12Import(p12Data, options, &items)
        
        guard securityError == errSecSuccess else {
            if securityError == errSecAuthFailed {
                _console("ERROR: SecPKCS12Import returned errSecAuthFailed. Incorrect password?")
            } else {
                _console("Failed to open the certificate file: \(certName).p12")
            }
            return nil
        }
        
        guard let theArray = items, CFArrayGetCount(theArray) > 0 else {
            return nil
        }
        
        let dictionary = (theArray as NSArray).object(at: 0)
        guard let identity = (dictionary as AnyObject).value(forKey: kSecImportItemIdentity as String) else {
            return nil
        }
        let certArray = [identity] as CFArray
        
        return certArray
    }
    
    
    deinit {
        /*
        if(self.isConnected){
            self.mqtt.disconnect()
        }
        */
        self.notificationCenter.removeObserver(self)
    }
    
}

extension MqttClient:CocoaMQTTDelegate{
    
    
    func mqtt(_ mqtt: CocoaMQTT, didConnect host: String, port: Int) {
        _console("didConnect \(host):\(port)")
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        
        _console("didConnectAck: \(ack)，rawValue: \(ack.rawValue)")
        
        if ack == .accept {
            self.subscriptionQueue.forEach{mqtt.subscribe($0.value)}
        }
        
        
        
    }
    
    
    
    // Optional ssl CocoaMQTTDelegate
    func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        /// Validate the server certificate
        ///
        /// Some custom validation...
        ///
        /// if validatePassed {
        ///     completionHandler(true)
        /// } else {
        ///     completionHandler(false)
        /// }
        completionHandler(true)
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {
        _console("didPublishMessage with message: \(message.string)")
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {
        _console("didPublishAck with id: \(id)")
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16 ) {
        //NotificationCenter.default.post(name: MessageNotification, object: message.payload, userInfo: ["id":id,"topic" : message.topic])
        if let msgCb = self.messageCallback{
            msgCb(id,message.topic,message.payload)
        }
        _console("didReceivedMessage: with id \(id)")
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopic topic: String) {
        _console("didSubscribeTopic to \(topic)")
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopic topic: String) {
        _console("didUnsubscribeTopic to \(topic)")
    }
    
    func mqttDidPing(_ mqtt: CocoaMQTT) {
       _console("didPing")
    }
    
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {
        _console("didReceivePong")
    }
    
    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        if(self.networkMonitor.isReachable){
            self.notificationCenter.post(name: NetworkAvailabilityChangedNotification, object: nil)
        }
        if let errMsg = err?.localizedDescription{
            _console("MQTT Disconnedted :: \(errMsg)")
        }
        _console("mqttDidDisconnect")
    }
    
    func _console(_ info: String) {
        Logger.log(String(describing: self),"Delegate: \(info)")
    }
    
}

/*

class DatabaseController{
    
    private init(){
        
    }
    
    class func getContext() -> NSManagedObjectContext {
        return DatabaseController.persistentContainer.viewContext
    }
    
    // MARK: - Core Data stack
    
    static var persistentContainer: NSPersistentContainer = {
        /*
         The persistent container for the application. This implementation
         creates and returns a container, having loaded the store for the
         application to it. This property is optional since there are legitimate
         error conditions that could cause the creation of the store to fail.
         */
        let container = NSPersistentContainer(name: "PushyDb")
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                // Replace this implementation with code to handle the error appropriately.
                // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
                
                /*
                 Typical reasons for an error here include:
                 * The parent directory does not exist, cannot be created, or disallows writing.
                 * The persistent store is not accessible, due to permissions or data protection when the device is locked.
                 * The device is out of space.
                 * The store could not be migrated to the current model version.
                 Check the error message to determine what the actual problem was.
                 */
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        })
        return container
    }()
    
    // MARK: - Core Data Saving support
    
    class func saveContext () {
        let context = persistentContainer.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                // Replace this implementation with code to handle the error appropriately.
                // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
                let nserror = error as NSError
                fatalError("Unresolved error \(nserror), \(nserror.userInfo)")
            }
        }
    }
}
 */

public struct PushyMessage{
    let channelId   :UInt16
    let messageId   :String
    let clientId    :String
    let messageType :Int
    let topic       :String
    let title       :String?
    let content     :String?
    let date        :Date
    let tags        :[String]?
    
    fileprivate init?(id:UInt16,topic:String,json: [String: Any]) {
       
       let formatter = DateFormatter()
       formatter.dateFormat = "yyyy-MM-dd hh:mm:ss"
       
       self.channelId = id
       self.topic = topic
       
       guard let messageId = json["messageId"] as? String,
             let clientId = json["clientId"] as? String,
             let messageType = json["messageType"] as? Int,
             let dateStr =  json["date"] as? String,
             let date = formatter.date(from: dateStr) else{
            return nil
        }
        
        self.messageId = messageId
        self.clientId = clientId
        self.messageType = messageType
        self.date = date
        
        self.title = json["title"] as? String
        self.content = json["content"] as? String
        self.tags = json["tags"] as? [String]
    
    }
}

public class PushyClient{
    
    fileprivate let networkMonitor = NetworkAvailability()!
    
    private let notificationCenter = NotificationCenter.default
 
    fileprivate let urlSuffix = "/api/ios/device"
    
    fileprivate let conf:PushyConf
    
    private var hasNetworkObserver = false
    
    /// Topic prefix for all subscribed topics
    private let notificationPrefix = "/earlydata/pushy"
    
    private let pushSvc:MqttClient
    
    private func notificationTopic(clientId:String)->String{
        return "\(self.notificationPrefix)\(clientId)/notify/#"
    }
    
    public init(config conf:PushyConf) throws {
        self.conf = conf
        do{
            try networkMonitor.startNotifier()
        }catch{
            Logger.log("Unable to start network notifier")
        }
        
        pushSvc = MqttClient(config: conf,networkMonitor:networkMonitor)
        unowned let that = self
        pushSvc.messageCallback = that.handleMessage
        pushSvc.subscribe(topic: notificationTopic(clientId: conf.clientId))
        
        try doUpdateDeviceId(deviceId: conf.deviceId, clientId: conf.clientId, host: conf.host)
        
        pushSvc.connect()
        
    }
    
    public func updateClientDevice(deviceId:String, clientId:String){
        try? self.doUpdateDeviceId(deviceId: deviceId, clientId: clientId, host: conf.host)
    }
    
    public func subscribe(topic: String){
        pushSvc.subscribe(topic: topic)
    }
    
    public func subscribe(clientId: String){
        pushSvc.subscribe(topic: notificationTopic(clientId: clientId))
        try? self.doUpdateDeviceId(deviceId: conf.deviceId, clientId: clientId, host: conf.host)
    }
    
    public func unsubscribe(topic: String){
        pushSvc.subscribe(topic: topic)
    }
    
    public func unsubscribe(clientId: String){
        pushSvc.unsubscribe(topic: notificationTopic(clientId: clientId))
    }
    
    @objc private func fireUpdateWhenNotified(notification:NSNotification){
        
        if let payload = notification.object as? (deviceId:String,clientId:String,host:String){
            if(networkMonitor.isReachable){
               try? doUpdateDeviceId(deviceId: payload.deviceId, clientId: payload.clientId, host: payload.host)
            }
        }
        
    }
    
    private func doUpdateDeviceId(deviceId:String,clientId:String,host:String) throws ->Void{
       try updateDeviceId(deviceId: deviceId, clientId: clientId, host: host){
        [unowned self] status in
        switch(status){
                case .success: DispatchQueue.main.async{
                    if(self.hasNetworkObserver){
                        self.notificationCenter.removeObserver(self)
                        self.hasNetworkObserver = false
                    }
                }
                case .failure: DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 60){
                    try! self.doUpdateDeviceId(deviceId: deviceId, clientId: clientId, host: host)
                   }
                case .down: DispatchQueue.main.async{
                    if(!self.hasNetworkObserver){
                        
                        self.notificationCenter.addObserver(self, selector: #selector(self.fireUpdateWhenNotified),
                                                       name: NetworkAvailabilityChangedNotification, object:(deviceId:deviceId,clientId:clientId,host:host))
                    }
                }
            }
        }
    }
    
    private func handleMessage(id:UInt16,topic:String,payload:[UInt8]){
        
        let payloadData = Data(bytes: payload)
        
        guard let payloadJson = try? JSONSerialization.jsonObject(with: payloadData, options: []),
              let json = payloadJson as? [String:Any],
              let message = PushyMessage(id: id, topic: topic, json: json) else{
              _console("Invalid message received for => id:\(id),topic:\(topic), payload:\(payload)")
              return
        }
        
        notificationCenter.post(name: PushyMessageNotification, object: message)
    }
    
    
}

extension PushyClient{
    enum Status{
                case success
                case failure
                case down
        }
    
    func updateDeviceId(deviceId:String,clientId:String,host:String, callback:@escaping (PushyClient.Status)->Void) throws{
        let scheme = conf.isSSL ? "https":"http"
        guard let connUrl =  URL(string: "\(scheme)://\(host)/\(self.urlSuffix)") else{
            
            throw PushyError.malformedUrl(reason: "\(host) is invalid")
        }
        
        if(!networkMonitor.isReachable){
            callback(.down)
        }else{
            var request = URLRequest(url: connUrl, cachePolicy: URLRequest.CachePolicy.reloadIgnoringCacheData, timeoutInterval:TimeInterval(120))
            let payload:[String: Any] = ["clientId": clientId, "deviceId": deviceId, "appKey":self.conf.user ?? "", "appSecret": self.conf.pass ?? ""]
            let payloadJson = try! JSONSerialization.data(withJSONObject: payload)
    
            request.httpMethod = "POST"
            request.httpBody = payloadJson
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let task = URLSession.shared.dataTask(with: request){
                data,response,error in
                
                if response != nil{
                    let statusCode = (response as! HTTPURLResponse).statusCode
                    
                    200 == statusCode ? callback(.success) : callback(.failure)
                    
                }else{
                    callback(.down)
                }
            }
            task.resume()
        }
        
    }
    func _console(_ stmt:String){
        Logger.log(String(describing:self),stmt)
    }
}


