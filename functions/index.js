const crypto = require("crypto");
const {initializeApp} = require("firebase-admin/app");
const {
  FieldValue,
  Timestamp,
  getFirestore,
} = require("firebase-admin/firestore");
const {HttpsError, onCall} = require("firebase-functions/v2/https");

initializeApp();
const db = getFirestore();

const PASSCODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

function normalizePasscode(value) {
  return String(value || "")
      .toUpperCase()
      .replace(/[^A-Z0-9]/g, "");
}

function hashPasscode(passcode) {
  return crypto.createHash("sha256").update(passcode).digest("hex");
}

function randomPasscode(length = 8) {
  const bytes = crypto.randomBytes(length);
  return Array.from(bytes)
      .map((byte) => PASSCODE_ALPHABET[byte % PASSCODE_ALPHABET.length])
      .join("");
}

function requiredText(value, field, maxLength) {
  const text = String(value || "").trim();
  if (!text || text.length > maxLength) {
    throw new HttpsError(
        "invalid-argument",
        `${field} must be between 1 and ${maxLength} characters.`,
    );
  }
  return text;
}

exports.createRace = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to create a race.");
  }

  const provider = request.auth.token.firebase?.sign_in_provider;
  if (provider === "anonymous") {
    throw new HttpsError(
        "permission-denied",
        "Create a permanent account before creating a race.",
    );
  }

  const raceName = requiredText(request.data?.raceName, "Race name", 80);
  const runnerName = requiredText(request.data?.runnerName, "Runner name", 60);
  const targetDistanceMiles = Number(request.data?.targetDistanceMiles);
  if (!Number.isFinite(targetDistanceMiles) ||
      targetDistanceMiles < 0.1 ||
      targetDistanceMiles > 500) {
    throw new HttpsError(
        "invalid-argument",
        "Distance must be between 0.1 and 500 miles.",
    );
  }

  const isPrivate = request.data?.isPrivate !== false;
  const raceRef = db.collection("races").doc();
  const batch = db.batch();
  let passcode = null;

  batch.set(raceRef, {
    ownerId: request.auth.uid,
    raceName,
    runnerName,
    targetDistanceMiles,
    isPrivate,
    status: "setup",
    createdAt: FieldValue.serverTimestamp(),
  });
  batch.set(raceRef.collection("members").doc(request.auth.uid), {
    role: "runner",
    joinedAt: FieldValue.serverTimestamp(),
  });

  if (isPrivate) {
    passcode = randomPasscode();
    const inviteHash = hashPasscode(passcode);
    batch.set(db.collection("raceInvites").doc(inviteHash), {
      raceId: raceRef.id,
      ownerId: request.auth.uid,
      expiresAt: Timestamp.fromMillis(Date.now() + 72 * 60 * 60 * 1000),
      createdAt: FieldValue.serverTimestamp(),
    });
  }

  await batch.commit();
  return {
    raceId: raceRef.id,
    raceName,
    runnerName,
    targetDistanceMiles,
    isPrivate,
    passcode,
  };
});

exports.joinRace = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in before joining a race.");
  }

  const passcode = normalizePasscode(request.data?.passcode);
  if (passcode.length !== 8) {
    throw new HttpsError("invalid-argument", "Enter the 8-character passcode.");
  }

  const inviteRef = db.collection("raceInvites").doc(hashPasscode(passcode));
  const invite = await inviteRef.get();
  if (!invite.exists) {
    throw new HttpsError("not-found", "That passcode was not found.");
  }

  const inviteData = invite.data();
  if (inviteData.expiresAt.toMillis() < Date.now()) {
    throw new HttpsError("deadline-exceeded", "That passcode has expired.");
  }

  const raceRef = db.collection("races").doc(inviteData.raceId);
  const race = await raceRef.get();
  if (!race.exists || race.data().status === "ended") {
    throw new HttpsError("not-found", "That race is no longer available.");
  }

  await raceRef.collection("members").doc(request.auth.uid).set({
    role: "spectator",
    joinedAt: FieldValue.serverTimestamp(),
  });

  const raceData = race.data();
  return {
    raceId: race.id,
    raceName: raceData.raceName,
    runnerName: raceData.runnerName,
    targetDistanceMiles: raceData.targetDistanceMiles,
    isPrivate: raceData.isPrivate,
  };
});
