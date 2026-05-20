import SwiftUI
import TaskMinerShared

/// Developer debug view for inspecting the knowledge graph.
/// Access via Option key to reveal the Graph tab.
struct GraphDebugView: View {
    @State private var nodes: [KnowledgeNode] = []
    @State private var edges: [KnowledgeEdge] = []
    @State private var selectedNode: KnowledgeNode?
    @State private var isLoading = true
    @State private var userName: String = "You"

    // Zoom and pan state
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    // Filters
    @State private var showIdentity = true
    @State private var showProjects = true
    @State private var showTechnologies = true
    @State private var showSkills = true
    @State private var showTopics = true
    @State private var minConfidence: Double = 0.0

    let dbReader: DatabaseReader

    init(dbReader: DatabaseReader) {
        self.dbReader = dbReader
    }

    var body: some View {
        HSplitView {
            // Left panel: Graph visualization
            graphVisualization
                .frame(minWidth: 500)

            // Right panel: Node details
            nodeDetailPanel
                .frame(width: 260)
        }
        .background(Theme.primaryBackground)
        .task {
            await loadGraph()
        }
    }

    // MARK: - Graph Visualization (Radial Layout)

    private var graphVisualization: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let maxRadius = min(geometry.size.width, geometry.size.height) / 2 - 60

            ZStack {
                if isLoading {
                    ProgressView("Loading graph...")
                } else if filteredNodes.isEmpty {
                    emptyState
                } else {
                    // Graph content with zoom/pan transforms
                    graphContent(center: center, maxRadius: maxRadius)
                        .scaleEffect(scale)
                        .offset(offset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let delta = value.magnification / lastScale
                        lastScale = value.magnification
                        scale = min(max(scale * delta, 0.5), 3.0)
                    }
                    .onEnded { _ in
                        lastScale = 1.0
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        lastOffset = offset
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        withAnimation(.spring(response: 0.3)) {
                            scale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        }
                    }
            )
            .overlay(alignment: .bottomTrailing) {
                zoomControls
                    .padding()
            }
        }
        .padding()
    }

    // MARK: - Zoom Controls

    private var zoomControls: some View {
        VStack(spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.3)) {
                    scale = min(scale * 1.25, 3.0)
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .background(Theme.secondaryBackground.opacity(0.8))
            .cornerRadius(6)

            Button {
                withAnimation(.spring(response: 0.3)) {
                    scale = max(scale / 1.25, 0.5)
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .background(Theme.secondaryBackground.opacity(0.8))
            .cornerRadius(6)

            Button {
                withAnimation(.spring(response: 0.3)) {
                    scale = 1.0
                    offset = .zero
                    lastOffset = .zero
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .background(Theme.secondaryBackground.opacity(0.8))
            .cornerRadius(6)
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
    }

    // MARK: - Graph Content

    @ViewBuilder
    private func graphContent(center: CGPoint, maxRadius: CGFloat) -> some View {
        ZStack {
            // Draw edges from nodes to their category centers
            ForEach(filteredNodes) { node in
                let nodePos = nodePosition(node: node, center: center, maxRadius: maxRadius)
                let categoryPos = categoryPosition(for: node.type, center: center, radius: maxRadius * 0.4)

                Path { path in
                    path.move(to: categoryPos)
                    path.addLine(to: nodePos)
                }
                .stroke(nodeColor(for: node.type).opacity(0.3), lineWidth: 1)
            }

            // Draw lines from center to categories
            ForEach(NodeType.allCases, id: \.self) { type in
                if hasNodesOfType(type) {
                    let categoryPos = categoryPosition(for: type, center: center, radius: maxRadius * 0.4)

                    Path { path in
                        path.move(to: center)
                        path.addLine(to: categoryPos)
                    }
                    .stroke(Theme.separator, lineWidth: 2)
                }
            }

            // Category labels (middle ring)
            ForEach(NodeType.allCases, id: \.self) { type in
                if hasNodesOfType(type) {
                    categoryLabel(type: type, center: center, radius: maxRadius * 0.4)
                }
            }

            // Individual nodes (outer ring)
            ForEach(filteredNodes) { node in
                nodeCircle(node: node, center: center, maxRadius: maxRadius)
            }

            // Center: User
            userCenterNode(center: center)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No knowledge yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Stubble learns about your projects, technologies, and interests as you work.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
    }

    // MARK: - Center Node (User)

    private func userCenterNode(center: CGPoint) -> some View {
        ZStack {
            Circle()
                .fill(Theme.accent)
                .frame(width: 64, height: 64)
                .shadow(color: Theme.accent.opacity(0.3), radius: 8, x: 0, y: 2)

            Text(userName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .position(center)
    }

    // MARK: - Category Labels

    private func categoryLabel(type: NodeType, center: CGPoint, radius: CGFloat) -> some View {
        let position = categoryPosition(for: type, center: center, radius: radius)
        let count = filteredNodes.filter { $0.type == type }.count

        return ZStack {
            Circle()
                .fill(nodeColor(for: type).opacity(0.15))
                .frame(width: 80, height: 80)

            Circle()
                .stroke(nodeColor(for: type), lineWidth: 2)
                .frame(width: 80, height: 80)

            VStack(spacing: 2) {
                Image(systemName: iconForType(type))
                    .font(.system(size: 18))
                    .foregroundStyle(nodeColor(for: type))
                Text(type.rawValue.capitalized)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                Text("\(count)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .position(position)
        .onTapGesture {
            selectedNode = nil
        }
    }

    private func iconForType(_ type: NodeType) -> String {
        switch type {
        case .identity: return "person.fill"
        case .project: return "folder.fill"
        case .technology: return "hammer.fill"
        case .skill: return "star.fill"
        case .topic: return "lightbulb.fill"
        }
    }

    // MARK: - Individual Nodes

    private func nodeCircle(node: KnowledgeNode, center: CGPoint, maxRadius: CGFloat) -> some View {
        let position = nodePosition(node: node, center: center, maxRadius: maxRadius)
        let isSelected = selectedNode?.id == node.id

        // Confidence-based sizing: base size + confidence bonus
        let baseSize: CGFloat = isSelected ? 32 : 20
        let confidenceBonus = CGFloat(node.confidence) * 6
        let size = baseSize + confidenceBonus

        // Calculate outward label position (radially outward from center)
        let dx = position.x - center.x
        let dy = position.y - center.y
        let labelAngle = atan2(dy, dx)
        let labelOffset = size / 2 + 12
        let labelPos = CGPoint(
            x: position.x + cos(labelAngle) * labelOffset,
            y: position.y + sin(labelAngle) * labelOffset
        )

        return ZStack {
            Circle()
                .fill(nodeColor(for: node.type))
                .frame(width: size, height: size)
                .opacity(0.7 + node.confidence * 0.3)

            if isSelected {
                Circle()
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: size + 4, height: size + 4)
            }

            Text(String(node.name.prefix(2)).uppercased())
                .font(.system(size: isSelected ? 11 : 9, weight: .bold))
                .foregroundStyle(.white)
        }
        .position(position)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedNode = node
            }
        }
        .overlay(
            Text(node.name)
                .font(.system(size: 9))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 80)
                .multilineTextAlignment(.center)
                .position(labelPos)
                .opacity(isSelected ? 1 : 0.7)
        )
    }

    // MARK: - Positioning

    private func categoryPosition(for type: NodeType, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = angleForType(type)
        return CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
    }

    private func angleForType(_ type: NodeType) -> CGFloat {
        switch type {
        case .identity:   return -.pi * 3 / 4     // Top-left (10:30)
        case .project:    return -.pi / 2          // Top (12 o'clock)
        case .technology: return 0                  // Right (3 o'clock)
        case .skill:      return .pi / 2           // Bottom (6 o'clock)
        case .topic:      return .pi               // Left (9 o'clock)
        }
    }

    private func nodePosition(node: KnowledgeNode, center: CGPoint, maxRadius: CGFloat) -> CGPoint {
        let typeNodes = filteredNodes.filter { $0.type == node.type }
        guard let index = typeNodes.firstIndex(where: { $0.id == node.id }) else {
            return center
        }

        let baseAngle = angleForType(node.type)
        let count = typeNodes.count

        // Multi-ring layout: 8 nodes per ring, overflow to outer rings
        let nodesPerRing = 8
        let ring = index / nodesPerRing
        let positionInRing = index % nodesPerRing
        let nodesInThisRing = min(nodesPerRing, count - ring * nodesPerRing)

        // Wider spread angle (72° base, +6° per ring for outer rings)
        let spreadAngle: CGFloat = .pi / 2.5 + CGFloat(ring) * 0.1

        let angleOffset: CGFloat
        if nodesInThisRing == 1 {
            angleOffset = 0
        } else {
            let normalizedIndex = CGFloat(positionInRing) / CGFloat(nodesInThisRing - 1) - 0.5
            angleOffset = normalizedIndex * spreadAngle
        }

        // Radius increases with each ring (inner ring at 55%, +12% per ring)
        let baseRadius = maxRadius * 0.55
        let ringSpacing = maxRadius * 0.12
        let radius = baseRadius + CGFloat(ring) * ringSpacing

        let angle = baseAngle + angleOffset
        return CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
    }

    // MARK: - Colors

    private func nodeColor(for type: NodeType) -> Color {
        switch type {
        case .identity:   return .pink
        case .project:    return .blue
        case .technology: return .green
        case .skill:      return .orange
        case .topic:      return .purple
        }
    }

    // MARK: - Detail Panel

    @State private var isRebuilding = false

    private var nodeDetailPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Details")
                    .font(.headline)
                Spacer()

                // Rebuild button
                Button {
                    rebuildGraph()
                } label: {
                    if isRebuilding {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Rebuild graph from history")
                .disabled(isRebuilding)

                // Filter toggles
                Menu {
                    Toggle("Identity", isOn: $showIdentity)
                    Toggle("Projects", isOn: $showProjects)
                    Toggle("Technologies", isOn: $showTechnologies)
                    Toggle("Skills", isOn: $showSkills)
                    Toggle("Topics", isOn: $showTopics)
                    Divider()
                    Button("Export JSON") {
                        exportGraph()
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
            .padding()
            .background(Theme.secondaryBackground)

            Divider()

            if let node = selectedNode {
                nodeDetails(node)
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "hand.tap")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("Tap a node to see details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.primaryBackground)
    }

    @ViewBuilder
    private func nodeDetails(_ node: KnowledgeNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(nodeColor(for: node.type))
                            .frame(width: 40, height: 40)
                        Image(systemName: iconForType(node.type))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name)
                            .font(.headline)
                        Text(node.type.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Stats
                VStack(spacing: 8) {
                    HStack {
                        Label("\(Int(node.confidence * 100))%", systemImage: "chart.bar.fill")
                        Spacer()
                        Text("confidence")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)

                    HStack {
                        Label("\(node.reinforcementCount)", systemImage: "arrow.counterclockwise")
                        Spacer()
                        Text("reinforcements")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                .padding()
                .background(Theme.secondaryBackground)
                .cornerRadius(8)

                // Timeline
                VStack(alignment: .leading, spacing: 4) {
                    Text("Timeline")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("First seen")
                            .font(.caption)
                        Spacer()
                        Text(formatDate(node.firstSeen))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Last seen")
                            .font(.caption)
                        Spacer()
                        Text(formatDate(node.lastSeen))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Aliases
                if !node.aliases.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Also known as")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        FlowLayout(spacing: 4) {
                            ForEach(node.aliases, id: \.self) { alias in
                                Text(alias)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Theme.secondaryBackground)
                                    .cornerRadius(4)
                            }
                        }
                    }
                }

                // Connected edges
                let connectedEdges = edges.filter { $0.sourceId == node.id || $0.targetId == node.id }
                if !connectedEdges.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connections")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(connectedEdges) { edge in
                            edgeRow(edge, currentNode: node)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func edgeRow(_ edge: KnowledgeEdge, currentNode: KnowledgeNode) -> some View {
        let isSource = edge.sourceId == currentNode.id
        let otherNodeId = isSource ? edge.targetId : edge.sourceId
        let otherNode = nodes.first { $0.id == otherNodeId }

        return HStack(spacing: 6) {
            Image(systemName: isSource ? "arrow.right" : "arrow.left")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Text(edge.type.rawValue)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.secondaryBackground)
                .cornerRadius(4)

            if let other = otherNode {
                Circle()
                    .fill(nodeColor(for: other.type))
                    .frame(width: 8, height: 8)
                Text(other.name)
                    .font(.caption)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    // MARK: - Filtering

    private var filteredNodes: [KnowledgeNode] {
        nodes.filter { node in
            switch node.type {
            case .identity: guard showIdentity else { return false }
            case .project: guard showProjects else { return false }
            case .technology: guard showTechnologies else { return false }
            case .skill: guard showSkills else { return false }
            case .topic: guard showTopics else { return false }
            }
            guard node.confidence >= minConfidence else { return false }
            return true
        }
    }

    private func hasNodesOfType(_ type: NodeType) -> Bool {
        filteredNodes.contains { $0.type == type }
    }

    // MARK: - Data Loading

    private func loadGraph() async {
        isLoading = true

        await MainActor.run {
            nodes = dbReader.knowledgeNodes()
            edges = dbReader.knowledgeEdges()

            // Try to get user name from memory profile
            let memoryPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Stubble")
                .appendingPathComponent("memory.json")

            if let path = memoryPath {
                let store = UserMemoryStore(filePath: path)
                let entries = store.load()
                if let nameEntry = entries.first(where: { $0.category == .identity && $0.content.lowercased().contains("name") }) {
                    // Extract name from content like "Name is Sam" or "Sam is the user"
                    let words = nameEntry.content.components(separatedBy: .whitespaces)
                    if let nameIndex = words.firstIndex(where: { $0.lowercased() == "name" || $0.lowercased() == "is" }),
                       nameIndex + 1 < words.count {
                        let possibleName = words[nameIndex + 1].trimmingCharacters(in: .punctuationCharacters)
                        if possibleName.count > 1 && possibleName.first?.isUppercase == true {
                            userName = possibleName
                        }
                    }
                }
            }
        }

        isLoading = false
    }

    // MARK: - Rebuild

    private func rebuildGraph() {
        isRebuilding = true

        // Post distributed notification to daemon to trigger backfill
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("rebuildKnowledgeGraph"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        // Wait a bit then reload
        Task {
            try? await Task.sleep(for: .seconds(2))
            await loadGraph()
            isRebuilding = false
        }
    }

    // MARK: - Export

    private func exportGraph() {
        let data: [String: Any] = [
            "nodes": nodes.map { node -> [String: Any] in
                [
                    "id": node.id.uuidString,
                    "type": node.type.rawValue,
                    "name": node.name,
                    "aliases": node.aliases,
                    "confidence": node.confidence,
                    "reinforcement_count": node.reinforcementCount,
                    "first_seen": formatDate(node.firstSeen),
                    "last_seen": formatDate(node.lastSeen)
                ]
            },
            "edges": edges.map { edge -> [String: Any] in
                [
                    "id": edge.id.uuidString,
                    "type": edge.type.rawValue,
                    "source_id": edge.sourceId.uuidString,
                    "target_id": edge.targetId.uuidString,
                    "confidence": edge.confidence,
                    "context": edge.context as Any
                ]
            }
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(jsonString, forType: .string)
        }
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#Preview {
    if let dbReader = try? DatabaseReader(path: URL(fileURLWithPath: "/tmp/test.db")) {
        GraphDebugView(dbReader: dbReader)
            .frame(width: 800, height: 600)
    } else {
        Text("Failed to create preview database")
    }
}
