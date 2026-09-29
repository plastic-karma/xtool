# Create App Extensions

Add app extensions to your iOS app.

## Overview

iOS includes several [App Extension Points](https://developer.apple.com/documentation/technologyoverviews/app-extensions) to deeply integrate with system functionality: such as Widgets, Share Extensions, and Safari Extensions. With a little setup, you can create App Extensions with xtool.

This guide will show you how to add a **Widget Extension** to your app. The steps are similar for other extensions as well.

> Note: This guide assumes you already have an xtool-based application up and running. If you don't, create one first with <doc:First-app>.

## Step 1: Add a new product

Start by adding a new product declaration to your `Package.swift`.

```diff
  // swift-tools-version: 6.0
  
  import PackageDescription
  
  let package = Package(
      name: "Hello",
      platforms: [.iOS(.v17)],
      products: [
          .library(
              name: "Hello",
              targets: ["Hello"]
          ),
+         .library(
+             name: "HelloWidget",
+             targets: ["HelloWidget"]
+         ),
      ],
      targets: [
          .target(name: "Hello"),
+         .target(name: "HelloWidget"),
      ]
  )
```

## Step 2: Update xtool.yml

Now that we have two products, we'll need to tell xtool which one corresponds to the _application_ and which one corresponds to the _extension_.

You should already have a bare-bones `xtool.yml` file that describes metadata about your package (the bundle ID, at the bare minimum.) We'll add the new information to this file.

```diff
  version: 1
  bundleID: com.example.Hello
+ product: Hello
+ extensions:
+   - product: HelloWidget
+     infoPath: HelloWidget-Info.plist
```

## Step 3: Add an Info.plist

App extensions require an `Info.plist` file that tells the system what kind of extension they are, amongst other things. In the previous step, we promised xtool that this file will be located at `./HelloWidget-Info.plist` in your project. We'll now create this file.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
```

> Note:
>
> The value `com.apple.widgetkit-extension` tells the system that this is a Widget Extension. If you're creating a different type of Extension, your `Info.plist` might look different.
>
> For a list of possible `NSExtensionPointIdentifier` values, see [Apple's documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionpointidentifier) on the subject. You may also need other keys like `NSExtensionPrincipalClass`: refer to Apple's ~better~ legacy [documentation library](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/AppExtensionKeys.html) for details.
>
> Finally, note that the above refers to the old paradigm of **Foundation Extensions**. Apple has started moving towards a newer framework called **ExtensionKit** for recent extension types. The main difference for extension consumers is that you replace `NSExtension -> EXAppExtensionAttributes`, and `NSExtensionPointIdentifier -> EXExtensionPointIdentifier`. xtool doesn't support ExtensionKit yet, but it's [planned](https://github.com/xtool-org/xtool/issues/138).

## Step 4: Code your widget 

We can finally write the code for the widget. Create a new file at `Sources/HelloWidget/Widget.swift` with these contents:

```swift
import WidgetKit
import SwiftUI

@main struct Bundle: WidgetBundle {
    var body: some Widget {
        HelloWidget()
    }
}

struct HelloWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "HelloWidget",
            provider: Provider()
        ) { entry in
            VStack {
                Text(entry.date, style: .date)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("HelloWidget")
        .description("This is an example widget.")
    }

    struct Entry: TimelineEntry {
        var date = Date()
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry {
            Entry()
        }

        func getSnapshot(
            in context: Context,
            completion: @escaping (Entry) -> Void
        ) {
            completion(Entry())
        }

        func getTimeline(
            in context: Context,
            completion: @escaping (Timeline<Entry>) -> Void
        ) {
            completion(Timeline(
                entries: [Entry()],
                policy: .after(.now + 3600)
            ))
        }
    }
}
```

> Note: Blindly refreshing once an hour isn't a great strategy in practice but it makes for a short snippet. I never said this was a tutorial on writing _good_ WidgetKit code; there's plenty of other resources online if that's your goal, including Apple's own [documentation](https://developer.apple.com/documentation/widgetkit).

Finally, build and run with `xtool dev`. You should be able to locate the widget in your widget library and add it to your home screen!

## Companion Watch apps

An iOS package can include a watchOS app and its own extensions. Declare separate library products for each bundle, and include the watchOS deployment target in `Package.swift`, for example `platforms: [.iOS(.v17), .watchOS(.v10)]`.

Configure the Watch product under `watchApp`, not the iOS `extensions` list:

```yaml
version: 1
product: Hello
bundleID: com.example.Hello
extensions:
  - product: HelloWidget
    infoPath: HelloWidget-Info.plist
watchApp:
  product: HelloWatch
  bundleID: com.example.Hello.watchkitapp
  infoPath: HelloWatch-Info.plist
  entitlementsPath: HelloWatch.entitlements
  extensions:
    - product: HelloWatchWidget
      bundleID: com.example.Hello.watchkitapp.widget
      infoPath: HelloWatchWidget-Info.plist
      entitlementsPath: HelloWatchWidget.entitlements
```

Each product accepts its own Info.plist, entitlements, and resources. A Watch widget uses the same `com.apple.widgetkit-extension` extension point as an iOS widget. xtool supplies the Watch device family, supported platform, `WKApplication`, and companion app identifier. Preserve app-specific Watch keys in its Info.plist.

`xtool dev build --configuration release` builds the phone and Watch products separately, then embeds the Watch app at `Hello.app/Watch/HelloWatch.app` and its extensions inside that app's `PlugIns` directory. Device companion builds merge `arm64_32` and `arm64` executables using `llvm-lipo`. The `arm64_32` slice retains the declared deployment target; device `arm64` uses a minimum of watchOS 26.0, matching that architecture's ABI. Linux native SwiftPM builds record the selected SDK version independently of the deployment target.

For a single-architecture companion build, specify `--watch-triple arm64_32-apple-watchos` or `--watch-triple arm64-apple-watchos`. Simulator builds use the phone simulator's host architecture and never mix device and simulator slices. A standalone Watch app puts its product at the top level and uses `--triple arm64_32-apple-watchos`.

On Linux, use an SDK containing WatchOS and a toolset with an `arm64_32` linker; see <doc:Installation-Linux>. Xcode-project generation does not support companion Watch configurations. Compiling asset catalogs and App Intents metadata for an existing Xcode app, and distribution signing for TestFlight, remain separate from `xtool dev build`.
