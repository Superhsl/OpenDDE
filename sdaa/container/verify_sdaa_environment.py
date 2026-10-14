#!/usr/bin/env python3
"""Probe OpenDDE's SDAA runtime and the operators used by inference."""

from __future__ import annotations

import math
import sys
import traceback

import torch
import torch.nn.functional as F
import torch_sdaa

from opendde.utils.environment import get_torch_runtime_info, select_torch_device
from opendde.utils.seed import seed_everything
from opendde.utils.torch_utils import cleanup_device_memory, disabled_autocast


failures: list[str] = []
warnings: list[str] = []


def check(name: str, fn, required: bool = True) -> None:
    try:
        result = fn()
        torch.sdaa.synchronize()
        print(f"PASS {name}: {result}")
    except Exception as exc:
        label = "FAIL" if required else "WARN"
        print(f"{label} {name}: {type(exc).__name__}: {exc}")
        traceback.print_exc()
        (failures if required else warnings).append(name)


def main() -> int:
    print(f"python={sys.version.split()[0]}")
    print(f"torch={torch.__version__}")
    print(f"torch_sdaa={getattr(torch_sdaa, '__version__', 'unknown')}")
    print(f"torch_cuda_available={torch.cuda.is_available()}")
    print(f"torch_sdaa_available={torch.sdaa.is_available()}")
    print(f"torch_sdaa_device_count={torch.sdaa.device_count()}")
    print(f"runtime_info={get_torch_runtime_info()}")

    if not torch.sdaa.is_available() or torch.sdaa.device_count() < 1:
        print("FAIL no mapped SDAA device is visible")
        return 1
    device = select_torch_device("sdaa", local_rank=0)
    print(f"selected_device={device}")

    def tensor_ops():
        a = torch.randn(8, 8, device=device)
        b = torch.randn(8, 8, device=device)
        matrix = a @ b
        einsum = torch.einsum("ij,jk->ik", a, b)
        normalized = F.layer_norm(matrix, (8,))
        probabilities = torch.softmax(normalized, dim=-1)
        indices = torch.tensor([0, 2, 2, 6], device=device)
        selected = torch.index_select(a, 0, indices)
        scattered = torch.zeros(8, device=device)
        scattered.scatter_add_(0, indices, torch.ones(4, device=device))
        assert all(torch.isfinite(x).all().item() for x in (matrix, einsum, normalized, probabilities, selected, scattered))
        return f"matmul/einsum/layer_norm/softmax/index_select/scatter_add finite; shape={tuple(matrix.shape)}"

    check("inference tensor operators", tensor_ops)

    def integer_charge_arcsinh():
        raw = torch.tensor([-1, 0, 1], dtype=torch.int64, device=device)
        actual = torch.arcsinh(raw.to(dtype=torch.float32))
        expected = torch.arcsinh(raw.cpu().to(dtype=torch.float32)).to(device)
        assert torch.allclose(actual, expected, atol=1e-6, rtol=1e-6)
        return f"int64 reference charges cast to float32; result={actual.cpu().tolist()}"

    check("int64 reference-charge arcsinh workaround", integer_charge_arcsinh)

    def bool_any_reduction():
        values = torch.tensor(
            [[True, False], [False, False]], dtype=torch.bool, device=device
        )
        observed = values.any(dim=-1)
        assert torch.equal(observed.cpu(), torch.tensor([True, False]))
        return f"bool any reduction={observed.cpu().tolist()}"

    check("boolean any reduction", bool_any_reduction)

    def bf16_autocast():
        x = torch.randn(16, 16, device=device)
        with torch.amp.autocast("sdaa", dtype=torch.bfloat16):
            y = x @ x
        assert torch.isfinite(y).all().item()
        return f"autocast output dtype={y.dtype}"

    check("bfloat16 autocast", bf16_autocast)

    def random_seed():
        seed_everything(20261010, deterministic=False)
        first = torch.rand(32, device=device)
        seed_everything(20261010, deterministic=False)
        second = torch.rand(32, device=device)
        assert torch.equal(first, second), "SDAA random stream changed after reseeding"
        return f"reseeded stream reproducible; checksum={first.sum().item():.6f}"

    check("seed_everything / SDAA RNG", random_seed)

    def disabled_amp():
        x = torch.ones(4, 4, device=device)
        with torch.amp.autocast("sdaa", dtype=torch.bfloat16):
            with disabled_autocast():
                y = x @ x
        assert y.dtype == torch.float32
        return f"disabled autocast output dtype={y.dtype}"

    check("disabled autocast scope", disabled_amp)

    def linalg_ops():
        x = torch.randn(4, 4, device=device)
        _, singular_values, _ = torch.linalg.svd(x)
        determinant = torch.linalg.det(x)
        assert torch.isfinite(singular_values).all().item() and math.isfinite(determinant.item())
        return f"svd/det finite; determinant={determinant.item():.6f}"

    check("optional linear algebra operators", linalg_ops, required=False)

    def memory_cleanup():
        cleanup_device_memory(device)
        return "SDAA synchronize and cache cleanup completed"

    check("memory cleanup", memory_cleanup)

    print(f"summary=failures:{len(failures)} warnings:{len(warnings)}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
