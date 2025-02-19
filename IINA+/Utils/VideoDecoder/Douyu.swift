//
//  Douyu.swift
//  IINA+
//
//  Created by xjbeta on 4/22/22.
//  Copyright © 2022 xjbeta. All rights reserved.
//

import Cocoa
import Alamofire
import PMKAlamofire
import PromiseKit
import JavaScriptCore
import Marshal
import CryptoSwift

class Douyu: NSObject, SupportSiteProtocol {
    func liveInfo(_ url: String) -> Promise<LiveInfo> {
        getDouyuHtml(url).map {
            Int($0.roomId) ?? -1
        }.then {
            self.douyuBetard($0)
        }.map {
            $0 as LiveInfo
        }
    }
    
    func decodeUrl(_ url: String) -> Promise<YouGetJSON> {
        var yougetJson = YouGetJSON(rawUrl: url)
        var roomId = 0
        var roomTitle = ""
        var jsContext: JSContext!
        return getDouyuHtml(url).get {
            guard let rid = Int($0.roomId) else {
                throw VideoGetError.douyuNotFoundRoomId
            }
            roomId = rid
            jsContext = $0.jsContext
        }.then { _ in
            self.douyuBetard(roomId)
        }.get {
            roomTitle = $0.title
        }.then { _ in
            self.getDouyuUrl(roomId, jsContext: jsContext)
        }.map {
            yougetJson.title = roomTitle
            $0.forEach {
                yougetJson.streams[$0.0] = $0.1
            }
            yougetJson.id = roomId
            return yougetJson
        }
    }
    
    func getDouyuHtml(_ url: String) -> Promise<(roomId: String, roomIds: [String], isLiving: Bool, pageId: String, jsContext: JSContext)> {
        
        AF.request(url).responseString().map {
            let text = $0.string
            
            let showStatus = text.subString(from: "$ROOM.show_status =", to: ";") == "1"
            let roomId = text.subString(from: "$ROOM.room_id =", to: ";").replacingOccurrences(of: " ", with: "")
            
            guard roomId != "",
                  let jsContext = self.douyuJSContext(text) else {
                throw VideoGetError.douyuNotFoundRoomId
            }
            
            var roomIds = [String]()
            var pageId = ""
            let roomIdsStr = text.subString(from: "window.room_ids=[", to: "],")
            
            if roomIdsStr != "" {
                roomIds = roomIdsStr.replacingOccurrences(of: "\"", with: "").split(separator: ",").map(String.init)
                pageId = text.subString(from: "\"pageId\":", to: ",")
            }

            return (roomId, roomIds, showStatus, pageId, jsContext)
        }
    }
    
    func douyuJSContext(_ text: String) -> JSContext? {
        var text = text
        
        let start = #"<script type="text/javascript">"#
        let end = #"</script>"#
        
        var scriptTexts = [String]()
        
        while text.contains(start) {
            let js = text.subString(from: start, to: end)
            scriptTexts.append(js)
            text = text.subString(from: start)
        }
        
        guard let context = JSContext(),
              let cryptoPath = Bundle.main.path(forResource: "crypto-js", ofType: "js"),
              let cryptoData = FileManager.default.contents(atPath: cryptoPath),
              let cryptoJS = String(data: cryptoData, encoding: .utf8)?.subString(from: #"}(this, function () {"#, to: #"return CryptoJS;"#),
              let signJS = scriptTexts.first(where: { $0.contains("ub98484234") })
        else {
            return nil
        }
        context.name = "DouYin Sign"
        context.evaluateScript(cryptoJS)
        context.evaluateScript(signJS)
        
        return context
    }
    
    func douyuBetard(_ rid: Int) -> Promise<DouyuInfo> {
        AF.request("https://www.douyu.com/betard/\(rid)").responseData().map {
            let json: JSONObject = try JSONParser.JSONObjectWithData($0.data)
            
            return try DouyuInfo(object: json)
        }
    }
    
    
//    https://butterfly.douyucdn.cn/api/page/loadPage?name=pageData2&pageId=1149&view=0
    func getDouyuEventRoomNames(_ pageId: String) -> Promise<[DouyuEventRoom]> {
        
        AF.request("https://butterfly.douyucdn.cn/api/page/loadPage?name=pageData2&pageId=\(pageId)&view=0").responseString().map {
            guard let data = self.douyuRoomJsonFormatter($0.string)?.data(using: .utf8) else {
                throw VideoGetError.douyuNotFoundRoomId
            }
            
            let json: JSONObject = try JSONParser.JSONObjectWithData(data)
            return try json.value(for: "children")
        }
    }
    
    func getDouyuUrl(_ roomID: Int, rate: Int = 0, jsContext: JSContext) -> Promise<[(String, Stream)]> {
        let time = Int(Date().timeIntervalSince1970)
        let didStr: String = {
            let time = UInt32(NSDate().timeIntervalSinceReferenceDate)
            srand48(Int(time))
            let random = "\(drand48())"
            return random.md5()
        }()
        
        
        guard let sign = jsContext.evaluateScript("ub98484234(\(roomID), '\(didStr)', \(time))").toString(),
              let v = jsContext.evaluateScript("vdwdae325w_64we").toString()
        else {
            return .init(error: VideoGetError.douyuSignError)
        }
        
        let pars = ["v": v,
                    "did": didStr,
                    "tt": time,
                    "sign": sign.subString(from: "sign="),
                    "cdn": "ali-h5",
                    "rate": "\(rate)",
                    "ver": "Douyu_221111905",
                    "iar": "0",
                    "ive": "0"] as [String : Any]
        
        return AF.request("https://www.douyu.com/lapi/live/getH5Play/\(roomID)", method: .post, parameters: pars).responseData().map {
            let json: JSONObject = try JSONParser.JSONObjectWithData($0.data)
            return try DouyuH5Play(object: json)
        }.then {
            self.douyuCDNs($0)
        }.map { play in
            play.multirates.map { rate -> (String, Stream) in
                var s = Stream(url: "")
                s.quality = rate.bit
                s.rate = rate.rate
                
                var urls = play.p2pUrls
                urls.append(play.flvUrl)
                
                if rate.rate == play.rate, urls.count > 0 {
                    s.url = urls.removeFirst()
                    s.src = urls
                }
                return (rate.name, s)
            }
        }
    }
    
    func douyuCDNs(_ info: DouyuH5Play) -> Promise<DouyuH5Play> {
        guard let url = info.cdnUrl else {
            return .value(info)
        }
        
        return AF.request(url).responseData().map {
            let json: JSONObject = try JSONParser.JSONObjectWithData($0.data)
            
            let sugs: [String] = try json.value(for: "sug")
            let baks: [String] = try json.value(for: "bak")
            var info = info
            info.initP2pUrls(sugs + baks)
            return info
        }
    }
    
    func douyuRoomJsonFormatter(_ text: String) -> String? {
        guard let index = text.index(of: #""NewPcBasicSwitchRoomAdvance""#)?.utf16Offset(in: text) else {
            return nil
        }
        
        let sIndex = text.indexes(of: "{").map({$0.utf16Offset(in: text)})
        let eIndex = text.indexes(of: "}").map({$0.utf16Offset(in: text)})
        
        let indexList = (sIndex.map {
            ($0, 1)
        } + eIndex.map {
            ($0, -1)
        }).sorted { i1, i2 in
            i1.0 < i2.0
        }
        
        // Find "{"
        var c2 = 0
        guard var i2 = indexList.lastIndex(where: { $0.0 < index }) else {
            return nil
        }
        
        c2 += indexList[i2].1
        while c2 != 1 {
            i2 -= 1
            guard i2 >= 0 else {
                return nil
            }
            c2 += indexList[i2].1
        }
        let startIndex = text.index(text.startIndex, offsetBy: indexList[i2].0)
        
        // Find "}"
        var c1 = 0
        guard var i1 = indexList.firstIndex(where: { $0.0 > index }) else {
            return nil
        }
        
        c1 += indexList[i1].1
        while c1 != -1 {
            i1 += 1
            guard indexList.count > i1 else {
                return nil
            }
            c1 += indexList[i1].1
        }
        
        let endIndex = text.index(startIndex, offsetBy: indexList[i1].0 - indexList[i2].0)
        
        return String(text[startIndex...endIndex])
    }
}

struct DouyuInfo: Unmarshaling, LiveInfo {
    var title: String = ""
    var name: String = ""
    var avatar: String
    var isLiving = false
    var cover: String = ""
    var site: SupportSites = .douyu
    
    init(object: MarshaledObject) throws {
        title = try object.value(for: "room.room_name")
        name = try object.value(for: "room.nickname")
        avatar = try object.value(for: "room.avatar.big")
        isLiving = "\(try object.any(for: "room.show_status"))" == "1"
//        isLiving = try object.value(for: "room.show_status") == 1 && object.value(for: "room.videoLoop") != 0
        
        cover = try object.value(for: "room.room_pic")
    }
}

struct DouyuVideoSelector: VideoSelector {
    let site = SupportSites.douyu
    let index: Int
    let title: String
    let id: Int
    let coverUrl: URL?
}

struct DouyuEventRoom: Unmarshaling {
    let onlineRoomId: String
    let text: String
    init(object: MarshaledObject) throws {
        onlineRoomId = try object.value(for: "props.onlineRoomId")
        text = try object.value(for: "props.text")
    }
}

struct DouyuH5Play: Unmarshaling {
    let roomId: Int
    let rtmpUrl: String
    let rtmpLive: String
    let rate: Int
    let multirates: [Rate]
    
    let flvUrl: String
    let xsString: String?
    let cdnUrl: String?
    
    var p2pUrls = [String]()
    
    struct Rate: Unmarshaling {
        let name: String
        let rate: Int
        let highBit: Int
        let bit: Int
        
        init(object: MarshaledObject) throws {
            name = try object.value(for: "name")
            rate = try object.value(for: "rate")
            highBit = try object.value(for: "highBit")
            bit = try object.value(for: "bit")
        }
    }
    
    struct P2pMeta: Unmarshaling {
        let domain: String
        let delay: Int
        let secret: String
        let time: String
        
        init(object: MarshaledObject) throws {
            domain = try object.value(for: "xp2p_domain")
            delay = try object.value(for: "xp2p_txDelay")
            secret = try object.value(for: "xp2p_txSecret")
            time = try object.value(for: "xp2p_txTime")
        }
    }
    
    init(object: MarshaledObject) throws {
        roomId = try object.value(for: "data.room_id")
        rtmpUrl = try object.value(for: "data.rtmp_url")
        rtmpLive = try object.value(for: "data.rtmp_live")
        multirates = try object.value(for: "data.multirates")
        rate = try object.value(for: "data.rate")
        
        flvUrl = rtmpUrl + "/" + rtmpLive
        
        guard let meta: P2pMeta = try? object.value(for: "data.p2pMeta") else {
            xsString = nil
            cdnUrl = nil
            return
        }
        
        var newRL = rtmpLive.replacingOccurrences(of: "flv", with: "xs").split(separator: "&").map(String.init)
        
        newRL.append(contentsOf: [
            "delay=\(meta.delay)",
            "txSecret=\(meta.secret)",
            "txTime=\(meta.time)",
//            "playid=1646460800000-3082600000",
            "uuid=\(UUID().uuidString)"
        ])
        
        xsString = "\(meta.domain)/live/" + newRL.joined(separator: "&")
        cdnUrl = "https://\(meta.domain)/\(rtmpLive.subString(to: ".")).xs"
    }
    
    mutating func initP2pUrls(_ urls: [String]) {
        guard let str = xsString else { return }
        p2pUrls = urls.map {
            "https://\($0)/" + str
        }
    }
}

