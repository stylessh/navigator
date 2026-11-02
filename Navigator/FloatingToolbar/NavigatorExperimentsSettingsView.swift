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

				Toggle(isOn: allBinding) {
					VStack(alignment: .leading, spacing: 2) {
						Text("All experiments")
							.font(.system(size: 13, weight: .semibold))
						Text("\(experiments.enabledCount) of \(NavigatorExperiment.all.count) on")
							.font(.system(size: 11))
							.foregroundStyle(.secondary)
							.monospacedDigit()
					}
				}
				.toggleStyle(.switch)
				.controlSize(.small)

				Divider()

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

	/// On only when every experiment is on; flipping it turns all of them on or off.
	private var allBinding: Binding<Bool> {
		Binding(
			get: { experiments.enabledCount == NavigatorExperiment.all.count },
			set: { isOn in
				withAnimation(FloatingMotion.snappy) {
					experiments.setAllEnabled(isOn)
				}
			}
		)
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
