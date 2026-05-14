import plotly.graph_objects as go
import plotly.io as pio

from app.plotly_theme import WHISPEROPS_DARK_TEMPLATE, register_whisperops_vercel


def test_template_has_correct_name():
    register_whisperops_vercel()
    assert "whisperops_vercel" in pio.templates


def test_template_colorway_starts_with_vercel_blue():
    color = WHISPEROPS_DARK_TEMPLATE.layout.colorway[0]
    assert color == "#0070f3"


def test_template_paper_bgcolor_is_transparent():
    assert WHISPEROPS_DARK_TEMPLATE.layout.paper_bgcolor == "rgba(0,0,0,0)"


def test_template_plot_bgcolor_is_transparent():
    assert WHISPEROPS_DARK_TEMPLATE.layout.plot_bgcolor == "rgba(0,0,0,0)"


def test_register_is_idempotent():
    register_whisperops_vercel()
    register_whisperops_vercel()
    assert pio.templates["whisperops_vercel"] is not None


def test_figure_renders_with_template():
    register_whisperops_vercel()
    fig = go.Figure(data=[go.Bar(x=[1, 2, 3], y=[4, 5, 6])])
    fig.update_layout(template="plotly_dark+whisperops_vercel")
    as_dict = fig.to_dict()
    assert "data" in as_dict
