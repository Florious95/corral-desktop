#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LABELS=(
  "Issue 1 — terminal context menu"
  "Issue 2 — wheel backlog drain"
  "Issue 3 — header center alignment"
  "Issue 4 — terminal light/dark palette"
  "Issue 5 — Tab/sidebar selection sync"
  "Issue 6 — Git branch icon rendering"
  "Issue 7 — Tab context menu actions"
  "Issue 8 — sidebar section toggle stability"
  "Issue 9 — sidebar scrollbars omission"
  "Issue 10 — local daemon auto-connect"
)
FILTERS=(
  "Issue1TerminalContextMenuTests/testRightClickMenuContainsWorkspaceAndTerminalActions"
  "CorralApplicationCoordinatorTests/testHighRateWheelBurstHasNoPostGestureInputTail"
  "Issue3HeaderAlignmentTests/testCollapsedSidebarToggleAndTabAlignWithTrafficLightsToOnePoint"
  "CorralApplicationCoordinatorTests/testTerminalColorsAndANSIPaletteFollowDarkLightPreferenceTransitions"
  "CorralApplicationCoordinatorTests/testTabBarSwitchSynchronizesSidebarSelectionAndScrollsTheActiveRowIntoView"
  "Issue6GitBranchIconTests/testGitBranchIconAssetIsRegisteredAndRenderable"
  "Issue7TabMenuTests/testTabContextMenuOmitsSplitActionsAndKeepsWorkspaceActions"
  "Issue8SidebarSectionToggleTests/testAgentsThenSpacesHeaderTogglesKeepSidebarAndWindowGeometryStable"
  "SidebarScrollbarOmissionTests/testSpacesAndAgentsHideScrollbarsAndRetainScrollableContent"
  "Issue10LocalDaemonAutoConnectTests/testEmptyDeviceStoreAutoConnectsToLocalDaemonUsingHomeTokenFile"
)

TOTAL=${#FILTERS[@]}
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/corral-polish-regression.XXXXXX")"
trap 'rm -rf "$LOG_DIR"' EXIT
RESULTS=()

printf 'CorralNative polish regression suite (%d tests)\n' "$TOTAL"
printf 'Repository: %s\n\n' "$ROOT"

for i in "${!FILTERS[@]}"; do
  number=$((i + 1))
  log="$LOG_DIR/issue-$number.log"
  started=$SECONDS
  printf '[%d/%d] RUN  %s\n' "$number" "$TOTAL" "${LABELS[$i]}"

  if swift test --package-path "$ROOT" --filter "${FILTERS[$i]}" >"$log" 2>&1; then
    passed_line="$(grep -E 'Test Case .* passed \(' "$log" | tail -n 1 || true)"
    if [[ -z "$passed_line" ]]; then
      printf '[%d/%d] FAIL no matching XCTest reported as passed; failing closed.\n' "$number" "$TOTAL"
      cat "$log"
      exit 1
    fi
    duration=$((SECONDS - started))
    RESULTS+=("PASS")
    printf '[%d/%d] PASS (%ds) %s\n' "$number" "$TOTAL" "$duration" "${LABELS[$i]}"
  else
    status=$?
    printf '[%d/%d] FAIL %s (swift test exit %d); stopping.\n' "$number" "$TOTAL" "${LABELS[$i]}" "$status"
    cat "$log"
    exit 1
  fi
done

printf '\nRegression reconciliation\n'
printf '%-8s | %-4s | %s\n' 'ISSUE' 'RESULT' 'TEST'
printf '%-8s-+-%-4s-+-%s\n' '--------' '----' '------------------------------------------'
for i in "${!FILTERS[@]}"; do
  printf '%-8d | %-4s | %s\n' "$((i + 1))" "${RESULTS[$i]}" "${LABELS[$i]}"
done
printf '\nPASS: %d/%d — exit 0\n' "$TOTAL" "$TOTAL"
