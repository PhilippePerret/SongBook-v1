require_relative "file_finder"

# Table unique de résolution des options `.infos` (chanson > carnet > défaut), formes
# plate (`shrink_diags:`) ET imbriquée (`diags: / shrink:`) acceptées à chaque étage.
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
    diags_size: { flat: "diags_size", nested: %w[diags size], default: 60.0, numeric: true, min: 48.0 },
  }.freeze

  def self.load!(meta:, infos_path:, carnet_folder:)
    @resolved = DEFINITIONS.each_with_object({}) { |(key, defn), h| h[key] = resolve(defn, meta, infos_path, carnet_folder) }
  end

  def self.get(key)
    resolved = @resolved || {}
    resolved.key?(key) ? resolved[key] : DEFINITIONS[key][:default]
  end

  def self.set!(key, value)
    (@resolved ||= {})[key] = value
  end

  def self.resolve(defn, meta, infos_path, carnet_folder)
    value = coerce(defn, raw_value(defn, meta, infos_path, carnet_folder))
    return value unless defn[:min] && value < defn[:min]

    Layout.conflict!("#{defn[:flat]} #{value}pt sous le minimum (#{defn[:min]}pt)", solution: "ramené à #{defn[:min]}pt")
    defn[:min]
  end

  def self.raw_value(defn, meta, infos_path, carnet_folder)
    return meta[defn[:flat]] if meta.key?(defn[:flat])

    v = nested(infos_path, defn[:nested])
    return v unless v.nil?

    carnet_infos_path = carnet_folder && FileFinder.find(carnet_folder, :inf)
    return defn[:default] unless carnet_infos_path

    carnet_flat = PageBuilder.parse_infos(carnet_infos_path)
    return carnet_flat[defn[:flat]] if carnet_flat.key?(defn[:flat])

    v = nested(carnet_infos_path, defn[:nested])
    v.nil? ? defn[:default] : v
  end

  def self.nested(path, keys)
    return nil unless path && keys

    node = CarnetBuilder.parse_nested_infos(path)
    keys.each { |k| node = node.is_a?(Hash) ? node[k] : nil }
    node
  end

  def self.coerce(defn, raw)
    return defn[:default] if raw.nil?
    return raw.to_s[/[\d.]+/].to_f if defn[:numeric]
    return !(raw == false || raw == "false") if defn[:bool]

    raw
  end
end
