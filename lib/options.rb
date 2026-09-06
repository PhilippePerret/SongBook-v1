require_relative "file_finder"

# Table unique de résolution de TOUTE option `.infos` (chanson < carnet < fichier indexé
# du `.tdm`, ex. "id [N].infos" < preset du layout nommé du carnet < défaut app), formes
# plate (`diags_shrink:`) ET imbriquée (`diags: / shrink:`) acceptées à N'IMPORTE QUEL
# étage. Un "layout" (`assets/layouts/*.yaml`) n'est qu'un preset de valeurs par défaut
# pour certaines de ces clés (`layout_key:`) — pas une cascade séparée, plus de fichier
# `.lay` à part.
# Deux lectures par source `.infos` : `PageBuilder.parse_infos` (plate, AVEUGLE à
# l'indentation — reproduit la convention existante des regroupements cosmétiques comme
# `options:`, `front_matter:`) et `CarnetBuilder.parse_nested_infos` (structurel, pour les
# seules clés dont l'imbrication a un sens réel : `diags:/shrink:`, `tabs:/shrink:`, etc.).
# `PageBuilder.parse_infos`/`CarnetBuilder.parse_nested_infos` appelés en LATE BINDING
# (jamais `require_relative` vers eux) pour casser le cycle layout -> options -> page_builder -> layout.
module Options
  DEFINITIONS = {
    diags_shrink: { flat: "diags_shrink", nested: %w[diags shrink], default: true, bool: true },
    tabs_shrink: { flat: "tabs_shrink", nested: %w[tabs shrink], default: true, bool: true },
    score_shrink: { flat: "score_shrink", nested: %w[score shrink], default: true, bool: true },
    shrink_text: { flat: "shrink_text", nested: nil, default: false, bool: true },
    rebalance_pages: { flat: "rebalance_pages", nested: nil, default: true, bool: true },
    show_specs: { flat: "show_specs", nested: nil, default: false, bool: true },
    font_family: { flat: "font-family", nested: nil, default: "HelveticaNeue" },
    font_size: { flat: "font-size", nested: nil, default: 11.0, numeric: true },
    diags_size: { flat: "diags_size", nested: %w[diags size], default: 60.0, numeric: true },
    tabs_preset: { flat: "tabs_preset", nested: %w[tabs preset], default: "regular-tablatures" },
    tabs_measures_per_page: { flat: "tabs_measures_per_page", nested: %w[tabs measures_per_page], default: nil, int: true },
    title_band: { flat: "title_band", nested: nil, default: true, bool: true, layout_key: :title_band },
    diags_position: { flat: "diags_position", nested: %w[diags position], default: "End", layout_key: :diags_position },
    diags_align: { flat: "diags_align", nested: %w[diags align], default: "justify", layout_key: :diags_align },
    lyrics_flux: { flat: "lyrics_flux", nested: nil, default: "side", layout_key: :lyrics_flux },
    intro_align: { flat: "intro_align", nested: nil, default: "left", layout_key: :intro_align },
    score_title_size: { flat: "score_title_size", nested: %w[score title_size], default: 11.0, numeric: true, layout_key: :score_title_size },
    score_title_style: { flat: "score_title_style", nested: %w[score title_style], default: nil, layout_key: :score_title_style },
  }.freeze

  # `meta` : hash déjà fusionné par l'appelant pour un override RUNTIME (`--transpose`,
  # sans fichier derrière) — prioritaire sur tout. `override_path` : fichier indexé du
  # `.tdm` pour cette entrée précise (souvent absent, `CarnetBuilder.resolve_infos_override_path`).
  # `layout_preset` : Hash du layout nommé du carnet (`PageBuilder::LAYOUTS`) — DERNIER
  # recours avant le défaut app, jamais une clé "explicite" (`explicit?`).
  def self.load!(meta:, infos_path:, carnet_folder:, override_path: nil, layout_preset: {})
    carnet_infos_path = carnet_folder && FileFinder.find(carnet_folder, :inf)

    # Priorité décroissante : override runtime (meta) > fichier indexé > carnet > chanson
    # > preset du layout nommé > défaut app (dans `coerce`).
    sources = [source_of(override_path), source_of(carnet_infos_path), source_of(infos_path)]
    @resolved = {}
    @explicit = {}
    DEFINITIONS.each do |key, defn|
      raw = raw_value(defn, meta, sources)
      @explicit[key] = !raw.nil?
      raw = layout_preset_value(defn, layout_preset) if raw.nil?
      @resolved[key] = coerce(defn, raw)
    end
  end

  def self.get(key)
    resolved = @resolved || {}
    resolved.key?(key) ? resolved[key] : DEFINITIONS[key][:default]
  end

  # Vrai si `key` a été fixée explicitement (chanson, carnet ou fichier indexé) — jamais
  # vrai pour une valeur reprise du preset de layout ou du défaut app (`show_specs` :
  # n'affiche QUE ce que l'user a réellement écrit quelque part).
  def self.explicit?(key)
    (@explicit || {}).fetch(key, false)
  end

  def self.set!(key, value)
    (@resolved ||= {})[key] = value
  end

  def self.source_of(path)
    return { flat: {}, tree: {} } unless path

    { flat: PageBuilder.parse_infos(path), tree: CarnetBuilder.parse_nested_infos(path) }
  end

  def self.raw_value(defn, meta, sources)
    raw = meta[defn[:flat]]
    raw = sources.map { |src| dig(src, defn) }.find { |v| !v.nil? } if raw.nil?
    raw
  end

  # Une seule clé peut être écrite plate OU imbriquée dans le même fichier — jamais les
  # deux formes lues séparément (source du bug initial : la forme non attendue à cet
  # étage était silencieusement ignorée).
  def self.dig(src, defn)
    return src[:flat][defn[:flat]] if src[:flat].key?(defn[:flat])
    return nil unless defn[:nested]

    defn[:nested].reduce(src[:tree]) { |node, k| node.is_a?(Hash) ? node[k] : nil }
  end

  # Valeurs de `assets/layouts/*.yaml` symbolisées (`load_layout_yaml`) — remises en
  # chaîne pour rester du même type que toute valeur venant d'un `.infos` (plat).
  def self.layout_preset_value(defn, layout_preset)
    return nil unless defn[:layout_key]

    v = layout_preset[defn[:layout_key]]
    v.is_a?(Symbol) ? v.to_s : v
  end

  def self.coerce(defn, raw)
    return defn[:default] if raw.nil?
    return raw.to_s[/[\d.]+/].to_f if defn[:numeric]
    return raw.to_s[/\d+/].to_i if defn[:int]
    return !(raw == false || raw == "false") if defn[:bool]

    raw
  end
end
