This is a professional-grade "mini-DC" architecture. Even on a single laptop with a 4060, this setup accurately mirrors a production H100 cluster environment.

### The Architecture: "The LLM SRE Sandbox"

The core challenge in your request is making **vLLM** and **Triton/TensorRT-LLM** switchable. While both support the OpenAI API spec, Triton requires a complex "Model Repository" folder structure and a preprocessing step (compiling the engine), whereas vLLM loads raw weights. We will use **LiteLLM** as a gateway to unify them perfectly.



---

### Succinct Lab Component Map

| Layer | Component | Implementation Detail |
| :--- | :--- | :--- |
| **UI** | **Streamlit** | Fast Python-based UI; will send a `user_id` header to simulate multi-tenancy. |
| **Orchestrator** | **LangChain / Python** | Runs the Agent logic. Instrumented with **OpenLLMetry**. |
| **Gateway** | **LiteLLM** | Acts as the "Load Balancer." It standardizes the API and provides a single endpoint for LangChain regardless of the backend. |
| **Inference A** | **vLLM** | Loads `Llama-3-8B-Instruct-AWQ` (4-bit quantization). Fast to start. |
| **Inference B** | **Triton + TRT-LLM** | The "Heavy" backend. Requires pre-compiling the model for the 4060. - This will be plugged in Phase 2 only. |
| **Hardware Obs** | **NVIDIA DCGM** | Exports GPU metrics (clocks, temp, power) to Prometheus. |
| **Tracing** | **Langfuse** | Captures the "Logic" traces (the Agent's thoughts/tool calls). |
| **Metrics** | **Prometheus + Grafana** | The single pane of glass for throughput vs. hardware health. |

---

### Docker Compose Blueprint (`docker-compose.yaml`)

You can structure your compose file into "Infrastructure" and "Compute" profiles.

```yaml
services:
  # --- OBSERVABILITY STACK ---
  prometheus:
    image: prom/prometheus
    volumes: [ "./prom-config:/etc/prometheus" ]
    ports: [ "9090:9090" ]

  grafana:
    image: grafana/grafana
    ports: [ "3000:3000" ]
    environment: [ "GF_AUTH_ANONYMOUS_ENABLED=true" ]

  langfuse:
    image: langfuse/langfuse:latest
    ports: [ "3001:3000" ]
    environment: [ "DATABASE_URL=postgresql://..." ] # Needs a DB container too

  # --- HARDWARE TELEMETRY ---
  dcgm-exporter:
    image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04
    deploy:
      resources:
        reservations:
          devices: [{driver: nvidia, count: 1, capabilities: [gpu]}]

  # --- INFERENCE ENGINES ---
  vllm-engine:
    image: vllm/vllm-openai
    command: --model unsloth/llama-3-8b-instruct-bnb-4bit --gpu-memory-utilization 0.7
    deploy:
      resources:
        reservations:
          devices: [{driver: nvidia, count: 1, capabilities: [gpu]}]

  # --- THE GATEWAY (Load Balancer / Standardizer) ---
  litellm:
    image: ghcr.io/berriai/litellm:main-latest
    ports: [ "4000:4000" ]
    volumes: [ "./litellm-config.yaml:/app/config.yaml" ]

  # --- THE APP ---
  agent-app:
    build: ./app
    environment:
      - OPENAI_API_BASE=http://litellm:4000
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://langfuse:3000/api/public/otel
```

---

### SRE Learning Objectives for this Lab

1.  **The "Switch-Over" test:** Start with `vllm-engine`. Update LiteLLM config to point to a (theoretical) `triton-engine`. Verify that your `agent-app` logic remains untouched.
2.  **Saturation Analysis:** Use `nvidia-smi` and DCGM metrics to see the "Memory Pressure" when you increase the batch size in LiteLLM.
3.  **Observability Correlation:** 
    *   **The Goal:** In Grafana, overlay **"Inference Latency"** (from LiteLLM) with **"GPU Power Draw"** (from DCGM). 
    *   **The Insight:** You'll see that LLMs are "bursty." Power spikes during the "Prefill" phase and stabilizes during "Decoding."
4.  **Multi-User Simulation:** Use the Streamlit UI to send requests with different `X-User-ID` headers. Check Langfuse to see how it groups traces by user—crucial for debugging "Why is user Robert getting hallucinations but user Maliwan isn't?"

### Note on Triton + 4060
Triton with TensorRT-LLM is much "finitier" than vLLM. You have to build a "plan file" specifically for the **compute capability** of the 4060 (v8.9). This is the "Hard Mode" of the lab, but it's exactly what an SRE does in a high-performance environment.
