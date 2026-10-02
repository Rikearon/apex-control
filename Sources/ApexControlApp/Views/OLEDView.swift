import SwiftUI
import UniformTypeIdentifiers
import ApexKit

struct OLEDView: View {
    @EnvironmentObject var controller: DeviceController

    private var oled: Binding<OLEDConfig> { $controller.oled }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            preview

            HStack(alignment: .top, spacing: Theme.Space.l) {
                contentCard
                saveCard.frame(width: 300)
            }
        }
    }

    // MARK: - Preview

    private var preview: some View {
        Card(title: "Preview") {
            HStack {
                Spacer(minLength: 0)
                if controller.oled.mode == .off {
                    OLEDScreen(bitmap: nil)
                        .overlay {
                            Text("Keyboard's own screen")
                                .font(Typo.caption)
                                .foregroundStyle(Theme.ink3)
                        }
                } else if controller.oled.isLive {
                    // Only the clock needs a ticking preview; text and images
                    // are static and re-render when they change.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        OLEDScreen(bitmap: controller.oled.render(now: context.date))
                    }
                } else {
                    OLEDScreen(bitmap: controller.oled.render())
                }
                Spacer(minLength: 0)
            }
        } accessory: {
            Readout("128 × 40", size: 10, color: Theme.ink3)
        }
    }

    // MARK: - Content

    private var contentCard: some View {
        Card(title: "Show") {
            SegmentedRail(
                selection: oled.mode,
                items: [
                    .init(OLEDConfig.Mode.text, "Text", icon: "textformat"),
                    .init(OLEDConfig.Mode.clock, "Clock", icon: "clock"),
                    .init(OLEDConfig.Mode.image, "Image", icon: "photo"),
                    .init(OLEDConfig.Mode.off, "Keyboard's own", icon: "keyboard"),
                ]
            )
            .onChange(of: controller.oled.mode) { _, _ in controller.applyOLED() }

            switch controller.oled.mode {
            case .text: textEditor
            case .clock: clockEditor
            case .image: imageEditor
            case .off:
                Note("Apex Control is leaving the screen alone. The keyboard shows whatever it was set to.")
            }
        }
    }

    @ViewBuilder
    private var textEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TextField("Top line", text: oled.line1).textFieldStyle(.apex)
            TextField("Bottom line — optional", text: oled.line2).textFieldStyle(.apex)

            ScaleControl(
                label: "Size",
                value: oled.fontSize,
                range: 10...30, step: 1, majorEvery: 5,
                readout: { (String(Int($0)), "pt") },
                tickLabel: { String(Int($0)) }
            )

            if controller.oled.line2.isEmpty == false && controller.oled.fontSize > 16 {
                Note("Two lines cap out at 16 pt so they both fit.", icon: "info.circle")
            }
        }
        .onChange(of: controller.oled.line1) { _, _ in controller.applyOLED() }
        .onChange(of: controller.oled.line2) { _, _ in controller.applyOLED() }
        .onChange(of: controller.oled.fontSize) { _, _ in controller.applyOLED() }
    }

    @ViewBuilder
    private var clockEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 5) {
                Eyebrow("Time")
                HStack(spacing: 6) {
                    ForEach(Self.timeFormats, id: \.1) { name, format in
                        formatChip(name, format: format, current: controller.oled.clockTimeFormat) {
                            controller.oled.clockTimeFormat = format
                        }
                    }
                    Spacer(minLength: 0)
                }
                TextField("Time format", text: oled.clockTimeFormat).textFieldStyle(.apexMono)
            }

            VStack(alignment: .leading, spacing: 5) {
                Eyebrow("Date")
                HStack(spacing: 6) {
                    ForEach(Self.dateFormats, id: \.1) { name, format in
                        formatChip(name, format: format, current: controller.oled.clockDateFormat) {
                            controller.oled.clockDateFormat = format
                        }
                    }
                    Spacer(minLength: 0)
                }
                TextField("Date format", text: oled.clockDateFormat).textFieldStyle(.apexMono)
            }

            Note("The keyboard is redrawn once a second while Apex Control is running.")
        }
        .onChange(of: controller.oled.clockTimeFormat) { _, _ in controller.applyOLED() }
        .onChange(of: controller.oled.clockDateFormat) { _, _ in controller.applyOLED() }
    }

    private func formatChip(_ name: String, format: String, current: String,
                            action: @escaping () -> Void) -> some View {
        Button(name, action: action)
            .buttonStyle(ApexButton(role: current == format ? .primary : .secondary, compact: true))
    }

    @ViewBuilder
    private var imageEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let path = controller.oled.imagePath {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "photo")
                        .font(.system(size: 12)).foregroundStyle(Theme.ink3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(Typo.callout).foregroundStyle(Theme.ink)
                            .lineLimit(1).truncationMode(.middle)
                        Text(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                            .font(Typo.caption).foregroundStyle(Theme.ink3)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                    IconButton(systemName: "xmark", help: "Remove image") {
                        controller.oled.imagePath = nil
                        controller.applyOLED()
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.surfaceHi.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.control))

                if controller.oled.render() == nil {
                    Banner(kind: .error, message: "That file could not be read as an image.")
                }
            }

            Button(controller.oled.imagePath == nil ? "Choose an image…" : "Choose a different image…") {
                pickImage()
            }
            .buttonStyle(.secondary)

            Note("Scaled to 128 × 40 and reduced to pure black and white. High-contrast artwork reads best.")
        }
    }

    // MARK: - Save

    private var saveCard: some View {
        Card(title: "Keep it") {
            Button("Save to keyboard") { controller.persistOLED() }
                .buttonStyle(.primary)
                .disabled(!controller.canPersistOLED)

            Note(controller.oled.mode == .clock
                 ? "A clock changes every second, so there is nothing fixed to store. Text and images can be saved."
                 : "Writes this screen into the keyboard's memory so it stays after you quit Apex Control.")

            Rule()

            Button("Hand the screen back") { controller.resetOLED() }
                .buttonStyle(.secondary)
            Note("Returns the screen to whatever the keyboard shows on its own.")
        }
    }

    // MARK: - Actions

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .bmp, .tiff, .image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use image"
        if panel.runModal() == .OK, let url = panel.url {
            controller.oled.imagePath = url.path
            controller.oled.mode = .image
            controller.applyOLED()
        }
    }

    private static let timeFormats: [(String, String)] = [
        ("24 h", "HH:mm"), ("24 h + s", "HH:mm:ss"), ("12 h", "h:mm a"),
    ]

    private static let dateFormats: [(String, String)] = [
        ("Day date", "EEE d MMM"), ("Numeric", "dd/MM/yyyy"), ("Long", "EEEE"),
    ]
}

// MARK: - Screen preview

/// The OLED shown at the size of the real panel, in its housing.
struct OLEDScreen: View {
    let bitmap: MonoBitmap?
    var scale: CGFloat = 4

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.black)
            if let bitmap {
                OLEDPixels(bitmap: bitmap)
                    .padding(4)
                    .shadow(color: Theme.readout.opacity(0.6), radius: 5)
            }
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [.white.opacity(0.07), .clear],
                                     startPoint: .top, endPoint: .center))
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .frame(width: CGFloat(MonoBitmap.width) * scale,
               height: CGFloat(MonoBitmap.height) * scale)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color(srgb: 0x24272D), Color(srgb: 0x15171B)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
