"use client";

import {FormEvent, useEffect, useState} from "react";
import RaceTracker from "./race-tracker";

export default function Home() {
  const [raceId, setRaceId] = useState("");
  const [linkedRaceId, setLinkedRaceId] = useState<string | null>(null);
  useEffect(() => {
    setLinkedRaceId(new URLSearchParams(window.location.search).get("race"));
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
      </section>
      <div className="runner-orbit" aria-hidden="true"><span>🏃</span></div>
    </main>
  );
}
