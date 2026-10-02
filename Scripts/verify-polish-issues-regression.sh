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
  "Issue 11 — split pane close and adapt actions"
  "Issue 13 — split layout padding symmetry"
  "Issue 14 — tab folder tracking and space session filtering"
  "Issue 15 — devices popover toggle dismissal"
  "Issue 16 — tab switch reflow sync"
  "PR 3 — drag split midline projection"
  "PR 4 — suppress autofill xpc and context menu"
  "PR 5 — equal width tabs and long title truncation"
  "PR 6 — compact terminal trailing margin"
  "PR 7 — adaptive tab shrinking and continuous close lock"
  "PR 8 — tab close robust lock and subview non-overlap"
  "PR 9 — hovered terminal scroll wheel forwarding"
  "PR 10 — working sidebar session context menu"
  "PR 11 — eliminate initial activation input lag and wheel backlog"
  "PR 12 — aggregate split-pane working status to tab indicator"
  "PR 13 — show close button and hover background on inactive tab hover"
  "PR 14 — enable inline double-click rename with enter/blur commit"
  "PR 15 — support tab drag and drop reordering with transient layout"
  "PR 16 — align terminal 256-color palette to standard xterm cube"
  "PR 17 — eliminate terminal git branch symbol tofu with font fallback"
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
  "Issue10LocalDaemonAutoConnectTests/testPersistedLocalDeviceUsesMacOSTokenToAuthenticateAndListSessions"
  "Issue11ContextMenuActionsTests/testBothSplitPaneMenusExposeActionsAndClosingLeftPaneRemovesIt"
  "Issue13SplitLayoutPaddingTests/testSplitTerminalViewportsKeepFivePointLeadingInsetWithoutRightGap"
  "Issue14TabFolderTrackingTests/testSwitchingTabSelectsItsSpaceAndFiltersSessionsToThatSpace"
  "Issue15DevicesPopoverToggleTests/testDevicesButtonSecondActivationClosesPopover"
  "Issue16MultiTabReflowSyncTests/testWindowResizeReflowsInactiveTabWhenItBecomesActive"
  "DragSplitMidlineProjectionTests/testMidlineLeftAndRightHoverProjectHalfPaneAndSplitTowardPointerSide"
  "AutoFillSubprocessSuppressionTests/testTerminalTextInputClientDeclaresNoAutofillContentType"
  "Issue17TabEqualWidthTests/testShortAndLongTitlesKeepTabItemsTheSameWidth"
  "Issue18TerminalTrailingMarginTests/testSplitPaneGridsKeepTrailingMarginsAsTightAsTheirFivePointLeadingInset"
  "Issue19TabBarAdaptiveCloseLockTests/testClosingWhilePointerIsInsideLocksWidthsUntilMouseExit"
  "Issue19TabCloseRobustnessTests/testInsideMouseExitedAfterCloseMustNotUnlockWidths"
  "CorralApplicationCoordinatorTests/testHoveredVisibleTerminalForwardsMouseWheelWithoutFirstResponder"
  "Issue20SidebarContextMenuTests/testRightClickSessionRowShowsOnlyFavoriteAndRemoteCloseActions"
  "CorralApplicationCoordinatorTests/testIssue26FirstFiveSecondsAfterActivatingLargeBackgroundScrollbackStayResponsive"
  "CorralApplicationCoordinatorTests/testIssue27SplitSessionWorkingStatusAggregatesOnTabWithoutRebuildingItem"
  "Issue23TabInactiveHoverTests/testUnselectedTabCloseAndHoverBackgroundFollowMouseEnteredAndExited"
  "Issue22TabInlineRenameTests/testOffscreenTitleDoubleClickOpensInlineEditorAndEnterCommits"
  "Issue24TabDragReorderTests/testTabDragPreviewsWithoutReorderingModelThenCommitsOnceAfterDrop"
  "Issue25TerminalPaletteXtermTests/testNativeTerminalUsesStandardXtermColorAtIndex174"
  "Issue21TerminalSymbolFontFallbackTests/testTerminalFontResolvesDiskAndGitSymbolsOutsideLastResort"
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
