/** Keep a user's provider choice when capability DTOs are refreshed in place. */
export function resolveProviderSelection(current, launchers, reset = false) {
  const options = Array.isArray(launchers) ? launchers : [];
  if (!reset && options.some((launcher) => launcher?.provider === current)) return current;
  return options[0]?.provider || '';
}
