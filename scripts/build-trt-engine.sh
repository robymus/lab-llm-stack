#!/usr/bin/env bash
# =============================================================================
#  build-trt-engine.sh — compile a TensorRT-LLM engine for Qwen2.5-3B-Instruct
# -----------------------------------------------------------------------------
#  One-off host-side step that prepares the `triton/model_repository/` so
#  the `triton-server` compose service (profile `triton`) can serve the
#  model. The compiled `.engine` is binary, ~3 GB, and *GPU-architecture
#  specific* — built for compute capability 8.9 (Ada / RTX 4060). It will
#  not run on Ampere, Hopper, or anything else; rebuild on a new GPU.
#
#  Time: ~10-15 minutes on a 4060 (CPU-bound for the conversion step,
#  GPU-bound for the build).
#  Disk: ~3 GB final engine + ~6 GB fp16 weights + ~5 GB intermediates
#  during the convert step. Cleaned up at the end except for engine + repo.
#
#  Important: this needs the GPU. Stop vLLM first — both engines won't fit
#  on an 8 GB card simultaneously:
#      docker compose stop vllm-engine
#
#  After this script:
#      docker compose --profile triton up -d triton-server
#      curl :4000/v1/chat/completions -d '{"model":"qwen-chat-trt", ...}'
#
#  This is Phase 2.0's load-bearing chore. If the script breaks, the
#  triton/README.md "Troubleshooting" section is your friend.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
#  Locations + image
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINES_DIR="${REPO_ROOT}/triton/engines"
MODEL_REPO="${REPO_ROOT}/triton/model_repository"
PATCHES_DIR="${REPO_ROOT}/triton/patches"
HF_CACHE="${HOME}/.cache/huggingface"

# Image pin must match docker-compose.yaml's triton-server service.
TRT_IMAGE="nvcr.io/nvidia/tritonserver:25.04-trtllm-python-py3"

# Use the fp16 Qwen2.5-3B-Instruct (not -AWQ). The HF AWQ checkpoint uses
# autoawq's format which TRT-LLM's convert_checkpoint.py doesn't natively
# accept; the standard TRT-LLM flow is fp16 weights → modelopt quantize
# (or weight-only on-the-fly) → trtllm-build. Adds ~6 GB to disk on first
# run; future runs reuse the HF cache.
HF_MODEL="Qwen/Qwen2.5-3B-Instruct"

# Internal names — what the conversion + Triton model layout expects.
CONVERTED_CKPT_DIR="/tmp/qwen_ckpt"          # convert_checkpoint.py output (inside container)
ENGINE_DIR_CONTAINER="/engines/qwen-chat-trt"
MODEL_REPO_CONTAINER="/models"

# ---------------------------------------------------------------------------
#  Colours
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; BOLD=""; RESET=""
fi

step() { echo; echo "${BOLD}===${RESET} $1"; }
note() { echo "  ${GREEN}•${RESET} $1"; }
warn() { echo "  ${YELLOW}!${RESET} $1"; }
fail() { echo "  ${RED}✗${RESET} $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
#  Preconditions
# ---------------------------------------------------------------------------
step "Checking preconditions"

command -v docker >/dev/null 2>&1 || fail "docker not on PATH"
if ! docker image inspect "$TRT_IMAGE" >/dev/null 2>&1; then
    fail "$TRT_IMAGE not pulled yet — run scripts/pull-phase2-images.sh first"
fi
note "Triton image present"

if docker ps --format '{{.Names}}' | grep -q '^vllm-engine$'; then
    warn "vllm-engine is running — both engines won't fit on 8 GB GPU"
    warn "stop it first:  docker compose stop vllm-engine"
    fail "abort"
fi
note "vllm-engine is not occupying the GPU"

[ -d "$HF_CACHE" ] || mkdir -p "$HF_CACHE"
mkdir -p "$ENGINES_DIR" "$MODEL_REPO"
note "Host dirs ready"

# Free RAM budget hint — the build process peaks around 10 GB.
free_kb=$(awk '/^MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
if [ "$free_kb" -lt 8000000 ]; then
    warn "Less than 8 GB RAM available — convert step may swap heavily"
fi

# Idempotency: if the engine is already compiled, skip the expensive
# convert + build stages and jump straight to model_repository assembly.
# Set FORCE_REBUILD=1 to override (e.g. after pulling a newer Triton image).
SKIP_BUILD=0
if [ "${FORCE_REBUILD:-0}" != "1" ] && \
   compgen -G "${ENGINES_DIR}/qwen-chat-trt/*.engine" >/dev/null; then
    SKIP_BUILD=1
    note "Existing engine found at ${ENGINES_DIR}/qwen-chat-trt/ — skipping convert + build"
    note "(set FORCE_REBUILD=1 to recompile from scratch)"
fi

# ---------------------------------------------------------------------------
#  Stage 1 — convert HF weights → TRT-LLM checkpoint
# ---------------------------------------------------------------------------
#  Runs the per-model convert script that ships with TRT-LLM. The image
#  bundles examples at /app/tensorrt_llm/examples/qwen — that's where the
#  Qwen-specific convert_checkpoint.py lives.
#
#  `--use_weight_only --weight_only_precision int4` is plain int4
#  weight-only quantization — no calibration, ~50% of fp16 footprint, a
#  bit less accurate than AWQ but fine for the sandbox demo. The "real"
#  AWQ flow in TRT-LLM 0.18 lives under examples/quantization/quantize.py
#  and needs modelopt + a calibration dataset; deferred unless this
#  rig's accuracy proves unacceptable.
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = "1" ]; then
    step "Stage 1/3 — SKIPPED (engine already exists)"
else
step "Stage 1/3 — convert HF weights → TRT-LLM checkpoint (~3-5 min)"

docker run --rm --gpus all \
    -v "${HF_CACHE}:/hf" \
    -v "${ENGINES_DIR}:/engines" \
    -e HF_HOME=/hf \
    -e HUGGINGFACE_HUB_CACHE=/hf/hub \
    "$TRT_IMAGE" \
    bash -c "
        set -e
        # convert_checkpoint.py needs a local directory, not a HF model id —
        # download (or reuse cached) snapshot first, then point --model_dir
        # at the resolved local path.
        MODEL_DIR=\$(python3 -c \"
from huggingface_hub import snapshot_download
print(snapshot_download(repo_id='$HF_MODEL'))
\")
        echo \"Local snapshot: \$MODEL_DIR\"

        cd /app/examples/qwen
        python3 convert_checkpoint.py \
            --model_dir \"\$MODEL_DIR\" \
            --output_dir '$CONVERTED_CKPT_DIR' \
            --dtype float16 \
            --use_weight_only \
            --weight_only_precision int4
    " || fail "convert_checkpoint.py failed — check the image's examples/qwen path and HF cache permissions"

note "Checkpoint converted"

# ---------------------------------------------------------------------------
#  Stage 2 — build the engine
# ---------------------------------------------------------------------------
#  `trtllm-build` reads the TRT-LLM checkpoint produced above and emits a
#  GPU-specific `.engine` file plus a config.json describing inputs/outputs.
#  The plugins below are required for AWQ + paged-KV-cache batching.
# ---------------------------------------------------------------------------
step "Stage 2/3 — trtllm-build → .engine (~7-10 min)"

# Free up before the GPU-heavy step.
rm -rf "${ENGINES_DIR}/qwen-chat-trt"

docker run --rm --gpus all \
    -v "${HF_CACHE}:/hf" \
    -v "${ENGINES_DIR}:/engines" \
    -e HF_HOME=/hf \
    -e HUGGINGFACE_HUB_CACHE=/hf/hub \
    "$TRT_IMAGE" \
    bash -c "
        set -e
        # Same convert step needs to be re-run inside this fresh container
        # to recreate $CONVERTED_CKPT_DIR; it lives in /tmp so it's lost
        # between docker run invocations. (Bind-mounting /tmp is an option
        # but pollutes the host's /tmp with multi-GB files.)
        MODEL_DIR=\$(python3 -c \"
from huggingface_hub import snapshot_download
print(snapshot_download(repo_id='$HF_MODEL'))
\")
        cd /app/examples/qwen
        python3 convert_checkpoint.py \
            --model_dir \"\$MODEL_DIR\" \
            --output_dir '$CONVERTED_CKPT_DIR' \
            --dtype float16 \
            --use_weight_only \
            --weight_only_precision int4 > /dev/null

        trtllm-build \
            --checkpoint_dir '$CONVERTED_CKPT_DIR' \
            --output_dir '$ENGINE_DIR_CONTAINER' \
            --gemm_plugin float16 \
            --gpt_attention_plugin float16 \
            --max_batch_size 8 \
            --max_input_len 3072 \
            --max_seq_len 4096 \
            --use_paged_context_fmha enable
    " || fail "trtllm-build failed — check stderr above for unsupported quant config or OOM"

note "Engine compiled at ${ENGINES_DIR}/qwen-chat-trt/"
fi   # end of SKIP_BUILD gate

# ---------------------------------------------------------------------------
#  Stage 3 — assemble the Triton model_repository
# ---------------------------------------------------------------------------
#  The TRT-LLM backend ships a template at /app/all_models/inflight_batcher_llm/
#  inside the image. Five sub-models: preprocessing, postprocessing,
#  tensorrt_llm (the engine wrapper), ensemble, and tensorrt_llm_bls. We
#  copy them out, plug the engine + tokenizer paths via fill_template.py,
#  and that becomes our model_repository.
#
#  LiteLLM hits the model named `ensemble` (preprocess → tensorrt_llm →
#  postprocess) — that's what triton/qwen-chat-trt in litellm/config.yaml
#  resolves to.
# ---------------------------------------------------------------------------
step "Stage 3/3 — assemble Triton model_repository"

# Note: clearing the previous repo happens INSIDE the docker run, not on
# the host. Files created by a previous run are owned by root (the
# in-container uid), and the host user can't rm them.

docker run --rm --gpus all \
    -v "${HF_CACHE}:/hf" \
    -v "${ENGINES_DIR}:/engines" \
    -v "${MODEL_REPO}:${MODEL_REPO_CONTAINER}" \
    -v "${PATCHES_DIR}:/patches:ro" \
    "$TRT_IMAGE" \
    bash -c "
        set -e
        # Clear any previous template inside the container (root has rm
        # rights on everything). Keep .gitkeep so the directory survives
        # in git on a fresh clone.
        find '$MODEL_REPO_CONTAINER' -mindepth 1 ! -name '.gitkeep' \
            -exec rm -rf {} + 2>/dev/null || true

        # Copy the upstream all_models template into our bind-mounted repo.
        cp -R /app/all_models/inflight_batcher_llm/* '$MODEL_REPO_CONTAINER/'

        # Patch preprocessing's model.py to apply Qwen's chat template
        # before tokenization. Without this, the chat-tuned model sees
        # raw text and produces freeform-completion garbage instead of
        # turn-of-conversation replies. See triton/patches/apply_chat_template.py
        # for the rationale + the exact transform.
        python3 /patches/apply_chat_template.py \\
            '$MODEL_REPO_CONTAINER/preprocessing/1/model.py'

        # Copy the tokenizer files INTO the model_repository so the running
        # triton-server (which only bind-mounts /models, not /hf) can load
        # them. Without this, preprocessing/postprocessing fail at startup
        # with 'Incorrect path_or_model_id: /hf/hub/...' because the build-
        # time HF path doesn't exist at runtime.
        #
        # IMPORTANT: we drop the tokenizer inside preprocessing/tokenizer/
        # (a SUB-directory of an existing model). Triton's model loader
        # scans the top level of /models/ and tries to load every direct
        # child as a model; a bare /models/tokenizer/ confuses it with
        # 'Could not determine backend for model "tokenizer"'. Sub-dirs of
        # models are not scanned, so this layout is safe.
        # tokenizer.json + tokenizer_config.json + vocab files together
        # are ~7 MB — cheap.
        HF_SNAPSHOT=\$(ls -d /hf/hub/models--Qwen--Qwen2.5-3B-Instruct/snapshots/*/ | head -1)
        mkdir -p '$MODEL_REPO_CONTAINER/preprocessing/tokenizer'
        cp -L \"\${HF_SNAPSHOT}\"/*.json '$MODEL_REPO_CONTAINER/preprocessing/tokenizer/'
        # Some tokenizers have BPE merges.txt; copy if present.
        cp -L \"\${HF_SNAPSHOT}\"/merges.txt '$MODEL_REPO_CONTAINER/preprocessing/tokenizer/' 2>/dev/null || true

        # Drop the engine alongside the tensorrt_llm sub-model.
        mkdir -p '$MODEL_REPO_CONTAINER/tensorrt_llm/1'
        cp -R '$ENGINE_DIR_CONTAINER'/* '$MODEL_REPO_CONTAINER/tensorrt_llm/1/'

        # Fill in the templated config.pbtxt placeholders. tokenizer_dir
        # points at the tokenizer dir nested under preprocessing/, which
        # is the path the running container will see (preprocessing/
        # itself is bind-mounted read-only as part of /models).
        # Fill EVERY placeholder in each config.pbtxt. fill_template.py
        # leaves unprovided \${X} as literal strings, and validate-triton-repo.sh
        # now catches those. Several previously-unfilled ones are silently
        # tolerated at LOAD time but break at INFERENCE time
        # (e.g. add_special_tokens, skip_special_tokens, logits_datatype).
        TOKENIZER_DIR_RUNTIME='$MODEL_REPO_CONTAINER/preprocessing/tokenizer'

        # ----- preprocessing -------------------------------------------------
        # add_special_tokens=true: prepend Qwen's <|im_start|>system/user.
        # engine_dir is used by the tokenizer to look up max-len constraints
        # from the engine's config.json. max_num_images=0 and visual_model_path=
        # empty disable the multimodal preprocessing path.
        python3 /app/tools/fill_template.py -i \\
            '$MODEL_REPO_CONTAINER/preprocessing/config.pbtxt' \\
            tokenizer_dir:\${TOKENIZER_DIR_RUNTIME},triton_max_batch_size:8,preprocessing_instance_count:1,add_special_tokens:true,engine_dir:$MODEL_REPO_CONTAINER/tensorrt_llm/1,max_num_images:0,visual_model_path:

        # ----- postprocessing ------------------------------------------------
        # skip_special_tokens=true so the decoded output is clean text
        # (no leading <|im_start|>assistant\\n in the response).
        python3 /app/tools/fill_template.py -i \\
            '$MODEL_REPO_CONTAINER/postprocessing/config.pbtxt' \\
            tokenizer_dir:\${TOKENIZER_DIR_RUNTIME},triton_max_batch_size:8,postprocessing_instance_count:1,skip_special_tokens:true

        # ----- ensemble ------------------------------------------------------
        python3 /app/tools/fill_template.py -i \\
            '$MODEL_REPO_CONTAINER/ensemble/config.pbtxt' \\
            triton_max_batch_size:8,logits_datatype:TYPE_FP32

        # ----- tensorrt_llm (the engine wrapper) -----------------------------
        # 28 placeholders; most are optional knobs but fill_template needs
        # a value or the literal \${X} stays in the file. Pass an empty
        # string for the unused ones; sensible defaults for the rest.
        python3 /app/tools/fill_template.py -i \\
            '$MODEL_REPO_CONTAINER/tensorrt_llm/config.pbtxt' \\
            triton_backend:tensorrtllm,triton_max_batch_size:8,decoupled_mode:false,max_beam_width:1,engine_dir:$MODEL_REPO_CONTAINER/tensorrt_llm/1,max_tokens_in_paged_kv_cache:2560,max_attention_window_size:4096,kv_cache_free_gpu_mem_fraction:0.5,exclude_input_in_output:true,enable_kv_cache_reuse:true,batching_strategy:inflight_fused_batching,max_queue_delay_microseconds:0,encoder_input_features_data_type:TYPE_FP16,logits_datatype:TYPE_FP32,batch_scheduler_policy:max_utilization,cancellation_check_period_ms:100,stats_check_period_ms:100,iter_stats_max_iterations:100,request_stats_max_iterations:0,enable_chunked_context:false,enable_context_fmha_fp32_acc:false,enable_trt_overlap:false,multi_block_mode:true,normalize_log_probs:true,decoding_mode:top_k_top_p,sink_token_length:,cross_kv_cache_fraction:,encoder_engine_dir:,gpu_device_ids:,gpu_weights_percent:1.0,kv_cache_host_memory_bytes:0,kv_cache_onboard_blocks:true,participant_ids:,medusa_choices:,eagle_choices:,speculative_decoding_fast_logits:false,cuda_graph_cache_size:0,cuda_graph_mode:false,lora_cache_gpu_memory_fraction:0.05,lora_cache_host_memory_bytes:0,lora_cache_max_adapter_size:64,lora_cache_optimal_adapter_size:8

        # ----- tensorrt_llm_bls (Business Logic Scripting wrapper) -----------
        # BLS needs tensorrt_llm_model_name set — the Triton-internal model
        # the BLS forwards each request to. draft/encoders are unused.
        python3 /app/tools/fill_template.py -i \\
            '$MODEL_REPO_CONTAINER/tensorrt_llm_bls/config.pbtxt' \\
            triton_max_batch_size:8,decoupled_mode:false,bls_instance_count:1,accumulate_tokens:false,logits_datatype:TYPE_FP32,tensorrt_llm_model_name:tensorrt_llm,tensorrt_llm_draft_model_name:,multimodal_encoders_name:
    " || fail "model_repository assembly failed"

note "Model repository assembled at ${MODEL_REPO}/"

# ---------------------------------------------------------------------------
#  Done
# ---------------------------------------------------------------------------
step "Done"
note "Engine binary: ${ENGINES_DIR}/qwen-chat-trt/"
note "Triton model repository: ${MODEL_REPO}/"
echo
echo "Next steps:"
echo "  1.  docker compose --profile triton up -d triton-server"
echo "  2.  curl :4000/v1/chat/completions \\"
echo "        -H \"Authorization: Bearer \$(grep ^LITELLM_MASTER_KEY .env | cut -d= -f2)\" \\"
echo "        -H 'Content-Type: application/json' \\"
echo "        -d '{\"model\":\"qwen-chat-trt\",\"messages\":[{\"role\":\"user\",\"content\":\"say hi\"}]}'"
echo
echo "If you want to swap back to vLLM, leave the triton profile off and"
echo "bring vllm-engine back:  docker compose up -d vllm-engine"
