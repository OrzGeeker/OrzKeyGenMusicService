//
//  File.swift
//  
//
//  Created by joker on 12/20/23.
//

import Foundation
import Vapor

struct KeyGenMusicController: RouteCollection {
    
    func boot(routes: Vapor.RoutesBuilder) throws {
        
        let musics = routes.grouped("musics")
        
        musics.get("list", use: musicList)
    }

    func musicList(req: Request) throws -> String {

        let workingDirectoryURL = URL(fileURLWithPath: req.application.directory.workingDirectory).appending(components: "Public")
        guard FileManager.default.fileExists(atPath: workingDirectoryURL.path(percentEncoded: false))
        else {
            return ""
        }
        
        let task = Process()
        task.currentDirectoryURL = workingDirectoryURL
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [
            "bash",
            "-c",
            "tree -sJf --du -- KeyGenMusic"
        ]
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        try task.run()
        
        guard let outputData = try outputPipe.fileHandleForReading.readToEnd(),
              let output = String(data: outputData, encoding: .utf8)
        else {
            return ""
        }
        return output
        
    }
}
