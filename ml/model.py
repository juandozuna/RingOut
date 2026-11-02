"""RingOut neural isolator: a causal, sample-aligned gated TCN.

This file is the source of truth for the architecture. The C++ inference in
Sources/RingOutEngine/NeuralIsolator.cpp mirrors `StreamingTCN` exactly, and
export.py writes the weights in the order documented below.

Shape: mono in, mono out, 48 kHz, zero added latency.
    h0      = W_in x + b_in                                  (C)
    layer l, dilation d_l, kernel 2:
        z   = W0_l h_l[t - d_l] + W1_l h_l[t] + b_l          (2C)
        g   = tanh(z[:C]) * sigmoid(z[C:])                   (C)
        s  += Ws_l g + bs_l                                  (C)  skip sum
        h_{l+1} = h_l + Wr_l g + br_l                        (C)  residual
    y       = x + w_o . relu(W_h relu(s) + b_h) + b_o
The output layer starts at zero, so an untrained model is an exact pass-through.
"""
from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F

CHANNELS = 16
DILATIONS = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024]
RECEPTIVE_FIELD = 1 + sum(DILATIONS)  # samples (2048 = 42.7 ms at 48 kHz)


class TCN(nn.Module):
    def __init__(self, channels: int = CHANNELS, dilations: list[int] = DILATIONS):
        super().__init__()
        C = channels
        self.C = C
        self.dilations = list(dilations)
        self.inp = nn.Conv1d(1, C, 1)
        self.dil = nn.ModuleList([nn.Conv1d(C, 2 * C, 2, dilation=d) for d in dilations])
        self.res = nn.ModuleList([nn.Conv1d(C, C, 1) for _ in dilations])
        self.skip = nn.ModuleList([nn.Conv1d(C, C, 1) for _ in dilations])
        self.head = nn.Conv1d(C, C, 1)
        self.out = nn.Conv1d(C, 1, 1)
        nn.init.zeros_(self.out.weight)
        nn.init.zeros_(self.out.bias)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """x: (B, T) -> (B, T). Causal: y[t] depends on x[<= t] only."""
        u = x.unsqueeze(1)
        h = self.inp(u)
        s = torch.zeros_like(h)
        for d, dil, res, skip in zip(self.dilations, self.dil, self.res, self.skip):
            z = dil(F.pad(h, (d, 0)))
            a, b = z.chunk(2, dim=1)
            g = torch.tanh(a) * torch.sigmoid(b)
            s = s + skip(g)
            h = h + res(g)
        y = self.out(F.relu(self.head(F.relu(s))))
        return x + y.squeeze(1)


def _pw(conv: nn.Conv1d, x: torch.Tensor) -> torch.Tensor:
    """1x1 conv as a matmul (much faster than conv1d for short CPU blocks)."""
    return torch.matmul(conv.weight[:, :, 0], x) + conv.bias.view(-1, 1)


class StreamingTCN:
    """Block-by-block inference with per-layer history. Matches TCN.forward
    sample for sample and is the reference the C++ port is tested against."""

    def __init__(self, model: TCN, batch: int = 1):
        self.m = model
        p = next(model.parameters())
        self.hist = [torch.zeros(batch, model.C, d, device=p.device, dtype=p.dtype) for d in model.dilations]

    @torch.no_grad()
    def process(self, x: torch.Tensor) -> torch.Tensor:
        """x: (B, n) -> (B, n), any n >= 1."""
        m = self.m
        u = x.unsqueeze(1)
        h = _pw(m.inp, u)
        s = torch.zeros_like(h)
        n = x.shape[1]
        for i, (d, dil, res, skip) in enumerate(zip(m.dilations, m.dil, m.res, m.skip)):
            full = torch.cat([self.hist[i], h], dim=2)  # (B, C, d + n)
            delayed = full[:, :, :n]
            self.hist[i] = full[:, :, n:]
            w = dil.weight  # (2C, C, 2): tap 0 multiplies t-d, tap 1 multiplies t
            z = torch.matmul(w[:, :, 0], delayed) + torch.matmul(w[:, :, 1], h) + dil.bias.view(-1, 1)
            a, b = z.chunk(2, dim=1)
            g = torch.tanh(a) * torch.sigmoid(b)
            s = s + _pw(skip, g)
            h = h + _pw(res, g)
        y = _pw(m.out, F.relu(_pw(m.head, F.relu(s))))
        return x + y.squeeze(1)


def param_count(model: nn.Module) -> int:
    return sum(p.numel() for p in model.parameters())


def macs_per_sample(C: int = CHANNELS, L: int = len(DILATIONS)) -> int:
    return C + L * (2 * C * C * 2 + 2 * C * C) + C * C + C


if __name__ == "__main__":
    torch.manual_seed(0)
    m = TCN()
    for p in [m.out.weight, m.out.bias]:
        nn.init.normal_(p, std=0.1)
    x = torch.randn(2, 4000) * 0.3
    full = m(x)
    st = StreamingTCN(m, batch=2)
    parts, pos = [], 0
    for n in [1, 31, 32, 64, 7, 1000, 2865]:
        parts.append(st.process(x[:, pos:pos + n]))
        pos += n
    diff = (torch.cat(parts, 1) - full).abs().max().item()
    print(f"params {param_count(m)}, MAC/sample {macs_per_sample()}, RF {RECEPTIVE_FIELD}, stream-vs-full {diff:.2e}")
