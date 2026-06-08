"use client";

import { useCallback, useEffect, useRef, useState } from "react";

type PlayState = "idle" | "playing" | "paused";

// How long a press must be held (ms) before it counts as a "hold" (restart
// from the beginning) rather than a tap (play / pause / resume).
const HOLD_MS = 500;

export default function TTSButton({ text }: { text: string }) {
  const [state, setState] = useState<PlayState>("idle");

  const utteranceRef = useRef<SpeechSynthesisUtterance | null>(null);
  const holdTimer = useRef<number | null>(null);
  // Set when a press crosses the hold threshold, so the click that fires on
  // release is ignored (the hold already did its work).
  const heldRef = useRef(false);

  // Detach handlers from this button's current utterance so a later cancel()
  // (ours or another button's) can't reset state we've since moved past.
  const releaseUtterance = useCallback(() => {
    if (utteranceRef.current) {
      utteranceRef.current.onend = null;
      utteranceRef.current.onerror = null;
      utteranceRef.current = null;
    }
  }, []);

  const speakFromStart = useCallback(() => {
    releaseUtterance();
    speechSynthesis.cancel(); // stop anything currently speaking (any button)
    const u = new SpeechSynthesisUtterance(text);
    u.rate = 1;
    u.pitch = 1;
    u.onend = () => setState("idle");
    u.onerror = () => setState("idle");
    utteranceRef.current = u;
    speechSynthesis.speak(u);
    setState("playing");
  }, [text, releaseUtterance]);

  // Clean up on unmount: drop the hold timer and detach handlers so a canceled
  // utterance can't call setState on an unmounted component.
  useEffect(() => {
    return () => {
      if (holdTimer.current) clearTimeout(holdTimer.current);
      releaseUtterance();
    };
  }, [releaseUtterance]);

  const handleClick = () => {
    if (heldRef.current) {
      // This click is the tail of a hold gesture — already handled.
      heldRef.current = false;
      return;
    }
    if (state === "playing") {
      speechSynthesis.pause();
      setState("paused");
    } else if (state === "paused") {
      speechSynthesis.resume();
      setState("playing");
    } else {
      speakFromStart();
    }
  };

  const startHoldTimer = () => {
    heldRef.current = false;
    holdTimer.current = window.setTimeout(() => {
      heldRef.current = true;
      speakFromStart(); // hold => restart from the beginning
    }, HOLD_MS);
  };

  const cancelHoldTimer = () => {
    if (holdTimer.current) {
      clearTimeout(holdTimer.current);
      holdTimer.current = null;
    }
  };

  const reading = state === "playing";

  return (
    <button
      onPointerDown={startHoldTimer}
      onPointerUp={cancelHoldTimer}
      onPointerLeave={cancelHoldTimer}
      onClick={handleClick}
      onContextMenu={(e) => e.preventDefault()}
      aria-label={
        reading ? "Pause reading. Hold to restart from the beginning." : "Read aloud"
      }
      style={{
        padding: "6px 12px",
        background: "#0070f3",
        color: "white",
        border: "none",
        borderRadius: 6,
        cursor: "pointer",
        marginTop: 10,
        fontSize: 14,
        userSelect: "none",
        WebkitUserSelect: "none",
        touchAction: "manipulation",
      }}
    >
      {reading ? "⏸️ Pause" : "🔊 Read Aloud"}
    </button>
  );
}
