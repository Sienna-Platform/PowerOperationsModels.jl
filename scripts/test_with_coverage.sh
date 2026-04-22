#!/bin/zsh
#
# Run tests with coverage and generate lcov.info for Coverage Gutters.
# Usage: ./scripts/test_with_coverage.sh

set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Running tests with coverage..."
julia --project=. --code-coverage -e '
    using TestEnv; TestEnv.activate()
    include("test/runtests.jl")
'

echo "==> Generating lcov.info..."
julia --project=. -e '
    using TestEnv; TestEnv.activate()
    include("scripts/generate_lcov.jl")
'

echo "==> Done. lcov.info written to $(pwd)/lcov.info"
