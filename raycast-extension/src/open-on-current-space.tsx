import {
  Action,
  ActionPanel,
  Icon,
  List,
  LocalStorage,
  closeMainWindow,
  getApplications,
  getPreferenceValues,
  open,
  popToRoot,
  showHUD,
} from "@raycast/api";
import { execFile } from "child_process";
import { useEffect, useMemo, useState } from "react";
import { promisify } from "util";

const execFileAsync = promisify(execFile);

interface Preferences {
  powerspacesBin: string;
}

interface App {
  name: string;
  path: string;
  bundleId?: string;
}

// How the list — and search results — are ordered. Persisted across launches so
// the choice sticks. "recent"/"frequent" lean on the per-app usage we record on
// every open below; both fall back to alphabetical until there's history.
type SortMode = "recent" | "frequent" | "alpha";

// Per-app usage we accumulate ourselves, keyed by bundle id (or path as a
// fallback). lastOpenedAt powers "Recently Opened"; openCount powers "Most Used".
interface Usage {
  lastOpenedAt: number;
  openCount: number;
}
type UsageMap = Record<string, Usage>;

const USAGE_KEY = "powerspaces.usage";
const SORT_KEY = "powerspaces.sortMode";
const DEFAULT_SORT: SortMode = "recent";

// Stable identity for an app across launches; bundle id is preferred, path is the
// fallback for the rare app without one.
const keyFor = (app: App) => app.bundleId ?? app.path;

// One root-search command that lists every installed app (via getApplications)
// and routes the default action through the `powerspaces` CLI, so the app opens
// or focuses on the desktop you're standing on instead of yanking you elsewhere.
export default function Command() {
  const [apps, setApps] = useState<App[]>([]);
  const [usage, setUsage] = useState<UsageMap>({});
  const [sortMode, setSortMode] = useState<SortMode>(DEFAULT_SORT);
  const [searchText, setSearchText] = useState("");
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    (async () => {
      const [installed, storedUsage, storedSort] = await Promise.all([
        getApplications(),
        LocalStorage.getItem<string>(USAGE_KEY),
        LocalStorage.getItem<string>(SORT_KEY),
      ]);
      setApps(
        installed.map((a) => ({
          name: a.name,
          path: a.path,
          bundleId: a.bundleId,
        })),
      );
      if (storedUsage) {
        try {
          setUsage(JSON.parse(storedUsage));
        } catch {
          // Corrupt cache — start fresh rather than crash the command.
        }
      }
      if (
        storedSort === "recent" ||
        storedSort === "frequent" ||
        storedSort === "alpha"
      ) {
        setSortMode(storedSort);
      }
      setIsLoading(false);
    })();
  }, []);

  const { powerspacesBin } = getPreferenceValues<Preferences>();

  function changeSort(mode: SortMode) {
    setSortMode(mode);
    LocalStorage.setItem(SORT_KEY, mode);
  }

  // Record an open so it bubbles up under the recency/frequency sorts. This is
  // what makes a just-opened app (e.g. "Weather") outrank an alphabetically
  // earlier sibling ("Warp") the next time you search for "W".
  function recordOpen(app: App) {
    const k = keyFor(app);
    setUsage((prev) => {
      const next: UsageMap = {
        ...prev,
        [k]: {
          lastOpenedAt: Date.now(),
          openCount: (prev[k]?.openCount ?? 0) + 1,
        },
      };
      LocalStorage.setItem(USAGE_KEY, JSON.stringify(next));
      return next;
    });
  }

  // powerspaces resolves a dotted bundle id specially, so pass that when we have
  // it; fall back to the display name otherwise (AppResolver handles both).
  async function runPowerspaces(app: App, forceNew = false) {
    const target = app.bundleId ?? app.name;
    recordOpen(app);
    await closeMainWindow();
    try {
      const args = ["open", target];
      if (forceNew) args.push("--new");
      await execFileAsync(powerspacesBin, args);
      await showHUD(
        forceNew
          ? `New ${app.name} window here`
          : `Opened ${app.name} on this Space`,
      );
    } catch {
      await showHUD(
        `⚠︎ powerspaces failed — check the CLI path in this extension's preferences`,
      );
    }
    await popToRoot({ clearSearchBar: true });
  }

  async function openNormally(app: App) {
    recordOpen(app);
    await closeMainWindow();
    await open(app.path);
    await popToRoot({ clearSearchBar: true });
  }

  // We do our own filtering (filtering={false} on the List) so the active sort
  // also governs the order of search results — not just the full, unfiltered
  // list. A query keeps name-prefix matches ahead of mid-name matches; within an
  // equally-relevant tier the chosen sort decides the order.
  const visible = useMemo(() => {
    const q = searchText.trim().toLowerCase();

    const matches = q
      ? apps.filter(
          (a) =>
            a.name.toLowerCase().includes(q) ||
            (a.bundleId?.toLowerCase().includes(q) ?? false),
        )
      : apps.slice();

    const relevance = (app: App) => {
      if (!q) return 0;
      const name = app.name.toLowerCase();
      if (name.startsWith(q)) return 2;
      if (name.includes(q)) return 1;
      return 0; // bundle-id-only match
    };

    const byMode = (a: App, b: App) => {
      if (sortMode === "recent") {
        const diff =
          (usage[keyFor(b)]?.lastOpenedAt ?? 0) -
          (usage[keyFor(a)]?.lastOpenedAt ?? 0);
        if (diff !== 0) return diff;
      } else if (sortMode === "frequent") {
        const diff =
          (usage[keyFor(b)]?.openCount ?? 0) -
          (usage[keyFor(a)]?.openCount ?? 0);
        if (diff !== 0) return diff;
      }
      return a.name.localeCompare(b.name);
    };

    return matches.sort((a, b) => {
      const rel = relevance(b) - relevance(a);
      if (rel !== 0) return rel;
      return byMode(a, b);
    });
  }, [apps, usage, sortMode, searchText]);

  return (
    <List
      isLoading={isLoading}
      filtering={false}
      onSearchTextChange={setSearchText}
      searchBarPlaceholder="Open an app on the Space you're on…"
      searchBarAccessory={
        <List.Dropdown
          tooltip="Sort order"
          value={sortMode}
          onChange={(v) => changeSort(v as SortMode)}
        >
          <List.Dropdown.Item
            title="Recently Opened"
            value="recent"
            icon={Icon.Clock}
          />
          <List.Dropdown.Item
            title="Most Used"
            value="frequent"
            icon={Icon.Star}
          />
          <List.Dropdown.Item
            title="Alphabetical"
            value="alpha"
            icon={Icon.Text}
          />
        </List.Dropdown>
      }
    >
      {visible.map((app) => (
        <List.Item
          key={app.bundleId ?? app.path}
          icon={{ fileIcon: app.path }}
          title={app.name}
          actions={
            <ActionPanel>
              <Action
                title="Open on Current Space"
                icon={Icon.Window}
                onAction={() => runPowerspaces(app)}
              />
              <Action
                title="Open New Window Here"
                icon={Icon.Plus}
                shortcut={{ modifiers: ["cmd"], key: "n" }}
                onAction={() => runPowerspaces(app, true)}
              />
              <Action
                title="Open Normally"
                icon={Icon.AppWindow}
                shortcut={{ modifiers: ["cmd"], key: "o" }}
                onAction={() => openNormally(app)}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
