# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Aureka AI Research
import os
import random

import numpy as np
import torch


def seed_everything(seed, deterministic):
    random.seed(seed)
    np.random.seed(seed)
    torch.random.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    sdaa_backend = getattr(torch, "sdaa", None)
    if sdaa_backend is not None and sdaa_backend.is_available():
        sdaa_backend.manual_seed_all(seed)
    # These are process-wide switches. Set both branches explicitly so a
    # non-deterministic run cannot inherit True from an earlier deterministic
    # run in a long-lived Python process.
    torch.use_deterministic_algorithms(bool(deterministic))
    if torch.cuda.is_available():
        torch.backends.cudnn.deterministic = bool(deterministic)
        if deterministic:
            torch.backends.cudnn.benchmark = False
            # Required only for deterministic CUDA/cuBLAS execution.
            os.environ["CUBLAS_WORKSPACE_CONFIG"] = ":4096:8"
