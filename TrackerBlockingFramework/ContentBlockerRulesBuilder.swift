//
//  ContentBlockerRulesBuilder.swift
//  DuckDuckGo Privacy Essentials
//
//  Created by Chris Brind on 22/08/2019.
//  Copyright © 2019 Duck Duck Go, Inc. All rights reserved.
//

import Foundation

public struct ContentBlockerRulesBuilder {
    
    struct Constants {
        // in the scheme .* overmatches and "OR" does not work
        static let subDomainPrefix = "^(https?)?(wss?)?://([a-z0-9-]+\\.)*"
        static let domainMatchSuffix = "(:?[0-9]+)?/.*"
    }
    
    static let resourceMapping: [String: ContentBlockerRule.Trigger.ResourceType] = [
        "script": .script,
        "xmlhttprequest": .raw,
        "subdocument": .document,
        "image": .image,
        "stylesheet": .stylesheet
    ]
    
    let trackerData: TrackerData
    
    /// Build all the rules for the given tracker data and list of exceptions.
    public func buildRules(withExceptions exceptions: [String]? = nil) -> [ContentBlockerRule] {
        
        let trackerRules = trackerData.trackers.values.compactMap {
            buildRules(from: $0)
        }.flatMap { $0 }
        
        return trackerRules + buildExceptions(from: exceptions)
    }
    
    /// Build the rules for a specific tracker.
    public func buildRules(from tracker: KnownTracker) -> [ContentBlockerRule] {
        
        let blockingRules: [ContentBlockerRule] = buildBlockingRules(from: tracker)
        
        let specialRules = tracker.rules?.compactMap { r -> [ContentBlockerRule] in
            buildRules(fromRule: r, inTracker: tracker)
            } ?? []
        
        let sortedRules = specialRules.sorted(by: { $0.count > $1.count })
        
        let dedupedRules = sortedRules.flatMap { $0 }.removeDuplicates()
        
        return blockingRules + dedupedRules
    }
    
    private func buildExceptions(from exceptions: [String]?) -> [ContentBlockerRule] {
        guard let exceptions = exceptions, !exceptions.isEmpty else { return [] }
        return [ContentBlockerRule(trigger: .trigger(urlFilter: ".*", ifDomain: exceptions, resourceType: nil), action: .ignorePreviousRules())]
    }
    
    private func buildBlockingRules(from tracker: KnownTracker) -> [ContentBlockerRule] {
        guard tracker.defaultAction == .block else { return [] }
        guard let domain = tracker.domain else { return [] }
        let urlFilter = Constants.subDomainPrefix + domain.regexEscape() + Constants.domainMatchSuffix
        return [ ContentBlockerRule(trigger: .trigger(urlFilter: urlFilter,
                                                      unlessDomain: trackerData.relatedDomains(for: tracker.owner)?.wildcards()),
                                    action: .block()) ]        
    }

    private func buildRules(fromRule r: KnownTracker.Rule,
                            inTracker tracker: KnownTracker) -> [ContentBlockerRule] {
        
        return tracker.defaultAction == .block ?
            buildRulesForBlockingTracker(fromRule: r, inTracker: tracker) :
            buildRulesForIgnoringTracker(fromRule: r, inTracker: tracker)
    }
    
    private func buildRulesForIgnoringTracker(fromRule r: KnownTracker.Rule,
                                              inTracker tracker: KnownTracker) -> [ContentBlockerRule] {
        if r.action == .some(.ignore) {
            return [
                block(r, withOwner: tracker.owner),
                ignorePrevious(r, matching: r.options)
            ]
        } else if r.options == nil && r.exceptions == nil {
            return [
                block(r, withOwner: tracker.owner)
            ]
        } else if r.exceptions != nil && r.options != nil {
            return [
                block(r, withOwner: tracker.owner, matching: r.options),
                ignorePrevious(r, matching: r.exceptions)
            ]
        } else if r.options != nil {
            return [
                block(r, withOwner: tracker.owner, matching: r.options)
            ]
        } else if r.exceptions != nil {
            return [
                block(r, withOwner: tracker.owner),
                ignorePrevious(r, matching: r.exceptions)
            ]
        }
        
        return []
    }
    
    private func buildRulesForBlockingTracker(fromRule r: KnownTracker.Rule,
                                              inTracker tracker: KnownTracker) -> [ContentBlockerRule] {
        
        if r.options != nil && r.exceptions != nil {
            return [
                ignorePrevious(r),
                block(r, withOwner: tracker.owner, matching: r.options),
                ignorePrevious(r, matching: r.exceptions)
            ]
        } else if r.action == .some(.ignore) {
            return [
                ignorePrevious(r, matching: r.options)
            ]
        } else if r.options != nil {
            return [
                ignorePrevious(r),
                block(r, withOwner: tracker.owner, matching: r.options)
            ]
        } else if r.exceptions != nil {
            return [
                ignorePrevious(r, matching: r.exceptions)
            ]
        } else {
            return [
                block(r, withOwner: tracker.owner)
            ]
        }
    }
    
    private func block(_ rule: KnownTracker.Rule,
                       withOwner owner: KnownTracker.Owner?,
                       matching: KnownTracker.Rule.Matching? = nil) -> ContentBlockerRule {
        
        if let matching = matching {
            return ContentBlockerRule(trigger: .trigger(urlFilter: rule.normalizedRule(),
                                                        ifDomain: matching.domains?.prefixAll(with: "*"),
                                                        resourceType: matching.types?.mapResources()),
                                      action: .block())
            
        } else {
            return ContentBlockerRule(trigger: .trigger(urlFilter: rule.normalizedRule(),
                                                        unlessDomain: trackerData.relatedDomains(for: owner)?.wildcards()),
                                      action: .block())
        }
    }
    
    private func ignorePrevious(_ rule: KnownTracker.Rule, matching: KnownTracker.Rule.Matching? = nil) -> ContentBlockerRule {
        return ContentBlockerRule(trigger: .trigger(urlFilter: rule.normalizedRule(),
                                                    ifDomain: matching?.domains?.prefixAll(with: "*"),
                                                    resourceType: matching?.types?.mapResources()),
                                  action: .ignorePreviousRules())
    }
    
}

fileprivate extension String {
    
    func regexEscape() -> String {
        return replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ".", with: "\\.")
    }
    
}

fileprivate extension Array where Element: Hashable {
    
    func removeDuplicates() -> [Element] {
        var unique = Set<Element>()
        return compactMap { unique.insert($0).inserted ? $0 : nil }
    }
    
}

fileprivate extension Array where Element == String {
    
    func prefixAll(with prefix: String) -> [String] {
        return map { prefix + $0 }
    }
    
    func wildcards() -> [String] {
        return prefixAll(with: "*")
    }
    
    func normalizeAsUrls() -> [String] {
        return map { ContentBlockerRulesBuilder.Constants.subDomainPrefix + $0 + "/.*" }
    }
    
    func mapResources() -> [ContentBlockerRule.Trigger.ResourceType] {
        return compactMap { ContentBlockerRulesBuilder.resourceMapping[$0] }
    }
    
}

fileprivate extension KnownTracker.Rule {
    
    func normalizedRule() -> String {
        guard !rule!.hasPrefix("http") else { return rule! }
        return ContentBlockerRulesBuilder.Constants.subDomainPrefix + rule!
    }
    
}
