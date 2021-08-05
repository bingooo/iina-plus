//
//  ImageLoader.swift
//  iina+
//
//  Created by xjbeta on 2019/6/26.
//  Copyright © 2019 xjbeta. All rights reserved.
//

import Cocoa
import Alamofire
import Kingfisher

class ImageLoader: NSObject {
    
    static let diskConfigName = "ImageCache"
    
    static let userCacheUrl: URL? = {
        return try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }()
    
    static let appCacheUrl: URL? = {
        return userCacheUrl?.appendingPathComponent(Bundle.main.bundleIdentifier!)
    }()
    
    static func removeOld() {
        do {
            // Old Image cache folder
            guard let cacheUrl = userCacheUrl else { return }
            
            let oldFolderName = Bundle.main.bundleIdentifier! + ".imageCache"
            let oldUrl = cacheUrl.appendingPathComponent(oldFolderName)
            if FileManager.default.fileExists(atPath: oldUrl.path) {
                try FileManager.default.removeItem(atPath: oldUrl.path)
            }
            

        } catch let error {
            Log(error)
        }
    }
    
}
