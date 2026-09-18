#!/usr/bin/env python3
"""Tiered KV eviction — tier4 (2026-09-14): permanent prefix pinning.

Makes the CC prefix cache permanent by pinning the deepest radix-tree chain
(the warm'd CC prefix) so it is never evicted by LRU or watermark sweeps.

Design:
  - UnifiedTreeNode gains a `pinned` flag (inherited on split).
  - `UnifiedRadixCache.pin_prefix()` finds the deepest node, walks up to root,
    sets pinned=True, and calls inc_lock_ref to take a permanent +1 lock on
    every node in the chain.  The lock is never released (no corresponding
    dec), so the nodes stay out of the evictable sets forever.
  - Safety nets in dec_lock_ref / dec_host_lock_ref / dec_swa_lock_only:
    after a normal release, any pinned node whose lock dropped to 0 is
    restored to 1 (belt-and-suspenders for edge cases).
  - `_is_cascade_evict_leaf` returns False for pinned nodes (extra safety).

Trigger: POST /admin/pin_prefix  (admin endpoint, mirrors /flush_cache).
Called from launch-awq.sh after the 2-pass warm completes.

Idempotent: re-run is a no-op if the tier4 markers are present.
"""
from __future__ import annotations

import py_compile
import shutil
import sys
from pathlib import Path

BASE = Path("/mnt/data/sglang-qwen38/sglang-src-0519-ttl/python/sglang/srt")
STAMP = ".bak-0914-tier4"

edits: dict[str, list[tuple[str, str]]] = {}

# ---------------------------------------------------------------- unified_tree_core.py
edits["mem_cache/unified_cache/unified_tree_core.py"] = [
    # 1. Add pinned flag to UnifiedTreeNode.__init__
    (
        "        self.load_back_pending_id: Optional[int] = None\n",
        "        self.load_back_pending_id: Optional[int] = None\n"
        "        # tier4: permanent pin (never evicted when True)\n"
        "        self.pinned = False\n",
    ),
    # 2. Inherit pinned on split
    (
        '        new_node.tier = getattr(child, "tier", 1)\n'
        '        new_node.expire_at = getattr(child, "expire_at", None)\n',
        '        new_node.tier = getattr(child, "tier", 1)\n'
        '        new_node.expire_at = getattr(child, "expire_at", None)\n'
        '        new_node.pinned = getattr(child, "pinned", False)\n',
    ),
    # 3. _is_cascade_evict_leaf: skip pinned nodes
    (
        "    def _is_cascade_evict_leaf(self, node: UnifiedTreeNode, target: EvictLayer) -> bool:\n"
        "        if target == EvictLayer.DEVICE:\n",
        "    def _is_cascade_evict_leaf(self, node: UnifiedTreeNode, target: EvictLayer) -> bool:\n"
        "        if getattr(node, \"pinned\", False):\n"
        "            return False\n"
        "        if target == EvictLayer.DEVICE:\n",
    ),
    # 4. dec_lock_ref: re-floor pinned nodes after release
    (
        "        for component in self.components:\n"
        "            if skip_swa and component.component_type == ComponentType.SWA:\n"
        "                continue\n"
        "            component.release_component_lock(node=node, params=params)\n"
        "        self._update_evictable_leaf_sets(node)\n",
        "        for component in self.components:\n"
        "            if skip_swa and component.component_type == ComponentType.SWA:\n"
        "                continue\n"
        "            component.release_component_lock(node=node, params=params)\n"
        "        # tier4: restore pin floor on any pinned node along the path\n"
        "        cur = node\n"
        "        while cur is not None and cur.parent is not None:\n"
        "            if getattr(cur, \"pinned\", False):\n"
        "                for component in self.components:\n"
        "                    cd = cur.component_data[component.component_type]\n"
        "                    if cd.lock_ref < 1:\n"
        "                        cd.lock_ref = 1\n"
        "                        if cd.value is not None:\n"
        "                            klen = len(cd.value)\n"
        "                            self.component_evictable_size_[component.component_type] -= klen\n"
        "                            self.component_protected_size_[component.component_type] += klen\n"
        "                self._update_evictable_leaf_sets(cur)\n"
        "            cur = cur.parent\n"
        "        self._update_evictable_leaf_sets(node)\n",
    ),
    # 5. dec_host_lock_ref: re-floor pinned nodes
    (
        "        for component in self.components:\n"
        "            component.release_component_lock(node=node, params=params, lock_host=True)\n"
        "        self._update_evictable_leaf_sets(node)\n",
        "        for component in self.components:\n"
        "            component.release_component_lock(node=node, params=params, lock_host=True)\n"
        "        # tier4: restore pin floor on any pinned node along the path\n"
        "        cur = node\n"
        "        while cur is not None and cur.parent is not None:\n"
        "            if getattr(cur, \"pinned\", False):\n"
        "                for component in self.components:\n"
        "                    cd = cur.component_data[component.component_type]\n"
        "                    if cd.host_lock_ref < 1:\n"
        "                        cd.host_lock_ref = 1\n"
        "                self._update_evictable_leaf_sets(cur)\n"
        "            cur = cur.parent\n"
        "        self._update_evictable_leaf_sets(node)\n",
    ),
    # 6. dec_swa_lock_only: re-floor pinned nodes after SWA+mamba release
    (
        "        for comp in self.components:\n"
        "            if comp.eviction_priority(is_leaf=False) < swa_priority:\n"
        "                comp.release_component_lock(node, dec_params)\n"
        "        return result\n",
        "        for comp in self.components:\n"
        "            if comp.eviction_priority(is_leaf=False) < swa_priority:\n"
        "                comp.release_component_lock(node, dec_params)\n"
        "        # tier4: restore pin floor\n"
        "        if getattr(node, \"pinned\", False):\n"
        "            for comp in self.components:\n"
        "                cd = node.component_data[comp.component_type]\n"
        "                if cd.lock_ref < 1:\n"
        "                    cd.lock_ref = 1\n"
        "                if cd.host_lock_ref < 1:\n"
        "                    cd.host_lock_ref = 1\n"
        "            self._update_evictable_leaf_sets(node)\n"
        "        return result\n",
    ),
]

# ---------------------------------------------------------------- unified_radix_cache.py
edits["mem_cache/unified_radix_cache.py"] = [
    # 7. Add pin_prefix method after evict_for_alloc
    (
        "        return self._evict(params, available_size_targets)\n"
        "\n"
        "    @staticmethod\n"
        "    def _evict_request_by_type",
        "        return self._evict(params, available_size_targets)\n"
        "\n"
        "    def pin_prefix(self) -> int:\n"
        "        \"\"\"Pin the longest prefix chain (deepest leaf to root) so it is\n"
        "        never evicted. Call after warm-up to make the CC prefix permanent.\n"
        "        Returns the number of pinned nodes.\n"
        "        \"\"\"\n"
        "        if self.disable:\n"
        "            return 0\n"
        "        core = self.tree_core\n"
        "        # DFS to find the deepest node (longest token path from root).\n"
        "        deepest = core.root_node\n"
        "        max_depth = 0\n"
        "        stack = [(core.root_node, 0)]\n"
        "        while stack:\n"
        "            node, depth = stack.pop()\n"
        "            if depth > max_depth:\n"
        "                max_depth = depth\n"
        "                deepest = node\n"
        "            for child in node.children.values():\n"
        "                klen = len(child.key) if child.key else 0\n"
        "                stack.append((child, depth + klen))\n"
        "        if deepest is core.root_node:\n"
        "            return 0\n"
        "        # Walk up from deepest to root, pinning each node.\n"
        "        count = 0\n"
        "        node = deepest\n"
        "        while node is not None and node.parent is not None:\n"
        "            node.pinned = True\n"
        "            for component in core.components:\n"
        "                cd = node.component_data[component.component_type]\n"
        "                if cd.lock_ref < 1:\n"
        "                    cd.lock_ref = 1\n"
        "                    if cd.value is not None:\n"
        "                        key_len = len(cd.value)\n"
        "                        core.component_evictable_size_[component.component_type] -= key_len\n"
        "                        core.component_protected_size_[component.component_type] += key_len\n"
        "                if cd.host_lock_ref < 1:\n"
        "                    cd.host_lock_ref = 1\n"
        "            core._update_evictable_leaf_sets(node)\n"
        "            count += 1\n"
        "            node = node.parent\n"
        "        return count\n"
        "\n"
        "    @staticmethod\n"
        "    def _evict_request_by_type",
    ),
]

# ---------------------------------------------------------------- io_struct.py
edits["managers/io_struct.py"] = [
    # 8. Add PinPrefixReqInput / PinPrefixReqOutput after FlushCacheReqOutput
    (
        "class FlushCacheReqOutput(BaseReq, kw_only=True):\n"
        "    success: bool\n"
        "    message: str = \"\"\n"
        "\n"
        "\n"
        "class AddExternalCorpusReqInput(BaseReq, kw_only=True):",
        "class FlushCacheReqOutput(BaseReq, kw_only=True):\n"
        "    success: bool\n"
        "    message: str = \"\"\n"
        "\n"
        "\n"
        "class PinPrefixReqInput(BaseReq, kw_only=True):\n"
        "    pass\n"
        "\n"
        "\n"
        "class PinPrefixReqOutput(BaseReq, kw_only=True):\n"
        "    success: bool\n"
        "    pinned_nodes: int = 0\n"
        "    message: str = \"\"\n"
        "\n"
        "\n"
        "class AddExternalCorpusReqInput(BaseReq, kw_only=True):",
    ),
]

# ---------------------------------------------------------------- tokenizer_control_mixin.py
edits["managers/tokenizer_control_mixin.py"] = [
    # 9. Add import
    (
        "    FlushCacheReqInput,\n"
        "    FlushCacheReqOutput,\n",
        "    FlushCacheReqInput,\n"
        "    FlushCacheReqOutput,\n"
        "    PinPrefixReqInput,\n"
        "    PinPrefixReqOutput,\n",
    ),
    # 10. Add spec entry
    (
        '    ("flush_cache", FlushCacheReqOutput),\n',
        '    ("flush_cache", FlushCacheReqOutput),\n'
        '    ("pin_prefix", PinPrefixReqOutput),\n',
    ),
    # 11. Add pin_prefix method after flush_cache method
    (
        "    async def flush_cache(\n"
        "        self: TokenizerManager, timeout_s: Optional[float] = None\n"
        "    ) -> FlushCacheReqOutput:\n"
        "        self.auto_create_handle_loop()\n"
        "        result = (\n"
        "            await self.flush_cache_communicator(FlushCacheReqInput(timeout_s=timeout_s))\n"
        "        )[0]\n"
        "        if result.success and self.mm_processor is not None:\n"
        "            self.mm_processor.clear_preprocess_cache()\n"
        "        return result\n",
        "    async def flush_cache(\n"
        "        self: TokenizerManager, timeout_s: Optional[float] = None\n"
        "    ) -> FlushCacheReqOutput:\n"
        "        self.auto_create_handle_loop()\n"
        "        result = (\n"
        "            await self.flush_cache_communicator(FlushCacheReqInput(timeout_s=timeout_s))\n"
        "        )[0]\n"
        "        if result.success and self.mm_processor is not None:\n"
        "            self.mm_processor.clear_preprocess_cache()\n"
        "        return result\n"
        "\n"
        "    async def pin_prefix(self: TokenizerManager) -> PinPrefixReqOutput:\n"
        "        \"\"\"Pin the longest cached prefix so it is never evicted.\"\"\"\n"
        "        self.auto_create_handle_loop()\n"
        "        result = (await self.pin_prefix_communicator(PinPrefixReqInput()))[0]\n"
        "        return result\n",
    ),
]

# ---------------------------------------------------------------- scheduler.py
edits["managers/scheduler.py"] = [
    # 12. Register PinPrefixReqInput in the event loop dispatcher
    (
        "                (FlushCacheReqInput, self.flush_wrapper.handle),\n",
        "                (FlushCacheReqInput, self.flush_wrapper.handle),\n"
        "                (PinPrefixReqInput, self._handle_pin_prefix),\n",
    ),
    # 13. Add _handle_pin_prefix method (after flush_cache method)
    (
        "    def flush_cache(self, empty_cache: bool = True):\n",
        "    def _handle_pin_prefix(self, req) -> PinPrefixReqOutput:\n"
        "        \"\"\"Pin the deepest radix prefix chain (CC warm prefix).\"\"\"\n"
        "        try:\n"
        "            if hasattr(self.tree_cache, \"pin_prefix\"):\n"
        "                count = self.tree_cache.pin_prefix()\n"
        "                return PinPrefixReqOutput(success=True, pinned_nodes=count)\n"
        "            return PinPrefixReqOutput(\n"
        "                success=False, pinned_nodes=0,\n"
        "                message=f\"tree_cache {type(self.tree_cache).__name__} has no pin_prefix\"\n"
        "            )\n"
        "        except Exception as e:\n"
        "            return PinPrefixReqOutput(success=False, pinned_nodes=0, message=str(e))\n"
        "\n"
        "    def flush_cache(self, empty_cache: bool = True):\n",
    ),
]

# ---------------------------------------------------------------- http_server.py
edits["entrypoints/http_server.py"] = [
    # 14. Add /admin/pin_prefix endpoint after /flush_cache
    (
        '@app.api_route("/flush_cache", methods=["GET", "POST"])\n'
        '@auth_level(AuthLevel.ADMIN_OPTIONAL)\n'
        "async def flush_cache(timeout: float = Query(0.0, ge=0.0)):\n"
        '    """Flush the radix cache."""\n',
        '@app.api_route("/admin/pin_prefix", methods=["POST"])\n'
        '@auth_level(AuthLevel.ADMIN_OPTIONAL)\n'
        "async def pin_prefix():\n"
        '    """Pin the longest cached prefix (CC warm prefix) so it is never evicted."""\n'
        "    result = await _global_state.tokenizer_manager.pin_prefix()\n"
        "    return ORJSONResponse(\n"
        '        {\"success\": result.success, \"pinned_nodes\": result.pinned_nodes, \"message\": result.message}\n'
        "    )\n"
        "\n"
        '\n'
        '@app.api_route("/flush_cache", methods=["GET", "POST"])\n'
        '@auth_level(AuthLevel.ADMIN_OPTIONAL)\n'
        "async def flush_cache(timeout: float = Query(0.0, ge=0.0)):\n"
        '    """Flush the radix cache."""\n',
    ),
]

# ---------------------------------------------------------------- launch-awq.sh
edits["launch-awq.sh"] = [
    # 15. Add pin curl after the 2-pass warm success check
    (
        '    if [ "$w1" = "0" ] && [ "$w2" = "0" ]; then\n'
        '      echo "[$NAME] cc-prefix warmed (2-pass: tier2 + host)"\n'
        "    else\n"
        '      echo "[$NAME] cc-prefix warm incomplete (w1=$w1 w2=$w2, non-fatal)"\n'
        "    fi\n",
        '    if [ "$w1" = "0" ] && [ "$w2" = "0" ]; then\n'
        '      echo "[$NAME] cc-prefix warmed (2-pass: tier2 + host)"\n'
        '      # tier4: pin the warmed prefix so it is never evicted\n'
        '      pin_resp=$(curl -s -m 10 -X POST "http://localhost:${PORT}/admin/pin_prefix" -H "Authorization: Bearer $KEY")\n'
        '      echo "[$NAME] pin_prefix: $pin_resp"\n'
        "    else\n"
        '      echo "[$NAME] cc-prefix warm incomplete (w1=$w1 w2=$w2, non-fatal)"\n'
        "    fi\n",
    ),
]

# ---------------------------------------------------------------- scheduler.py imports
# The scheduler needs to import PinPrefixReqInput and PinPrefixReqOutput.
# Find the existing import from io_struct and add to it.
edits["managers/scheduler.py"] += [
    # 16. Add PinPrefix imports to the io_struct import block
    (
        "    FlushCacheReqInput,\n",
        "    FlushCacheReqInput,\n"
        "    PinPrefixReqInput,\n"
        "    PinPrefixReqOutput,\n",
    ),
]

MARKERS = {
    "mem_cache/unified_cache/unified_tree_core.py": "self.pinned = False",
    "mem_cache/unified_radix_cache.py": "def pin_prefix(self)",
    "managers/io_struct.py": "class PinPrefixReqInput",
    "managers/tokenizer_control_mixin.py": '("pin_prefix", PinPrefixReqOutput)',
    "managers/scheduler.py": "_handle_pin_prefix",
    "entrypoints/http_server.py": '"/admin/pin_prefix"',
    "launch-awq.sh": "pin_prefix",
}


def main() -> int:
    for rel, pairs in edits.items():
        if rel == "launch-awq.sh":
            path = Path("/mnt/data/sglang-qwen38/launch-awq.sh")
        else:
            path = BASE / rel
        text = path.read_text(encoding="utf-8")
        if MARKERS[rel] in text:
            print(f"SKIP [{rel}] tier4 marker already present (idempotent)")
            continue
        for i, (old, new) in enumerate(pairs):
            n = text.count(old)
            if n != 1:
                print(f"FAIL [{rel}] edit#{i}: anchor hit {n} times (expect 1)")
                # Print context for debugging
                if n > 1:
                    for j, line in enumerate(text.split("\n"), 1):
                        if old.strip()[:40] in line:
                            print(f"  candidate line {j}: {line[:100]}")
                return 1
            text = text.replace(old, new, 1)
        if not path.with_name(path.name + STAMP).exists():
            shutil.copy2(path, path.with_name(path.name + STAMP))
        path.write_text(text, encoding="utf-8")
        print(f"OK   [{rel}] {len(pairs)} edit(s)")

    # Syntax check all Python files
    for rel in edits:
        if rel.endswith(".py"):
            if rel == "launch-awq.sh":
                continue
            path = BASE / rel if rel != "launch-awq.sh" else Path("/mnt/data/sglang-qwen38/launch-awq.sh")
            py_compile.compile(str(path), doraise=True)
    print("SYNTAX OK — tier4 (prefix pin) applied; rebuild image + canary")
    return 0


if __name__ == "__main__":
    sys.exit(main())
