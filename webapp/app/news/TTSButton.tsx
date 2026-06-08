"use client";

export default function TTSButton({ text }: { text: string }) {
  const speak = () => {
    const utterance = new SpeechSynthesisUtterance(text);
    utterance.rate = 1;
    utterance.pitch = 1;
    speechSynthesis.speak(utterance);
  };

  return (
    <button
      onClick={speak}
      style={{
        padding: "6px 12px",
        background: "#0070f3",
        color: "white",
        border: "none",
        borderRadius: 6,
        cursor: "pointer",
        marginTop: 10,
        fontSize: 14,
      }}
    >
      🔊 Read Aloud
    </button>
  );
}
