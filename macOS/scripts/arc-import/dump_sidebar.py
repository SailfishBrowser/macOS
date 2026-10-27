"""Prints an Arc data folder's sidebar tree, shortcuts and archive counts: the format note for ArcReader.swift.

Usage: python3 -I dump_sidebar.py ["~/Library/Application Support/Arc"]

Arc 1.170 keeps its state as JSON files in the folder (dated copies such as StorableSidebar.<date>-...json are
its backups). Swift dictionaries and enums are written in Codable's array form:
- A dictionary is a flat list of alternating keys and values: ["pinned", "<container id>", "unpinned", "<id>"].
- An enum case is a one-key object; an associated value sits under "_0": {"spaceItems": {"_0": "<space id>"}}.
- Dates are seconds since 2001-01-01 (Foundation's reference date).

StorableSidebar.json: {"version", "sidebar", "sidebarSyncState", "firebaseSyncState"}. The sync states are Arc's
cloud bookkeeping and are not read. sidebar.containers is a list; the entry with "spaces" holds everything:
- spaces: id/value list of spaces, in Arc's order. A space has "title" (missing for the untitled default space),
  "profile" ({"default": true} or {"default": {}} for Default; {"custom": {"_0": {"directoryBasename": "Profile 1",
  "machineID": ...}}} for another profile, named in User Data/Local State's profile.info_cache), "containerIDs"
  (["pinned", id, "unpinned", id] in either order) and "customInfo", whose "iconType" is {"emoji_v2": "<emoji>",
  "emoji": <code point>} or {"icon": "<Arc symbol name>"}.
- items: id/value list of sidebar items. Each has "id", "parentID", "childrenIds" (order), "title" (the user's custom
  name, else null) and "data", one of:
  - {"itemContainer": {"containerType": {"spaceItems": {"_0": <space id>}}}}: a space's pinned or Today container;
    which one is said by the space's containerIDs.
  - {"itemContainer": {"containerType": {"topApps": {"_0": <profile>}}}}: a profile's favorites.
  - {"list": {}}: a folder; its children are tabs, folders and split views.
  - {"tab": {"savedURL", "savedTitle", "timeLastActiveAt", "customInfo": {"iconType": ...}?}}: a tab. An archived tab
    that never loaded has no savedURL.
  - {"splitView": {"layoutOrientation", "itemWidthFactors", ...}}: tabs side by side, as its children.
  - {"welcomeToArc": ...} and other Arc pages without a URL.
- topAppsContainerIDs: profile/container id list naming each profile's favorites container.

StorableKeyBindings.json: {"version", "userOverrides": [{"action": {"identifier", "name"}, "state", "default"}]}.
state is {"valid": {"_0": {"keyEquivalent", "deviceIndependentModifierFlags"}}} for a changed shortcut or
{"unset": {}} for a removed one. Modifier flags are NSEvent.ModifierFlags raw values; key equivalents use glyphs for
special keys (U+21E5 for Tab, arrows as U+2190-2193).

StorableArchiveItems.json: {"version", "items": id/value list of {"sidebarItem" (an item as above), "reason"
("manual" or "auto"), "archivedAt", "source" ({"space": {"_0": <space id>}}, {"littleArc": {}},
{"standaloneSidebar": {}} or {"unknown": {}})}}.
"""

import json
import sys
from collections import Counter
from pathlib import Path


def pairs(flat):
    return list(zip(flat[0::2], flat[1::2]))


def profile_name(profile):
    if "default" in profile:
        return "Default"
    return profile["custom"]["_0"]["directoryBasename"]


def main():
    folder = Path(sys.argv[1] if len(sys.argv) > 1 else "~/Library/Application Support/Arc").expanduser()
    sidebar = json.loads((folder / "StorableSidebar.json").read_text())
    container = next(c for c in sidebar["sidebar"]["containers"] if "spaces" in c)
    items = dict(pairs(container["items"]))
    kinds = Counter()

    def show(item_id, depth):
        item = items[item_id]
        kind = next(iter(item["data"]))
        kinds[kind] += 1
        indent = "  " * depth
        if kind == "tab":
            tab = item["data"]["tab"]
            icon = tab.get("customInfo", {}).get("iconType", {}).get("emoji_v2", "")
            name = item["title"] or tab["savedTitle"]
            print(f"{indent}- {icon}{name}  <{tab['savedURL']}>" + ("  (custom title)" if item["title"] else ""))
        elif kind == "list":
            print(f"{indent}+ folder {item['title']}")
        else:
            print(f"{indent}* {kind} {item['title'] or ''}")
        for child in item["childrenIds"]:
            show(child, depth + 1)

    for profile, container_id in pairs(container["topAppsContainerIDs"]):
        print(f"Favorites of {profile_name(profile)}:")
        for child in items[container_id]["childrenIds"]:
            show(child, 1)
    for index, (space_id, space) in enumerate(pairs(container["spaces"])):
        icon = space["customInfo"].get("iconType", {})
        print(f"\nSpace {index + 1}: {space.get('title')!r} profile={profile_name(space['profile'])} icon={icon}")
        for role, container_id in pairs(space["containerIDs"]):
            print(f" {role}:")
            for child in items[container_id]["childrenIds"]:
                show(child, 2)
    print("\nItems shown by kind:", dict(kinds))

    bindings = json.loads((folder / "StorableKeyBindings.json").read_text())
    print("\nShortcuts:")
    for override in bindings["userOverrides"]:
        state = override["state"]
        keys = state["valid"]["_0"] if "valid" in state else "removed"
        print(f" {override['action']['name']} ({override['action']['identifier']}): {keys}")

    archive = json.loads((folder / "StorableArchiveItems.json").read_text())
    entries = [value for _, value in pairs(archive["items"])]
    print(f"\nArchived tabs: {len(entries)}", dict(Counter(next(iter(e["source"])) for e in entries)))


main()
