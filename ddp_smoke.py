#!/usr/bin/env python3
"""Minimal torchrun smoke test for verifying DDP connectivity.

The script initializes a distributed process group, runs an ``all_reduce`` over
the per-rank values, and checks that the reduced sum matches the expected value
for the world size.

Example:

    Node 0:
        NCCL_DEBUG=INFO \
        torchrun \
        --nnodes=2 \
        --nproc-per-node=8 \
        --node-rank=0 \
        --rdzv-backend=c10d \
        --rdzv-endpoint=2x8xa100-80gb-0.svc-2x8xa100-80gb:29500 \
        ddp_smoke.py

        # --device cpu \
        # --rdzv-id=myjob-001 \

    Node 1:
        NCCL_DEBUG=INFO \
        torchrun \
        --nnodes=2 \
        --nproc-per-node=8 \
        --node-rank=1 \
        --rdzv-backend=c10d \
        --rdzv-endpoint=2x8xa100-80gb-0.svc-2x8xa100-80gb:29500 \
        ddp_smoke.py

        # --device cpu
        # --rdzv-id=myjob-001 \


    # Static hostname may mismatch and cause hang on AWS
    Node 0:
        NCCL_DEBUG=INFO \
        torchrun \
        --nnodes=2 \
        --nproc-per-node=8 \
        --node-rank=0 \
        --master-addr=2x8xa100-80gb-0.svc-2x8xa100-80gb \
        --master-port=29500 \
        ddp_smoke.py 

        # --device cpu

    Node 1:
        NCCL_DEBUG=INFO \
        torchrun \
        --nnodes=2 \
        --nproc-per-node=8 \
        --node-rank=1 \
        --master-addr=2x8xa100-80gb-0.svc-2x8xa100-80gb \
        --master-port=29500 \
        ddp_smoke.py 

        # --device cpu


"""
import argparse
import os
import socket

import torch
import torch.distributed as dist


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Minimal torchrun DDP smoke test")
    parser.add_argument(
        "--device",
        choices=("cpu", "cuda"),
        default="cuda",
        help="Distributed device/backend target",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if args.device == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("--device cuda requested, but CUDA is not available")

    backend = "gloo" if args.device == "cpu" else "nccl"
    dist.init_process_group(backend=backend, init_method="env://")

    rank = dist.get_rank()
    world_size = dist.get_world_size()
    local_rank = int(os.environ.get("LOCAL_RANK", "0"))
    hostname = socket.gethostname()

    if args.device == "cuda":
        torch.cuda.set_device(local_rank)
        device = torch.device("cuda", local_rank)
        value = torch.tensor([rank], device=device, dtype=torch.float32)
    else:
        device = torch.device("cpu")
        value = torch.tensor([rank], device=device, dtype=torch.float32)

    dist.all_reduce(value, op=dist.ReduceOp.SUM)
    expected = world_size * (world_size - 1) / 2

    master_addr = os.environ.get("MASTER_ADDR", "unknown")
    master_port = os.environ.get("MASTER_PORT", "unknown")

    print(
        f"host={hostname} rank={rank}/{world_size} local_rank={local_rank} "
        f"device={device} reduced_sum={value.item()} expected={expected}",
        f"master_addr={master_addr} master_port={master_port}",
        flush=True,
    )

    if value.item() != expected:
        raise RuntimeError(f"DDP all_reduce failed: got {value.item()}, expected {expected}")

    dist.barrier()
    if rank == 0:
        print("DDP smoke test passed", flush=True)
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
