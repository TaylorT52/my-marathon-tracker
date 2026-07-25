"use client";

import {FormEvent, useEffect, useState} from "react";
import RaceTracker from "./race-tracker";

export default function Home() {
  const [raceId, setRaceId] = useState("");
  const [linkedRaceId, setLinkedRaceId] = useState<string | null>(null);
  const [pathname, setPathname] = useState("/");

  useEffect(() => {
    setLinkedRaceId(new URLSearchParams(window.location.search).get("race"));
    setPathname(window.location.pathname);
    const handleNavigation = () => setPathname(window.location.pathname);
    window.addEventListener("popstate", handleNavigation);
    return () => window.removeEventListener("popstate", handleNavigation);
  }, []);

  function openRace(event: FormEvent) {
    event.preventDefault();
    const input = raceId.trim();
    let value = input.split("/").filter(Boolean).pop() ?? "";
    try {
      const pasted = new URL(input);
      value = pasted.searchParams.get("race") ?? value;
    } catch {
      // Plain race IDs are accepted too.
    }
    if (value) {
      setLinkedRaceId(value);
      window.history.pushState({}, "", `/?race=${encodeURIComponent(value)}`);
    }
  }

  if (pathname === "/privacy") return <LegalPage kind="privacy"/>;
  if (pathname === "/support") return <LegalPage kind="support"/>;
  if (linkedRaceId) return <RaceTracker raceId={linkedRaceId}/>;

  return (
    <main className="landing">
      <section className="hero">
        <div className="brand"><span className="brand-mark">R</span> RUNALONG</div>
        <p className="eyebrow">LIVE RACE DAY</p>
        <h1>Cheer from anywhere.</h1>
        <p className="hero-copy">
          Follow live location, pace, estimated finish time, and updates—no app required.
        </p>
        <form className="join-form" onSubmit={openRace}>
          <label htmlFor="race-id">Race link or ID</label>
          <div className="join-row">
            <input
              id="race-id"
              value={raceId}
              onChange={(event) => setRaceId(event.target.value)}
              placeholder="Paste the link your runner sent"
              autoComplete="off"
            />
            <button type="submit">Watch live</button>
          </div>
        </form>
        <p className="privacy-note">Private races ask for the runner’s passcode.</p>
        <nav className="site-links" aria-label="RunAlong information">
          <a href="/privacy">Privacy</a>
          <a href="/support">Support</a>
        </nav>
      </section>
      <div className="runner-orbit" aria-hidden="true"><span>🏃</span></div>
    </main>
  );
}

function LegalPage({kind}: {kind: "privacy" | "support"}) {
  const privacy = kind === "privacy";
  return (
    <main className="legal-shell">
      <a className="brand" href="/"><span className="brand-mark">R</span> RUNALONG</a>
      <article className="legal-card">
        <p className="eyebrow">{privacy ? "PRIVACY" : "SUPPORT"}</p>
        <h1>{privacy ? "Your race. Your location. Your control." : "We’re here to help."}</h1>
        {privacy ? <PrivacyContent/> : <SupportContent/>}
      </article>
      <nav className="site-links">
        <a href="/">Live tracker</a>
        <a href="/privacy">Privacy</a>
        <a href="/support">Support</a>
      </nav>
    </main>
  );
}

function PrivacyContent() {
  return (
    <div className="legal-copy">
      <p className="updated">Effective July 25, 2026</p>
      <p>
        RunAlong lets runners share live race progress with people they choose. This policy
        explains what information is handled when you use the iPhone app or spectator website.
      </p>

      <h2>Information RunAlong handles</h2>
      <ul>
        <li>Creator account information, including an email address and Firebase user identifier.</li>
        <li>Race details such as race name, runner name, distance, visibility, and timestamps.</li>
        <li>Precise runner location, distance, pace, elapsed time, and estimated finish information while live tracking is active.</li>
        <li>Messages the runner chooses to post and spectator membership identifiers.</li>
        <li>Basic technical and security information processed by Firebase to authenticate users and operate the service.</li>
      </ul>

      <h2>How information is used and shared</h2>
      <p>
        Information is used only to create races, authenticate users, synchronize live progress,
        protect private races, recover race sessions, and display race updates. Public races can
        be discovered by anyone using RunAlong. Private race data is available to authenticated
        spectators who join with the invitation passcode.
      </p>
      <p>
        Firebase, operated by Google, stores and synchronizes RunAlong data. Spectator maps are
        displayed using OpenStreetMap; loading a map sends the displayed coordinates and ordinary
        web-request information to OpenStreetMap from the spectator’s browser. RunAlong does not
        sell personal information or use race location for advertising.
      </p>

      <h2>Retention and deletion</h2>
      <p>
        Race information remains available so a runner can reopen a race. A creator can delete an
        individual race from My Races or delete their account inside the app. Those actions remove
        the associated race records, locations, messages, memberships, and private invitations
        from RunAlong’s active Firebase database.
      </p>

      <h2>Your choices</h2>
      <p>
        Location access is controlled in iOS Settings and live sharing stops when the runner pauses
        or finishes a race. A runner can make each race public or passcode-protected. Account and
        race deletion are available in the iPhone app.
      </p>

      <h2>Contact</h2>
      <p>Questions or deletion assistance: <a href="mailto:taylor@taylortam.com">taylor@taylortam.com</a>.</p>
    </div>
  );
}

function SupportContent() {
  return (
    <div className="legal-copy">
      <p>
        For help with RunAlong, email <a href="mailto:taylor@taylortam.com">taylor@taylortam.com</a>.
        Include what you were doing, your iPhone model and iOS version, and any error message you saw.
        Never email a password or private race passcode.
      </p>

      <h2>Runner checklist</h2>
      <ul>
        <li>Allow location access when RunAlong asks.</li>
        <li>Start live tracking before the race and confirm the first GPS update appears.</li>
        <li>Locking the screen is okay, but do not force-quit or swipe RunAlong away.</li>
        <li>Keep the phone charged and use a battery pack for longer events.</li>
        <li>If service returns after an outage, use Sync now to publish the newest position.</li>
      </ul>

      <h2>Spectator checklist</h2>
      <ul>
        <li>Open the exact race link sent by the runner.</li>
        <li>For a private race, enter the 8-character passcode from the invitation.</li>
        <li>Delayed or stale indicators show how old the latest GPS update is.</li>
        <li>Refresh or reopen the page if your browser has been suspended for a long time.</li>
      </ul>

      <h2>Safety</h2>
      <p>
        Location, pace, and finish-time information are estimates and should not be used for
        emergencies. Contact local emergency services through the normal emergency channels.
      </p>
    </div>
  );
}
