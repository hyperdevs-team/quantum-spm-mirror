# QMSwiftUIAnalysis: the SwiftUI View-context map

`QMSwiftUIAnalysis` runs as a build phase in your app target. It reads your Swift source and writes
one file, `QMSwiftUIMap.json`, into the app bundle being built. With that file in the bundle, the
Quantum Metric SDK records which of your SwiftUI View types drew each piece of captured text, and,
for text that came from a network response, which response field it came from. Masking,
encryption, and event rules can then target your own View names.

This guide covers the whole setup: one build phase, one build setting, and one switch. It's
written so that a coding assistant can follow it step by step. Don't edit, move, or rename the
files in this folder; an SDK update replaces them.

## Before you start

- **Build machine:** a Mac with Apple silicon, running macOS 14 or later. The executable is
  arm64-only, so an Intel Mac, including an Intel CI runner, can't run it. The phase in step 2
  turns that into a build warning instead of a failed build.
- **SDK:** a Quantum Metric iOS SDK release that has `QMSwiftUIAnalysis` in this folder.
- **Your app target** must be able to turn off script sandboxing (step 3).

The phase reads your source files and writes the map. It makes no network requests. It takes a
second or two on a large project, so it runs on every build.

## 1. Find the executable's path

Use the path that matches how you added the SDK. Each one is written the way the build phase in
step 2 uses it.

| Integration | Path to `QMSwiftUIAnalysis` |
|---|---|
| CocoaPods | `${PODS_ROOT}/QuantumMetric-SDK/QuantumMetric-SDK/Assets/SwiftUIScripts/QMSwiftUIAnalysis` |
| Swift Package Manager | `${BUILD_DIR%/Build/*}/SourcePackages/checkouts/quantum-sdk-ios/Sources/SwiftUIScripts/QMSwiftUIAnalysis` |
| Manual (zip) | Wherever you copied the `SwiftUIScripts` folder, for example `${SRCROOT}/QuantumMetric/SwiftUIScripts/QMSwiftUIAnalysis` |

Notes:

- **CocoaPods:** the folder comes with the `SwiftUI` subspec, which the pod includes by default.
- **Swift Package Manager:** Xcode checks the package out under DerivedData, next to the `Build`
  folder. `${BUILD_DIR%/Build/*}` is that DerivedData folder, for both a normal build and an
  archive. The checkout folder is named after the package URL. If you added the package from a
  mirror, look in `SourcePackages/checkouts` for the folder that holds `Sources/SwiftUIScripts`.
  If your CI resolves packages somewhere else (`xcodebuild -clonedSourcePackagesDirPath`), use
  that folder instead of `${BUILD_DIR%/Build/*}/SourcePackages`.

## 2. Add the build phase

1. In Xcode, select your **app target**, then **Build Phases**.
2. Click **+** and choose **New Run Script Phase**.
3. Rename the phase to `Quantum Metric View-context map`.
4. Drag it below **Copy Bundle Resources**.
5. Paste this script, with the path from step 1 in place of the placeholder:

   ```sh
   QM_ANALYZER="<path from step 1>"
   "$QM_ANALYZER" --root "${SRCROOT}" \
       || echo "warning: QMSwiftUIAnalysis did not run; this build has no SwiftUI View-context map"
   ```

6. Uncheck **Based on dependency analysis**.
7. Leave **Input Files**, **Input File Lists**, **Output Files**, and **Output File Lists** empty.
8. Leave **For install builds only** unchecked.

Why steps 6 and 7 matter: a phase with an output and no inputs runs once, and Xcode skips it on
every later build. The map then goes stale. It still loads, but it names your Views as they were
on the day it was made. The analyzer finishes in a second or two, so let it run every build.

With no `-o`, the analyzer writes the map into the app bundle it's building, which is where the
SDK looks first. It works the same way for **Product > Archive**: the map ends up inside the
archived app.

The `|| echo` line keeps the build going if the executable can't run at all: a wrong path, or an
Intel build machine. The analyzer itself never fails your build. It reports problems as warnings
and exits 0.

**If you edit `project.pbxproj` directly** instead of using Xcode, the phase is a
`PBXShellScriptBuildPhase` with `alwaysOutOfDate = 1`, empty `inputPaths`, `outputPaths`,
`inputFileListPaths`, and `outputFileListPaths`, and `runOnlyForDeploymentPostprocessing = 0`.
List it in the app target's `buildPhases` after the Resources phase. If you generate the project
with a tool such as XcodeGen or Tuist, add the same script as a post-build script of the app
target in its manifest, with no inputs or outputs.

## 3. Turn off script sandboxing for the app target

In the app target's **Build Settings**, set **User Script Sandboxing**
(`ENABLE_USER_SCRIPT_SANDBOXING`) to **No**. Projects created in Xcode 15 or later have it set to
**Yes**.

With sandboxing on, the phase can't read anything under your project folder. The build still
succeeds, the analyzer writes no map, and the build log shows:

```
warning: QMSwiftUIAnalysis could not read the app's source because ENABLE_USER_SCRIPT_SANDBOXING is YES.
warning: Set it to NO for the target running this phase, or generate the map outside Xcode.
```

Declaring your source folders as input files doesn't help. The sandbox allows only the exact paths
you declare, not the files inside them.

## 4. Scan every folder that draws your text

`--root "${SRCROOT}"` covers your app's source and everything under the project folder, including
CocoaPods. Remote Swift packages are added automatically, for builds and archives alike, when Xcode
checks them out to its usual place under DerivedData. If your CI resolves packages to a folder of
its own (`xcodebuild -clonedSourcePackagesDirPath <dir>`), add `--root "<dir>/checkouts"`.

**Local packages outside the project folder need their own `--root`.** For example, if your design
system is a sibling checkout at `../DesignSystem`:

```sh
QM_ANALYZER="<path from step 1>"
"$QM_ANALYZER" --root "${SRCROOT}" --root "${SRCROOT}/../DesignSystem" \
    || echo "warning: QMSwiftUIAnalysis did not run; this build has no SwiftUI View-context map"
```

Text that reaches the screen through a View the analyzer never saw can't be attributed, so add a
root for every folder of Swift source your app compiles that isn't under `${SRCROOT}`.

Other flags you might use:

| Flag | Effect |
|---|---|
| `--root <dir>` | Scan this folder and everything under it. Repeatable. |
| `--exclude <glob>` | Skip matching paths. Repeatable. `*` stays within one path component; `**` crosses them. |
| `--emit-origins <list>` | Which sources may add entries to the map: `app`, `dependency`, `test`. The default is `app,dependency`. Use `app` to keep third-party strings out of the map. Every file is still read either way. |
| `--report [<file>]` | Write a coverage report. With no file, it goes to the build log. |
| `--source-revision <s>` | Record a revision, such as a git commit, in the map. |
| `--strict` | Exit with an error if a file couldn't be read. Off by default, so the phase can't fail your build. |
| `-o <file>` | Write the map somewhere other than the app bundle. Required when you run the tool outside Xcode. |
| `--plain` | Write readable JSON. The SDK loads either form; the default form keeps the map from being a readable file in your shipped app. |

Run the executable with `--help` for the complete list.

## 5. Turn the feature on

The map does nothing until the feature is on. Use one of these:

- **Configuration (recommended):** ask your Quantum Metric contact to set
  `swiftui_view_context_map_enabled` to `true` for your subscription. You can then turn it on or
  off without an app release.
- **Code:** call `enableSwiftUIViewContextMap` right after you initialize the SDK.

  ```swift
  QMNative.enableSwiftUIViewContextMap()
  ```

  ```objc
  [QMNative enableSwiftUIViewContextMap];
  ```

  The call wins over configuration, so after an app ships with it, the feature can't be turned off
  remotely for that app version. It's safe to call when no map is bundled.

## 6. Check that it worked

1. Build the app, then open the build log and find the `Quantum Metric View-context map` phase. It
   should have no warnings.
2. Check that the map is in the built app:

   ```sh
   ls "<path to YourApp.app>/QMSwiftUIMap.json"
   ```

   For an archive, the app is at `Products/Applications/YourApp.app` inside the `.xcarchive`.
   The file isn't readable JSON unless you passed `--plain`. That's expected.
3. To see what was scanned, add `--report` to the command for one build. The build log then lists
   the files read, split into `app`, `dependency`, and `test`. `app` should be close to the
   number of Swift files in your own code. If it's 0, the phase couldn't read your source.

When the feature is on, captured text in a session carries a `data-swiftui-view-context`
attribute naming the View that drew it.

## Troubleshooting

| What you see | Cause and fix |
|---|---|
| `warning: QMSwiftUIAnalysis could not read the app's source because ENABLE_USER_SCRIPT_SANDBOXING is YES.` | Script sandboxing is on. See step 3. |
| `warning: QMSwiftUIAnalysis did not run; ...` | The executable couldn't start. Check the path from step 1. Earlier lines in the log say why: `No such file or directory` means a wrong path, and `Bad CPU type in executable` means an Intel build machine. |
| `error: -o/--output is required outside an Xcode build phase` | You ran the tool outside Xcode. Pass `-o <file>`. |
| `error: refusing to write output inside a scan root (...)` | Your `-o` points inside a folder being scanned. Write the map to a build folder instead. |
| No map in the app, and no warning | The phase didn't run, or ran in another target. Check that it's in the app target, not a framework target, and that **For install builds only** is unchecked. |
| The map names Views you've since renamed | The phase is being skipped. Uncheck **Based on dependency analysis** and remove any input or output files (step 2). |
| Text from a local package isn't attributed | Add a `--root` for that package (step 4). |

## What not to do

- Don't commit `QMSwiftUIMap.json` to your repository, and don't add it to **Copy Bundle
  Resources**. The phase writes a fresh map into every build.
- Don't add the phase to a framework target. The SDK looks for the map in the app's own bundle, so
  the phase belongs to the target that builds the app.
- Don't change the files in this folder. Pass flags to change what the analyzer does.
