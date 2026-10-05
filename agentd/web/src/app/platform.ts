/**
 * Browser facts the shell branches on: iOS (push and installation differ),
 * Home Screen mode, secure context, and the name this device suggests when
 * pairing.
 */
export interface PlatformFacts {
  ios: boolean;
  standalone: boolean;
  secureContext: boolean;
  deviceName: string;
}

interface PlatformInput {
  userAgent: string;
  /** iPadOS 13+ reports a Mac user agent; a touch-capable "Mac" is an iPad. */
  maxTouchPoints: number;
  standaloneDisplay: boolean;
  /** Safari's non-standard flag, the only signal in older iOS versions. */
  navigatorStandalone?: boolean;
  secureContext: boolean;
}

export function readPlatform(input: PlatformInput): PlatformFacts {
  const agent = input.userAgent;
  const iPadDesktopMode = /Macintosh/.test(agent) && input.maxTouchPoints > 1;
  const ios = /iPhone|iPad|iPod/.test(agent) || iPadDesktopMode;
  return {
    ios,
    standalone: input.standaloneDisplay || input.navigatorStandalone === true,
    secureContext: input.secureContext,
    deviceName: suggestDeviceName(agent, iPadDesktopMode),
  };
}

/** Prefilled in the pairing form; the user can overwrite it. */
export function suggestDeviceName(userAgent: string, iPadDesktopMode = false): string {
  if (/iPhone/.test(userAgent)) return "iPhone";
  if (/iPad/.test(userAgent) || iPadDesktopMode) return "iPad";
  if (/Android/.test(userAgent)) return "Android";
  if (/Edg\//.test(userAgent)) return "Edge";
  if (/Firefox\//.test(userAgent)) return "Firefox";
  if (/Chrome\//.test(userAgent)) return "Chrome";
  if (/Safari\//.test(userAgent)) return "Safari";
  return "Browser";
}

export function currentPlatform(): PlatformFacts {
  const media = globalThis.matchMedia?.("(display-mode: standalone)");
  return readPlatform({
    userAgent: globalThis.navigator?.userAgent ?? "",
    maxTouchPoints: globalThis.navigator?.maxTouchPoints ?? 0,
    standaloneDisplay: media?.matches ?? false,
    navigatorStandalone: (globalThis.navigator as { standalone?: boolean } | undefined)?.standalone,
    secureContext: globalThis.isSecureContext ?? false,
  });
}
