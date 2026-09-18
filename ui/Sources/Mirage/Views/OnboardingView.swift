import SwiftUI

/// Setup gate. Shown until an eligible device and a valid consent record both exist.
///
/// The order matters: device eligibility is checked *before* the age gate, so a managed
/// phone is turned away without anyone being asked to verify anything.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                StepCard(number: 1, title: "Engine", state: engineState) {
                    engineDetail
                }

                StepCard(number: 2, title: "Your iPhone", state: deviceState) {
                    deviceDetail
                }

                StepCard(number: 3, title: "Age verification", state: ageState) {
                    ageDetail
                }

                StepCard(number: 4, title: "What Mirage may do", state: grantState) {
                    grantsDetail
                }

                if let err = model.consentError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                }
            }
            .padding(32)
            .frame(maxWidth: 680)
        }
        .frame(maxWidth: .infinity)
        .background(.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "location.viewfinder")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            Text("Set up Mirage")
                .font(.system(size: 26, weight: .bold))
            Text("Mirage changes the location your iPhone reports, including to everyone you share your location with in Find My. Setup confirms who owns this device and what you are allowing.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Step 1: engine

    private var engineState: StepState {
        switch model.engine.phase {
        case .running: model.connected ? .done : .active
        case .starting: .active
        case .failed, .notConfigured: .blocked
        case .stopped: .pending
        }
    }

    @ViewBuilder private var engineDetail: some View {
        switch model.engine.phase {
        case .running where model.connected:
            Text("Running and connected.").font(.system(size: 12)).foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting the engine and tunnel…").font(.system(size: 12))
            }
        case .notConfigured(let message), .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await model.startUp() } }
                    .controlSize(.small)
            }
        default:
            Button("Start Engine") { Task { await model.startUp() } }.controlSize(.small)
        }
    }

    // MARK: - Step 2: device eligibility

    private var deviceState: StepState {
        guard model.connected else { return .pending }
        if !model.eligibility.checked { return .active }
        return model.eligibility.ok ? .done : .blocked
    }

    @ViewBuilder private var deviceDetail: some View {
        if !model.connected {
            Text("Waiting for the engine.").font(.system(size: 12)).foregroundStyle(.secondary)
        } else if !model.eligibility.checked {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking whether this iPhone is managed…").font(.system(size: 12))
            }
        } else if model.eligibility.ok {
            Text("Not supervised, not enrolled in device management, no restriction profiles.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.eligibility.reasons, id: \.self) { reason in
                    Label(reason, systemImage: "hand.raised.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Mirage does not run on devices managed by a school, employer, or family organiser.")
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Step 3: age

    private var ageState: StepState {
        guard model.eligibility.ok else { return .pending }
        guard let age = model.ageVerification else { return .active }
        return age.blockingReason == nil ? .done : .blocked
    }

    @ViewBuilder private var ageDetail: some View {
        if !model.eligibility.ok {
            Text("Complete the previous step first.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else if let age = model.ageVerification {
            VStack(alignment: .leading, spacing: 8) {
                Label(age.summary, systemImage: age.isAppleAttested ? "checkmark.seal.fill" : "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(age.isAppleAttested ? .green : .orange)
                if let reason = age.blockingReason {
                    Text(reason).font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Check Again") { Task { await model.verifyAge() } }.controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(AgeGate.isSupported
                     ? "Mirage asks Apple for your account's age range and whether parental controls are active. Your date of birth is never shared with Mirage."
                     : "Apple's age verification needs macOS 26 or later. On this system Mirage cannot confirm your age or detect parental controls.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Verify with Apple Account") { Task { await model.verifyAge() } }
                    .controlSize(.small)
                    .disabled(!AgeGate.isSupported)

                if model.appleAgeCheckUnavailable {
                    Divider().padding(.vertical, 2)
                    manualAgeEntry
                }
            }
        }
    }

    /// Shown only after Apple's service has failed. Deliberately a date entry rather
    /// than an "I am over 18" checkbox: the friction is the point, and a date is a
    /// specific claim rather than a box to dismiss.
    @ViewBuilder private var manualAgeEntry: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 8) {
            Label("Apple could not verify your age on this build", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)

            Text("Confirm your date of birth instead. This is recorded as self-attested, not verified by Apple, and Mirage cannot detect parental controls without Apple's service. The device checks in step 2 still apply.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DatePicker("Date of birth", selection: $model.birthDate,
                       in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
                .frame(width: 140)

            Button("Confirm Date of Birth") { model.confirmAgeManually() }
                .controlSize(.small)
        }
    }

    // MARK: - Step 4: grants

    private var grantState: StepState {
        guard model.ageVerification?.blockingReason == nil, model.ageVerification != nil
        else { return .pending }
        return model.consentGranted ? .done : .active
    }

    @ViewBuilder private var grantsDetail: some View {
        @Bindable var model = model

        if model.ageVerification == nil || model.ageVerification?.blockingReason != nil {
            Text("Complete the previous step first.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $model.grants.allowPin) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Hold a fixed location").font(.system(size: 12, weight: .medium))
                        Text("Your iPhone reports a place you choose and stays there.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $model.grants.allowDrive) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Simulate a drive").font(.system(size: 12, weight: .medium))
                        Text("Your iPhone reports moving along a route at traffic-aware speeds.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)

                HStack {
                    Text("Stop automatically after").font(.system(size: 12))
                    Picker("", selection: $model.grants.maxSessionMinutes) {
                        Text("15 minutes").tag(15)
                        Text("1 hour").tag(60)
                        Text("4 hours").tag(240)
                        Text("12 hours").tag(720)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                Text("Consent lasts 30 days and applies only to the iPhone connected now. You can revoke it at any time.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Agree and Continue") { Task { await model.grantConsent() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.grants.allowPin && !model.grants.allowDrive)
                    if model.consentGranted {
                        Button("Revoke") { Task { await model.revokeConsent() } }
                    }
                }
            }
        }
    }
}

/// State of a setup step. Top level rather than nested in `StepCard`, so it can be
/// named without repeating the generic's type arguments at every use site.
enum StepState { case pending, active, done, blocked }

/// A numbered setup step with a state chip.
struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let state: StepState
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(badgeColor.opacity(0.15)).frame(width: 26, height: 26)
                switch state {
                case .done: Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                case .blocked: Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                default: Text("\(number)").font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(badgeColor)

            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold))
                content
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.quaternary.opacity(state == .pending ? 0.12 : 0.22),
                    in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(state == .blocked ? Color.orange.opacity(0.5) : .clear, lineWidth: 1))
        .opacity(state == .pending ? 0.6 : 1)
    }

    private var badgeColor: Color {
        switch state {
        case .done: .green
        case .blocked: .orange
        case .active: .accentColor
        case .pending: .secondary
        }
    }
}
