#if os(iOS)
import SwiftUI

/// Camera mode's controls float over the viewfinder on glass, dark as the Camera app's: Liquid Glass from
/// iOS 26, the system's thin material with a hairline edge before it, and an opaque dark fill with Reduce
/// Transparency on. `tint` colours the glass (`cameraShade` under white words); `interactive` lets it
/// answer a touch on iOS 26.
struct CameraGlass<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency: Bool
    let shape: S
    let interactive: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        glass(content)
            .environment(\.colorScheme, ColorScheme.dark)
    }

    @ViewBuilder
    private func glass(_ content: Content) -> some View {
        if reduceTransparency {
            content
                .background {
                    ZStack {
                        shape.fill(Color(white: 0.12))
                        if let tint {
                            shape.fill(tint)
                        }
                    }
                }
        } else {
#if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(Self.effect(tint: tint, interactive: interactive), in: shape)
            } else {
                material(content)
            }
#else
            material(content)
#endif
        }
    }

    private func material(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(Material.ultraThinMaterial)
                    if let tint {
                        shape.fill(tint)
                    }
                }
            }
            .overlay {
                shape.stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }

#if compiler(>=6.2)
    @available(iOS 26.0, *)
    private static func effect(tint: Color?, interactive: Bool) -> Glass {
        let tinted: Glass = tint.map { (color: Color) -> Glass in Glass.regular.tint(color) } ?? Glass.regular
        return interactive ? tinted.interactive() : tinted
    }
#endif
}

/// Glass shapes drawn together, so neighbours blend and one with the same `cameraGlassID` as another that
/// leaves morphs into it (`GlassEffectContainer` on iOS 26; the content as it is before).
struct CameraGlassGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                content
            }
        } else {
            content
        }
#else
        content
#endif
    }
}

/// The glass's identity in its `CameraGlassGroup`, so a shape leaving and one coming in with the same id
/// morph into each other on iOS 26; not with Reduce Motion, where they only fade.
struct CameraGlassID: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    let id: String
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if reduceMotion {
                content
            } else {
                content
                    .glassEffectID(id, in: namespace)
            }
        } else {
            content
        }
#else
        content
#endif
    }
}

/// A prominent button over the viewfinder (Save, Now the backs, New document): the accent colour's glass
/// on iOS 26, a filled capsule before it.
struct CameraProminentButton: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
        } else {
            content
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        }
#else
        content
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
#endif
    }
}

/// A secondary button over the viewfinder (No back, Put in order): white words on shaded glass, as tall
/// as a finger needs.
struct CameraGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .cameraGlass(in: Capsule(), interactive: true, tint: Color.cameraShade)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }
}

extension View {
    func cameraGlass(in shape: some Shape, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(CameraGlass(shape: shape, interactive: interactive, tint: tint))
    }

    func cameraGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        modifier(CameraGlassID(id: id, namespace: namespace))
    }
}

extension Color {
    /// Darkens camera mode's glass under white words, so they read over the white page too.
    static let cameraShade: Color = Color.black.opacity(0.4)
}
#endif
