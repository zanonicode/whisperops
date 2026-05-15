"""Vercel-harmonized Plotly dark template for whisperops.

Registers `whisperops_vercel` as a named Plotly template. Intended to be
applied via ``pio.templates.default = 'plotly_dark+whisperops_vercel'``
inside the sandbox execution prelude, so every figure produced by the
worker inherits the template without any per-figure configuration.

Color palette:
  - Background: transparent (chat UI dark surface shows through)
  - Accent / first series: #0070f3 (Vercel blue, ADR-F1-009)
  - Grid: oklch(0.27 0 0) → #444 approximate
  - Font: Geist Sans fallback to system-ui
"""

from __future__ import annotations

import plotly.graph_objects as go
import plotly.io as pio

WHISPEROPS_COLORWAY = [
    "#0070f3",
    "#34d399",
    "#a78bfa",
    "#f97316",
    "#ec4899",
    "#facc15",
    "#22d3ee",
    "#f472b6",
]

WHISPEROPS_DARK_TEMPLATE = go.layout.Template(
    layout=go.Layout(
        paper_bgcolor="rgba(0,0,0,0)",
        plot_bgcolor="rgba(0,0,0,0)",
        colorway=WHISPEROPS_COLORWAY,
        font=dict(
            family="Geist Sans, ui-sans-serif, system-ui, sans-serif",
            color="#e4e4e7",
            size=13,
        ),
        title=dict(
            font=dict(
                family="Geist Sans, ui-sans-serif, system-ui, sans-serif",
                color="#f4f4f5",
                size=15,
            ),
            x=0.01,
            xanchor="left",
        ),
        xaxis=dict(
            gridcolor="#333",
            linecolor="#444",
            tickcolor="#444",
            zerolinecolor="#444",
            tickfont=dict(color="#a1a1aa"),
        ),
        yaxis=dict(
            gridcolor="#333",
            linecolor="#444",
            tickcolor="#444",
            zerolinecolor="#444",
            tickfont=dict(color="#a1a1aa"),
        ),
        legend=dict(
            bgcolor="rgba(0,0,0,0)",
            bordercolor="#333",
            font=dict(color="#e4e4e7"),
        ),
        hoverlabel=dict(
            bgcolor="#18181b",
            bordercolor="#333",
            font=dict(color="#f4f4f5", family="Geist Sans, ui-sans-serif, system-ui, sans-serif"),
        ),
        margin=dict(l=48, r=24, t=48, b=48),
    )
)


def register_whisperops_vercel() -> None:
    """Register the whisperops_vercel template so it can be referenced by name."""
    pio.templates["whisperops_vercel"] = WHISPEROPS_DARK_TEMPLATE
