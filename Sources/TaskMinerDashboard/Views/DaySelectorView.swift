import SwiftUI
import TaskMinerShared

/// Horizontal scrollable date picker showing day numbers only.
/// Today is rightmost. Days with no data are greyed out.
struct DaySelectorView: View {
    @Environment(DashboardViewModel.self) var viewModel

    private let dayCount = 30

    private var days: [DayItem] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let availableSet = Set(viewModel.availableDates)

        return (0..<dayCount).reversed().map { offset in
            let date = cal.date(byAdding: .day, value: -offset, to: today)!
            let dateStr = dateFmt.string(from: date)
            let dayNum = cal.component(.day, from: date)
            let isToday = offset == 0
            let hasData = availableSet.contains(dateStr)
            let isSelected = cal.isDate(date, inSameDayAs: viewModel.selectedDate)
            return DayItem(
                date: date,
                dayNumber: dayNum,
                isToday: isToday,
                hasData: hasData,
                isSelected: isSelected
            )
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(days) { day in
                            DayPill(day: day) {
                                viewModel.selectDate(day.date)
                            }
                            .id(day.id)
                        }
                    }
                    // Wide padding so the first/last items can be centered
                    .padding(.horizontal, geometry.size.width / 2 - 18)
                    .padding(.vertical, 8)
                }
                .onAppear {
                    let cal = Calendar.current
                    let selectedStart = cal.startOfDay(for: viewModel.selectedDate)
                    proxy.scrollTo(selectedStart, anchor: .center)
                }
                .onChange(of: viewModel.selectedDate) { _, newDate in
                    let cal = Calendar.current
                    let selectedStart = cal.startOfDay(for: newDate)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(selectedStart, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 48)
    }
}

struct DayItem: Identifiable {
    let date: Date
    let dayNumber: Int
    let isToday: Bool
    let hasData: Bool
    let isSelected: Bool

    var id: Date { date }
}

struct DayPill: View {
    let day: DayItem
    let action: () -> Void

    private var pillSize: CGFloat { day.isSelected ? 36 : 32 }
    private var fontSize: CGFloat { day.isSelected ? 15 : 13 }

    var body: some View {
        Button(action: action) {
            Text("\(day.dayNumber)")
                .font(.system(size: fontSize, weight: day.isSelected ? .bold : .medium).monospacedDigit())
                .foregroundStyle(foregroundColor)
                .frame(width: pillSize, height: pillSize)
                .background(backgroundColor)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        if day.isSelected {
            return Theme.textPrimary
        } else if !day.hasData {
            return Theme.textMuted.opacity(0.5)
        } else {
            return Theme.textPrimary
        }
    }

    private var backgroundColor: Color {
        if day.isSelected {
            return Theme.selectedSurface
        } else {
            return Color.clear
        }
    }
}
