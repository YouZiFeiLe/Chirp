const callbacks = new Map([
  ['chirp-apple', 'cn.youzifeile.chirp://auth/callback'],
  ['chirp-android', 'cn.youzifeile.chirp.android://auth/callback'],
  ['chirp-windows', 'cn.youzifeile.chirp.windows://auth/callback'],
]);

export function nativeLoginCallback(authorization, value) {
  const redirect = callbacks.get(authorization.client_id);
  if (!redirect || authorization.redirect_uri !== redirect || typeof value !== 'string' ||
      !value.startsWith(redirect + '?') || value.length > 512 || /[\s#]/u.test(value)) return null;

  const callback = new URL(value);
  const fields = callback.searchParams;
  if (fields.size !== 2 || fields.get('state') !== authorization.state ||
      !/^[A-Za-z0-9_-]{43}$/u.test(fields.get('code') ?? '')) return null;
  return callback.href;
}

export async function waitForWindowsHandoff(getStatus) {
  const deadline = Date.now() + 60_000;
  let delay = 1000;
  do {
    await new Promise((resolve) => setTimeout(resolve, delay));
    try {
      if ((await getStatus()).received === true) return true;
    } catch (error) {
      if (error.code === 'INVALID_AUTHORIZATION') return false;
    }
    delay = Math.min(delay * 2, 4000);
  } while (Date.now() < deadline);
  return false;
}
