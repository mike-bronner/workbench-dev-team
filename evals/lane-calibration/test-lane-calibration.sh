#!/usr/bin/env bash
set -u
cd "$(dirname "$0")" || exit 1
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_calibrate.py
