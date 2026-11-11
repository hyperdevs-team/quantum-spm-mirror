# Quantum Metric iOS SDK

Welcome to the Quantum Metric iOS SDK Swift Package! Please review the instructions below once you've installed the package.


# Integration Guide

**Add Linker Flag**
**Step 1:** Go to Build Settings in your Xcode Project.
**Step 2:** Filter for *Other Linker Flags*.
**Step 3:** Add **-ObjC** to the list if not already added. 


### Additional Steps for Swift Projects


If the project does not already have a Bridging Header, create one by completing the following steps. (Or, refer to [Apple's Bridging Header Documentation](https://developer.apple.com/documentation/swift/imported_c_and_objective-c_apis/importing_objective-c_into_swift))

1. Under `File -> New -> File`, select `Header File`, and name the file something like `MyApp-Bridging-Header.h`

2. In your target's Build Settings, under the `Objective-C Bridging Header` settings, add the path to the new Header File you just created (this normally needs to include your app name – for example: `MyApp/MyApp-Bridging-Header.h`).

  

Once you have the bridging header settup, open `MyApp-Bridging-Header.h` and add `#import "QMNative.h"` to allow Objective-C headers to be available in Swift.

  

## Configure Quantum Metric within your App Delegate

Within your App Delegate's `application:didFinishLaunchingWithOptions:` method, initialize QMNative.

  

#### Objective-C

```

#import "QMNative.h"; //add to the top of the file

  

[QMNative initializeWithSubscription:@"yoursubscription" uid:@"youruid"];

```

  

#### Swift

```

QMNative.initialize(withSubscription: "yoursubscription", uid: "youruid")

```
 **Done! You're ready to use the Quantum Metric iOS SDK.**
## Note on Crash Reporting

  

Quantum Metric has crash reporting out of the box, however, if your app uses another service for crash reporting such as Crashlytics or Sentry, you can disable QM's internal crash reporting with the following (add this line after the initialize line):

  

**Swift**

```swift

QMNative.disableCrashReporting()

```

  

**Objective-C**

```

[QMNative disableCrashReporting];

```

  

## Viewing your first session

  

Once you have the call to `initializeWithSubscription:uid:` in your app delegate, run your application and click around a bit. Within a few moments, you should see the session appear within your subscription. To find it more easily, you can search for `platform is iPhone` to show sessions from iPhones (or simulators).

  

# Debugging

  

## Using the session callback

  

If you don't see your session appear, or can't find it, we can use the session callback to search for the session based on the session id. After the line that starts QM inside of your app delegate, use the session callback API to log the session information.

  

#### Swift

  

```swift

QMNative.gotSessionCookieCallback { (session, user) in

if  let sessionCookie = session {

NSLog("Quantum Metric: got session cookie: %@", sessionCookie);

}

};

```

  

#### Objective-C

  

```objc

[[QMNative sharedInstance] gotSessionCookieCallback:^(NSString *sessionCookie, NSString *userString) {

NSLog(@"Quantum Metric: got session cookie: %@", sessionCookie);

}];

```

  

Run your app again and search your logs for `Quantum Metric`. You can use the logged session cookie to search for your session, with `QM Session Cookie is abc123`. If you don't see the `Quantum Metric` log after adding the above snippet, your session didn't start because the configuration was setup in a way that excluded your session from capture, or the configuration json could not be downloaded.


## Sending Events Manually

Using an Event ID, which can be found in the Quantum Metric Web UI in  `Settings > Events`, a new Event and its value can be sent through the SDK, using the following syntax:

 **Objective-C**
```objc
[QMNative sendEventWithID:10  value:@"Hello World!"];
```
**Swift** 
```swift
QMNative.sendEvent(withID: 10, value:"Hello World!")
```
Some Events signify special situations, such as conversions. These special cases can be flagged using an optional set of EventType arguments as follows:

 **Objective-C**
```objc
[QMNative sendEventWithID:10  value:@"Hello World!"  flags:QMEventTypeCartValue];
```
**Swift** 
```swift
QMNative.sendEvent(withID:10, value:"Hello, world", flags: QMEventTypeFlag.cartValue)
```
Tip: Some useful EventType options are  `QMEventTypeFlag.conversion`,  `QMEventTypeFlag.cartValue`  and  `QMEventTypeFlag.encrypted`
