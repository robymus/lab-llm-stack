"""Patch the inflight_batcher_llm `preprocessing/1/model.py` so the tokenizer's
chat template is applied to every incoming text_input before tokenization.

Why this exists
---------------
The upstream NVIDIA template at
`/app/all_models/inflight_batcher_llm/preprocessing/1/model.py` reads raw
text_input and tokenizes it directly:

    start_ids = [
        np.array(
            self.tokenizer.encode(s[0].decode(),
                                  add_special_tokens=self.add_special_tokens)
        ).astype(int)
        for s in query
    ]

When the model is chat-tuned (Qwen2.5-Instruct uses the ChatML format with
<|im_start|>/<|im_end|> framing), feeding it raw user text produces garbage
("say hi in 5 words" → "   20\\n\\n  ") because the model interprets the
prompt as a freeform completion, not a turn-of-conversation.

The fix is to wrap the text as a single-user-role chat and apply the
tokenizer's chat template (which embeds the role markers) before encoding.
LiteLLM's Triton provider sends one consolidated text_input per request,
so single-turn wrapping is the right shape — multi-turn history would
require a richer protocol than `{text_input: "..."}`.

This script is invoked by scripts/build-trt-engine.sh at Stage 3, AFTER
the upstream template has been copied into the model_repository. It
edits the file in place. Idempotent: running on an already-patched file
fails loudly rather than corrupting it (the regex matches exactly one
block in the upstream source).
"""

from __future__ import annotations

import argparse
import re
import sys

# The exact block we replace. Matched as a single regex against the
# upstream NVIDIA inflight_batcher_llm/preprocessing/1/model.py
# (TensorRT-LLM 0.18.x as of nvcr.io/nvidia/tritonserver:25.04-trtllm-python-py3).
# Whitespace is flexible — Triton ships this with 12 spaces of indent on
# each non-blank line. We match leading-whitespace agnostically so the
# regex survives reformatting drift.
OLD_RE = re.compile(
    r"start_ids\s*=\s*\[\s*"
    r"np\.array\(\s*"
    r"self\.tokenizer\.encode\(\s*s\[0\]\.decode\(\)\s*,\s*"
    r"add_special_tokens\s*=\s*self\."
    r"\s*add_special_tokens\s*\)\s*"
    r"\)\.astype\(int\)\s*"
    r"for\s+s\s+in\s+query\s*"
    r"\]"
)

# What we replace it with. Keep the same end-of-block shape so the
# surrounding control flow is unchanged.
NEW = '''start_ids = [
                    np.array(
                        self.tokenizer.encode(
                            self.tokenizer.apply_chat_template(
                                [{"role": "user", "content": s[0].decode()}],
                                tokenize=False,
                                add_generation_prompt=True,
                            ),
                            # The chat template already includes the model's
                            # BOS / <|im_start|> markers — don't double-add.
                            add_special_tokens=False,
                        )
                    ).astype(int)
                    for s in query
                ]'''


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path", help="path to preprocessing/1/model.py to patch in place")
    args = ap.parse_args()

    with open(args.path) as f:
        text = f.read()

    if "apply_chat_template" in text:
        # Already patched — second runs of build-trt-engine.sh shouldn't
        # error out, since Stage 3 clears the model_repository inside the
        # container before re-copying. This branch only trips if someone
        # invokes the patch script directly on an already-patched copy.
        print(f"[apply_chat_template] {args.path} already patched — no-op")
        return 0

    new_text, n_subs = OLD_RE.subn(NEW, text)
    if n_subs != 1:
        print(
            f"[apply_chat_template] ERROR: expected exactly 1 match in {args.path}, "
            f"got {n_subs}. The upstream template's tokenization block has "
            f"likely changed shape between TRT-LLM releases. Update OLD_RE in "
            f"this file to match the new upstream code.",
            file=sys.stderr,
        )
        return 1

    with open(args.path, "w") as f:
        f.write(new_text)
    print(f"[apply_chat_template] patched {args.path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
