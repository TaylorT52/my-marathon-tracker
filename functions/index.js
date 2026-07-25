"use strict";

const {initializeApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const {
  onDocumentCreated,
  onDocumentUpdated,
} = require("firebase-functions/v2/firestore");

initializeApp();

async function spectatorTokens(raceId) {
  const members = await getFirestore()
      .collection("races")
      .doc(raceId)
      .collection("members")
      .where("role", "==", "spectator")
      .get();

  return [...new Set(members.docs
      .map((member) => member.data())
      .filter((member) => member.notificationsEnabled === true)
      .map((member) => member.pushToken)
      .filter((token) => typeof token === "string" && token.length > 0))];
}

async function notifySpectators(raceId, notification, event) {
  const tokens = await spectatorTokens(raceId);
  if (tokens.length === 0) return;

  const batches = [];
  for (let index = 0; index < tokens.length; index += 500) {
    batches.push(getMessaging().sendEachForMulticast({
      tokens: tokens.slice(index, index + 500),
      notification,
      data: {raceId, event},
      apns: {
        payload: {
          aps: {sound: "default"},
        },
      },
    }));
  }
  await Promise.all(batches);
}

exports.notifyRaceStatus = onDocumentUpdated(
    "races/{raceId}",
    async (event) => {
      const before = event.data.before.data();
      const after = event.data.after.data();
      if (before.status === after.status) return;

      if (before.status === "setup" && after.status === "live") {
        await notifySpectators(
            event.params.raceId,
            {
              title: `${after.runnerName}'s race has started`,
              body: `Open RunAlong to follow ${after.raceName} live.`,
            },
            "race_started",
        );
      } else if (after.status === "ended") {
        await notifySpectators(
            event.params.raceId,
            {
              title: `${after.runnerName} finished!`,
              body: `See the final result for ${after.raceName}.`,
            },
            "race_finished",
        );
      }
    },
);

exports.notifyRunnerMessage = onDocumentCreated(
    "races/{raceId}/updates/{updateId}",
    async (event) => {
      const update = event.data.data();
      const race = await getFirestore()
          .collection("races")
          .doc(event.params.raceId)
          .get();
      if (!race.exists || typeof update.message !== "string") return;

      const raceData = race.data();
      await notifySpectators(
          event.params.raceId,
          {
            title: `Update from ${raceData.runnerName}`,
            body: update.message.slice(0, 180),
          },
          "runner_message",
      );
    },
);
