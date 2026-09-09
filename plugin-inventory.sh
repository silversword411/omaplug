#!/bin/bash
# Enumerate every installed plugin with the metadata the panel rows need.
#
# Omarchy 4.0.3 moved third-party plugins behind capability-scoped facades, so
# PluginRegistry.installedPlugins is no longer reachable from inside a plugin
# (it reports only the caller). This rebuilds the same view from outside the
# QML sandbox.
#
# Everything is read from disk rather than over `omarchy-shell` IPC: the panel
# runs this from inside the shell process it would be calling, and the wrapper's
# 2s timeout is not reliably met while the panel is loading. The manifests and
# shell.json are the same state the registry itself reads. One bar instance per
# monitor runs this concurrently, so it stays a single jq pass rather than one
# process per manifest.
#
# Emits a JSON array on stdout, one object per plugin:
#   id, name, kinds, enabled, active, canDisable, firstParty, clonedFrom,
#   version, author, description, sourceDir, sourceKey, updatable

set -uo pipefail

PLUGINS_DIR="${1:-$HOME/.config/omarchy/plugins}"
FIRST_PARTY_DIR="${2:-${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins}"
SHELL_CONFIG="${3:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json}"

# Mirror PluginRegistry's own scan: a first-party source may hold several widget
# manifests (widgets/Tray.manifest.json), while a third-party plugin is always
# one manifest.json at the root of its own directory.
mapfile -t manifests < <(
  find "$FIRST_PARTY_DIR" -mindepth 2 -maxdepth 3 -type f \
    \( -name manifest.json -o -name '*.manifest.json' \) 2>/dev/null
  find "$PLUGINS_DIR" -mindepth 2 -maxdepth 2 -type f -name manifest.json 2>/dev/null
)

if (( ${#manifests[@]} == 0 )); then
  echo '[]'
  exit 0
fi

config='{}'
if [[ -f $SHELL_CONFIG ]]; then
  config=$(jq '.' "$SHELL_CONFIG" 2>/dev/null) || config='{}'
fi

# Resolve enabled/active the way PluginRegistry and shell.qml's listPlugins do:
# a bar option is enabled only while it is the selected bar, a bar widget only
# while it sits in the layout, and anything else unless disabledPlugins[] names
# it (first-party plugins default on; third-party must appear in the config).
jq -n \
  --argjson config "$config" \
  --arg fpdir "$FIRST_PARTY_DIR" \
  --arg pdir "$PLUGINS_DIR" \
  '
  def source_dir($f):
    if ($f | endswith("/manifest.json")) then ($f | sub("/manifest\\.json$"; ""))
    else ($f | sub("/[^/]+$"; "")) end;

  ($fpdir | sub("/+$"; "")) as $fp
  | ($pdir | sub("/+$"; "")) as $base
  | ($config.bar // {}) as $bar
  | ((($bar.id // "") | tostring) | if . == "" then "omarchy.bar" else . end) as $selectedBar
  | ($bar.layout // {}) as $layout
  | ([ ("left","center","right") as $s
       | ($layout[$s] // [])[]
       | if type == "object" then (.id // "") else . end
       | tostring ]) as $inBar
  | ($config.disabledPlugins // []) as $disabled
  | ([ ($config.plugins // [])[]
       | if type == "object" then (.id // "") else . end
       | tostring ]) as $configured
  | [ inputs as $m
      | input_filename as $file
      | select(($m | type) == "object"
               and ($m.id | type) == "string"
               and $m.id != "")
      | source_dir($file) as $dir
      | ($m.id) as $id
      | (if ($m.kinds | type) == "array" then $m.kinds else [] end) as $kinds
      | ($kinds | index("bar") != null) as $isBarOption
      | ($kinds | index("bar-widget") != null) as $isBarWidget
      | ($selectedBar == $id) as $active
      | (($inBar | index($id)) != null) as $placed
      | {
          id: $id,
          name: (($m.name // $id) | tostring),
          kinds: $kinds,
          enabled: (
            if $isBarOption then $active
            elif $isBarWidget then $placed
            elif (($disabled | index($id)) != null) then false
            elif ($file | startswith($fp + "/")) then true
            else ($placed or (($configured | index($id)) != null))
            end),
          active: $active,
          canDisable: ($isBarOption | not),
          firstParty: ($file | startswith($fp + "/")),
          clonedFrom: (($m.omarchy // {})
                       | if type == "object" then (.clonedFrom // "") else "" end
                       | tostring),
          version: (($m.version // "") | tostring),
          author: (($m.author // "") | tostring),
          description: (($m.description // "") | tostring),
          sourceDir: $dir,
          sourceKey: ($dir | split("/") | last // ""),
          updatable: ($dir | startswith($base + "/"))
        }
    ]
  | sort_by((if .firstParty then 0 else 1 end), (.name | ascii_downcase))
  ' "${manifests[@]}"
