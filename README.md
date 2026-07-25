# RunAlong

RunAlong lets people follow a runner without constantly asking for location
updates. The runner uses the iPhone app; friends and family can watch from the
app or a browser.

Live spectator site: <https://runalong-live.fehguy.chatgpt.site>

## What works

- Create a race with an email/password account
- Public races and passcode-protected private races
- Anonymous spectators (no spectator account setup)
- 5K, 10K, 15K, 10-mile, half marathon, marathon, 50K, or a custom distance
- Live location, distance, pace, progress, and estimated finish time
- Runner updates that appear in the app and on the website
- Background location tracking on the runner's phone
- A manual refresh/force-update button
- Offline, cached, delayed, and stale-location warnings
- A **My Races** screen for returning to an unfinished race
- Races stay active until the runner presses **Finish**
- Private passcodes stay valid until the race is finished
- Shareable browser links for people who do not want the app

Push notifications, SMS, and Strava integration are not part of the app. A
spectator needs to have the app or website open to see new runner messages.

## How it works

The runner's phone collects GPS fixes with Core Location and writes the latest
race state to Firestore. The spectator app and website listen to the same
Firestore documents, so they update without polling or refreshing.

Public races can be discovered in the app. A private race is only available
after the spectator joins with its eight-character passcode. Private website
links keep the race ID in the query string and the passcode in the URL fragment.
The fragment stays in the browser and is not sent to the web server.

Firestore rules enforce the runner and spectator roles. Only the race owner can
publish GPS state, post updates, change the race status, or finish the race.

## Project layout

```text
my-marathon-trackerr/   iOS app and Xcode project
website/                browser-based spectator view
firestore.rules         production Firestore rules
firestore-tests/        rules tests
TestData/               GPX route for simulator testing
```

## Firebase setup

The project uses Firebase Authentication and Cloud Firestore and works on the
Spark plan.

1. Create or select the Firebase project.
2. Enable **Email/Password** and **Anonymous** under Authentication.
3. Download the iOS `GoogleService-Info.plist`.
4. Put it in `my-marathon-trackerr/GoogleService-Info.plist`.
5. Deploy the Firestore rules:

   ```sh
   npx firebase-tools login
   npx firebase-tools use my-marathon-trackerr
   npx firebase-tools deploy --only firestore:rules
   ```

The real Firebase plist, local environment files, signing keys, and website
build output are ignored by Git.

## Running the iOS app

Open `my-marathon-trackerr/my-marathon-trackerr.xcodeproj` in Xcode 15.4 or
newer. The deployment target is iOS 17.5.

The app only uses Firebase Auth and Firestore capabilities, so it can be signed
with a free Apple Personal Team. The runner will be asked for foreground and
background location access when live tracking starts.

## Testing a race

The easiest setup is two simulators:

1. Create a race on the first simulator and start tracking.
2. Join it as a spectator on the second simulator.
3. For a private race, use the passcode shown on the runner's screen.
4. In Xcode, load `TestData/SanFranciscoRun.gpx` from the simulated location
   menu.
5. Watch the map, pace, distance, progress, and ETA change on the spectator.
6. Post a runner update and confirm it appears on both spectator views.
7. Open the shared race URL in Safari and repeat the check on the website.
8. Turn networking off briefly to check the offline and stale-data states.
9. Press **Finish** and confirm the final state is retained.

For a real race, test on a physical iPhone before relying on it. Do a long walk
with the phone locked, Low Power Mode enabled, and spotty service. Background
GPS and battery use behave differently on a device than in Simulator.

## Automated checks

Run the iOS tests from Xcode, or with:

```sh
xcodebuild \
  -project my-marathon-trackerr/my-marathon-trackerr.xcodeproj \
  -scheme my-marathon-trackerr \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:my-marathon-trackerrTests \
  test
```

Run the Firestore rules tests with:

```sh
npx firebase-tools emulators:exec --only firestore \
  "npm --prefix firestore-tests test"
```

The current suite has 12 iOS tests and 7 Firestore rules tests.
