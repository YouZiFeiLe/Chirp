const versionPattern = /^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$/;

function versionParts(version) {
  if (typeof version !== 'string' || version.match(versionPattern)?.[0] !== version) return null;
  return version.split('.').map(Number);
}

export function isValidClientVersionPolicy(policy) {
  const latest = versionParts(policy.latest_version);
  const minimum = versionParts(policy.minimum_version);
  const validBuild = (build) => Number.isInteger(build) && build >= 1 && build <= 2147483647;
  if (!latest || !minimum || !validBuild(policy.latest_build) || !validBuild(policy.minimum_build)) return false;
  for (let i = 0; i < latest.length; i++) {
    if (minimum[i] !== latest[i]) return minimum[i] < latest[i];
  }
  return policy.minimum_build <= policy.latest_build;
}
