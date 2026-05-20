import Foundation

/// Handles migration from the flat memory.json format to the knowledge graph.
/// Run on app launch to convert existing memory entries to graph nodes.
public struct GraphMigration {

    /// Check if migration is needed and perform it.
    /// Returns the number of nodes created, or nil if no migration was needed.
    public static func migrateIfNeeded(
        memoryPath: URL,
        store: KnowledgeGraphStore
    ) -> Int? {
        // Check if migration is needed:
        // 1. memory.json exists
        // 2. knowledge_nodes table is empty
        guard FileManager.default.fileExists(atPath: memoryPath.path) else {
            Logger.debug("GraphMigration: No memory.json found, skipping migration")
            return nil
        }

        guard store.knowledgeNodeCount() == 0 else {
            Logger.debug("GraphMigration: Knowledge graph already populated, skipping migration")
            return nil
        }

        // Load existing memory entries
        let memoryStore = UserMemoryStore(filePath: memoryPath)
        let entries = memoryStore.load()

        guard !entries.isEmpty else {
            Logger.debug("GraphMigration: memory.json is empty, skipping migration")
            return nil
        }

        Logger.info("GraphMigration: Migrating \(entries.count) memory entries to knowledge graph")

        var nodesCreated = 0

        for entry in entries {
            let entityName = extractEntityName(from: entry.content)
            let sourceLabel = sourceToString(entry.source)

            switch entry.category {
            case .identity:
                // Identity entries become identity nodes with the full content as description
                let node = KnowledgeNode(
                    type: .identity,
                    name: entityName,
                    confidence: entry.confidence,
                    firstSeen: entry.firstSeen,
                    lastSeen: entry.lastSeen,
                    reinforcementCount: entry.reinforcementCount,
                    properties: [
                        "description": entry.content,
                        "source": sourceLabel
                    ]
                )
                store.upsertKnowledgeNode(node)
                nodesCreated += 1

            case .project:
                let node = KnowledgeNode(
                    type: .project,
                    name: entityName,
                    confidence: entry.confidence,
                    firstSeen: entry.firstSeen,
                    lastSeen: entry.lastSeen,
                    reinforcementCount: entry.reinforcementCount,
                    properties: [
                        "description": entry.content,
                        "source": sourceLabel
                    ]
                )
                store.upsertKnowledgeNode(node)
                nodesCreated += 1

            case .technology:
                let node = KnowledgeNode(
                    type: .technology,
                    name: entityName,
                    confidence: entry.confidence,
                    firstSeen: entry.firstSeen,
                    lastSeen: entry.lastSeen,
                    reinforcementCount: entry.reinforcementCount,
                    properties: [
                        "description": entry.content,
                        "source": sourceLabel
                    ]
                )
                store.upsertKnowledgeNode(node)
                nodesCreated += 1

            case .workflow:
                // Workflow entries map to skills
                let node = KnowledgeNode(
                    type: .skill,
                    name: entityName,
                    confidence: entry.confidence,
                    firstSeen: entry.firstSeen,
                    lastSeen: entry.lastSeen,
                    reinforcementCount: entry.reinforcementCount,
                    properties: [
                        "description": entry.content,
                        "source": sourceLabel
                    ]
                )
                store.upsertKnowledgeNode(node)
                nodesCreated += 1

            case .interest:
                let node = KnowledgeNode(
                    type: .topic,
                    name: entityName,
                    confidence: entry.confidence,
                    firstSeen: entry.firstSeen,
                    lastSeen: entry.lastSeen,
                    reinforcementCount: entry.reinforcementCount,
                    properties: [
                        "description": entry.content,
                        "source": sourceLabel
                    ]
                )
                store.upsertKnowledgeNode(node)
                nodesCreated += 1
            }
        }

        // Create implicit edges from co-occurrence patterns
        // (projects that appear with technologies in the same time window)
        createImplicitEdges(from: entries, store: store)

        // Backup the original memory.json
        let backupPath = memoryPath.deletingLastPathComponent().appendingPathComponent("memory.json.backup")
        do {
            if FileManager.default.fileExists(atPath: backupPath.path) {
                try FileManager.default.removeItem(at: backupPath)
            }
            try FileManager.default.copyItem(at: memoryPath, to: backupPath)
            Logger.info("GraphMigration: Backed up memory.json to memory.json.backup")
        } catch {
            Logger.warning("GraphMigration: Failed to backup memory.json: \(error.localizedDescription)")
        }

        Logger.info("GraphMigration: Created \(nodesCreated) nodes from \(entries.count) memory entries")
        return nodesCreated
    }

    // MARK: - Helper Functions

    /// Convert MemorySource to a string label for storage.
    private static func sourceToString(_ source: MemorySource) -> String {
        switch source {
        case .activityInference: return "activityInference"
        case .chatInteraction: return "chatInteraction"
        case .userExplicit: return "userExplicit"
        }
    }

    // MARK: - Entity Extraction

    /// Extract a concise entity name from a memory content string.
    /// For example: "Building a macOS activity tracker called Stubble" → "Stubble"
    private static func extractEntityName(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Helper to validate candidate before returning
        func validateCandidate(_ candidate: String) -> String? {
            let cleaned = candidate.trimmingCharacters(in: .punctuationCharacters)
            guard cleaned.count >= NodeValidator.minNameLength,
                  !NodeValidator.blockedTerms.contains(cleaned.lowercased()) else {
                return nil
            }
            return cleaned
        }

        // Look for "called X" pattern
        if let range = trimmed.range(of: "called ", options: .caseInsensitive) {
            let afterCalled = String(trimmed[range.upperBound...])
            let words = afterCalled.split(separator: " ", maxSplits: 2)
            if let first = words.first, let validated = validateCandidate(String(first)) {
                return validated
            }
        }

        // Look for "named X" pattern
        if let range = trimmed.range(of: "named ", options: .caseInsensitive) {
            let afterNamed = String(trimmed[range.upperBound...])
            let words = afterNamed.split(separator: " ", maxSplits: 2)
            if let first = words.first, let validated = validateCandidate(String(first)) {
                return validated
            }
        }

        // Look for quoted strings
        if let firstQuote = trimmed.firstIndex(of: "\""),
           let secondQuote = trimmed[trimmed.index(after: firstQuote)...].firstIndex(of: "\"") {
            let quoted = String(trimmed[trimmed.index(after: firstQuote)..<secondQuote])
            if let validated = validateCandidate(quoted) {
                return validated
            }
        }

        // Look for capitalized words that might be project/technology names
        let words = trimmed.split(separator: " ")
        for word in words {
            let wordStr = String(word).trimmingCharacters(in: .punctuationCharacters)
            // Skip common words
            let common = ["uses", "using", "with", "for", "the", "and", "building", "working", "on", "in", "a", "an"]
            guard !common.contains(wordStr.lowercased()) else { continue }
            // Look for PascalCase, camelCase, or fully capitalized
            if wordStr.first?.isUppercase == true && wordStr.count > 2 {
                if let validated = validateCandidate(wordStr) {
                    return validated
                }
            }
        }

        // Fall back to first few words (cleaned up)
        let firstWords = words.prefix(4).map { String($0) }.joined(separator: " ")
        return firstWords.isEmpty ? trimmed : firstWords
    }

    // MARK: - Implicit Edge Creation

    /// Create edges based on patterns in memory entries.
    /// For example, if a project and technology appear with similar timestamps, create a "uses" edge.
    private static func createImplicitEdges(from entries: [MemoryEntry], store: KnowledgeGraphStore) {
        // Group entries by category
        let projects = entries.filter { $0.category == .project }
        let technologies = entries.filter { $0.category == .technology }

        // Create "uses" edges for projects that mention technologies
        for project in projects {
            let projectName = extractEntityName(from: project.content)
            guard let projectNode = store.knowledgeNode(type: .project, name: projectName) else { continue }

            for tech in technologies {
                let techName = extractEntityName(from: tech.content)
                guard let techNode = store.knowledgeNode(type: .technology, name: techName) else { continue }

                // Check if the tech is mentioned in the project content
                if project.content.lowercased().contains(techName.lowercased()) {
                    let edge = KnowledgeEdge(
                        type: .uses,
                        sourceId: projectNode.id,
                        targetId: techNode.id,
                        confidence: min(project.confidence, tech.confidence),
                        firstSeen: max(project.firstSeen, tech.firstSeen),
                        lastSeen: max(project.lastSeen, tech.lastSeen)
                    )
                    store.upsertKnowledgeEdge(edge)
                }

                // Check if entries appeared within 24 hours of each other
                let timeDiff = abs(project.lastSeen.timeIntervalSince(tech.lastSeen))
                if timeDiff < 86400 {  // 24 hours
                    let edge = KnowledgeEdge(
                        type: .uses,
                        sourceId: projectNode.id,
                        targetId: techNode.id,
                        confidence: min(project.confidence, tech.confidence) * 0.7,  // Lower confidence for time-based inference
                        firstSeen: max(project.firstSeen, tech.firstSeen),
                        lastSeen: max(project.lastSeen, tech.lastSeen)
                    )
                    store.upsertKnowledgeEdge(edge)
                }
            }
        }
    }

    // MARK: - Backfill from Historical Data

    /// Backfill the knowledge graph from existing tasks and project_activities.
    /// This extracts project names, technologies (from apps), and creates relationships.
    /// Call this after initial migration to enrich the graph with historical data.
    public static func backfillFromHistoricalData(
        tasks: [TaskRecord],
        projectActivities: [ProjectActivityRecord],
        store: KnowledgeGraphStore
    ) -> Int {
        var nodesCreated = 0

        // Known technology apps and their canonical names
        let appToTechnology: [String: String] = [
            "xcode": "Swift",
            "visual studio code": "VS Code",
            "vscode": "VS Code",
            "terminal": "Command Line",
            "iterm": "Command Line",
            "docker": "Docker",
            "postman": "API Development",
            "figma": "Figma",
            "sketch": "Sketch",
            "safari": "Web Development",
            "chrome": "Web Development",
            "firefox": "Web Development",
            "slack": "Team Communication",
            "discord": "Team Communication",
            "notion": "Documentation",
            "linear": "Project Management",
            "github desktop": "Git",
            "tower": "Git",
            "sourcetree": "Git",
            "tableplus": "Database",
            "postico": "PostgreSQL",
            "datagrip": "Database",
            "simulator": "iOS Development",
            "instruments": "Performance Profiling"
        ]

        // Extract projects from project_activities
        for project in projectActivities {
            // Convert date string to Date
            let projectDate = SharedFormatters.dayFormatter.date(from: project.date) ?? Date()

            let node = KnowledgeNode(
                type: .project,
                name: project.name,
                confidence: 0.85,
                firstSeen: projectDate,
                lastSeen: projectDate,
                reinforcementCount: 1,
                properties: ["summary": project.summary]
            )

            // Check if already exists
            if store.knowledgeNode(type: .project, name: project.name) == nil {
                store.upsertKnowledgeNode(node)
                nodesCreated += 1
            }
        }

        // Extract technologies from task apps
        var techOccurrences: [String: (count: Int, firstSeen: Date, lastSeen: Date)] = [:]

        for task in tasks {
            for app in task.appNamesList {
                let appLower = app.lowercased()
                if let tech = appToTechnology[appLower] {
                    if var existing = techOccurrences[tech] {
                        existing.count += 1
                        existing.firstSeen = min(existing.firstSeen, task.startTime)
                        existing.lastSeen = max(existing.lastSeen, task.endTime)
                        techOccurrences[tech] = existing
                    } else {
                        techOccurrences[tech] = (1, task.startTime, task.endTime)
                    }
                }
            }
        }

        // Create technology nodes for frequently used apps
        for (tech, data) in techOccurrences where data.count >= 3 {
            let confidence = min(0.9, 0.5 + Double(data.count) * 0.05)
            let node = KnowledgeNode(
                type: .technology,
                name: tech,
                confidence: confidence,
                firstSeen: data.firstSeen,
                lastSeen: data.lastSeen,
                reinforcementCount: data.count
            )

            if store.knowledgeNode(type: .technology, name: tech) == nil {
                store.upsertKnowledgeNode(node)
                nodesCreated += 1
            }
        }

        // Create edges: project -> technology based on app co-occurrence
        for project in projectActivities {
            guard let projectNode = store.knowledgeNode(type: .project, name: project.name) else { continue }
            let projectDate = SharedFormatters.dayFormatter.date(from: project.date) ?? Date()

            // Find tasks on the same date that might be related
            let sameDateTasks = tasks.filter {
                Calendar.current.isDate($0.startTime, inSameDayAs: projectDate)
            }

            var projectTechs = Set<String>()
            for task in sameDateTasks {
                for app in task.appNamesList {
                    if let tech = appToTechnology[app.lowercased()] {
                        projectTechs.insert(tech)
                    }
                }
            }

            for tech in projectTechs {
                guard let techNode = store.knowledgeNode(type: .technology, name: tech) else { continue }

                let edge = KnowledgeEdge(
                    type: .uses,
                    sourceId: projectNode.id,
                    targetId: techNode.id,
                    confidence: 0.6,
                    firstSeen: projectDate,
                    lastSeen: projectDate
                )
                store.upsertKnowledgeEdge(edge)
            }
        }

        if nodesCreated > 0 {
            Logger.info("GraphMigration: Backfilled \(nodesCreated) nodes from historical data")
        }

        return nodesCreated
    }

    // MARK: - Cleanup Invalid Nodes

    /// Remove nodes that fail validation (garbage data like short names, first names, etc.).
    /// Returns the number of nodes deleted.
    public static func cleanupInvalidNodes(store: KnowledgeGraphStore) -> Int {
        var deleted = 0
        for node in store.knowledgeNodes(type: nil) {
            if !NodeValidator.isValidName(node.name, type: node.type) {
                store.deleteKnowledgeNode(id: node.id)
                deleted += 1
                Logger.debug("Graph cleanup: removed invalid node '\(node.name)' (type: \(node.type.rawValue))")
            }
        }
        return deleted
    }

    /// Extract interests/topics from browser URL domains.
    /// Maps common domains to topic areas.
    public static func extractTopicsFromBrowserHistory(
        activities: [ActivityRecord],
        store: KnowledgeGraphStore
    ) -> Int {
        // Domain patterns to topics
        let domainToTopic: [String: String] = [
            // Developer & Tech
            "github.com": "Open Source",
            "gitlab.com": "Open Source",
            "stackoverflow.com": "Problem Solving",
            "developer.apple.com": "Apple Development",
            "docs.swift.org": "Swift",
            "react.dev": "React",
            "vuejs.org": "Vue.js",
            "angular.io": "Angular",
            "nodejs.org": "Node.js",
            "python.org": "Python",
            "rust-lang.org": "Rust",
            "go.dev": "Go",
            "kubernetes.io": "Kubernetes",
            "docker.com": "Docker",
            "aws.amazon.com": "AWS",
            "cloud.google.com": "Google Cloud",
            "azure.microsoft.com": "Azure",
            "vercel.com": "Web Development",
            "netlify.com": "Web Development",

            // Tech News & Blogs
            "medium.com": "Tech Blogs",
            "dev.to": "Developer Community",
            "hackernews.com": "Tech News",
            "news.ycombinator.com": "Tech News",
            "techcrunch.com": "Tech News",
            "theverge.com": "Tech News",
            "wired.com": "Tech News",
            "arstechnica.com": "Tech News",

            // AI & ML
            "arxiv.org": "Research",
            "openai.com": "AI/ML",
            "anthropic.com": "AI/ML",
            "huggingface.co": "Machine Learning",
            "tensorflow.org": "Machine Learning",
            "pytorch.org": "Machine Learning",
            "midjourney.com": "AI Art",

            // Design
            "figma.com": "Design",
            "dribbble.com": "Design",
            "behance.net": "Design",
            "canva.com": "Design",

            // Video & Entertainment
            "youtube.com": "Video Content",
            "youtu.be": "Video Content",
            "vimeo.com": "Video Content",
            "twitch.tv": "Streaming",
            "netflix.com": "Entertainment",
            "spotify.com": "Music",

            // News & Media
            "nytimes.com": "News",
            "wsj.com": "Business News",
            "bbc.com": "News",
            "cnn.com": "News",
            "reuters.com": "News",
            "bloomberg.com": "Business News",
            "ft.com": "Business News",
            "economist.com": "Business News",
            "theguardian.com": "News",
            "washingtonpost.com": "News",

            // Social & Professional
            "twitter.com": "Social Media",
            "x.com": "Social Media",
            "linkedin.com": "Professional Networking",
            "reddit.com": "Community",
            "discord.com": "Community",

            // Learning
            "coursera.org": "Online Learning",
            "udemy.com": "Online Learning",
            "edx.org": "Online Learning",
            "khanacademy.org": "Online Learning",
            "skillshare.com": "Online Learning",

            // Finance & Crypto
            "coinbase.com": "Cryptocurrency",
            "binance.com": "Cryptocurrency",
            "finance.yahoo.com": "Finance",
            "tradingview.com": "Finance",

            // Productivity
            "notion.so": "Productivity",
            "linear.app": "Project Management",
            "asana.com": "Project Management",
            "trello.com": "Project Management",
            "jira.atlassian.com": "Project Management",
            "confluence.atlassian.com": "Documentation",
            "docs.google.com": "Documentation",
            "airtable.com": "Productivity"
        ]

        var domainCounts: [String: (topic: String, count: Int, firstSeen: Date, lastSeen: Date)] = [:]

        for activity in activities {
            guard let urlString = activity.browserURL,
                  let url = URL(string: urlString),
                  let host = url.host else { continue }

            let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

            for (pattern, topic) in domainToTopic {
                if domain.contains(pattern) || pattern.contains(domain) {
                    if var existing = domainCounts[topic] {
                        existing.count += 1
                        existing.firstSeen = min(existing.firstSeen, activity.timestamp)
                        existing.lastSeen = max(existing.lastSeen, activity.timestamp)
                        domainCounts[topic] = existing
                    } else {
                        domainCounts[topic] = (topic, 1, activity.timestamp, activity.timestamp)
                    }
                    break
                }
            }
        }

        var nodesCreated = 0

        // Create topic nodes for interests seen multiple times
        for (topic, data) in domainCounts where data.count >= 2 {
            let confidence = min(0.85, 0.4 + Double(data.count) * 0.1)
            let node = KnowledgeNode(
                type: .topic,
                name: topic,
                confidence: confidence,
                firstSeen: data.firstSeen,
                lastSeen: data.lastSeen,
                reinforcementCount: data.count
            )

            if store.knowledgeNode(type: .topic, name: topic) == nil {
                store.upsertKnowledgeNode(node)
                nodesCreated += 1
            }
        }

        if nodesCreated > 0 {
            Logger.info("GraphMigration: Created \(nodesCreated) topic nodes from browser history")
        }

        return nodesCreated
    }
}
