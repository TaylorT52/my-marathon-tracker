# RunAlong

RunAlong is a race-day companion for sharing a runner's live location, pace,
distance, estimated finish, and short updates with friends and family. It
supports common race presets and any custom target distance.

## What the prototype includes

- A spectator-friendly live race dashboard
- A MapKit route with start, finish, completed course, and runner markers
- Runner mode with Core Location GPS tracking
- Average pace and projected finish-time calculations
- 5K, 10K, 15K, 10-mile, half marathon, marathon, 50K, and custom distances
- A short race-update composer and share link
- Location permission and background-location configuration
- Unit tests for pace and finish projections

The initial screen intentionally contains demo data. Open race settings, turn on
**I'm the runner**, then tap **Start live tracking** to clear the demo progress
and begin a real GPS session.

## Recommended race-day architecture

```text
Runner iPhone
  Core Location
       |
       | publish every 10–20 seconds
       v
Realtime backend (Supabase or Firebase)
       |
       +----> spectator web link (no install)
       +----> spectator iOS app
       +----> push notifications for runner updates
```

For a Sunday launch, the spectator experience should be a private web link. It
avoids App Store review and asking every guest to install an app. The native iOS
app can remain the runner's GPS publisher.

Store only the latest location plus a low-frequency breadcrumb trail. Protect a
race with a random, unguessable share token, expire access after the race, and
never put backend service keys or Strava secrets in the iOS app.

Suggested backend records:

- `races`: runner, name, start time, goal time, share token, status
- `race_locations`: race, latitude, longitude, accuracy, distance, elapsed time,
  recorded time
- `race_updates`: race, message, mile, posted time
- `followers`: race, notification token or opted-in phone number

## Backend testing status

Firebase Authentication, secure race creation, anonymous passcode joining,
and Firestore membership rules are scaffolded in the repository. This version
works on Firebase's free Spark plan and does not require Cloud Functions.
Runner GPS state and short race updates sync through Firestore snapshot
listeners so joined spectators receive location, distance, pace, and finish
estimate changes without refreshing.

Before using race creation:

1. Download your Apple app's `GoogleService-Info.plist` from Firebase Console
   and place it in `my-marathon-trackerr/`. This local file is intentionally
   ignored by Git; `GoogleService-Info.example.plist` documents the expected
   location and shape.
2. In Firebase Authentication, enable both **Email/Password** and **Anonymous**.
3. From the repository root, authenticate and deploy:

   ```sh
   npx firebase-tools login
   npx firebase-tools use my-marathon-trackerr
   npx firebase-tools deploy --only firestore:rules
   ```

4. Run the app. Create a permanent email/password account under **Create a
   race**, then choose whether it is public or private. Private races receive an
   8-character passcode.
5. On another simulator or device, choose **Join a race**. Public races appear
   in the discoverable list; private races require their passcode. Either path
   creates an anonymous Firebase spectator.

You can test the current on-device tracking:

1. Run the app from Xcode and open race settings.
2. Choose a preset or enter a custom distance, then enable **I'm the runner**.
3. Tap **Start live tracking** and approve location access.
4. In Xcode, choose **Debug → Simulate Location → Add GPX File to Project…**
   and select `TestData/SanFranciscoRun.gpx`.
5. Confirm that the marker, distance, pace, progress, and finish estimate change.

Test the realtime backend in three layers:

1. Create a race as the runner and open it from a second simulator or phone.
2. Publish the included simulated Xcode GPX route and verify
   `races/{raceId}/state/latest` changes in Firestore.
3. Confirm that the spectator map, distance, pace, finish estimate, and messages
   update without refreshing.

The minimum end-to-end checks are: an invalid share token cannot read a race;
only the runner can publish; stale/out-of-order GPS points are rejected; a
spectator reconnect receives the latest state; and a completed or expired race
no longer accepts locations.

## Strava

Strava should be treated as an optional after-race sync. Its public API exposes
activities and activity streams after upload, and its webhook events notify apps
when an activity is created or changed. It does not expose Strava Beacon as a
general-purpose live location API.

If Strava sync is added later:

1. Perform OAuth and token refresh on the backend.
2. Store refresh tokens encrypted on the backend, never in the client.
3. Use the activity webhook to discover the finished run.
4. Fetch the completed activity/streams and link or reconcile them with the race.

## Before relying on it during a race

- Replace the sample course coordinates with the official GPX route.
- Add the realtime backend and spectator web page.
- Test background tracking on a physical iPhone for at least 90 minutes.
- Test with Low Power Mode and intermittent cellular coverage.
- Use a battery pack and keep Strava plus RunAlong running during the test.
- Add a stale-location warning when the last GPS update is over 60 seconds old.
- If sending SMS, collect explicit opt-in and use a server-side provider such as
  Twilio. In-app updates and push notifications are simpler for the first release.

## Opening the project

Open `my-marathon-trackerr/my-marathon-trackerr.xcodeproj` in Xcode 15.4 or
newer. The deployment target is iOS 17.5.
