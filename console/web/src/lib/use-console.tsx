import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { io, type Socket } from "socket.io-client";
import { toast } from "sonner";
import type { Snapshot, TurtleRole } from "./types";

const TOKEN_KEY = "ccutil.console.token";

export type ConsoleStatus = "booting" | "live" | "offline" | "unauthorized";
export type CommandOp = "start" | "abort" | "return" | "ping";

type UpdateTurtle = { label?: string; role?: TurtleRole };

type ConsoleContextValue = {
  snapshot: Snapshot | null;
  status: ConsoleStatus;
  token: string;
  setToken: (token: string) => void;
  lastSync: number;
  apiFetch: (path: string, init?: RequestInit) => Promise<Response>;
  refresh: () => Promise<void>;
  command: (turtleId: string, op: CommandOp, name?: string) => Promise<boolean>;
  updateTurtle: (turtleId: string, patch: UpdateTurtle) => Promise<boolean>;
  isPending: (turtleId: string, op: CommandOp) => boolean;
  exportUrl: () => string;
};

const ConsoleContext = createContext<ConsoleContextValue | null>(null);

function readUrlToken(): string {
  try {
    const url = new URL(window.location.href);
    const token = url.searchParams.get("token") ?? "";
    if (token) {
      localStorage.setItem(TOKEN_KEY, token);
      url.searchParams.delete("token");
      window.history.replaceState({}, "", url.toString());
    }
    return token;
  } catch {
    return "";
  }
}

function readStoredToken(): string {
  try {
    return localStorage.getItem(TOKEN_KEY) ?? "";
  } catch {
    return "";
  }
}

const commandCopy: Record<CommandOp, string> = {
  start: "Start sent",
  abort: "Abort sent",
  return: "Recall sent",
  ping: "Ping sent",
};

export function ConsoleProvider({ children }: { children: ReactNode }) {
  const [token, setTokenState] = useState(() => readUrlToken() || readStoredToken());
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [status, setStatus] = useState<ConsoleStatus>("booting");
  const [lastSync, setLastSync] = useState(0);
  const [pending, setPending] = useState<Set<string>>(() => new Set());
  const socketRef = useRef<Socket | null>(null);

  const setToken = useCallback((next: string) => {
    const clean = next.trim();
    try {
      if (clean) localStorage.setItem(TOKEN_KEY, clean);
      else localStorage.removeItem(TOKEN_KEY);
    } catch {
      /* private browsing */
    }
    setTokenState(clean);
    setSnapshot(null);
    setStatus("booting");
  }, []);

  const apiFetch = useCallback(
    async (path: string, init: RequestInit = {}) => {
      const headers = new Headers(init.headers);
      if (token) headers.set("authorization", `Bearer ${token}`);
      if (typeof init.body === "string" && !headers.has("content-type")) {
        headers.set("content-type", "application/json");
      }
      const response = await fetch(path, { ...init, headers });
      if (response.status === 401) setStatus("unauthorized");
      return response;
    },
    [token],
  );

  const refresh = useCallback(async () => {
    try {
      const response = await apiFetch("/api/state");
      if (response.status === 401) {
        setStatus("unauthorized");
        return;
      }
      if (!response.ok) throw new Error(`state request failed (${response.status})`);
      const data = (await response.json()) as Snapshot;
      setSnapshot(data);
      setLastSync(Date.now());
      setStatus((current) => {
        if (current === "unauthorized") return current;
        return socketRef.current?.connected ? "live" : "offline";
      });
    } catch {
      setStatus((current) => (current === "unauthorized" ? current : "offline"));
    }
  }, [apiFetch]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  useEffect(() => {
    const socket = io({
      auth: { token },
      transports: ["websocket", "polling"],
      reconnectionDelayMax: 6000,
    });
    socketRef.current = socket;

    socket.on("connect", () => setStatus("live"));
    socket.on("state", (data: Snapshot) => {
      setSnapshot(data);
      setLastSync(Date.now());
      setStatus("live");
    });
    socket.on("connect_error", (error: Error) => {
      if (/unauthor/i.test(error.message)) setStatus("unauthorized");
      else setStatus((current) => (current === "unauthorized" ? current : "offline"));
    });
    socket.on("disconnect", () => {
      setStatus((current) => (current === "unauthorized" ? current : "offline"));
    });

    return () => {
      socket.disconnect();
      socketRef.current = null;
    };
  }, [token]);

  useEffect(() => {
    const timer = window.setInterval(() => {
      if (!socketRef.current?.connected) void refresh();
    }, 10_000);
    return () => window.clearInterval(timer);
  }, [refresh]);

  const command = useCallback(
    async (turtleId: string, op: CommandOp, name?: string) => {
      const key = `${turtleId}:${op}`;
      setPending((current) => new Set(current).add(key));
      try {
        const response = await apiFetch(
          `/api/turtles/${encodeURIComponent(turtleId)}/${op}`,
          { method: "POST" },
        );
        const payload = (await response.json().catch(() => ({ ok: false }))) as {
          ok?: boolean;
          error?: string;
        };
        if (!response.ok || !payload.ok) {
          throw new Error(payload.error ?? `request failed (${response.status})`);
        }
        toast.success(commandCopy[op], {
          description: name ? `${name} · delivered over the link when connected` : undefined,
        });
        return true;
      } catch (error) {
        toast.error("Command not sent", { description: (error as Error).message });
        return false;
      } finally {
        setPending((current) => {
          const next = new Set(current);
          next.delete(key);
          return next;
        });
      }
    },
    [apiFetch],
  );

  const updateTurtle = useCallback(
    async (turtleId: string, patch: UpdateTurtle) => {
      const field = patch.role !== undefined ? "role" : "label";
      const body = patch.role !== undefined ? { role: patch.role } : { label: patch.label ?? "" };
      try {
        const response = await apiFetch(`/api/turtles/${encodeURIComponent(turtleId)}/${field}`, {
          method: "POST",
          body: JSON.stringify(body),
        });
        const payload = (await response.json().catch(() => ({ ok: false }))) as {
          ok?: boolean;
          error?: string;
        };
        if (!response.ok || !payload.ok) {
          throw new Error(payload.error ?? `request failed (${response.status})`);
        }
        toast.success(field === "role" ? "Role updated" : "Call sign updated");
        return true;
      } catch (error) {
        toast.error("Update failed", { description: (error as Error).message });
        return false;
      }
    },
    [apiFetch],
  );

  const isPending = useCallback(
    (turtleId: string, op: CommandOp) => pending.has(`${turtleId}:${op}`),
    [pending],
  );

  const exportUrl = useCallback(() => {
    return `/api/export${token ? `?token=${encodeURIComponent(token)}` : ""}`;
  }, [token]);

  const value = useMemo<ConsoleContextValue>(
    () => ({
      snapshot,
      status,
      token,
      setToken,
      lastSync,
      apiFetch,
      refresh,
      command,
      updateTurtle,
      isPending,
      exportUrl,
    }),
    [
      snapshot,
      status,
      token,
      setToken,
      lastSync,
      apiFetch,
      refresh,
      command,
      updateTurtle,
      isPending,
      exportUrl,
    ],
  );

  return <ConsoleContext.Provider value={value}>{children}</ConsoleContext.Provider>;
}

export function useConsole(): ConsoleContextValue {
  const value = useContext(ConsoleContext);
  if (!value) throw new Error("useConsole must be used inside ConsoleProvider");
  return value;
}

export function useNow(interval = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), interval);
    return () => window.clearInterval(timer);
  }, [interval]);
  return now;
}
