"use client";

import {useCallback, useEffect, useMemo, useState} from "react";
import {FirebaseError, initializeApp, getApps} from "firebase/app";
import {getAuth, onAuthStateChanged, signInAnonymously} from "firebase/auth";
import {
  collection,
  doc,
  getDoc,
  getFirestore,
  limit,
  onSnapshot,
  orderBy,
  query,
  serverTimestamp,
  setDoc,
  Timestamp,
} from "firebase/firestore";

type Race = {
  raceName: string;
  runnerName: string;
  targetDistanceMiles: number;
  status: string;
  isPrivate: boolean;
};

type RaceState = {
  latitude: number;
  longitude: number;
  distanceMiles: number;
  elapsedSeconds: number;
  paceSeconds: number;
  isTracking: boolean;
  isFinished: boolean;
  recordedAt?: Timestamp;
};

type Update = {id: string; message: string; mile: number; sentAt?: Timestamp};

const firebaseConfig = {
  apiKey: process.env.NEXT_PUBLIC_FIREBASE_API_KEY,
  authDomain: process.env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN,
  projectId: process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID,
  appId: process.env.NEXT_PUBLIC_FIREBASE_APP_ID,
};

const app = getApps()[0] ?? initializeApp(firebaseConfig);
const auth = getAuth(app);
const database = getFirestore(app);

function paceText(seconds: number) {
  if (!Number.isFinite(seconds) || seconds <= 0) return "—";
  const rounded = Math.round(seconds);
  return `${Math.floor(rounded / 60)}:${String(rounded % 60).padStart(2, "0")}`;
}

function finishText(state: RaceState | null, target: number) {
  if (!state || state.paceSeconds <= 0) return "—";
  const remaining = Math.max(0, target - state.distanceMiles);
  const recordedAt = state.recordedAt?.toDate().getTime() ?? Date.now();
  return new Date(recordedAt + remaining * state.paceSeconds * 1000)
      .toLocaleTimeString([], {hour: "numeric", minute: "2-digit"});
}

function ageText(date: Date | null, now: number) {
  if (!date) return "no GPS yet";
  const seconds = Math.max(0, Math.floor((now - date.getTime()) / 1000));
  if (seconds < 5) return "just now";
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m ago`;
}

async function sha256(value: string) {
  const bytes = new TextEncoder().encode(value);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash))
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");
}

async function ensureMembership(
    raceId: string,
    userId: string,
    inviteHash?: string,
) {
  const memberRef = doc(database, "races", raceId, "members", userId);
  try {
    const existing = await getDoc(memberRef);
    if (existing.data()?.role === "spectator") return;
  } catch (caught) {
    if (!(caught instanceof FirebaseError) || caught.code !== "permission-denied") {
      throw caught;
    }
  }
  await setDoc(memberRef, {
    role: "spectator",
    ...(inviteHash ? {inviteHash} : {}),
    joinedAt: serverTimestamp(),
  });
}

export default function RaceTracker({raceId}: {raceId: string}) {
  const [race, setRace] = useState<Race | null>(null);
  const [state, setState] = useState<RaceState | null>(null);
  const [updates, setUpdates] = useState<Update[]>([]);
  const [passcode, setPasscode] = useState(() => {
    if (typeof window === "undefined") return "";
    return new URLSearchParams(window.location.hash.slice(1)).get("code") ?? "";
  });
  const [needsPasscode, setNeedsPasscode] = useState(false);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [online, setOnline] = useState(true);
  const [stateCached, setStateCached] = useState(false);
  const [updatesCached, setUpdatesCached] = useState(false);
  const [now, setNow] = useState(Date.now());

  const attachListeners = useCallback(() => {
    const raceRef = doc(database, "races", raceId);
    const unsubRace = onSnapshot(raceRef, (snapshot) => {
      setRace(snapshot.data() as Race);
    });
    const unsubState = onSnapshot(
        doc(database, "races", raceId, "state", "latest"),
        {includeMetadataChanges: true},
        (snapshot) => {
          setStateCached(snapshot.metadata.fromCache);
          setState(snapshot.exists() ? snapshot.data() as RaceState : null);
        },
    );
    const unsubUpdates = onSnapshot(
        query(
            collection(database, "races", raceId, "updates"),
            orderBy("sentAt", "desc"),
            limit(20),
        ),
        {includeMetadataChanges: true},
        (snapshot) => {
          setUpdatesCached(snapshot.metadata.fromCache);
          setUpdates(snapshot.docs.map((item) => ({
            id: item.id,
            ...item.data(),
          })) as Update[]);
        },
    );
    return () => {
      unsubRace();
      unsubState();
      unsubUpdates();
    };
  }, [raceId]);

  const joinPublicRace = useCallback(async () => {
    const user = auth.currentUser;
    if (!user) return undefined;
    const raceRef = doc(database, "races", raceId);
    const raceSnapshot = await getDoc(raceRef);
    if (!raceSnapshot.exists()) throw new Error("This race link is no longer available.");
    const raceData = raceSnapshot.data() as Race;
    if (raceData.isPrivate) {
      setNeedsPasscode(true);
      setLoading(false);
      return undefined;
    }
    await ensureMembership(raceId, user.uid);
    setRace(raceData);
    setLoading(false);
    return attachListeners();
  }, [attachListeners, raceId]);

  useEffect(() => {
    setOnline(navigator.onLine);
    const onlineHandler = () => setOnline(true);
    const offlineHandler = () => setOnline(false);
    window.addEventListener("online", onlineHandler);
    window.addEventListener("offline", offlineHandler);
    const timer = window.setInterval(() => setNow(Date.now()), 5_000);
    return () => {
      window.removeEventListener("online", onlineHandler);
      window.removeEventListener("offline", offlineHandler);
      window.clearInterval(timer);
    };
  }, []);

  useEffect(() => {
    let detach: (() => void) | undefined;
    const unsubscribeAuth = onAuthStateChanged(auth, async (user) => {
      if (!user) {
        await signInAnonymously(auth);
        return;
      }
      try {
        detach = await joinPublicRace();
      } catch (caught) {
        const code = caught instanceof FirebaseError ? caught.code : "";
        if (code === "permission-denied") {
          setNeedsPasscode(true);
        } else {
          setError(caught instanceof Error ? caught.message : "Could not open this race.");
        }
        setLoading(false);
      }
    });
    return () => {
      unsubscribeAuth();
      detach?.();
    };
  }, [joinPublicRace]);

  async function unlockPrivateRace() {
    setError("");
    setLoading(true);
    try {
      const user = auth.currentUser;
      if (!user) throw new Error("Still connecting. Try again.");
      const normalized = passcode.toUpperCase().replace(/[^A-Z0-9]/g, "");
      if (normalized.length !== 8) throw new Error("Enter the 8-character passcode.");
      const inviteHash = await sha256(normalized);
      const invite = await getDoc(doc(database, "raceInvites", inviteHash));
      if (!invite.exists() || invite.data().raceId !== raceId) {
        throw new Error("That passcode does not match this race.");
      }
      await ensureMembership(raceId, user.uid, inviteHash);
      const raceSnapshot = await getDoc(doc(database, "races", raceId));
      setRace(raceSnapshot.data() as Race);
      setNeedsPasscode(false);
      attachListeners();
    } catch (caught) {
      if (caught instanceof FirebaseError && caught.code === "permission-denied") {
        setError("This race has finished, or this private invitation is no longer available.");
      } else {
        setError(caught instanceof Error ? caught.message : "Could not unlock this race.");
      }
    } finally {
      setLoading(false);
    }
  }

  const lastFix = state?.recordedAt?.toDate() ?? null;
  const ageSeconds = lastFix ? (now - lastFix.getTime()) / 1000 : 0;
  const cached = stateCached || updatesCached;
  const health = state?.isFinished ? "finished" :
    !online ? "offline" :
    cached ? "cached" :
    state && ageSeconds > 90 ? "stale" :
    state && ageSeconds > 30 ? "delayed" :
    state ? "live" : "waiting";
  const healthLabel = {
    offline: "OFFLINE",
    cached: "CACHED DATA",
    stale: "STALE LOCATION",
    delayed: "GPS DELAYED",
    live: "LIVE GPS",
    waiting: "WAITING FOR GPS",
    finished: "FINISHED",
  }[health];
  const progress = Math.min(100, Math.max(
      0,
      ((state?.distanceMiles ?? 0) / (race?.targetDistanceMiles ?? 1)) * 100,
  ));

  const mapURL = useMemo(() => {
    if (!state) return "";
    const delta = 0.012;
    const bbox = [
      state.longitude - delta,
      state.latitude - delta,
      state.longitude + delta,
      state.latitude + delta,
    ].join(",");
    return `https://www.openstreetmap.org/export/embed.html?bbox=${encodeURIComponent(bbox)}&marker=${state.latitude},${state.longitude}&layer=mapnik`;
  }, [state]);

  if (loading && !race) {
    return <main className="center-state"><div className="loader"/><p>Joining the race…</p></main>;
  }

  if (needsPasscode) {
    return (
      <main className="center-state">
        <a className="brand" href="/"><span className="brand-mark">R</span> RUNALONG</a>
        <section className="unlock-card">
          <p className="eyebrow">PRIVATE RACE</p>
          <h1>Passcode required</h1>
          <p>Enter the 8-character code the runner sent you.</p>
          <input
            className="passcode"
            value={passcode}
            onChange={(event) => setPasscode(event.target.value)}
            placeholder="ABCD2345"
            maxLength={8}
            autoCapitalize="characters"
          />
          {error && <p className="error">{error}</p>}
          <button onClick={unlockPrivateRace}>Watch race</button>
        </section>
      </main>
    );
  }

  if (error || !race) {
    return <main className="center-state"><h1>Race unavailable</h1><p>{error}</p><a href="/">Try another link</a></main>;
  }

  return (
    <main className="tracker-shell">
      <header>
        <a className="brand" href="/"><span className="brand-mark">R</span> RUNALONG</a>
        <span className="watching">● WATCHING</span>
      </header>
      <section className="race-heading">
        <p className="eyebrow">{race.raceName}</p>
        <h1>{race.runnerName} is on the move</h1>
        <p>Live race-day progress for the people cheering loudest.</p>
      </section>

      <section className="map-card">
        {mapURL ? (
          <iframe title={`${race.runnerName}'s live location`} src={mapURL}/>
        ) : (
          <div className="map-empty">Waiting for the runner to share their first GPS point.</div>
        )}
        <div className={`live-pill ${health}`}>
          <span>●</span> {healthLabel}
          <small>· {ageText(lastFix, now)}</small>
        </div>
      </section>

      {!["live", "waiting", "finished"].includes(health) && (
        <section className={`sync-banner ${health}`}>
          <strong>{healthLabel}</strong>
          <span>
            {health === "offline" && "You’re offline. Showing the last saved race data."}
            {health === "cached" && "Firestore is reconnecting; this data came from the browser cache."}
            {(health === "stale" || health === "delayed") &&
              `The last GPS update was ${ageText(lastFix, now)}. This page will recover automatically.`}
          </span>
        </section>
      )}

      <section className="stats">
        <article><strong>{paceText(state?.paceSeconds ?? 0)}</strong><small>/MI</small><span>CURRENT PACE</span></article>
        <article><strong>{(state?.distanceMiles ?? 0).toFixed(1)}</strong><small>MI</small><span>DISTANCE</span></article>
        <article><strong>{finishText(state, race.targetDistanceMiles)}</strong><span>EST. FINISH</span></article>
      </section>

      <section className="progress-card">
        <div><strong>Course progress</strong><b>{Math.round(progress)}%</b></div>
        <div className="progress-track"><span style={{width: `${progress}%`}}/></div>
        <small>START <span>FINISH {race.targetDistanceMiles.toFixed(1)} MI</span></small>
      </section>

      <section className="updates-card">
        <p className="eyebrow">FROM {race.runnerName}</p>
        <h2>Race updates</h2>
        {updates.length === 0 && <p className="muted">No runner updates yet.</p>}
        {updates.slice(0, 5).map((update) => (
          <article key={update.id}>
            <span className="quote">“</span>
            <div>
              <p>{update.message}</p>
              <small>Mile {update.mile.toFixed(1)} · {
                update.sentAt ? ageText(update.sentAt.toDate(), now) : "sending"
              }</small>
            </div>
          </article>
        ))}
      </section>
      <footer>
        <p>Location, pace, and finish time are estimates. GPS and course conditions can cause delays.</p>
        <p><a href="/privacy">Privacy</a> · <a href="/support">Support</a></p>
      </footer>
    </main>
  );
}
