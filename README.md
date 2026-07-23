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
Cloud Functions, and Firestore membership rules are scaffolded in the
repository. Live GPS state and update syncing are the next backend phase.

Before using race creation:

1. In Firebase Authentication, enable both **Email/Password** and **Anonymous**.
2. From the repository root, authenticate and deploy:

   ```sh
   npx firebase-tools login
   npx firebase-tools use my-marathon-trackerr
   npx firebase-tools deploy --only firestore:rules,functions
   ```

3. Run the app. Create a permanent email/password account under **Create a
   race**. The backend creates the race and an 8-character private passcode.
4. On another simulator or device, choose **Join a race**. The app creates an
   anonymous Firebase user and exchanges the passcode for race membership.

Firebase may require the project to use a billing-enabled plan before Cloud
Functions can be deployed.

You can test the current on-device tracking:

1. Run the app from Xcode and open race settings.
2. Choose a preset or enter a custom distance, then enable **I'm the runner**.
3. Tap **Start live tracking** and approve location access.
4. In Xcode, choose **Debug → Simulate Location → Add GPX File to Project…**
   and select `TestData/SanFranciscoRun.gpx`.
5. Confirm that the marker, distance, pace, progress, and finish estimate change.

Once the realtime backend is added, test it in three layers:

1. Start the backend locally and run its schema/authorization tests.
2. Launch the iOS app with a debug backend URL, publish a simulated Xcode GPX
   route, and verify location rows and updates appear.
3. Open the private spectator URL in a second browser or phone and confirm that
   location, pace, finish estimate, and messages update without refreshing.

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
