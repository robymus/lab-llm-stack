"""Streamlit chat UI."""

import uuid

import streamlit as st

import agent

# --- Page config -----------------------------------------------------------
st.set_page_config(
    page_title="LLM Sandbox Chat",
    page_icon="🤖",
    layout="centered",
)

st.title("LLM Sandbox Chat")
st.caption("Qwen2.5-3B via LiteLLM → vLLM. Tool calls hit mock-services. Traces land in Langfuse.")


# --- User-id capture -------------------------------------------------------
# Streamlit reruns the whole script on every interaction; state lives in
# st.session_state. We use this for both the user_id and the chat history.

if "user_id" not in st.session_state:
    st.session_state.user_id = ""

# Seed a default for the input box exactly once. Without this, every
# keystroke triggers a rerun, the line below would generate a *new* uuid,
# and Streamlit would see the widget's `value=` change and reset the box
# back to that new uuid — so the user can't actually type their own id.
if "user_id_input" not in st.session_state:
    st.session_state.user_id_input = f"user-{uuid.uuid4().hex[:6]}"

if not st.session_state.user_id:
    # First-load gate: ask for a user-id before showing chat. The user
    # id is sent as X-User-Id on every gateway call AND becomes a Langfuse
    # user_id / session_id — group "everything Robert did" in one place.
    # Use `key=` (NOT `value=`) so user edits live in session state and
    # survive reruns.
    st.text_input(
        "Pick a user-id (becomes X-User-Id, Langfuse user_id, and session_id):",
        key="user_id_input",
    )
    if st.button("Start", type="primary"):
        st.session_state.user_id = st.session_state.user_id_input.strip()
        st.rerun()
    st.stop()


# --- Sidebar ---------------------------------------------------------------
st.sidebar.markdown(f"**Session as:** `{st.session_state.user_id}`")
st.sidebar.markdown(
    "**Try:**\n"
    "- `what's the weather in London?`\n"
    "- `umbrella in London and NVDA stock?`\n"
    "- `summarise the latest AI news`\n"
    "- `how does prefix caching work?`\n"
    "- `demonstrate an error by calling flaky_call with seed=a`"
)
st.sidebar.markdown("---")
st.sidebar.markdown("[Langfuse UI](http://localhost:3001) · [Grafana](http://localhost:3000)")
if st.sidebar.button("Reset chat"):
    st.session_state.messages = []
    st.rerun()


# --- Chat state + agent ----------------------------------------------------
if "messages" not in st.session_state:
    st.session_state.messages = []


@st.cache_resource(show_spinner=False)
def _executor_for(user_id: str):
    """One Agent per user-id, cached for the session.

    `@st.cache_resource` survives reruns within the Streamlit process so
    we don't rebuild ChatOpenAI / AgentExecutor on every keystroke. OTLP
    tracing (Phase 2.2) is initialised at agent.py import time and
    doesn't need re-binding per user; the user_id is stamped per-call via
    `Traceloop.set_association_properties`.
    """
    return agent.build_executor(user_id)


executor = _executor_for(st.session_state.user_id)


# Render past turns
for m in st.session_state.messages:
    with st.chat_message(m["role"]):
        st.markdown(m["content"])


# Take next input
prompt = st.chat_input("Ask anything. Multi-part questions produce richer trace trees.")
if prompt:
    # Display user message immediately
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    # Invoke agent; show spinner while LLM + tools chew on it
    with st.chat_message("assistant"):
        with st.spinner("thinking..."):
            # Chat history is everything *before* this turn — the current
            # prompt is passed as the first arg separately.
            prior = st.session_state.messages[:-1]
            try:
                response = executor.chat(prompt, prior)
            except Exception as e:
                # The Agent has already flushed the (error) trace by now.
                # Surface the failure plainly in the UI.
                response = f"⚠️ {type(e).__name__}: {e}"
        st.markdown(response)
        st.session_state.messages.append({"role": "assistant", "content": response})
