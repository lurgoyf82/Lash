"""Default Streamlit entrypoint for the LASH local dashboard."""

import streamlit as st


def render_dashboard() -> None:
    """Render a minimal dashboard so the generated Streamlit service can start."""
    st.set_page_config(page_title="LASH", layout="wide")
    st.title("LASH")
    st.success("Streamlit service is running.")
    st.write("Use this placeholder dashboard as the starting point for your local AI workspace.")


render_dashboard()
