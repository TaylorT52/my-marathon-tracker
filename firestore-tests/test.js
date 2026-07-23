const fs = require("fs");
const path = require("path");
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");
const {
  addDoc,
  collection,
  doc,
  getDoc,
  getDocs,
  orderBy,
  query,
  serverTimestamp,
  setDoc,
  Timestamp,
} = require("firebase/firestore");
const {after, before, beforeEach, describe, it} = require("mocha");

const projectId = "runalong-rules-test";
const raceId = "public-race";
const privateRaceId = "private-race";
const inviteHash = "a".repeat(64);
let environment;

function ownerDatabase() {
  return environment.authenticatedContext("owner", {
    firebase: {sign_in_provider: "password"},
  }).firestore();
}

function spectatorDatabase() {
  return environment.authenticatedContext("spectator", {
    firebase: {sign_in_provider: "anonymous"},
  }).firestore();
}

function outsiderDatabase() {
  return environment.authenticatedContext("outsider", {
    firebase: {sign_in_provider: "anonymous"},
  }).firestore();
}

async function seedRace() {
  await environment.withSecurityRulesDisabled(async (context) => {
    const database = context.firestore();
    await setDoc(doc(database, "races", raceId), {
      ownerId: "owner",
      raceName: "Integration Test 10K",
      runnerName: "Taylor",
      targetDistanceMiles: 6.21371,
      isPrivate: false,
      status: "live",
      createdAt: Timestamp.now(),
    });
    await setDoc(doc(database, "races", raceId, "members", "owner"), {
      role: "runner",
      joinedAt: Timestamp.now(),
    });
    await setDoc(doc(database, "races", raceId, "members", "spectator"), {
      role: "spectator",
      joinedAt: Timestamp.now(),
    });
    await setDoc(doc(database, "races", privateRaceId), {
      ownerId: "owner",
      raceName: "Private Test Race",
      runnerName: "Taylor",
      targetDistanceMiles: 13.1,
      isPrivate: true,
      status: "setup",
      createdAt: Timestamp.now(),
    });
    await setDoc(doc(database, "races", privateRaceId, "members", "owner"), {
      role: "runner",
      joinedAt: Timestamp.now(),
    });
    await setDoc(doc(database, "raceInvites", inviteHash), {
      raceId: privateRaceId,
      ownerId: "owner",
      expiresAt: Timestamp.fromMillis(Date.now() + 60 * 60 * 1000),
      createdAt: Timestamp.now(),
    });
  });
}

describe("RunAlong spectator access", () => {
  before(async () => {
    environment = await initializeTestEnvironment({
      projectId,
      firestore: {
        rules: fs.readFileSync(
            path.join(__dirname, "..", "firestore.rules"),
            "utf8",
        ),
      },
    });
  });

  beforeEach(async () => {
    await environment.clearFirestore();
    await seedRace();
  });

  after(async () => {
    await environment.cleanup();
  });

  it("lets a joined spectator read live runner state", async () => {
    const spectator = spectatorDatabase();
    const owner = ownerDatabase();
    const statePath = `races/${raceId}/state/latest`;

    await assertSucceeds(setDoc(doc(owner, ...statePath.split("/")), {
      latitude: 37.7829,
      longitude: -122.4429,
      distanceMiles: 1.25,
      elapsedSeconds: 720,
      paceSeconds: 575,
      isTracking: true,
      isFinished: false,
      recordedAt: serverTimestamp(),
    }));

    const snapshot = await assertSucceeds(getDoc(
        doc(spectator, ...statePath.split("/")),
    ));
    const state = snapshot.data();
    if (state.latitude !== 37.7829) {
      throw new Error("Spectator received an unexpected location.");
    }
  });

  it("lets a joined spectator read runner messages", async () => {
    const spectator = spectatorDatabase();
    const owner = ownerDatabase();
    await assertSucceeds(addDoc(
        collection(owner, "races", raceId, "updates"),
        {
          message: "Feeling strong!",
          mile: 1.25,
          sentAt: serverTimestamp(),
        },
    ));
    const snapshot = await assertSucceeds(getDocs(query(
        collection(spectator, "races", raceId, "updates"),
        orderBy("sentAt", "desc"),
    )));
    if (snapshot.docs[0]?.data().message !== "Feeling strong!") {
      throw new Error("Spectator did not receive the runner message.");
    }
  });

  it("blocks non-members from live state and messages", async () => {
    const outsider = outsiderDatabase();
    await assertFails(getDoc(
        doc(outsider, "races", raceId, "state", "latest"),
    ));
    await assertFails(getDocs(
        collection(outsider, "races", raceId, "updates"),
    ));
  });

  it("lets a returning spectator reuse membership after exiting", async () => {
    const spectator = spectatorDatabase();
    const membership = await assertSucceeds(getDoc(
        doc(spectator, "races", raceId, "members", "spectator"),
    ));
    if (membership.data()?.role !== "spectator") {
      throw new Error("Returning viewer lost the spectator role.");
    }
    await assertSucceeds(getDoc(doc(spectator, "races", raceId)));
  });

  it("joins a private race as a spectator, never as a runner", async () => {
    const spectator = spectatorDatabase();
    const memberRef = doc(
        spectator,
        "races",
        privateRaceId,
        "members",
        "spectator",
    );

    await assertSucceeds(setDoc(memberRef, {
      role: "spectator",
      inviteHash,
      joinedAt: serverTimestamp(),
    }));
    const member = await getDoc(memberRef);
    if (member.data()?.role !== "spectator") {
      throw new Error("Private watcher was not stored as a spectator.");
    }
    await assertSucceeds(getDoc(doc(spectator, "races", privateRaceId)));

    const outsider = outsiderDatabase();
    await assertFails(setDoc(
        doc(outsider, "races", privateRaceId, "members", "outsider"),
        {
          role: "runner",
          joinedAt: serverTimestamp(),
        },
    ));
  });
});
