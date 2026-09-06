require_relative "file_finder"

# Table unique de résolution des options `.infos` (chanson < carnet < fichier indexé du
# `.tdm`, ex. "id [N].infos"), formes plate (`shrink_diags:`) ET imbriquée (`diags: /
# shrink:`) acceptées à N'IMPORTE QUEL étage, pour les 3 sources.
# Deux lectures par source : `PageBuilder.parse_infos` (plate, AVEUGLE à l'indentation —
# reproduit la convention existante des regroupements cosmétiques comme `options:`,
# `front_matter:`) et `CarnetBuilder.parse_nested_infos` (structurel, pour les seules
# clés dont l'imbrication a un sens réel : `diags:/shrink:`, `tabla:/shrink:`, etc.).
# `PageBuilder.parse_infos`/`CarnetBuilder.parse_nested_infos` appelés en LATE BINDING
# (jamais `require_relative` vers eux) pour casser le cycle layout -> options -> page_builder -> layout.
module Options
  DEFINITIONS = {
    shrink_diags: { flat: "shrink_diags", nested: %w[diags shrink], default: true, bool: true },
    shrink_tabla: { flat: "shrink_tabla", nested: %w[tabla shrink], default: true, bool: true },
    shrink_score: { flat: "shrink_score", nested: %w[score shrink], default: true, bool: true },
    shrink_text: { flat: "shrink_text", nested: nil, default: false, bool: true },
    rebalance_pages: { flat: "rebalance_pages", nested: nil, default: true, bool: true },
    show_specs: { flat: "show_specs", nested: nil, default: false, bool: true },
    font_family: { flat: "font-family", nested: nil, default: "HelveticaNeue" },
    font_size: { flat: "font-size", nested: nil, default: 11.0, numeric: true },
    diags_size: { flat: "diags_size", nested: %w[diags size], default: 60.0, numeric: true },
  }.freeze

  # `meta` : hash déjà fusionné par l'appelant pour un override RUNTIME (`--transpose`,
  # sans fichier derrière) — prioritaire sur tout. `override_path` : fichier indexé du
  # `.tdm` pour cette entrée précise (souvent absent, `CarnetBuilder.resolve_infos_override_path`).
  def self.load!(meta:, infos_path:, carnet_folder:, override_path: nil)
    carnet_infos_path = carnet_folder && FileFinder.find(carnet_folder, :inf)

    # Priorité décroissante : override runtime (meta) > fichier indexé > carnet > chanson.
    sources = [source_of(override_path), source_of(carnet_infos_path), source_of(infos_path)]
    @resolved = {}
    @explicit = {}
    DEFINITIONS.each do |key, defn|
      raw = raw_value(defn, meta, sources)
      @explicit[key] = !raw.nil?
      @resolved[key] = coerce(defn, raw)
    end
  end

  def self.get(key)
    resolved = @resolved || {}
    resolved.key?(key) ? resolved[key] : DEFINITIONS[key][:default]
  end

  # Vrai si `key` a été fixée explicitement (chanson, carnet ou fichier indexé) — jamais
  # vrai pour une valeur simplement égale au défaut app (`show_specs` : n'affiche QUE ce
  # que l'user a réellement écrit quelque part, pas les valeurs par défaut silencieuses).
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

  def self.coerce(defn, raw)
    return defn[:default] if raw.nil?
    return raw.to_s[/[\d.]+/].to_f if defn[:numeric]
    return !(raw == false || raw == "false") if defn[:bool]

    raw
  end
end
