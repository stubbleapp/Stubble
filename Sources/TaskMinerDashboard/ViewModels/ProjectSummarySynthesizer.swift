import Foundation
import TaskMinerShared

/// Synthesizes comprehensive project summaries from aggregated task data.
/// Unlike daily summaries which describe what was done that day, synthesized
/// summaries describe WHAT the project IS (e.g., "Building a macOS app for time tracking").
final class ProjectSummarySynthesizer: Sendable {
    private let geminiClient: GeminiClient

    init(geminiClient: GeminiClient) {
        self.geminiClient = geminiClient
    }

    // MARK: - Public API

    /// Synthesize a comprehensive summary for a project based on all available data.
    /// Returns a 1-2 sentence description of what the project IS, not just what was done.
    func synthesize(
        project: AggregatedProject,
        memoryContext: String?
    ) async throws -> String {
        let prompt = buildPrompt(project: project, memoryContext: memoryContext)

        let systemInstruction = """
        You are analyzing a user's work project to describe WHAT it is. \
        Based on the task titles, apps used, and any user context, write a 1-2 sentence \
        description of what this project IS — the deliverable, product, or goal. \
        \
        Examples of good summaries: \
        - "A macOS menu bar app for tracking productivity and screen time, built with SwiftUI and SQLite." \
        - "Q4 marketing campaign materials including email templates and landing page designs." \
        - "Python data pipeline for processing customer analytics from multiple sources." \
        - "Internal documentation wiki migration from Confluence to Notion." \
        \
        Rules: \
        - Describe the PROJECT, not the activities (not "Working on..." but "A macOS app for...") \
        - Include the technology stack when evident from task titles or apps (Swift, React, Python, etc.) \
        - Include the purpose or audience when evident (for customers, internal team, etc.) \
        - Be specific — extract concrete details from task titles \
        - If task titles are generic (emails, meetings), describe the apparent work type \
        - Maximum 2 sentences, aim for 1 when possible \
        \
        Respond with ONLY the summary text, no JSON, no quotes, no explanation.
        """

        for attempt in 0..<2 {
            do {
                let response = try await geminiClient.generateContent(
                    prompt: prompt,
                    systemInstruction: systemInstruction
                )

                // Clean up the response (remove quotes, whitespace)
                let summary = response
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !summary.isEmpty && summary.count > 10 && summary.count < 500 {
                    return summary
                }

                if attempt == 0 {
                    Logger.warning("ProjectSummarySynthesizer: invalid response length, retrying")
                }
            } catch {
                if attempt == 1 { throw error }
                Logger.warning("ProjectSummarySynthesizer: API error (attempt 1): \(error.localizedDescription)")
            }
        }

        // Fallback: return the existing summary or generate a basic one
        if !project.summary.isEmpty {
            return project.summary
        }

        // Generate a basic fallback summary from available data
        return generateFallbackSummary(project: project)
    }

    /// Batch synthesize summaries for multiple projects.
    /// Returns a dictionary mapping project IDs to synthesized summaries.
    func synthesizeBatch(
        projects: [AggregatedProject],
        memoryContext: String?
    ) async -> [UUID: String] {
        var results: [UUID: String] = [:]

        // Process in parallel with limited concurrency
        await withTaskGroup(of: (UUID, String?).self) { group in
            for project in projects {
                // Skip projects with good existing summaries
                if hasGoodSummary(project) {
                    results[project.id] = project.summary
                    continue
                }

                group.addTask {
                    do {
                        let summary = try await self.synthesize(
                            project: project,
                            memoryContext: memoryContext
                        )
                        return (project.id, summary)
                    } catch {
                        Logger.warning("ProjectSummarySynthesizer: failed for \(project.name): \(error.localizedDescription)")
                        return (project.id, nil)
                    }
                }
            }

            for await (id, summary) in group {
                if let summary = summary {
                    results[id] = summary
                }
            }
        }

        return results
    }

    // MARK: - Private Helpers

    private func buildPrompt(project: AggregatedProject, memoryContext: String?) -> String {
        var lines: [String] = []

        // User context (helps identify their role and typical work)
        if let memory = memoryContext, !memory.isEmpty {
            lines.append("## User Context")
            lines.append(memory)
            lines.append("")
        }

        // Project name
        lines.append("## Project: \(project.name)")
        lines.append("")

        // Time investment (helps gauge project significance)
        let totalHours = project.totalDuration / 3600
        lines.append("Time invested: \(String(format: "%.1f", totalHours)) hours over \(project.daysActive) day\(project.daysActive == 1 ? "" : "s")")
        lines.append("")

        // Apps used (strong signal for technology/work type)
        if !project.appNames.isEmpty {
            lines.append("## Apps Used")
            lines.append(project.appNames.sorted().joined(separator: ", "))
            lines.append("")
        }

        // Task titles (primary source of context)
        if !project.taskTitles.isEmpty {
            lines.append("## Task Titles (activities performed)")
            for title in project.taskTitles.prefix(20) {
                lines.append("- \(title)")
            }
            lines.append("")
        }

        // Existing summary if available (might have useful context)
        if !project.summary.isEmpty {
            lines.append("## Daily Summary (most recent)")
            lines.append(project.summary)
            lines.append("")
        }

        lines.append("Based on the above, describe WHAT this project IS in 1-2 sentences.")

        return lines.joined(separator: "\n")
    }

    /// Check if a project already has a good summary that doesn't need synthesis.
    private func hasGoodSummary(_ project: AggregatedProject) -> Bool {
        let summary = project.summary.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty or very short
        if summary.count < 20 { return false }

        // Contains project description (what it IS, not just what was done)
        let projectIndicators = [
            "app for", "tool for", "system for", "platform for",
            "website for", "api for", "service for", "dashboard for",
            "built with", "using swift", "using react", "using python",
            "macOS app", "iOS app", "web app", "mobile app"
        ]

        let lowercased = summary.lowercased()
        for indicator in projectIndicators {
            if lowercased.contains(indicator) {
                return true
            }
        }

        // If it starts with a gerund, it's probably an activity description, not a project description
        let activityStarters = [
            "working on", "developing", "building", "implementing",
            "debugging", "testing", "reviewing", "updating"
        ]

        for starter in activityStarters {
            if lowercased.hasPrefix(starter) {
                return false
            }
        }

        // Assume good if reasonably long and not starting with activity words
        return summary.count >= 50
    }

    /// Generate a basic fallback summary without AI.
    private func generateFallbackSummary(project: AggregatedProject) -> String {
        let apps = project.appNames.sorted()
        let hours = project.totalDuration / 3600

        // Infer project type from apps
        let hasIDE = apps.contains { ["Xcode", "VS Code", "Visual Studio Code", "IntelliJ IDEA", "PyCharm", "Android Studio", "Cursor"].contains($0) }
        let hasDesign = apps.contains { ["Figma", "Sketch", "Adobe XD", "Photoshop", "Illustrator"].contains($0) }
        let hasComms = apps.contains { ["Slack", "Microsoft Teams", "Discord", "Zoom"].contains($0) }
        let hasBrowser = apps.contains { ["Safari", "Chrome", "Firefox", "Arc", "Brave"].contains($0) }

        if hasIDE && apps.contains("Xcode") {
            return "Software development project using Xcode (\(String(format: "%.1f", hours))h invested)."
        } else if hasIDE {
            return "Software development project (\(String(format: "%.1f", hours))h invested)."
        } else if hasDesign {
            return "Design project (\(String(format: "%.1f", hours))h invested)."
        } else if hasComms && !hasIDE && !hasDesign {
            return "Communications and collaboration work (\(String(format: "%.1f", hours))h invested)."
        } else if hasBrowser && apps.count <= 2 {
            return "Research and browsing work (\(String(format: "%.1f", hours))h invested)."
        } else {
            return "Work project spanning \(project.daysActive) day\(project.daysActive == 1 ? "" : "s") (\(String(format: "%.1f", hours))h invested)."
        }
    }
}
