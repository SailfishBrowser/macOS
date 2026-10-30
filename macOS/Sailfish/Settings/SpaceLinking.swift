import AppKit
import ComposableArchitecture
import SwiftUI

// The Space Linking sheet: New Route, each route's URL test and where it opens, and the default.
struct SpaceLinking: View {
  let spaces: [(Space.ID, String)]
  let dismiss: () -> Void
  @Shared(.linkRoutes) private var linkRoutes

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Space Linking").font(.system(size: 14, weight: .semibold))
        Spacer()
        Button {
          $linkRoutes.withLock { $0.routes.append(LinkRoutes.Route(id: UUID())) }
        } label: {
          Text("New Route").frame(width: 98)
        }
        Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 14)) }
          .buttonStyle(.plain)
          .keyboardShortcut(.cancelAction)
          .padding(.leading, 28)
          .padding(.trailing, 8)
      }
      .padding(.bottom, 26)
      Divider()
      ScrollView {
        VStack(spacing: 20) {
          ForEach(Binding($linkRoutes).routes) { $route in
            RouteView(route: $route, spaces: spaces) {
              $linkRoutes.withLock { $0.routes.removeAll { $0.id == route.id } }
            }
          }
        }
        .padding(.vertical, 24)
      }
      Divider()
      HStack(spacing: 8) {
        Text("Default").frame(width: RouteView.labelWidth, alignment: .trailing)
        DestinationPicker(destination: Binding($linkRoutes).defaultDestination, spaces: spaces).frame(width: 270)
      }
      .padding(.vertical, 24)
    }
    .font(.system(size: 13))
    .padding(.horizontal, 24)
    .padding(.vertical, 19)
    .padding(.top, 19)
    .frame(width: 506, height: 498)
    // The sheet opens with no field focused.
    .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
  }
}

private struct RouteView: View {
  static let labelWidth: CGFloat = 79
  @Binding var route: LinkRoutes.Route
  let spaces: [(Space.ID, String)]
  let delete: () -> Void

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
      GridRow {
        RouteLabel(title: "URL", systemImage: "link")
        HStack(spacing: 10) {
          Picker("", selection: $route.match) {
            ForEach(LinkRoutes.Match.allCases, id: \.self) { Text($0.rawValue) }
          }
          .labelsHidden()
          .frame(width: 160)
          TextField("example.com", text: $route.text).textFieldStyle(.roundedBorder).frame(width: 158)
          Button(action: delete) { Image(systemName: "minus.circle.fill") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
      }
      GridRow {
        RouteLabel(title: "Open in", systemImage: "arrow.turn.down.right")
        DestinationPicker(destination: $route.destination, spaces: spaces).frame(width: 355)
      }
    }
  }
}

// A route's gray row label with its symbol, right-aligned against the controls.
private struct RouteLabel: View {
  let title: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
      Text(title)
    }
    .foregroundStyle(.secondary)
    .frame(width: RouteView.labelWidth, alignment: .trailing)
  }
}

// The destinations: each space with its profile, then Most Recent Space and Little Sailfish.
private struct DestinationPicker: View {
  @Binding var destination: LinkRoutes.Destination
  let spaces: [(Space.ID, String)]

  var body: some View {
    Picker("", selection: $destination) {
      ForEach(spaces, id: \.0) { Text($0.1).tag(LinkRoutes.Destination.space($0.0)) }
      Divider()
      Text("Most Recent Space").tag(LinkRoutes.Destination.mostRecentSpace)
      Text("Little Sailfish").tag(LinkRoutes.Destination.littleSailfish)
    }
    .labelsHidden()
  }
}
