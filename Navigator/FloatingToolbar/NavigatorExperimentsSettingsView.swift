import SwiftUI
import Vendors

/// Settings → Experiments: one toggle per entry in `NavigatorExperiment.all`.
struct NavigatorExperimentsSettingsView: View {
	private let experiments = NavigatorExperiments.shared

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 14) {
				Text("Work-in-progress ideas. Flip them on and off to compare; changes apply immediately.")
					.font(.system(size: 12))
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)

				ForEach(NavigatorExperiment.all) { experiment in
					Toggle(isOn: binding(for: experiment)) {
						VStack(alignment: .leading, spacing: 2) {
							Text(experiment.title)
								.font(.system(size: 13, weight: .medium))
							Text(experiment.summary)
								.font(.system(size: 11))
								.foregroundStyle(.secondary)
								.fixedSize(horizontal: false, vertical: true)
						}
					}
					.toggleStyle(.switch)
					.controlSize(.small)
				}

				Button("Reset to Defaults") {
					withAnimation(FloatingMotion.snappy) {
						experiments.resetAll()
					}
				}
				.controlSize(.small)
				.padding(.top, 4)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.scrollIndicators(.never)
	}

	private func binding(for experiment: NavigatorExperiment) -> Binding<Bool> {
		Binding(
			get: { experiments.isEnabled(experiment) },
			set: { isOn in
				withAnimation(FloatingMotion.snappy) {
					experiments.setEnabled(experiment, isOn)
				}
			}
		)
	}
}
