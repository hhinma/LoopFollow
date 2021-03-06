//
//  NightScout.swift
//  LoopFollow
//
//  Created by Jon Fawcett on 6/16/20.
//  Copyright © 2020 Jon Fawcett. All rights reserved.
//

import Foundation
import UIKit


extension MainViewController {
    
    // Main loader for all data
    func nightscoutLoader(forceLoad: Bool = false) {
        
        
        var needsLoaded: Bool = false
        var onlyPullLastRecord = false
        
        // If we have existing data and it's within 5 minutes, we aren't going to do a network call
        if bgData.count > 0 {
            let now = NSDate().timeIntervalSince1970
            let lastReadingTime = bgData[bgData.count - 1].date
            let secondsAgo = now - lastReadingTime
            if secondsAgo >= 5*60 {
                needsLoaded = true
                if secondsAgo < 10*60 {
                    onlyPullLastRecord = true
                }
            }
        } else {
            needsLoaded = true
        }
        
        if forceLoad { needsLoaded = true}
        // Only do the network calls if we don't have a current reading
        if needsLoaded {
            loadProfile(urlUser: urlUser)
            loadTempBasals(urlUser: urlUser)
            loadDeviceStatus(urlUser: urlUser)
            loadBGData(urlUser: urlUser, onlyPullLastRecord: onlyPullLastRecord)
            clearLastInfoData()
            loadCage(urlUser: urlUser)
            loadSage(urlUser: urlUser)
            
           // loadBoluses(urlUser: urlUser)
           
        } else {
            loadProfile(urlUser: urlUser)
            loadTempBasals(urlUser: urlUser)
            loadDeviceStatus(urlUser: urlUser)
            updateMinAgo()
            clearOldSnoozes()
            checkAlarms(bgs: bgData)
            loadProfile(urlUser: urlUser)
        }
        
    }
    
    // Main NS BG Data Pull
    func loadBGData(urlUser: String, onlyPullLastRecord: Bool = false) {

        // Set the count= in the url either to pull 24 hours or only the last record
        var points = "1"
        if !onlyPullLastRecord {
            points = String(self.graphHours * 12 + 1)
        }

        // URL processor
        var urlBGDataPath: String = urlUser + "/api/v1/entries/sgv.json?"
        if token == "" {
            urlBGDataPath = urlBGDataPath + "count=" + points
        } else {
            urlBGDataPath = urlBGDataPath + "token=" + token + "&count=" + points
        }
        guard let urlBGData = URL(string: urlBGDataPath) else { return }
        var request = URLRequest(url: urlBGData)
        request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData

        // Downloader
        let getBGTask = URLSession.shared.dataTask(with: request) { data, response, error in
            if self.consoleLogging == true {print("start bg url")}
            guard error == nil else {
                return
            }
            guard let data = data else {
                return
            }

            let decoder = JSONDecoder()
            let entriesResponse = try? decoder.decode([sgvData].self, from: data)
            if let entriesResponse = entriesResponse {
                DispatchQueue.main.async {
                    // trigger the processor for the data after downloading.
                    self.ProcessNSBGData(data: entriesResponse, onlyPullLastRecord: onlyPullLastRecord)
                }
            } else {
                return
            }
        }
        getBGTask.resume()
    }
       
    // Primary processor for what to do with the downloaded NS BG data
    func ProcessNSBGData(data: [sgvData], onlyPullLastRecord: Bool){
        var pullDate = data[data.count - 1].date / 1000
        pullDate.round(FloatingPointRoundingRule.toNearestOrEven)
        
        // If we already have data, we're going to pop it to the end and remove the first. If we have old or no data, we'll destroy the whole array and start over. This is simpler than determining how far back we need to get new data from in case Dex back-filled readings
        if !onlyPullLastRecord {
            bgData.removeAll()
        } else if bgData[bgData.count - 1].date != pullDate {
            bgData.removeFirst()
        } else {
            // Update the badge, bg, graph settings even if we don't have a new reading.
            self.updateBadge(entries: bgData)
            self.updateBG(entries: bgData)
            return
        }
        
        // loop through the data so we can reverse the order to oldest first for the graph and convert the NS timestamp to seconds instead of milliseconds. Makes date comparisons easier for everything else.
        for i in 0..<data.count{
            var dateString = data[data.count - 1 - i].date / 1000
            dateString.round(FloatingPointRoundingRule.toNearestOrEven)
            let reading = sgvData(sgv: data[data.count - 1 - i].sgv, date: dateString, direction: data[data.count - 1 - i].direction)
            bgData.append(reading)
        }
        self.updateBadge(entries: bgData)
        self.updateBG(entries: bgData)
        self.createGraph(entries: bgData)
        if UserDefaultsRepository.writeCalendarEvent.value {
            self.writeCalendar()
        }
       }
    
    func updateBG (entries: [sgvData]) {
        if consoleLogging == true {print("in update BG")}
        if entries.count > 0 {
            let latestEntryi = entries.count - 1
            let latestBG = entries[latestEntryi].sgv
            let priorBG = entries[latestEntryi - 1].sgv
            let deltaBG = latestBG - priorBG as Int
            let lastBGTime = entries[latestEntryi].date //NS has different units
            let deltaTime = (TimeInterval(Date().timeIntervalSince1970)-lastBGTime) / 60
            var userUnit = " mg/dL"
            if mmol {
                userUnit = " mmol/L"
            }
            if UserDefaultsRepository.appBadge.value {
                UIApplication.shared.applicationIconBadgeNumber = latestBG
            } else {
                UIApplication.shared.applicationIconBadgeNumber = 0
            }
            
            BGText.text = bgOutputFormat(bg: Double(latestBG), mmol: mmol)
            setBGTextColor()

            MinAgoText.text = String(Int(deltaTime)) + " min ago"
            print(String(Int(deltaTime)) + " min ago")
            if let directionBG = entries[latestEntryi].direction {
                DirectionText.text = bgDirectionGraphic(directionBG)
            }
            else
            {
                DirectionText.text = ""
            }
            
          if deltaBG < 0 {
            self.DeltaText.text = String(deltaBG)
            }
            else
            {
                self.DeltaText.text = "+" + String(deltaBG)
            }
        
        }
        else
        {
            
            return
        }
        
        checkAlarms(bgs: entries)
    }
    
     // NS Device Status Pull from NS
      func loadDeviceStatus(urlUser: String) {
          var urlStringDeviceStatus = urlUser + "/api/v1/devicestatus.json?count=1"
          if token != "" {
              urlStringDeviceStatus = urlUser + "/api/v1/devicestatus.json?token=" + token + "&count=1"
          }
          let escapedAddress = urlStringDeviceStatus.addingPercentEncoding(withAllowedCharacters:NSCharacterSet.urlQueryAllowed)
          guard let urlDeviceStatus = URL(string: escapedAddress!) else {
              return
          }
          if consoleLogging == true {print("entered device status task.")}
          var requestDeviceStatus = URLRequest(url: urlDeviceStatus)
          requestDeviceStatus.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
          let deviceStatusTask = URLSession.shared.dataTask(with: requestDeviceStatus) { data, response, error in
          if self.consoleLogging == true {print("in device status loop.")}
          guard error == nil else {
              return
          }
          guard let data = data else {
              return
          }
              
              let json = try? (JSONSerialization.jsonObject(with: data) as! [[String:AnyObject]])
          if let json = json {
              DispatchQueue.main.async {
                  self.updateDeviceStatusDisplay(jsonDeviceStatus: json)
              }
          } else {
              return
          }
          if self.consoleLogging == true {print("finish pump update")}}
          deviceStatusTask.resume()
      }
      
      // Parse Device Status Data
      func updateDeviceStatusDisplay(jsonDeviceStatus: [[String:AnyObject]]) {
          if consoleLogging == true {print("in updatePump")}
          if jsonDeviceStatus.count == 0 {
              return
          }
          
          //only grabbing one record since ns sorts by {created_at : -1}
          let lastDeviceStatus = jsonDeviceStatus[0] as [String : AnyObject]?
          
          //pump and uploader
          let formatter = ISO8601DateFormatter()
          formatter.formatOptions = [.withFullDate,
                                     .withTime,
                                     .withDashSeparatorInDate,
                                     .withColonSeparatorInTime]
          if let lastPumpRecord = lastDeviceStatus?["pump"] as! [String : AnyObject]? {
              if let lastPumpTime = formatter.date(from: (lastPumpRecord["clock"] as! String))?.timeIntervalSince1970  {
                  if let reservoirData = lastPumpRecord["reservoir"] as? Double
                  {
                      tableData[5].value = String(format:"%.0f", reservoirData) + "U"
                  } else {
                      tableData[5].value = "50+U"
                  }
                  
                  if let uploader = lastDeviceStatus?["uploader"] as? [String:AnyObject] {
                      let upbat = uploader["battery"] as! Double
                      tableData[4].value = String(format:"%.0f", upbat) + "%"
                  }
              }
          }
              
          // Loop
          if let lastLoopRecord = lastDeviceStatus?["loop"] as! [String : AnyObject]? {
              if let lastLoopTime = formatter.date(from: (lastLoopRecord["timestamp"] as! String))?.timeIntervalSince1970  {

                  UserDefaultsRepository.alertLastLoopTime.value = lastLoopTime
                  
                  if let failure = lastLoopRecord["failureReason"] {
                      LoopStatusLabel.text = "⚠"
                  }
                  else
                  {
                      if let enacted = lastLoopRecord["enacted"] as? [String:AnyObject] {
                          if let lastTempBasal = enacted["rate"] as? Double {
                              tableData[2].value = String(format:"%.1f", lastTempBasal)
                          }
                      }
                      if let iobdata = lastLoopRecord["iob"] as? [String:AnyObject] {
                          tableData[0].value = String(format:"%.1f", (iobdata["iob"] as! Double))
                      }
                      if let cobdata = lastLoopRecord["cob"] as? [String:AnyObject] {
                          tableData[1].value = String(format:"%.0f", cobdata["cob"] as! Double)
                      }
                      if let predictdata = lastLoopRecord["predicted"] as? [String:AnyObject] {
                          let prediction = predictdata["values"] as! [Double]
                          PredictionLabel.text = String(Int(prediction.last!))
                          PredictionLabel.textColor = UIColor.systemPurple
                          predictionData.removeAll()
                          var i = 1
                          while i <= 12 {
                              predictionData.append(prediction[i])
                              i += 1
                          }
                          
                      }
                      
                      
                      
                      if let loopStatus = lastLoopRecord["recommendedTempBasal"] as? [String:AnyObject] {
                          if let tempBasalTime = formatter.date(from: (loopStatus["timestamp"] as! String))?.timeIntervalSince1970 {
                              if tempBasalTime > lastLoopTime {
                                  LoopStatusLabel.text = "⏀"
                                 } else {
                                  LoopStatusLabel.text = "↻"
                              }
                          }
                         
                      } else {
                          LoopStatusLabel.text = "↻"
                      }
                      
                  }
                  if ((TimeInterval(Date().timeIntervalSince1970) - lastLoopTime) / 60) > 10 {
                      LoopStatusLabel.text = "⚠"
                  }
              }
              
              
              
          }
          
          var oText = "" as String
                 
                 if let lastOverride = lastDeviceStatus?["override"] as! [String : AnyObject]? {
                     if let lastOverrideTime = formatter.date(from: (lastOverride["timestamp"] as! String))?.timeIntervalSince1970  {
                     }
                     if lastOverride["active"] as! Bool {
                         
                         let lastCorrection  = lastOverride["currentCorrectionRange"] as! [String: AnyObject]
                         if let multiplier = lastOverride["multiplier"] as? Double {
                                                oText += String(format:"%.1f", multiplier*100)
                                            }
                                            else
                                            {
                                                oText += String(format:"%.1f", 100)
                                            }
                         oText += "% ("
                         let minValue = lastCorrection["minValue"] as! Double
                         let maxValue = lastCorrection["maxValue"] as! Double
                         oText += bgOutputFormat(bg: minValue, mmol: mmol) + "-" + bgOutputFormat(bg: maxValue, mmol: mmol) + ")"
                        
                      tableData[3].value =  oText
                     }
                 }
          
          infoTable.reloadData()
          }
      
      // Get last CAGE entry
      func loadCage(urlUser: String) {
          var urlString = urlUser + "/api/v1/treatments.json?find[eventType]=Site%20Change&count=1"
          if token != "" {
              urlString = urlUser + "/api/v1/treatments.json?token=" + token + "&find[eventType]=Site%20Change&count=1"
          }

          guard let urlData = URL(string: urlString) else {
              return
          }
          var request = URLRequest(url: urlData)
          request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData

          let task = URLSession.shared.dataTask(with: request) { data, response, error in
              if self.consoleLogging == true {print("start cage url")}
              guard error == nil else {
                  return
              }
              guard let data = data else {
                  return
              }

              let decoder = JSONDecoder()
              let entriesResponse = try? decoder.decode([cageData].self, from: data)
              if let entriesResponse = entriesResponse {
                  DispatchQueue.main.async {
                      self.updateCage(data: entriesResponse)
                  }
              } else {
                  return
              }
          }
          task.resume()
      }
       
      // Parse Cage Data
      func updateCage(data: [cageData]) {
          if consoleLogging == true {print("in updateCage")}
          if data.count == 0 {
              return
          }

          let lastCageString = data[0].created_at

          let formatter = ISO8601DateFormatter()
          formatter.formatOptions = [.withFullDate,
                                  .withTime,
                                  .withDashSeparatorInDate,
                                  .withColonSeparatorInTime]
          UserDefaultsRepository.alertCageInsertTime.value = formatter.date(from: (lastCageString))?.timeIntervalSince1970 as! TimeInterval
          if let cageTime = formatter.date(from: (lastCageString))?.timeIntervalSince1970 {
              let now = NSDate().timeIntervalSince1970
              let secondsAgo = now - cageTime
              //let days = 24 * 60 * 60

              let formatter = DateComponentsFormatter()
              formatter.unitsStyle = .positional // Use the appropriate positioning for the current locale
              formatter.allowedUnits = [ .hour, .minute ] // Units to display in the formatted string
              formatter.zeroFormattingBehavior = [ .pad ] // Pad with zeroes where appropriate for the locale

              let formattedDuration = formatter.string(from: secondsAgo)
              tableData[7].value = formattedDuration ?? ""
          }
          infoTable.reloadData()
      }
       
      // Get last SAGE entry
      func loadSage(urlUser: String) {
          var dayComponent    = DateComponents()
          dayComponent.day    = -10 // For removing 10 days
          let theCalendar     = Calendar.current

          let startDate    = theCalendar.date(byAdding: dayComponent, to: Date())!
          let dateFormatter = DateFormatter()
          dateFormatter.dateFormat = "yyyy-MM-dd"
          var startDateString = dateFormatter.string(from: startDate)


          var urlString = urlUser + "/api/v1/treatments.json?find[eventType]=Sensor%20Start&find[created_at][$gte]=2020-05-31&count=1"
          if token != "" {
              urlString = urlUser + "/api/v1/treatments.json?token=" + token + "&find[eventType]=Sensor%20Start&find[created_at][$gte]=2020-05-31&count=1"
          }

          guard let urlData = URL(string: urlString) else {
              return
          }
          var request = URLRequest(url: urlData)
          request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData

          let task = URLSession.shared.dataTask(with: request) { data, response, error in
              if self.consoleLogging == true {print("start cage url")}
              guard error == nil else {
                  return
              }
              guard let data = data else {
                  return
              }

              let decoder = JSONDecoder()
              let entriesResponse = try? decoder.decode([cageData].self, from: data)
              if let entriesResponse = entriesResponse {
                  DispatchQueue.main.async {
                      self.updateSage(data: entriesResponse)
                  }
              } else {
                  return
              }
          }
          task.resume()
      }
       
      // Parse Sage Data
      func updateSage(data: [cageData]) {
          if consoleLogging == true {print("in updateSage")}
          if data.count == 0 {
              return
          }

          var lastSageString = data[0].created_at

          let formatter = ISO8601DateFormatter()
          formatter.formatOptions = [.withFullDate,
                               .withTime,
                               .withDashSeparatorInDate,
                               .withColonSeparatorInTime]
          UserDefaultsRepository.alertSageInsertTime.value = formatter.date(from: (lastSageString))?.timeIntervalSince1970 as! TimeInterval
          if let sageTime = formatter.date(from: (lastSageString as! String))?.timeIntervalSince1970 {
              let now = NSDate().timeIntervalSince1970
              let secondsAgo = now - sageTime
              let days = 24 * 60 * 60

              let formatter = DateComponentsFormatter()
              formatter.unitsStyle = .positional // Use the appropriate positioning for the current locale
              formatter.allowedUnits = [ .day, .hour] // Units to display in the formatted string
              formatter.zeroFormattingBehavior = [ .pad ] // Pad with zeroes where appropriate for the locale

              let formattedDuration = formatter.string(from: secondsAgo)
              tableData[6].value = formattedDuration ?? ""
          }
          infoTable.reloadData()
      }
       
      // Load Current Profile
      func loadProfile(urlUser: String) {
          
          let urlString = urlUser + "/api/v1/profile/current.json"
          let escapedAddress = urlString.addingPercentEncoding(withAllowedCharacters:NSCharacterSet.urlQueryAllowed)
          guard let url = URL(string: escapedAddress!) else {
              return
          }
          
          var request = URLRequest(url: url)
          request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
          let task = URLSession.shared.dataTask(with: request) { data, response, error in
              guard error == nil else {
                  return
              }
              guard let data = data else {
                  return
              }
              
              
              let json = try? JSONSerialization.jsonObject(with: data) as! Dictionary<String, Any>
              
              if let json = json {
                  DispatchQueue.main.async {
                      self.updateProfile(jsonDeviceStatus: json)
                  }
              } else {
                  return
              }
          }
          task.resume()
      }
      
      // Parse Basal schedule from the profile
      func updateProfile(jsonDeviceStatus: Dictionary<String, Any>) {
     
          if jsonDeviceStatus.count == 0 {
              return
          }
          let basal = jsonDeviceStatus[keyPath: "store.Default.basal"] as! NSArray
          for i in 0..<basal.count {
              let dict = basal[i] as! Dictionary<String, Any>
              let thisValue = dict[keyPath: "value"] as! Double
              let thisTime = dict[keyPath: "time"] as! String
              let thisTimeAsSeconds = dict[keyPath: "timeAsSeconds"] as! Double
              let entry = basalProfileStruct(value: thisValue, time: thisTime, timeAsSeconds: thisTimeAsSeconds)
              basalProfile.append(entry)
          }
          
      }
      

      func loadTempBasals(urlUser: String) {
          let today = Date()
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            dateFormatter.timeZone = TimeZone.init(secondsFromGMT: 0)
            let yesterdayString = dateFormatter.string(from: yesterday)
            
            var urlString = urlUser + "/api/v1/treatments.json?find[eventType][$eq]=Temp%20Basal&find[created_at][$gte]=" + yesterdayString
            if token != "" {
                urlString = urlUser + "/api/v1/treatments.json?token=" + token + "&find[eventType][$eq]=Temp%20Basal&find[created_at][$gte]=" + yesterdayString
            }
            
            guard let urlData = URL(string: urlString) else {
                return
            }
            
          
            var request = URLRequest(url: urlData)
            request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
           
            guard error == nil else {
                return
            }
            guard let data = data else {
                return
            }
                
                let json = try? (JSONSerialization.jsonObject(with: data) as! [[String:AnyObject]])
            if let json = json {
                DispatchQueue.main.async {
                    self.updateBasals(entries: json)
                }
            } else {
                return
            }
            }
            task.resume()
      }
      
      func updateBasals(entries: [[String:AnyObject]]) {
          
          // due to temp basal durations, we're going to destroy the array and load everything each cycle for the time being.
          basalData.removeAll()
          
        var lastEndDot = 0.0
        
          var tempArray: [basalGraphStruct] = []
          for i in 0..<entries.count {
              let currentEntry = entries[entries.count - 1 - i] as [String : AnyObject]?
              let basalDate = currentEntry?["timestamp"] as! String
              let strippedZone = String(basalDate.dropLast())
              let dateFormatter = DateFormatter()
              dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
              dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
              let dateString = dateFormatter.date(from: strippedZone)
              let dateTimeStamp = dateString!.timeIntervalSince1970
              let basalRate = currentEntry?["absolute"] as! Double
                let midnightTime = dateTimeUtils.getTimeIntervalMidnightToday()
              // Setting end dots
              var duration = 0.0
              // For all except the last we're going to use stored duration for end dot. For last we'll just put it 5 mintues after the entry
              if i <= entries.count - 1 {
                   duration = currentEntry?["duration"] as! Double
              } else {
                  duration = dateTimeStamp + 60
              }
              
              // This adds scheduled basal wherever there is a break between temps. can't check the prior ending on the first item. it is 24 hours old, so it isn't important for display anyway
              if i > 0 {
                  let priorEntry = entries[entries.count - i] as [String : AnyObject]?
                  let priorBasalDate = priorEntry?["timestamp"] as! String
                  let priorStrippedZone = String(priorBasalDate.dropLast())
                  let priorDateFormatter = DateFormatter()
                  priorDateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                  priorDateFormatter.timeZone = TimeZone(abbreviation: "UTC")
                  let priorDateString = dateFormatter.date(from: priorStrippedZone)
                  let priorDateTimeStamp = priorDateString!.timeIntervalSince1970
                 let priorDuration = priorEntry?["duration"] as! Double
                // if difference between time stamps is greater than the duration of the last entry, there is a gap
                if Double( dateTimeStamp - priorDateTimeStamp ) > Double( priorDuration * 60 ) {
                     
                      var scheduled = 0.0
                    // cycle through basal profiles.
                    // TODO figure out how to deal with profile changes that happen mid-gap
                      for b in 0..<self.basalProfile.count {
                        let scheduleTimeYesterday = self.basalProfile[b].timeAsSeconds + dateTimeUtils.getTimeIntervalMidnightYesterday()
                        let scheduleTimeToday = self.basalProfile[b].timeAsSeconds + dateTimeUtils.getTimeIntervalMidnightToday()
                        // check the prior temp ending to the profile seconds from midnight
                        if (priorDateTimeStamp + (priorDuration * 60)) >= scheduleTimeYesterday {
                            scheduled = basalProfile[b].value
                        }
                        if (priorDateTimeStamp + (priorDuration * 60)) >= scheduleTimeToday {
                            scheduled = basalProfile[b].value
                        }
                          
                        // This will iterate through from midnight on and set it for the highest matching one.
                      }
                      // Make the starting dot at the last ending dot
                      let startDot = basalGraphStruct(basalRate: scheduled, date: Double(priorDateTimeStamp + (priorDuration * 60)))
                      basalData.append(startDot)
                    
                    // Make the ending dot at the new starting dot
                    let endDot = basalGraphStruct(basalRate: scheduled, date: Double(dateTimeStamp))
                    basalData.append(endDot)
                      
                     
                 }
              }
              
              // Make the starting dot
              let startDot = basalGraphStruct(basalRate: basalRate, date: Double(dateTimeStamp))
              basalData.append(startDot)
            
            // Make the ending dot
            // If it's the last one and not ended yet, extend it for 1 hour to match the prediction length. Otherwise let it end
            if i == entries.count - 1 && dateTimeStamp + duration <= dateTimeUtils.getNowTimeIntervalUTC() {
                lastEndDot = Date().timeIntervalSince1970 + (55 * 60)
            } else {
                lastEndDot = dateTimeStamp + (duration * 60)
            }
            let endDot = basalGraphStruct(basalRate: basalRate, date: Double(lastEndDot))
            basalData.append(endDot)
            
              
          }
        
        // If last scheduled basal was prior to right now, we need to create one last scheduled entry
        if lastEndDot <= dateTimeUtils.getNowTimeIntervalUTC() {
            var scheduled = 0.0
                // cycle through basal profiles.
                // TODO figure out how to deal with profile changes that happen mid-gap
                  for b in 0..<self.basalProfile.count {
                    let scheduleTimeYesterday = self.basalProfile[b].timeAsSeconds + dateTimeUtils.getTimeIntervalMidnightYesterday()
                    let scheduleTimeToday = self.basalProfile[b].timeAsSeconds + dateTimeUtils.getTimeIntervalMidnightToday()
                    // check the prior temp ending to the profile seconds from midnight
                    if lastEndDot >= scheduleTimeYesterday {
                        scheduled = basalProfile[b].value
                    }
                    if lastEndDot >= scheduleTimeToday {
                        scheduled = basalProfile[b].value
                    }
                      
                    
                  }
                  // Make the starting dot at the last ending dot
                  let startDot = basalGraphStruct(basalRate: scheduled, date: Double(lastEndDot))
                  basalData.append(startDot)
                
                // Make the ending dot 1 hour after now
                let endDot = basalGraphStruct(basalRate: scheduled, date: Double(Date().timeIntervalSince1970))
                basalData.append(endDot)
                  
                 
             }
            
        
        
        /*
        // Add 1 hour to end to match prediction time length
        var scheduled = 0.0
        // cycle through basal profiles to get current schedule for end.
        // TODO figure out how to deal with profile changes that happen mid-gap
        
          for b in 0..<self.basalProfile.count {
            let scheduleTimeToday = self.basalProfile[b].timeAsSeconds + dateTimeUtils.getTimeIntervalMidnightToday()
            // check the last end time to the profile seconds from midnight
            if lastEndDot >= scheduleTimeToday {
                scheduled = basalProfile[b].value
            }
          }
          // Make the starting dot at the last ending dot
          let startDot = basalGraphStruct(basalRate: scheduled, date: Double(lastEndDot))
          basalData.append(startDot)
        
        // Make the ending dot 1 hour from the latest BG reading
        let endDot = basalGraphStruct(basalRate: scheduled, date: Double(Date().timeIntervalSince1970 + (60 * 60)))
        basalData.append(endDot)
        */
        createBasalGraph(entries: basalData)
      }
    
      // NOT IMPLEMENTED YET
      func loadBoluses(urlUser: String){
          var calendar = Calendar.current
          let today = Date()
          let midnight = calendar.startOfDay(for: today)
          let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
          let dateFormatter = DateFormatter()
          dateFormatter.timeZone = TimeZone(abbreviation: "GMT")
          dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
          let formattedDate = dateFormatter.string(from: yesterday)
          
          var searchString = "find[eventType]=Meal%20Bolus&find[created_at][$gte]=" + formattedDate
          var urlBGDataPath: String = urlUser + "/api/v1/treatments.json?"
          if token == "" {
              urlBGDataPath = urlBGDataPath + searchString
          }
          else
          {
              urlBGDataPath = urlBGDataPath + "token=" + token + searchString
          }
          guard let urlBGData = URL(string: urlBGDataPath) else {
              return
          }
          var request = URLRequest(url: urlBGData)
          request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
          
          let getTask = URLSession.shared.dataTask(with: request) { data, response, error in
              if self.consoleLogging == true {print("start meal bolus url")}
              guard error == nil else {
                  return
              }
              guard let data = data else {
                  return
              }
              
              let decoder = JSONDecoder()
              let entriesResponse = try? decoder.decode([sgvData].self, from: data)
              if let entriesResponse = entriesResponse {
                  DispatchQueue.main.async {
                     // self.ProcessNSData(data: entriesResponse, onlyPullLastRecord: onlyPullLastRecord)
                  }
              }
              else
              {
                  
                  return
              }
          }
          getTask.resume()
      }
    
    
}
