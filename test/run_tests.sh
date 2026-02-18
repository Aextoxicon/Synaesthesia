#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

cd "$PROJECT_ROOT"

echo "run all unit tests"
echo "current dir: $(pwd)"
flutter test test/unit/

if [ $? -eq 0 ]; then
    echo "all tests passed"
else
    echo "tests failed"
    exit 1
fi