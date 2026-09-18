#!/usr/bin/env python3
"""PATCH 2026-09-17 tc-lookahead for reasoning_parser.py (SGLang 0.5.19).

Fixes: a <tool_call_section_begin> ("
") appearing INSIDE thinking
prematurely closes the reasoning block, leaking the rest of the thinking
(incl. the real <think_end>) into normal text -> tool-call parser sees mixed
thinking fragments -> malformed tool_calls / raw tags in content.

Rule (streaming + one-shot, qwen3 family only):
  - <think_end> always closes reasoning (all <tool> before it are thinking).
  - A <tool> whose next marker is another <tool> (before any <think_end>)
    was thinking prose -> keep reasoning, re-hold at the next <tool>.
  - A <tool> immediately followed (modulo whitespace) by <function= is a
    well-formed real block (model omitted <think_end>) -> close there.
  - Stream ends while holding -> last held <tool> is the real tool start.

Idempotent-ish: fails (exit 1) if any OLD block is not found exactly once.
"""
import sys

SRC = "_reasoning_parser_orig.py"
DST = "_reasoning_parser_patched.py"

text = open(SRC, encoding="utf-8").read()

def rep(old: str, new: str, label: str):
    global text
    n = text.count(old)
    if n != 1:
        print(f"FAIL [{label}]: found {n} occurrence(s), expected 1")
        sys.exit(1)
    text = text.replace(old, new)
    print(f"ok   [{label}]")

# R1: guard marker at file top
rep(
    "import inspect\nimport re\n",
    "# PATCH 2026-09-17 tc-lookahead: tool tags in thinking no longer "
    "prematurely close reasoning (guard marker)\n"
    "import inspect\nimport re\n",
    "R1-marker",
)

# R2: base __init__ state
rep(
    "        self._force_nonempty_content = force_nonempty_content\n"
    "        self._accumulated_reasoning = \"\"\n",
    "        self._force_nonempty_content = force_nonempty_content\n"
    "        self._accumulated_reasoning = \"\"\n"
    "\n"
    "        # PATCH 2026-09-17 tc-lookahead: state for tool-tag-in-thinking.\n"
    "        # When a tool_start_token is seen during reasoning we hold from\n"
    "        # that point and wait for think_end (definitive close), another\n"
    "        # tool_start_token (this one was thinking prose), or a\n"
    "        # well-formed real block (tool_start + function prefix, model\n"
    "        # omitted think_end). Only detectors that opt in via\n"
    "        # _tc_lookahead change behavior; others keep the legacy\n"
    "        # immediate close.\n"
    "        self._tc_lookahead = False\n"
    "        self._held_tc = None\n"
    "        self.tc_block_prefix = None\n",
    "R2-base-init",
)

# R3: Qwen3Detector opt-in
rep(
    "            thinks_internally=True,\n"
    "            reasoning_default=\"enable_thinking\",\n"
    "            force_nonempty_content=force_nonempty_content,\n"
    "        )\n",
    "            thinks_internally=True,\n"
    "            reasoning_default=\"enable_thinking\",\n"
    "            force_nonempty_content=force_nonempty_content,\n"
    "        )\n"
    "        # PATCH 2026-09-17 tc-lookahead: Qwen3.8 SFT writes tool tags\n"
    "        # inside thinking while planning calls; enable lookahead and the\n"
    "        # <function= well-formed-block check (pairs with the qwen3_coder\n"
    "        # tool-call parser).\n"
    "        self._tc_lookahead = True\n"
    "        self.tc_block_prefix = \"<function=\"\n",
    "R3-qwen3-optin",
)

# R4: one-shot split point
rep(
    "                # Find the first occurrence of tool_start_token and split there\n"
    "                tool_idx = processed_text.find(self.tool_start_token)\n",
    "                # Find the tool_start_token split point and split there.\n"
    "                # PATCH 2026-09-17 tc-lookahead: a tool tag followed by\n"
    "                # prose is a thinking mention; the real tool start is the\n"
    "                # first one followed by a <function= block (or the last\n"
    "                # one if none is).\n"
    "                if self._tc_lookahead:\n"
    "                    tool_idx = self._find_real_tool_start(processed_text)\n"
    "                else:\n"
    "                    tool_idx = processed_text.find(self.tool_start_token)\n",
    "R4-oneshot",
)

# R5a: streaming held-state early return
rep(
    "    def _parse_streaming_increment_impl(self, new_text: str) -> StreamingParseResult:\n"
    "        self._buffer += new_text\n"
    "        current_text = self._buffer\n",
    "    def _parse_streaming_increment_impl(self, new_text: str) -> StreamingParseResult:\n"
    "        # PATCH 2026-09-17 tc-lookahead: while holding a tool tag seen\n"
    "        # during reasoning, accumulate into the held buffer and re-check\n"
    "        # the close decision instead of running the normal state machine.\n"
    "        if self._held_tc is not None:\n"
    "            self._held_tc += new_text\n"
    "            return self._process_tc_held()\n"
    "        self._buffer += new_text\n"
    "        current_text = self._buffer\n",
    "R5a-streaming-early-return",
)

# R5b: streaming close -> hold
rep(
    "            if self.tool_start_token and self.tool_start_token in current_text:\n"
    "                tool_idx = current_text.find(self.tool_start_token)\n"
    "                reasoning_text = current_text[:tool_idx]\n"
    "                # Preserve tool_start_token in normal text\n"
    "                normal_text = current_text[tool_idx:]\n"
    "                self._buffer = \"\"\n"
    "                self._in_reasoning = False\n"
    "                return StreamingParseResult(\n"
    "                    normal_text=normal_text, reasoning_text=reasoning_text\n"
    "                )\n",
    "            if self.tool_start_token and self.tool_start_token in current_text:\n"
    "                tool_idx = current_text.find(self.tool_start_token)\n"
    "                if self._tc_lookahead:\n"
    "                    # PATCH 2026-09-17 tc-lookahead: a tool tag in thinking\n"
    "                    # must not close reasoning. Hold from the tag and wait\n"
    "                    # for think_end / another tool tag / a well-formed real\n"
    "                    # block. current_text[:tool_idx] is all still-unemitted\n"
    "                    # reasoning (incl. any holdback tail); emit it now.\n"
    "                    self._held_tc = current_text[tool_idx:]\n"
    "                    self._buffer = \"\"\n"
    "                    ret = self._process_tc_held()\n"
    "                    ret.reasoning_text = (\n"
    "                        current_text[:tool_idx] + ret.reasoning_text\n"
    "                    )\n"
    "                    return ret\n"
    "                reasoning_text = current_text[:tool_idx]\n"
    "                # Preserve tool_start_token in normal text\n"
    "                normal_text = current_text[tool_idx:]\n"
    "                self._buffer = \"\"\n"
    "                self._in_reasoning = False\n"
    "                return StreamingParseResult(\n"
    "                    normal_text=normal_text, reasoning_text=reasoning_text\n"
    "                )\n",
    "R5b-streaming-hold",
)

# R6: new helper methods (before _strip_leading_think_start)
rep(
    "    def _strip_leading_think_start(self, text: str) -> str:\n",
    "    def _process_tc_held(self) -> StreamingParseResult:\n"
    "        \"\"\"PATCH 2026-09-17 tc-lookahead: resolve a held tool tag that was\n"
    "        seen during reasoning.\n"
    "\n"
    "        - think_end arrives first -> close at think_end; held text up to it\n"
    "          (incl. the tool tag) is reasoning, the rest is normal text.\n"
    "        - A well-formed real block (tool tag + <function= modulo whitespace)\n"
    "          -> the model omitted think_end; close at the held tool tag.\n"
    "        - Another tool tag arrives first -> the held tag was thinking prose;\n"
    "          emit it as reasoning and keep holding from the new tag.\n"
    "        - None of the above yet -> keep holding (wait for more tokens).\n"
    "        \"\"\"\n"
    "        held = self._held_tc\n"
    "        tc_len = len(self.tool_start_token)\n"
    "        rest = held[tc_len:]\n"
    "        rest_l = rest.lstrip()\n"
    "\n"
    "        end_pos = held.find(self.think_end_token)\n"
    "        next_tc = held.find(self.tool_start_token, tc_len)\n"
    "        wf_pos = -1\n"
    "        if self.tc_block_prefix and rest_l.startswith(self.tc_block_prefix):\n"
    "            wf_pos = tc_len + (len(rest) - len(rest_l))\n"
    "\n"
    "        candidates = []\n"
    "        if end_pos != -1:\n"
    "            candidates.append((\"end\", end_pos))\n"
    "        if next_tc != -1:\n"
    "            candidates.append((\"next_tc\", next_tc))\n"
    "        if wf_pos != -1:\n"
    "            candidates.append((\"wf\", wf_pos))\n"
    "        if not candidates:\n"
    "            return StreamingParseResult()\n"
    "\n"
    "        kind, pos = min(candidates, key=lambda x: x[1])\n"
    "\n"
    "        if kind == \"end\":\n"
    "            reasoning_seg = held[:end_pos]\n"
    "            normal_seg = held[end_pos + len(self.think_end_token):]\n"
    "            self._in_reasoning = False\n"
    "            self._held_tc = None\n"
    "            self._buffer = \"\"\n"
    "            return StreamingParseResult(\n"
    "                normal_text=normal_seg, reasoning_text=reasoning_seg\n"
    "            )\n"
    "\n"
    "        if kind == \"wf\":\n"
    "            # Real block right after the held tool tag (think_end omitted).\n"
    "            # Thinking before the tag was already streamed by the caller.\n"
    "            self._in_reasoning = False\n"
    "            self._held_tc = None\n"
    "            self._buffer = \"\"\n"
    "            return StreamingParseResult(normal_text=held)\n"
    "\n"
    "        # kind == \"next_tc\": the held tag was thinking prose; advance.\n"
    "        reasoning_seg = held[:next_tc]\n"
    "        self._held_tc = held[next_tc:]\n"
    "        return StreamingParseResult(reasoning_text=reasoning_seg)\n"
    "\n"
    "    def _find_real_tool_start(self, text: str) -> int:\n"
    "        \"\"\"PATCH 2026-09-17 tc-lookahead (one-shot): index of the real\n"
    "        tool start. A tool tag followed by prose is a thinking mention;\n"
    "        the first one followed by a <function= block is real, else the\n"
    "        last tool tag (mirrors the streaming hold/finish rule).\"\"\"\n"
    "        tc = self.tool_start_token\n"
    "        start = 0\n"
    "        last = -1\n"
    "        while True:\n"
    "            pos = text.find(tc, start)\n"
    "            if pos == -1:\n"
    "                break\n"
    "            last = pos\n"
    "            if self.tc_block_prefix and text[pos + len(tc):].lstrip().startswith(\n"
    "                self.tc_block_prefix\n"
    "            ):\n"
    "                return pos\n"
    "            start = pos + len(tc)\n"
    "        return last\n"
    "\n"
    "    def _strip_leading_think_start(self, text: str) -> str:\n",
    "R6-helpers",
)

# R7: finish() flush of held buffer
rep(
    "        force_nonempty_content emits it as normal_text, else as reasoning_text.\"\"\"\n"
    "        if not self._in_reasoning:\n",
    "        force_nonempty_content emits it as normal_text, else as reasoning_text.\"\"\"\n"
    "        # PATCH 2026-09-17 tc-lookahead: stream ended while holding a tool\n"
    "        # tag. No think_end arrived, so the last held tool tag is the real\n"
    "        # tool start: text between earlier held tags was already emitted as\n"
    "        # reasoning; the remainder (last tag onward) feeds the tool-call\n"
    "        # parser as normal text.\n"
    "        if self._held_tc is not None:\n"
    "            held = self._held_tc\n"
    "            self._held_tc = None\n"
    "            self._buffer = \"\"\n"
    "            self._in_reasoning = False\n"
    "            if self.tool_start_token:\n"
    "                last_tc = held.rfind(self.tool_start_token)\n"
    "                if last_tc > 0:\n"
    "                    return StreamingParseResult(\n"
    "                        reasoning_text=held[:last_tc],\n"
    "                        normal_text=held[last_tc:],\n"
    "                    )\n"
    "            return StreamingParseResult(normal_text=held)\n"
    "        if not self._in_reasoning:\n",
    "R7-finish",
)

open(DST, "w", encoding="utf-8", newline="\n").write(text)
print(f"\nWrote {DST} ({len(text)} bytes)")
import py_compile
py_compile.compile(DST, doraise=True)
print("py_compile: OK")
