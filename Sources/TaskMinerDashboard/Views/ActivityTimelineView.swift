import SwiftUI
import TaskMinerShared

struct ActivityTimelineView: View {
    @Environment(DashboardViewModel.self) var viewModel

    var body: some View {
        VStack(spacing: 0) {
            // Visual timeline bar
            if !viewModel.groupedActivities.isEmpty {
                TimelineBarView(groups: viewModel.groupedActivities)
                    .frame(height: 28)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                Rectangle()
                    .fill(Theme.separator)
                    .frame(height: 1)
            }

            // Activity list
            if viewModel.groupedActivities.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.textQuaternary)
                    Text("No activity recorded")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.groupedActivities) { group in
                            ActivityGroupView(group: group)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
    }
}
