#!/usr/bin/env python3
"""Summarise a LoRa walk-test recording exported from the Sophon app (#309).

The walker carries the gateway and the phone while the sensor stays at base
(LORA-UPDATED-PLAN.md § Walk-test procedure). The app logs one row per LoRa Link
record -- one per variant per 10 s window -- with the phone's position and its
distance from a pin dropped at the sensor. This turns that CSV into the table
LORA-PROTOCOL.md § Walk-test results wants: per distance band and variant, link
quality, margin, RSSI, and whether the variant passes at LQ >= 99%.

LQ is pooled over a band (total samples received / total expected), not
averaged per window, so a window that heard little cannot outvote one that heard
a lot. Rows with no position are reported apart. A recording with no pin at all
(made before the app took the start position as the pin) is measured from its
first fix, the same rule the app now applies.

"Worst margin" is the window's minimum SNR above the floor. On a moving link it
is the one that predicts loss: the first hardware walk lost 10-20 % of samples
while the average margin still read +12 to +19 dB.

Usage:
    scripts/walktest-report.py RECORDING.csv [--pass-lq 99] [--max-accuracy 30]
"""

from __future__ import annotations

import argparse
import csv
import itertools
import math
import sys
from collections import defaultdict
from dataclasses import dataclass, field

# Distance bands in metres, matching the walk test's stops (25, 50, 100 ... m).
BAND_EDGES = [0, 25, 50, 100, 200, 400, 800, 1600, 3200, 6400]


def band_of(distance: float) -> str:
    for low, high in itertools.pairwise(BAND_EDGES):
        if distance < high:
            return f"{low}-{high} m"
    return f">={BAND_EDGES[-1]} m"


def band_sort_key(band: str) -> float:
    if band == "no position":
        return math.inf
    return float(band.lstrip(">=").split("-")[0].split(" ")[0])


@dataclass
class Cell:
    windows: int = 0
    samples: int = 0
    missing: int = 0
    bad: int = 0
    unheard: int = 0
    margins: list[float] = field(default_factory=list)
    worst_margins: list[float] = field(default_factory=list)
    rssis: list[int] = field(default_factory=list)

    def add(self, row: dict[str, str]) -> None:
        self.windows += 1
        self.samples += int(row["samples"] or 0)
        self.missing += int(row["missing"] or 0)
        self.bad += int(row["bad"] or 0)
        if row["heard"] != "1":
            self.unheard += 1
            return
        if row["margin_db"]:
            self.margins.append(float(row["margin_db"]))
        if row.get("margin_min_db"):
            self.worst_margins.append(float(row["margin_min_db"]))
        elif row.get("snr_min") and row.get("sf"):
            # Recordings from before the column: SNRlim = -2.5 dB x (SF - 4).
            self.worst_margins.append(float(row["snr_min"]) + 2.5 * (int(row["sf"]) - 4))
        if row["rssi_avg"]:
            self.rssis.append(int(row["rssi_avg"]))

    def lq(self) -> float | None:
        expected = self.samples + self.missing
        return 100.0 * self.samples / expected if expected else None


def fill_missing_distances(rows: list[dict[str, str]]) -> None:
    """Give pinless recordings a distance from their first fix (equirectangular)."""
    if any(r.get("distance_m") for r in rows):
        return
    fixes = [r for r in rows if r.get("lat") and r.get("lon")]
    if not fixes:
        return
    lat0, lon0 = float(fixes[0]["lat"]), float(fixes[0]["lon"])
    for r in fixes:
        dy = (float(r["lat"]) - lat0) * 111_320
        dx = (float(r["lon"]) - lon0) * 111_320 * math.cos(math.radians(lat0))
        r["distance_m"] = f"{math.hypot(dx, dy):.0f}"
    print("(no pin in this recording: distances are from its first fix)\n")


def fmt(value: float | None, spec: str) -> str:
    return "—" if value is None else format(value, spec)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("csv", help="recording exported from the Sophon app")
    parser.add_argument(
        "--pass-lq", type=float, default=99.0, help="pass threshold, %% (default 99)"
    )
    parser.add_argument(
        "--max-accuracy",
        type=float,
        default=30.0,
        help="ignore positions with horizontal accuracy worse than this, m (default 30)",
    )
    args = parser.parse_args()

    with open(args.csv, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        print("no rows", file=sys.stderr)
        return 1

    fill_missing_distances(rows)
    cells: dict[tuple[str, str, str], Cell] = defaultdict(Cell)
    for row in rows:
        distance = row.get("distance_m", "")
        accuracy = row.get("h_accuracy_m", "")
        if distance and accuracy and float(accuracy) <= args.max_accuracy:
            band = band_of(float(distance))
        else:
            band = "no position"
        boost = "on" if row["rx_boost"] == "1" else "off"
        cells[(band, row["preset"], boost)].add(row)

    walk_test = any(r["walk_test"] == "1" for r in rows)
    print(f"# Walk-test report: {args.csv}\n")
    mode = " (walk-test mode)" if walk_test else ""
    print(f"{len(rows)} records{mode}; pass = LQ >= {args.pass_lq:g}%\n")
    print(
        "| Distance | Preset | RX boost | Windows | LQ % "
        "| Margin avg (dB) | Worst margin min (dB) | RSSI avg (dBm) | Bad | Pass |"
    )
    print("|---|---|---|---|---|---|---|---|---|---|")
    for band, preset, boost in sorted(cells, key=lambda k: (band_sort_key(k[0]), k[1], k[2])):
        cell = cells[(band, preset, boost)]
        lq = cell.lq()
        margin_avg = sum(cell.margins) / len(cell.margins) if cell.margins else None
        worst = min(cell.worst_margins) if cell.worst_margins else None
        rssi_avg = sum(cell.rssis) / len(cell.rssis) if cell.rssis else None
        verdict = "—" if lq is None else ("✓" if lq >= args.pass_lq else "✗")
        print(
            f"| {band} | {preset} | {boost} | {cell.windows} | {fmt(lq, '.1f')} | "
            f"{fmt(margin_avg, '+.1f')} | {fmt(worst, '+.1f')} | {fmt(rssi_avg, '.0f')} | "
            f"{cell.bad} | {verdict} |"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
