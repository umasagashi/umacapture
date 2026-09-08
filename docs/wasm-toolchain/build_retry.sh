#!/usr/bin/env bash
# Build OpenCV; when a translation unit crashes the LLVM wasm ISel at -O2/-O3,
# recompile that single file at -O1 (last -O wins) and resume. Loop until done.
export PATH="/c/Program Files/Microsoft Visual Studio/2022/Community/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja:$PATH"
source /c/Projects/umacapture-wasm-toolchain/emsdk/emsdk_env.sh >/dev/null 2>&1
BD=/c/Projects/umacapture-wasm-toolchain/opencv-build
cd "$BD"
LOG=/c/Projects/umacapture-wasm-toolchain/build.log
for attempt in $(seq 1 30); do
  echo "===== build attempt $attempt =====" | tee -a "$LOG"
  cmake --build . -j > "$BD/attempt.log" 2>&1
  rc=$?
  cat "$BD/attempt.log" >> "$LOG"
  if [ $rc -eq 0 ]; then echo "BUILD_OK" | tee -a "$LOG"; exit 0; fi
  if ! grep -q "clang frontend command failed" "$BD/attempt.log"; then
    echo "NON_ISEL_FAILURE" | tee -a "$LOG"; exit 1
  fi
  # find the source that failed: the line after FAILED: is the em++ command
  cmd=$(grep -A1 "^FAILED:" "$BD/attempt.log" | grep "em++" | tail -1)
  if [ -z "$cmd" ]; then echo "NO_CMD_FOUND" | tee -a "$LOG"; exit 1; fi
  src=$(echo "$cmd" | grep -oE '[^ ]+\.cpp$')
  echo ">>> recompiling at -O1: $src" | tee -a "$LOG"
  # append -O1 before the -c to override -O3; run the exact command
  eval "$cmd -O1" >> "$LOG" 2>&1 || { echo "O1_ALSO_FAILED: $src" | tee -a "$LOG"; exit 1; }
done
echo "TOO_MANY_ATTEMPTS" | tee -a "$LOG"; exit 1
